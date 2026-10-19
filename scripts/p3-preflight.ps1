$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
$evidenceDir = Join-Path $repoRoot 'evidence'
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $evidenceDir "preflight-$stamp.log"
$sshPath = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$scpPath = Join-Path $env:WINDIR 'System32\OpenSSH\scp.exe'
$privateKey = Join-Path $env:USERPROFILE '.ssh\openclaw-server'
$netRun = Join-Path $PSScriptRoot 'net-run.ps1'
$pwshExe = Join-Path $PSHOME 'pwsh.exe'
$results = [ordered]@{
	OpenSSH = 'FAIL'
	SSH = 'FAIL'
	SCP = 'FAIL'
	COM9 = 'FAIL'
}

Start-Transcript -LiteralPath $logPath -Force | Out-Null
try {
	Write-Host "PREFLIGHT_LOG=$logPath"
	Write-Host '=== OpenSSH binaries ==='
	foreach ($path in @($sshPath, $scpPath)) {
		Write-Host "PATH=$path EXISTS=$(Test-Path -LiteralPath $path -PathType Leaf)"
	}
	if ((Test-Path -LiteralPath $sshPath -PathType Leaf) -and
		(Test-Path -LiteralPath $scpPath -PathType Leaf)) {
		& $sshPath -V 2>&1
		$sshVersionExit = $LASTEXITCODE
		if ($sshVersionExit -eq 0) { $results.OpenSSH = 'PASS' }
	}

	Write-Host '=== SSH read-only connectivity/authentication ==='
	if (Test-Path -LiteralPath $privateKey -PathType Leaf) {
		& $pwshExe -NoProfile -File $netRun ssh -vvv -o ConnectTimeout=5 -o BatchMode=yes -i $privateKey -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes root@192.168.1.1 true
		if ($LASTEXITCODE -eq 0) { $results.SSH = 'PASS' }
	} else {
		Write-Host "PRIVATE_KEY_MISSING=$privateKey"
	}

	Write-Host '=== SCP read-only file fetch ==='
	$copyPath = Join-Path $evidenceDir "preflight-$stamp-openwrt_release.txt"
	& $pwshExe -NoProfile -File $netRun scp -O -o ConnectTimeout=5 -o BatchMode=yes -i $privateKey -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes 'root@192.168.1.1:/etc/openwrt_release' $copyPath
	if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $copyPath -PathType Leaf)) {
		Get-FileHash -LiteralPath $copyPath -Algorithm SHA256 | Format-List
		$results.SCP = 'PASS'
	}

	Write-Host '=== COM9 read-only 3-second probe (115200 8N1) ==='
	$port = $null
	try {
		$port = [System.IO.Ports.SerialPort]::new('COM9', 115200, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
		$port.ReadTimeout = 100
		$port.Open()
		$timer = [Diagnostics.Stopwatch]::StartNew()
		$received = [Text.StringBuilder]::new()
		while ($timer.Elapsed.TotalSeconds -lt 3) {
			$data = $port.ReadExisting()
			if ($data.Length -gt 0) { [void]$received.Append($data) }
			Start-Sleep -Milliseconds 100
		}
		$timer.Stop()
		Write-Host "COM9_OPEN=PASS elapsed_seconds=$([math]::Round($timer.Elapsed.TotalSeconds, 2)) bytes=$($received.Length)"
		if ($received.Length -gt 0) { Write-Host "COM9_DATA=$received" }
		$results.COM9 = 'PASS'
	} catch {
		$exception = $_.Exception
		Write-Host "COM9_EXCEPTION_TYPE=$($exception.GetType().FullName)"
		Write-Host "COM9_EXCEPTION_MESSAGE=$($exception.Message)"
		if ($exception -is [UnauthorizedAccessException] -or $exception.Message -match '(?i)access is denied|unauthorized|拒绝访问') {
			Write-Host '=== COM9 owner process details ==='
			foreach ($id in 59808, 59976) {
				try {
					$proc = Get-CimInstance Win32_Process -Filter "ProcessId = $id"
					if ($proc) {
						$parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.ParentProcessId)"
						[PSCustomObject]@{
							ProcessId = $proc.ProcessId
							CommandLine = $proc.CommandLine
							ParentProcessId = $proc.ParentProcessId
						ParentCommandLine = $parent.CommandLine
							StartTime = $proc.CreationDate
							StartedByThisPreflight = $false
							HistoricalStarter = 'Unknown from process metadata'
						} | Format-List
					} else { Write-Host "PID=$id NOT_FOUND" }
				} catch { Write-Host "PID=$id QUERY_EXCEPTION=$($_.Exception.GetType().FullName): $($_.Exception.Message)" }
			}
		}
	} finally {
		if ($port -and $port.IsOpen) { $port.Close() }
	}
} finally {
	Write-Host '=== PREFLIGHT SUMMARY ==='
	foreach ($name in $results.Keys) { Write-Host "$name=$($results[$name])" }
	Stop-Transcript | Out-Null
}

if ($results.Values -contains 'FAIL') { exit 1 }
exit 0
