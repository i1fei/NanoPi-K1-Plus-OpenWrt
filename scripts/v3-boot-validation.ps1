[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$ImagePath,
	[Parameter(Mandatory = $true)][string]$ImageSha256,
	[Parameter(Mandatory = $true)][string]$WatchdogSha256,
	[Parameter(Mandatory = $true)][string]$RunId,
	[Parameter(Mandatory = $true)][string]$SerialLog,
	[Parameter(Mandatory = $true)][string]$CommandDirectory,
	[Parameter(Mandatory = $true)][string]$KnownHosts,
	[Parameter(Mandatory = $true)][string]$PrivateKey,
	[Parameter(Mandatory = $true)][string]$EvidenceRoot,
	[int]$PriorFlashCount = 22,
	[int]$FlashLimit = 30
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$netRun = Join-Path $PSScriptRoot 'net-run.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$sshKeygen = Join-Path $env:WINDIR 'System32/OpenSSH/ssh-keygen.exe'
$remoteImage = "/tmp/v3-$RunId.img.gz"
$script:serialOffset = 0L
$script:bootNumber = 0
$script:events = [System.Collections.Generic.List[object]]::new()
$script:lastBootWall = $null
$script:serialGapReported = $false

function Add-Event([string]$Name, [string]$Detail) {
	$line = '[{0}] {1} {2}' -f [DateTimeOffset]::Now.ToString('o'), $Name, $Detail
	[IO.File]::AppendAllText((Join-Path $EvidenceRoot 'validation.log'), $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
	Write-Host $line
}

function Get-SerialDelta {
	$stream = [IO.File]::Open($SerialLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
	try {
		if ($script:serialOffset -gt $stream.Length) {
			Add-Event 'COM9_LOG_TRUNCATED' "old_offset=$script:serialOffset new_length=$($stream.Length); continuing from current end"
			$script:serialOffset = $stream.Length
		}
		$stream.Position = $script:serialOffset
		$reader = [IO.StreamReader]::new($stream)
		$text = $reader.ReadToEnd()
		$script:serialOffset = $stream.Length
		return $text
	} finally { $stream.Dispose() }
}

function Assert-Recorder {
	$heartbeat = Select-String -LiteralPath $SerialLog -Pattern '\] INFO HEARTBEAT pid=' | Select-Object -Last 1
	$heartbeatAge = [double]::PositiveInfinity
	if ($heartbeat) {
		$stamp = [regex]::Match($heartbeat.Line, '^\[(?<t>[^\]]+)\]').Groups['t'].Value
		try { $heartbeatAge = ([DateTimeOffset]::Now - [DateTimeOffset]::Parse($stamp)).TotalSeconds } catch {}
	}
	$recentError = Select-String -LiteralPath $SerialLog -Pattern '\] ERROR ' | Select-Object -Last 1
	$lastOpen = Select-String -LiteralPath $SerialLog -Pattern 'COM9_OPEN=PASS' | Select-Object -Last 1
	$stale = $heartbeatAge -gt 30 -or ($recentError -and $lastOpen -and $recentError.LineNumber -gt $lastOpen.LineNumber)
	if ($stale -and -not $script:serialGapReported) {
		Add-Event 'COM9_LOGGING_GAP' "heartbeat_age_seconds=$([math]::Round($heartbeatAge,1)); SSH fallback will be checked after the observation window"
		$script:serialGapReported = $true
	} elseif (-not $stale) {
		$script:serialGapReported = $false
	}
}

function Invoke-SSH([string]$Command, [string]$OutputPath, [int]$Timeout = 10) {
	$args = @('-T', '-o', "ConnectTimeout=$Timeout", '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes', '-o', "UserKnownHostsFile=$KnownHosts", '-i', $PrivateKey, 'root@192.168.1.1', $Command)
	$out = @(& $pwsh -NoProfile -File $netRun ssh @args 2>&1)
	$rc = $LASTEXITCODE
	if ($OutputPath) { [IO.File]::WriteAllLines($OutputPath, [string[]]$out, [Text.UTF8Encoding]::new($false)) }
	return [pscustomobject]@{ ExitCode = $rc; Text = ($out -join [Environment]::NewLine) }
}

function Invoke-SCP([string[]]$Args, [string]$OutputPath) {
	$out = @(& $pwsh -NoProfile -File $netRun scp -O -o ConnectTimeout=10 -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KnownHosts" -i $PrivateKey @Args 2>&1)
	$rc = $LASTEXITCODE
	[IO.File]::WriteAllLines($OutputPath, [string[]]$out, [Text.UTF8Encoding]::new($false))
	if ($rc -ne 0) { throw "SCP failed (rc=$rc): $($out -join ' ')" }
}

function Send-SerialCommand([string]$Command, [string]$Label, [int]$Timeout = 60) {
	Assert-Recorder
	$marker = "V3_${Label}_$([guid]::NewGuid().ToString('N'))"
	$file = Join-Path $CommandDirectory (('{0:D13}-{1}.cmd' -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds(), $Label))
	[IO.File]::WriteAllText($file, "$Command; echo $marker`n", [Text.UTF8Encoding]::new($false))
	$watch = [Diagnostics.Stopwatch]::StartNew()
	$buffer = ''
	while ($watch.Elapsed.TotalSeconds -lt $Timeout) {
		$buffer += Get-SerialDelta
		if ($buffer.Contains($marker)) { return $buffer }
		Start-Sleep -Milliseconds 250
	}
	throw "COM9 command marker timed out: $Label"
}

function Restore-SSHFromSerial([string]$BootDirectory) {
	$wakeFile = Join-Path $CommandDirectory (('{0:D13}-wake.cmd' -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds()))
	[IO.File]::WriteAllText($wakeFile, "`n", [Text.UTF8Encoding]::new($false))
	$timer = [Diagnostics.Stopwatch]::StartNew()
	$promptText = ''
	while ($timer.Elapsed.TotalSeconds -lt 60) {
		$promptText += Get-SerialDelta
		if ($promptText -match 'root@[^\s]+:~#') { break }
		Start-Sleep -Milliseconds 250
	}
	if ($promptText -notmatch 'root@[^\s]+:~#') { throw 'COM9 shell prompt not observed after newline wake.' }
	$hostResult = Send-SerialCommand 'dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key' 'hostkey' 45
	$hostText = $promptText + $hostResult
	[IO.File]::WriteAllText((Join-Path $BootDirectory 'hostkey-com9-transcript.log'), $hostText, [Text.UTF8Encoding]::new($false))
	$pubMatch = [regex]::Match($hostText, '(ssh-ed25519\s+[A-Za-z0-9+/]+={0,2}(?:\s+root@[^\s]+)?)')
	if (-not $pubMatch.Success) { throw 'COM9 did not return a device ED25519 public key.' }
	$pubPath = Join-Path $BootDirectory 'device-hostkey-from-com9.pub'
	[IO.File]::WriteAllText($pubPath, $pubMatch.Value.Trim() + "`n", [Text.ASCIIEncoding]::new())
	$serialFpOut = @(& $sshKeygen -lf $pubPath -E sha256 2>&1)
	$serialFp = [regex]::Match(($serialFpOut -join ' '), 'SHA256:[A-Za-z0-9+/]+').Value
	if (-not $serialFp) { throw 'Could not calculate the COM9 device host-key fingerprint.' }
	$probeHosts = Join-Path $BootDirectory 'known_hosts.probe'
	$probeArgs = @('-vvv','-T','-o','ConnectTimeout=5','-o','BatchMode=yes','-o','PreferredAuthentications=none','-o','PubkeyAuthentication=no','-o','PasswordAuthentication=no','-o','StrictHostKeyChecking=accept-new','-o','HashKnownHosts=no','-o',"UserKnownHostsFile=$probeHosts",'root@192.168.1.1','true')
	$probe = @(& $pwsh -NoProfile -File $netRun ssh @probeArgs 2>&1)
	[IO.File]::WriteAllLines((Join-Path $BootDirectory 'ssh-hostkey-probe.log'), [string[]]$probe, [Text.UTF8Encoding]::new($false))
	$sshFp = [regex]::Match(($probe -join "`n"), 'Server host key: ssh-ed25519 \(?(SHA256:[A-Za-z0-9+/]+)\)?').Groups[1].Value
	$hostLine = Get-Content -LiteralPath $probeHosts -ErrorAction SilentlyContinue | Where-Object { $_ -match '^192\.168\.1\.1\s+ssh-ed25519\s+' } | Select-Object -First 1
	if (-not $sshFp -or -not $hostLine) { throw 'SSH did not provide a host key for fingerprint comparison.' }
	if ($serialFp -ne $sshFp) { throw "Host-key mismatch: COM9=$serialFp SSH=$sshFp; verified known_hosts unchanged." }
	$verifiedHosts = Join-Path $BootDirectory 'known_hosts.verified'
	[IO.File]::WriteAllText($verifiedHosts, $hostLine + "`n", [Text.ASCIIEncoding]::new())
	$script:KnownHosts = $verifiedHosts
	Add-Event 'HOSTKEY_MATCH' "COM9=$serialFp SSH=$sshFp boot=$($BootDirectory | Split-Path -Leaf)"
	$auth = Invoke-SSH 'true' (Join-Path $BootDirectory 'ssh-auth-probe.log') 5
	if ($auth.ExitCode -ne 0) {
		$publicKey = (Get-Content -Raw -LiteralPath "$PrivateKey.pub").Trim()
		if ($publicKey -notmatch '^ssh-ed25519\s+[A-Za-z0-9+/]+={0,2}(\s+[^\r\n]+)?$') { throw 'SSH client public key is not a single ED25519 key.' }
		$keyBase64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($publicKey))
		$null = Send-SerialCommand "mkdir -p /etc/dropbear; printf '%s' '$keyBase64' | base64 -d > /etc/dropbear/authorized_keys; printf '\n' >> /etc/dropbear/authorized_keys; chown root:root /etc/dropbear /etc/dropbear/authorized_keys; chmod 700 /etc/dropbear; chmod 600 /etc/dropbear/authorized_keys; /etc/init.d/dropbear restart" 'ssh-key-install' 90
		$timer = [Diagnostics.Stopwatch]::StartNew()
		while ($timer.Elapsed.TotalSeconds -lt 120) {
			$auth = Invoke-SSH 'true' (Join-Path $BootDirectory 'ssh-auth-probe.log') 5
			if ($auth.ExitCode -eq 0) { break }
			Start-Sleep -Seconds 3
		}
		if ($auth.ExitCode -ne 0) { throw 'SSH authentication did not recover after COM9 authorized_keys installation.' }
	}
	Add-Event 'SSH_READY' "boot=$($BootDirectory | Split-Path -Leaf); hostkey=$serialFp"
}

function Wait-NewBoot([int]$Timeout = 240) {
	$timer = [Diagnostics.Stopwatch]::StartNew()
	$buffer = ''
	while ($timer.Elapsed.TotalSeconds -lt $Timeout) {
		Assert-Recorder
		$buffer += Get-SerialDelta
		if ($buffer -match 'Booting Linux on physical CPU') {
			$script:bootNumber++
			$script:lastBootWall = [DateTimeOffset]::Now
			$bootDir = Join-Path $EvidenceRoot ('boot-{0:D2}' -f $script:bootNumber)
			New-Item -ItemType Directory -Force -Path $bootDir | Out-Null
			[IO.File]::WriteAllText((Join-Path $bootDir 'com9-boot-segment.log'), $buffer, [Text.UTF8Encoding]::new($false))
			$script:events.Add([pscustomobject]@{ number=$script:bootNumber; directory=$bootDir; wall=$script:lastBootWall; serial=$buffer })
			Add-Event 'BOOT_SEEN' "number=$($script:bootNumber) elapsed=$([math]::Round($timer.Elapsed.TotalSeconds,1))s"
			return $script:events[-1]
		}
		if ($buffer -match '(?i)Oops:|Kernel panic|BUG: unable to handle|soft lockup|hard LOCKUP') { throw 'Serial log contains a kernel OOPS/PANIC/lockup signature.' }
		Start-Sleep -Seconds 2
	}
	throw 'No Linux boot banner observed within timeout.'
}

function Get-EventTimes([string]$Serial) {
	$phy = [regex]::Match($Serial, '(?m)^.*?\[\s*(?<u>\d+(?:\.\d+)?)\].{0,240}(?:wiphy_register\(phy0\)|phy0.*registered)')
	$net = [regex]::Match($Serial, '(?m)^.*?\[\s*(?<u>\d+(?:\.\d+)?)\].{0,300}wifi-scripts: Starting')
	$ap = [regex]::Match($Serial, '(?m)^.*?\[\s*(?<u>\d+(?:\.\d+)?)\].{0,240}(?:add_virtual_intf\(phy0-ap0\)|rtw_ndev_init\(phy0-ap0\))')
	$stage = @([regex]::Matches($Serial, '(?m)^.*?\[\s*(?<u>\d+(?:\.\d+)?)\].{0,240}(?:recovery stage [123]:|settle:|health recovered|stage3 aborted)'))
	return [pscustomobject]@{
		phy0 = if ($phy.Success) { $phy.Groups['u'].Value } else { 'not-seen' }
		netifd = if ($net.Success) { $net.Groups['u'].Value } else { 'not-seen' }
		ap = if ($ap.Success) { $ap.Groups['u'].Value } else { 'not-seen' }
		stages = (($stage | ForEach-Object { $_.Value.Trim() }) -join ' | ')
	}
}

function Complete-Boot([object]$Boot, [bool]$NeedSshRecovery, [int]$MinimumSeconds = 300) {
	$bootDir = $Boot.directory
	while (([DateTimeOffset]::Now - $Boot.wall).TotalSeconds -lt $MinimumSeconds) {
		Assert-Recorder
		$delta = Get-SerialDelta
		$Boot.serial += $delta
		if ($delta -match '(?i)Oops:|Kernel panic|BUG: unable to handle|soft lockup|hard LOCKUP') { throw "Kernel exception signature in $bootDir" }
		Start-Sleep -Seconds 2
	}
	if ($NeedSshRecovery) { Restore-SSHFromSerial $bootDir }
	$stateCommand = 'printf "DATE "; date; printf "UPTIME "; cat /proc/uptime; printf "BOOT_ID "; cat /proc/sys/kernel/random/boot_id; printf "IW_DEV\n"; iw dev; printf "TRACE\n"; cat /tmp/wifi-trace.log 2>/dev/null; printf "WATCHDOG\n"; cat /root/wifi-diag/watchdog.log 2>/dev/null; printf "SETTLE\n"; cat /root/wifi-diag/settle.log 2>/dev/null; printf "MTIME\n"; busybox ls -l --full-time /etc/config/wireless 2>&1'
	$state = Invoke-SSH $stateCommand (Join-Path $bootDir 'device-state.log') 10
	if ($state.ExitCode -ne 0) {
		Restore-SSHFromSerial $bootDir
		$state = Invoke-SSH $stateCommand (Join-Path $bootDir 'device-state.log') 10
	}
	if ($state.ExitCode -ne 0) { throw "SSH evidence collection failed for boot $($Boot.number), rc=$($state.ExitCode)." }
	$Boot.serial += Get-SerialDelta
	[IO.File]::WriteAllText((Join-Path $bootDir 'com9-boot-segment.log'), $Boot.serial, [Text.UTF8Encoding]::new($false))
	$times = Get-EventTimes $Boot.serial
	$stateText = $state.Text
	$watchdogMatch = [regex]::Match($stateText, '(?m)^([a-fA-F0-9]{64})\s+/usr/sbin/k1plus-wifi-watchdog\s*$')
	if (-not $watchdogMatch.Success) {
		$hashProbe = Invoke-SSH 'sha256sum /usr/sbin/k1plus-wifi-watchdog' $null 10
		$watchdogMatch = [regex]::Match($hashProbe.Text, '(?m)^([a-fA-F0-9]{64})\s+/usr/sbin/k1plus-wifi-watchdog\s*$')
	}
	$apUp = [bool]($stateText -match '(?m)^\s*Interface phy0-ap0\s*$')
	$settleAt = [regex]::Match($stateText, '(?m)settle: wifi reload at up=([0-9.]+)s')
	$stageEvents = @($stateText -split "`r?`n" | Where-Object { $_ -match 'HEALTH|recovery stage [123]:|health recovered|stage3 aborted|settle:' })
	$summary = [ordered]@{
		boot = $Boot.number
		bootWall = $Boot.wall.ToString('o')
		bootId = [regex]::Match($stateText, '(?m)^BOOT_ID\s+(.+)$').Groups[1].Value.Trim()
		phy0Uptime = $times.phy0
		netifdFirstRadioUptime = $times.netifd
		phy0Ap0Uptime = $times.ap
		apPresentAtCapture = $apUp
		settleReloadUptime = if ($settleAt.Success) { $settleAt.Groups[1].Value } else { 'none' }
		watchdogEvents = $stageEvents
		watchdogSha256 = if ($watchdogMatch.Success) { $watchdogMatch.Groups[1].Value.ToLowerInvariant() } else { 'not-read' }
		evidence = $bootDir
	}
	$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $bootDir 'summary.json') -Encoding utf8
	if ($summary.watchdogSha256 -ne $WatchdogSha256.ToLowerInvariant()) { throw "Device watchdog hash mismatch at boot $($Boot.number): $($summary.watchdogSha256)" }
	$script:events[$Boot.number - 1] = [pscustomobject]$summary
	Add-Event 'BOOT_CAPTURED' "number=$($Boot.number) phy0=$($times.phy0) netifd=$($times.netifd) ap=$($times.ap) settle=$($summary.settleReloadUptime) AP-present=$apUp"
}

if ($PriorFlashCount -ge $FlashLimit) { throw "Flash limit already reached ($PriorFlashCount/$FlashLimit)." }
if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) { throw "Image not found: $ImagePath" }
if (-not (Test-Path -LiteralPath $SerialLog -PathType Leaf)) { throw "COM9 log not found: $SerialLog" }
Assert-Recorder
$actualImageHash = (Get-FileHash -LiteralPath $ImagePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualImageHash -ne $ImageSha256.ToLowerInvariant()) { throw "Local image hash mismatch: expected=$ImageSha256 actual=$actualImageHash" }
if ((Get-FileHash -LiteralPath $PrivateKey -Algorithm SHA256).Hash.Length -ne 64) { throw 'SSH private key unreadable.' }
New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$script:serialOffset = (Get-Item -LiteralPath $SerialLog).Length
Add-Event 'VALIDATION_START' "run=$RunId flash_count_before=$PriorFlashCount/$FlashLimit image_sha256=$actualImageHash"

$remoteHash = (Invoke-SSH "sha256sum $remoteImage" (Join-Path $EvidenceRoot 'remote-image-before-upload.log') 10)
if ($remoteHash.ExitCode -ne 0) {
	Invoke-SCP @($ImagePath, "root@192.168.1.1:$remoteImage") (Join-Path $EvidenceRoot 'image-upload.log')
}
$remoteCheck = Invoke-SSH "sha256sum $remoteImage && sysupgrade -T $remoteImage" (Join-Path $EvidenceRoot 'image-precheck.log') 30
if ($remoteCheck.ExitCode -ne 0 -or $remoteCheck.Text -notmatch [regex]::Escape($actualImageHash)) { throw 'Remote image hash or sysupgrade -T check failed; no flash performed.' }
Add-Event 'IMAGE_PRECHECK_PASS' "sha256=$actualImageHash sysupgrade_T=0"
$flash = Invoke-SSH "sync; sysupgrade -F -n -v $remoteImage" (Join-Path $EvidenceRoot 'flash-command.log') 20
Add-Event 'FLASH_ISSUED' "ssh_exit=$($flash.ExitCode) cumulative=$($PriorFlashCount + 1)/$FlashLimit"
$boot = Wait-NewBoot
Complete-Boot $boot $true 300

for ($round = 1; $round -le 8; $round++) {
	$cmd = Invoke-SSH 'firstboot -y; sync; reboot' (Join-Path $EvidenceRoot ("firstboot-$round-command.log")) 8
	Add-Event 'FIRSTBOOT_ISSUED' "round=$round ssh_exit=$($cmd.ExitCode)"
	$boot = Wait-NewBoot
	Complete-Boot $boot $true 300
}

for ($round = 1; $round -le 3; $round++) {
	$cmd = Invoke-SSH 'sync; reboot' (Join-Path $EvidenceRoot ("ordinary-reboot-$round-command.log")) 8
	Add-Event 'ORDINARY_REBOOT_ISSUED' "round=$round ssh_exit=$($cmd.ExitCode)"
	$boot = Wait-NewBoot
	Complete-Boot $boot $false 300
}

$script:events | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'all-boots.json') -Encoding utf8
Add-Event 'VALIDATION_COMPLETE' 'flash=1 firstboot=8 ordinary_reboot=3; device left on v3 recover image'
