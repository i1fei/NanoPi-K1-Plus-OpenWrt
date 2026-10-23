param(
	[Parameter(Mandatory = $true)][ValidateSet('Reboot', 'FaultInjection', 'DriverReload')][string]$Mode,
	[ValidateRange(1, 10)][int]$Rounds = 10,
	[Parameter(Mandatory = $true)][string]$KnownHosts
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$legacyRepo = Join-Path (Split-Path -Parent $repo) 'nanopi-release-bridge'
$serialLog = Join-Path $legacyRepo 'evidence\com9-20261020-102145.log'
$privateKey = Join-Path $env:USERPROFILE '.ssh\openclaw-server'
$netRun = Join-Path $PSScriptRoot 'net-run.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$evidenceDir = Join-Path $repo "evidence\device-v2-$Mode-$stamp"
$roundSummary = Join-Path $repo 'evidence\device-v2-validation.md'
$script:stopTest = $false

if (-not (Test-Path -LiteralPath $KnownHosts -PathType Leaf)) { throw "Known-hosts file missing: $KnownHosts" }
if (-not (Test-Path -LiteralPath $privateKey -PathType Leaf)) { throw "SSH key missing: $privateKey" }
if (-not (Test-Path -LiteralPath $serialLog -PathType Leaf)) { throw "COM9 recorder log missing: $serialLog" }
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
$resultsPath = Join-Path $evidenceDir 'results.md'
$tableHeader = if ($Mode -eq 'Reboot') {
	"| Round | Boot ID | phy0 uptime | phy0-ap0 first uptime | Watchdog HEALTH/stages | Reboot uptime(s) | Final uptime | Snapshot |`n|---:|---|---:|---:|---|---|---:|---|"
} elseif ($Mode -eq 'FaultInjection') {
	"| Round | Injection | T0 uptime | AP recovery observations | Stage 2 | Stage 3 | Reboot count | phy0/AP serial uptime |`n|---:|---|---:|---|---|---|---:|---|"
} else {
	"| Operation | T0 uptime | Exact command sequence | AP result | Watchdog events | Evidence |`n|---|---:|---|---|---|---|"
}
[IO.File]::WriteAllText($resultsPath, $tableHeader + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

function Write-Evidence([string]$Path, [string]$Text) {
	[IO.File]::AppendAllText($Path, $Text + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Add-Event([string]$Text) {
	$line = "[$([DateTimeOffset]::Now.ToString('o'))] $Text"
	Write-Evidence (Join-Path $evidenceDir 'runner.log') $line
	Write-Host $line
}

function Get-SerialAge {
	try { return ([DateTimeOffset]::Now - (Get-Item -LiteralPath $serialLog).LastWriteTime).TotalSeconds }
	catch { return [double]::PositiveInfinity }
}

function Assert-CombinedConnectivity([int]$SshFailureSeconds) {
	$age = Get-SerialAge
	if ($age -gt 60 -and $SshFailureSeconds -ge 60) {
		Add-Event "STOP both channels unavailable: serial_age_s=$([math]::Round($age,1)) ssh_failure_s=$SshFailureSeconds"
		$script:stopTest = $true
		throw 'COM9 recorder and SSH have both been unavailable for more than 60 seconds.'
	}
}

function Invoke-SSH([string]$Command, [string]$Name, [int]$TimeoutSeconds = 15) {
	$sshArgs = @('-T', '-b', '192.168.1.222', '-o', "ConnectTimeout=$TimeoutSeconds", '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes', '-o', "UserKnownHostsFile=$KnownHosts", '-i', $privateKey, 'root@192.168.1.1', $Command)
	$output = @(& $pwsh -NoProfile -File $netRun ssh @sshArgs 2>&1)
	$code = $LASTEXITCODE
	$path = Join-Path $evidenceDir $Name
	[IO.File]::WriteAllLines($path, [string[]]$output, [Text.UTF8Encoding]::new($false))
	return [PSCustomObject]@{ ExitCode = $code; Text = ($output -join "`n"); Path = $path }
}

function Get-Snapshot([string]$Name) {
	return Invoke-SSH 'echo SNAPSHOT; cat /proc/uptime; cat /proc/sys/kernel/random/boot_id; iw dev; echo WATCHDOG_EVENTS; grep -E "HEALTH|health recovered|recovery stage [123]:|stage3 aborted|reboot suppressed by cooldown" /root/wifi-diag/watchdog.log 2>/dev/null || true' $Name
}

function Get-Uptime([string]$Text) {
	$m = [regex]::Match($Text, '(?m)^([0-9]+(?:\.[0-9]+)?)\s+[0-9]+(?:\.[0-9]+)?$')
	if ($m.Success) { return [double]$m.Groups[1].Value }
	return $null
}

function Get-BootId([string]$Text) {
	$m = [regex]::Match($Text, '(?m)^([0-9a-f]{8}-[0-9a-f-]{27,})$')
	if ($m.Success) { return $m.Groups[1].Value }
	return $null
}

function Test-AP([string]$Text) {
	foreach ($block in [regex]::Matches($Text, '(?ms)^\s*Interface\s+[^\r\n]+.*?(?=^\s*Interface\s+|^phy#|\z)')) {
		if ($block.Value -match 'phy0-ap0' -and $block.Value -match '(?m)^\s*type\s+AP\s*$') { return $true }
	}
	return $false
}

function Get-SerialSegment([long]$Offset, [string]$Path) {
	$stream = [IO.File]::Open($serialLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
	try {
		$stream.Position = [Math]::Min($Offset, $stream.Length)
		$reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
		$text = $reader.ReadToEnd()
		[IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
		return $text
	} finally { $stream.Dispose() }
}

function Get-SerialOffset { return [long](Get-Item -LiteralPath $serialLog).Length }

function Wait-SSHBoot([string]$PreviousBootId, [string]$Prefix) {
	$failedSince = $null
	while ($true) {
		$snapshot = Get-Snapshot "$Prefix-ssh-probe.log"
		if ($snapshot.ExitCode -eq 0) {
			$failedSince = $null
			$bootId = Get-BootId $snapshot.Text
			if ($bootId -and $bootId -ne $PreviousBootId) { return $snapshot }
		} else {
			if ($null -eq $failedSince) { $failedSince = [DateTimeOffset]::Now }
			Assert-CombinedConnectivity ([int]([DateTimeOffset]::Now - $failedSince).TotalSeconds)
		}
		Start-Sleep -Seconds 10
	}
}

function Wait-Uptime([string]$BootId, [double]$Target, [string]$Prefix) {
	$failedSince = $null
	$firstAp = $null
	$rebootIds = [System.Collections.Generic.List[string]]::new()
	while ($true) {
		$snapshot = Get-Snapshot "$Prefix-sample.log"
		if ($snapshot.ExitCode -eq 0) {
			$failedSince = $null
			$currentBoot = Get-BootId $snapshot.Text
			$up = Get-Uptime $snapshot.Text
			if ($currentBoot -and $currentBoot -ne $BootId) {
				$rebootIds.Add($currentBoot)
				Add-Event "$Prefix unexpected boot change $BootId -> $currentBoot"
				$BootId = $currentBoot
			}
			if ((Test-AP $snapshot.Text) -and $null -eq $firstAp) { $firstAp = $up; Add-Event "$Prefix AP observed by SSH at uptime=$up" }
			if ($null -ne $up -and $up -ge $Target) {
				return [PSCustomObject]@{ Snapshot = $snapshot; Uptime = $up; FirstAP = $firstAp; BootId = $BootId; Reboots = ($rebootIds -join ',') }
			}
		} else {
			if ($null -eq $failedSince) { $failedSince = [DateTimeOffset]::Now }
			Assert-CombinedConnectivity ([int]([DateTimeOffset]::Now - $failedSince).TotalSeconds)
		}
		Start-Sleep -Seconds 15
	}
}

function Save-Watchdog([string]$Prefix) {
	$result = Invoke-SSH 'cat /root/wifi-diag/watchdog.log 2>/dev/null || true' "$Prefix-watchdog.log" 30
	if ($result.ExitCode -ne 0) { throw "Cannot retrieve watchdog log for $Prefix." }
	return $result.Text
}

function Save-Serial([long]$Offset, [string]$Prefix) {
	$serialText = Get-SerialSegment $Offset (Join-Path $evidenceDir "$Prefix-com9.log")
	$phy = [regex]::Match($serialText, '\[\s*([0-9]+(?:\.[0-9]+)?)\].{0,180}(?:wiphy_register\(phy0\)|phy0.*registered)')
	$ap = [regex]::Match($serialText, '\[\s*([0-9]+(?:\.[0-9]+)?)\].{0,220}phy0-ap0')
	return [PSCustomObject]@{ Text = $serialText; Phy = $(if($phy.Success){$phy.Groups[1].Value}else{'not-recorded'}); AP = $(if($ap.Success){$ap.Groups[1].Value}else{'not-recorded'}) }
}

if ($Mode -eq 'Reboot') {
	for ($round = 1; $round -le $Rounds; $round++) {
		$prefix = 'reboot-{0:d2}' -f $round
		$before = Get-Snapshot "$prefix-before.log"
		if ($before.ExitCode -ne 0) { throw "Cannot read pre-reboot state for $prefix." }
		$oldBoot = Get-BootId $before.Text
		$offset = Get-SerialOffset
		Add-Event "$prefix request reboot boot_id=$oldBoot uptime=$(Get-Uptime $before.Text)"
		$reboot = Invoke-SSH 'reboot' "$prefix-reboot-command.log" 10
		Add-Event "$prefix reboot command exit=$($reboot.ExitCode) output=$($reboot.Text -replace '[\r\n]+',' | ')"
		$boot = Wait-SSHBoot $oldBoot $prefix
		$bootId = Get-BootId $boot.Text
		$initialUptime = Get-Uptime $boot.Text
		Add-Event "$prefix new boot observed boot_id=$bootId uptime=$initialUptime"
		$finish = Wait-Uptime $bootId 600 $prefix
		$watchdog = Save-Watchdog $prefix
		$serial = Save-Serial $offset $prefix
		$stage = @($watchdog -split "`n" | Where-Object { $_ -match 'health recovered|recovery stage [123]:|stage3 aborted|HEALTH|reboot suppressed by cooldown' }) -join ' || '
		$reboots = @([regex]::Matches($serial.Text, '\[\s*([0-9]+(?:\.[0-9]+)?)\].{0,80}reboot: Restarting system') | ForEach-Object { $_.Groups[1].Value }) -join ','
		$line = "| $round | $bootId | $($serial.Phy) | $($serial.AP) | $stage | $reboots | $($finish.Uptime) | $($finish.Snapshot.Path) |"
		Write-Evidence (Join-Path $evidenceDir 'results.md') $line
		Add-Event "$prefix complete phy0=$($serial.Phy) phy0-ap0=$($serial.AP) uptime=$($finish.Uptime) reboots=$reboots"
		Write-Output "RESULT=$line"
	}
}

if ($Mode -eq 'FaultInjection') {
	for ($round = 1; $round -le 6; $round++) {
		$kind = if ($round -le 3) { 'delete-ap' } else { 'kill-hostapd' }
		$prefix = 'fault-{0:d2}-{1}' -f $round, $kind
		$stable = 0
		$sshFailedAt = $null
		while ($stable -lt 60) {
			$snapshot = Get-Snapshot "$prefix-stability.log"
			if ($snapshot.ExitCode -ne 0) {
				if ($null -eq $sshFailedAt) { $sshFailedAt = [DateTimeOffset]::Now }
				Assert-CombinedConnectivity ([int]([DateTimeOffset]::Now - $sshFailedAt).TotalSeconds)
				Start-Sleep 5
				continue
			}
			$sshFailedAt = $null
			if (Test-AP $snapshot.Text) { $stable += 5 } else { $stable = 0 }
			Start-Sleep -Seconds 5
		}
		$pre = Get-Snapshot "$prefix-pre.log"
		if ($pre.ExitCode -ne 0 -or -not (Test-AP $pre.Text)) { throw "$prefix precondition AP not present." }
		$offset = Get-SerialOffset
		$t0 = Get-Uptime $pre.Text
		$lineCountResult = Invoke-SSH 'wc -l < /root/wifi-diag/watchdog.log 2>/dev/null || echo 0' "$prefix-watchdog-linecount.log" 10
		if ($lineCountResult.ExitCode -ne 0 -or $lineCountResult.Text -notmatch '(?m)^\s*\d+\s*$') { throw "$prefix cannot establish watchdog log boundary." }
		$watchdogLineCount = [int]([regex]::Match($lineCountResult.Text, '(?m)^\s*(\d+)\s*$').Groups[1].Value)
		$injection = if ($round -le 3) { 'iw dev phy0-ap0 del' } else { 'killall hostapd' }
		$cmd = @(
			'start=$(cut -d. -f1 /proc/uptime); base=__BASE__; echo T0_UPTIME=$start; __INJECTION__; echo INJECTION_RC=$?; last=; i=0'
			'while [ $i -le 600 ]; do'
				'now=$(cut -d. -f1 /proc/uptime)'
				'ap=$(iw dev 2>/dev/null | awk ''$1=="Interface"{n=$2} $1=="type" && $2=="AP" && n=="phy0-ap0"{print n; exit}'')'
				'ev=$(tail -n +$((base+1)) /root/wifi-diag/watchdog.log 2>/dev/null | grep -E ''recovery stage 2:|recovery stage 3:|stage3 aborted|reboot suppressed by cooldown'' | tail -n 1)'
				'state=$(if [ -n "$ap" ]; then echo AP; else echo NOAP; fi)'
				'if [ "$state|$ev" != "$last" ]; then echo "OBS uptime=$now ap=$state event=$ev"; last="$state|$ev"; fi'
				'case "$ev" in *''recovery stage 3:''*|*''stage3 aborted''*|*''reboot suppressed by cooldown''*) echo "STOP_STAGE3 uptime=$now"; exit 0;; esac'
				'if [ "$state" = AP ]; then echo "AP_RECOVERED uptime=$now elapsed=$((now-start))"; exit 0; fi'
				'sleep 1; i=$((i+1))'
			'done'
			'echo "AP_TIMEOUT uptime=$(cut -d. -f1 /proc/uptime)"; exit 0'
		) -join "`n"
		$cmd = $cmd.Replace('__INJECTION__', $injection).Replace('__BASE__', [string]$watchdogLineCount)
		$result = Invoke-SSH $cmd "$prefix-monitor.log" 660
		if ($result.ExitCode -ne 0) {
			Add-Event "$prefix monitor SSH exit=$($result.ExitCode) $($result.Text -replace '[\r\n]+',' | ')"
			$wd = Save-Watchdog $prefix
			$newWd = @($wd -split "`n" | Select-Object -Skip $watchdogLineCount) -join "`n"
			$serial = Save-Serial $offset $prefix
			if ($newWd -match 'recovery stage 3:|stage3 aborted' -or $serial.Text -match 'reboot: Restarting system') { throw "$prefix entered stage 3 or rebooted; stopped after preserving evidence." }
			throw "$prefix remote monitor failed; stopped after preserving evidence."
		}
		$monitor = $result.Text
		$watchdog = Save-Watchdog $prefix
		$newWatchdog = @($watchdog -split "`n" | Select-Object -Skip $watchdogLineCount)
		$logread = Invoke-SSH 'logread' "$prefix-logread.log" 30
		$serial = Save-Serial $offset $prefix
		$stage2 = @($newWatchdog | Where-Object { $_ -match 'recovery stage 2:' })
		$stage3 = @($newWatchdog | Where-Object { $_ -match 'recovery stage 3:|stage3 aborted|reboot suppressed by cooldown' })
		$rebootRows = @([regex]::Matches($serial.Text, '\[\s*([0-9]+(?:\.[0-9]+)?)\].{0,80}reboot: Restarting system'))
		$line = "| $round | $kind | $t0 | $($monitor -replace '[\r\n]+','; ') | stage2=$($stage2 -join ';') | stage3=$($stage3 -join ';') | reboot=$rebootRows.Count | $($serial.Phy)/$($serial.AP) |"
		Write-Evidence $resultsPath $line
		Add-Event "$prefix result $line"
		if ($stage3.Count -gt 0 -or $rebootRows.Count -gt 0) { throw "$prefix entered stage 3 or rebooted; stopped after preserving evidence." }
		if ($round -lt 6) {
			Add-Event "$prefix waiting for AP stable for 300 seconds before next injection"
			$stable = 0
			$sshFailedAt = $null
			while ($stable -lt 300) {
				$snapshot = Get-Snapshot "$prefix-stable-gap.log"
				if ($snapshot.ExitCode -ne 0) {
					if ($null -eq $sshFailedAt) { $sshFailedAt = [DateTimeOffset]::Now }
					Assert-CombinedConnectivity ([int]([DateTimeOffset]::Now - $sshFailedAt).TotalSeconds)
					Start-Sleep 5
					continue
				}
				$sshFailedAt = $null
				if (Test-AP $snapshot.Text) { $stable += 5 } else { $stable = 0 }
				Start-Sleep -Seconds 5
			}
		}
	}
}

if ($Mode -eq 'DriverReload') {
	$prefix = 'driver-reload'
	$stable = 0
	$sshFailedAt = $null
	while ($stable -lt 60) {
		$snapshot = Get-Snapshot "$prefix-stability.log"
		if ($snapshot.ExitCode -ne 0) {
			if ($null -eq $sshFailedAt) { $sshFailedAt = [DateTimeOffset]::Now }
			Assert-CombinedConnectivity ([int]([DateTimeOffset]::Now - $sshFailedAt).TotalSeconds)
			Start-Sleep 5
			continue
		}
		$sshFailedAt = $null
		if (Test-AP $snapshot.Text) { $stable += 5 } else { $stable = 0 }
		Start-Sleep -Seconds 5
	}
	$before = Get-Snapshot "$prefix-before.log"
	if ($before.ExitCode -ne 0 -or -not (Test-AP $before.Text)) { throw 'Driver reload precondition AP not present.' }
	$offset = Get-SerialOffset
	$startUptime = Get-Uptime $before.Text
	$lineCountResult = Invoke-SSH 'wc -l < /root/wifi-diag/watchdog.log 2>/dev/null || echo 0' "$prefix-watchdog-linecount.log" 10
	if ($lineCountResult.ExitCode -ne 0 -or $lineCountResult.Text -notmatch '(?m)^\s*\d+\s*$') { throw 'Cannot establish watchdog log boundary before driver reload.' }
	$watchdogLineCount = [int]([regex]::Match($lineCountResult.Text, '(?m)^\s*(\d+)\s*$').Groups[1].Value)
	Add-Event "$prefix exact source sequence: /sbin/kmodloader -r rtl8189es; /sbin/kmodloader rtl8189es; wifi reload"
	$background = "( /sbin/kmodloader -r rtl8189es; r1=`$?; echo kmodloader_remove_rc=`$r1; /sbin/kmodloader rtl8189es; r2=`$?; echo kmodloader_load_rc=`$r2; wifi reload; r3=`$?; echo wifi_reload_rc=`$r3 ) >/tmp/p4-driver-reload.log 2>&1 </dev/null &"
	$launch = Invoke-SSH $background "$prefix-launch.log" 15
	if ($launch.ExitCode -ne 0) { throw 'Could not launch source-equivalent driver reload sequence.' }
	$monitorCommand = @(
		'start=$(cut -d. -f1 /proc/uptime); base=__BASE__; i=0; last='
		'while [ $i -le 600 ]; do'
			'now=$(cut -d. -f1 /proc/uptime)'
			'ap=$(iw dev 2>/dev/null | awk ''$1=="Interface"{n=$2} $1=="type" && $2=="AP" && n=="phy0-ap0"{print n; exit}'')'
		'ev=$(tail -n +$((base+1)) /root/wifi-diag/watchdog.log 2>/dev/null | grep -E ''recovery stage [123]:|stage3 aborted|health recovered'' | tail -n 1)'
			'state=$(if [ -n "$ap" ]; then echo AP; else echo NOAP; fi)'
			'if [ "$state|$ev" != "$last" ]; then echo "OBS uptime=$now ap=$state event=$ev"; last="$state|$ev"; fi'
			'case "$ev" in *''recovery stage 3:''*|*''stage3 aborted''*) echo "STOP_STAGE3 uptime=$now"; exit 0;; esac'
			'if [ "$state" = AP ]; then echo "AP_RECOVERED uptime=$now elapsed=$((now-start))"; exit 0; fi'
			'sleep 1; i=$((i+1))'
		'done'
		'echo "AP_TIMEOUT uptime=$(cut -d. -f1 /proc/uptime)"'
	) -join "`n"
	$monitorCommand = $monitorCommand.Replace('__BASE__', [string]$watchdogLineCount)
	$monitor = Invoke-SSH $monitorCommand "$prefix-monitor.log" 660
	$watchdog = Save-Watchdog $prefix
	$newWatchdog = @($watchdog -split "`n" | Select-Object -Skip $watchdogLineCount) -join "`n"
	$cycle = Invoke-SSH 'cat /tmp/p4-driver-reload.log 2>/dev/null || true' "$prefix-command-output.log" 20
	$serial = Save-Serial $offset $prefix
	if ($monitor.ExitCode -ne 0 -or $monitor.Text -match 'STOP_STAGE3|AP_TIMEOUT' -or $newWatchdog -match 'recovery stage 3:|stage3 aborted' -or $serial.Text -match 'reboot: Restarting system') {
		throw 'Driver reload reached a stop condition; raw evidence was saved.'
	}
	$watchdogEvents = @($newWatchdog -split "`n" | Where-Object { $_ -match 'HEALTH|health recovered|recovery stage [123]:' }) -join '; '
	Write-Evidence $resultsPath "| rtl8189es | $startUptime | /sbin/kmodloader -r rtl8189es; /sbin/kmodloader rtl8189es; wifi reload | $($monitor.Text -replace '[\r\n]+','; ') | $watchdogEvents | $evidenceDir |"
	Add-Event "$prefix complete start_uptime=$startUptime result=$($monitor.Text -replace '[\r\n]+','; ') command_output=$($cycle.Text -replace '[\r\n]+','; ')"
}

if (-not (Test-Path -LiteralPath $roundSummary)) {
	"# Device v2 validation`n`nEvidence directories: evidence/device-v2-*" | Set-Content -LiteralPath $roundSummary -Encoding utf8
}
Add-Content -LiteralPath $roundSummary -Value "`n- $Mode evidence: $($evidenceDir.Replace($repo + '\',''))" -Encoding utf8
Add-Event "MODE_COMPLETE mode=$Mode evidence=$evidenceDir"
Write-Output "EVIDENCE_DIR=$evidenceDir"
