param(
	[Parameter(Mandatory = $true)][string]$KnownHosts,
	[int]$DurationSeconds = 7200,
	[int]$IntervalSeconds = 300
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$evidenceRoot = Join-Path $repo 'evidence'
$legacyRepo = Join-Path (Split-Path -Parent $repo) 'nanopi-release-bridge'
$serialLog = Join-Path $legacyRepo 'evidence\com9-20261020-102145.log'
$privateKey = Join-Path $env:USERPROFILE '.ssh\openclaw-server'
$netRun = Join-Path $PSScriptRoot 'net-run.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputPath = Join-Path $evidenceRoot "P4\stability-v2-$stamp.log"
$started = [DateTimeOffset]::Now
$previousBootId = $null
$previousApPresent = $null
$previousRecorderAge = 0.0

if (-not (Test-Path -LiteralPath $KnownHosts -PathType Leaf)) { throw "Known-hosts file missing: $KnownHosts" }
if (-not (Test-Path -LiteralPath $privateKey -PathType Leaf)) { throw "SSH key missing: $privateKey" }

function Get-HeartbeatAge {
	if (-not (Test-Path -LiteralPath $serialLog)) { return [double]::PositiveInfinity }
	$line = Select-String -LiteralPath $serialLog -Pattern '\] INFO HEARTBEAT pid=' | Select-Object -Last 1
	if (-not $line) { return [double]::PositiveInfinity }
	$match = [regex]::Match($line.Line, '^\[(?<stamp>[^\]]+)\]')
	if (-not $match.Success) { return [double]::PositiveInfinity }
	try { return ([DateTimeOffset]::Now - [DateTimeOffset]::Parse($match.Groups['stamp'].Value)).TotalSeconds } catch { return [double]::PositiveInfinity }
}

function Invoke-DeviceSnapshot {
	$sshArgs = @('-T', '-b', '192.168.1.222', '-o', 'ConnectTimeout=8', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes', '-o', "UserKnownHostsFile=$KnownHosts", '-i', $privateKey, 'root@192.168.1.1', 'echo SNAPSHOT; date -Iseconds; cat /proc/uptime; cat /proc/sys/kernel/random/boot_id; iw dev; wc -l /root/wifi-diag/watchdog.log 2>/dev/null')
	$output = @(& $pwsh -NoProfile -File $netRun ssh @sshArgs 2>&1)
	return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Text = ($output -join "`n") }
}

New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
"START=$($started.ToString('o')) duration_s=$DurationSeconds interval_s=$IntervalSeconds" | Set-Content -LiteralPath $outputPath -Encoding utf8
$watch = [Diagnostics.Stopwatch]::StartNew()
$iteration = 0
while ($watch.Elapsed.TotalSeconds -le $DurationSeconds) {
	$now = [DateTimeOffset]::Now
	$recorderAge = Get-HeartbeatAge
	$snapshot = Invoke-DeviceSnapshot
	if ($snapshot.ExitCode -ne 0) {
		$line = "[$($now.ToString('o'))] SAMPLE=$iteration ssh=FAIL recorder_heartbeat_age_s=$([math]::Round($recorderAge,1)) output=$($snapshot.Text -replace '[\r\n]+',' | ')"
		Add-Content -LiteralPath $outputPath -Value $line -Encoding utf8
		if ($recorderAge -gt 60) { throw "SSH unavailable and COM9 recorder heartbeat older than 60 seconds ($([math]::Round($recorderAge,1))s)." }
	} else {
		$uptime = [regex]::Match($snapshot.Text, '(?m)^([0-9]+(?:\.[0-9]+)?)\s+[0-9]+(?:\.[0-9]+)?$')
		$bootId = [regex]::Match($snapshot.Text, '(?m)^([0-9a-f-]{36})$')
		$apPresent = $snapshot.Text -match '(?m)^\s*Interface\s+phy0-ap0\s*$'
		$logLines = [regex]::Match($snapshot.Text, '(?m)^\s*([0-9]+)\s+/root/wifi-diag/watchdog\.log\s*$')
		$events = [System.Collections.Generic.List[string]]::new()
		if ($previousBootId -and $bootId.Success -and $bootId.Groups[1].Value -ne $previousBootId) { $events.Add("REBOOT boot_id=$($bootId.Groups[1].Value)") }
		if ($null -ne $previousApPresent -and $previousApPresent -and -not $apPresent) { $events.Add('AP_DISAPPEARED') }
		$eventText = if ($events.Count) { $events -join ',' } else { 'none' }
		$line = "[$($now.ToString('o'))] SAMPLE=$iteration ssh=PASS uptime_s=$($uptime.Groups[1].Value) boot_id=$($bootId.Groups[1].Value) ap_present=$apPresent watchdog_log_lines=$($logLines.Groups[1].Value) recorder_heartbeat_age_s=$([math]::Round($recorderAge,1)) events=$eventText"
		Add-Content -LiteralPath $outputPath -Value $line -Encoding utf8
		if ($events -contains 'AP_DISAPPEARED') { throw 'AP disappeared during the stability window; evidence recorded.' }
		$previousBootId = if ($bootId.Success) { $bootId.Groups[1].Value } else { $previousBootId }
		$previousApPresent = $apPresent
	}
	$iteration++
	$remaining = $DurationSeconds - $watch.Elapsed.TotalSeconds
	if ($remaining -le 0) { break }
	Start-Sleep -Seconds ([Math]::Min($IntervalSeconds, [Math]::Ceiling($remaining)))
}
$watch.Stop()
Add-Content -LiteralPath $outputPath -Value "END=$([DateTimeOffset]::Now.ToString('o')) elapsed_s=$([math]::Round($watch.Elapsed.TotalSeconds,1)) samples=$iteration" -Encoding utf8
Write-Output "STABILITY_EVIDENCE=$outputPath"
