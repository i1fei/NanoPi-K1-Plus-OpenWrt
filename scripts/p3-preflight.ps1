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

function Write-ComProcessAudit {
	try {
		$all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
		$pattern = '(?i)COM9|serial|SerialPort|pyserial|putty|plink|teraterm|minicom|com-bridge'
		$matches = @($all | Where-Object {
			$_.ProcessId -in 59808, 59976 -or $_.Name -match $pattern -or $_.CommandLine -match $pattern
		})
		foreach ($proc in $matches) {
			[PSCustomObject]@{
				ProcessId = $proc.ProcessId
				ParentProcessId = $proc.ParentProcessId
				Name = $proc.Name
				CommandLine = $proc.CommandLine
				CreationDate = $proc.CreationDate
				ExecutablePath = $proc.ExecutablePath
			} | Format-List
			$current = $proc
			for ($depth = 0; $depth -lt 12 -and $current.ParentProcessId; $depth++) {
				$parent = $all | Where-Object ProcessId -eq $current.ParentProcessId | Select-Object -First 1
				if (-not $parent) { break }
				Write-Host "PARENT_CHAIN depth=$($depth + 1) PID=$($parent.ProcessId) PPID=$($parent.ParentProcessId) NAME=$($parent.Name) CREATED=$($parent.CreationDate) PATH=$($parent.ExecutablePath) COMMAND=$($parent.CommandLine)"
				$current = $parent
			}
		}
	} catch {
		Write-Host "PROCESS_AUDIT_EXCEPTION=$($_.Exception.GetType().FullName): $($_.Exception.Message)"
	}
	try {
		Write-Host "COM_PORT_NAMES=$([string]::Join(',', [System.IO.Ports.SerialPort]::GetPortNames()))"
	} catch {
		Write-Host "COM_PORT_NAMES_EXCEPTION=$($_.Exception.GetType().FullName): $($_.Exception.Message)"
	}
}

function Get-DevicePropertyData([string]$InstanceId, [string]$KeyName) {
	try {
		(Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction Stop).Data
	} catch { $null }
}

function Write-ComPnpState {
	try {
		$devices = @(Get-PnpDevice -Class Ports -ErrorAction Stop | Where-Object FriendlyName -match '\(COM9\)')
		if (-not $devices) { Write-Host 'COM9_PNP_DEVICE=NOT_FOUND' }
		foreach ($device in $devices) {
			[PSCustomObject]@{
				FriendlyName = $device.FriendlyName
				Status = $device.Status
				InstanceId = $device.InstanceId
				ProblemCode = Get-DevicePropertyData $device.InstanceId 'DEVPKEY_Device_ProblemCode'
				DriverDescription = Get-DevicePropertyData $device.InstanceId 'DEVPKEY_Device_DriverDesc'
				DriverVersion = Get-DevicePropertyData $device.InstanceId 'DEVPKEY_Device_DriverVersion'
				DriverProvider = Get-DevicePropertyData $device.InstanceId 'DEVPKEY_Device_DriverProvider'
			} | Format-List
			$parentId = Get-DevicePropertyData $device.InstanceId 'DEVPKEY_Device_Parent'
			for ($depth = 0; $parentId -and $depth -lt 8; $depth++) {
				$parent = Get-PnpDevice -InstanceId $parentId -ErrorAction SilentlyContinue
				$present = $false
				if ($parent) {
					$present = [bool](Get-DevicePropertyData $parentId 'DEVPKEY_Device_IsPresent')
					[PSCustomObject]@{
						USBParentDepth = $depth + 1
						FriendlyName = $parent.FriendlyName
						Status = $parent.Status
						Present = $present
						InstanceId = $parent.InstanceId
						ProblemCode = Get-DevicePropertyData $parentId 'DEVPKEY_Device_ProblemCode'
					} | Format-List
				}
				if ($parentId -match '^USB\\VID_' -or $parentId -match '^USB\\ROOT_HUB') { break }
				$parentId = Get-DevicePropertyData $parentId 'DEVPKEY_Device_Parent'
			}
		}
	} catch {
		Write-Host "COM9_PNP_EXCEPTION=$($_.Exception.GetType().FullName): $($_.Exception.Message)"
	}
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
	Write-ComPnpState
	$port = $null
	try {
		$port = [System.IO.Ports.SerialPort]::new('COM9', 115200)
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
		$level = 0
		while ($exception -and $level -lt 10) {
			Write-Host "COM9_EXCEPTION[$level]_TYPE=$($exception.GetType().FullName)"
			Write-Host "COM9_EXCEPTION[$level]_MESSAGE=$($exception.Message)"
			$exception = $exception.InnerException
			$level++
		}
		Write-Host '=== COM9 failure process audit ==='
		Write-ComProcessAudit
		Write-Host '=== Visible serial-capable applications (read-only) ==='
		Get-Process -ErrorAction SilentlyContinue |
			Where-Object { $_.ProcessName -match '(?i)putty|terminal|serial|arduino|teraterm|tterm|securecrt|realterm|minicom|plink|xshell|mobaxterm|tabby|windterm' } |
			Select-Object Id,ProcessName,MainWindowTitle,StartTime,Path | Format-Table -AutoSize
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
