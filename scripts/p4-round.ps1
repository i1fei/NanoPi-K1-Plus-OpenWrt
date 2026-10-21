param(
	[Parameter(Mandatory = $true)][ValidateSet('observe', 'recover', 'rollback')][string]$Mode,
	[Parameter(Mandatory = $true)][ValidateRange(1, 10)][int]$Round,
	[switch]$ResumePostObservation,
	[switch]$ResumePassiveObservation,
	[switch]$ResumeAfterSysupgrade
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$evidenceRoot = Join-Path $repo 'evidence'
$serialLog = Join-Path $evidenceRoot 'com9-20261020-102145.log'
$commandDir = Join-Path $evidenceRoot 'com9-20261020-102145-commands'
$privateKey = Join-Path $env:USERPROFILE '.ssh\openclaw-server'
$ssh = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$scp = Join-Path $env:WINDIR 'System32\OpenSSH\scp.exe'
$sshKeygen = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
$netRun = Join-Path $PSScriptRoot 'net-run.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$tracker = Join-Path $evidenceRoot 'P3-P4-20261019.md'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$roundName = if ($Mode -eq 'rollback') { 'rollback-stop-condition' } elseif ($Mode -eq 'recover') { 'recover-r394088-{0:d2}' -f $Round } else { 'observe-r394165-{0:d2}' -f $Round }
$roundDir = Join-Path $evidenceRoot "P4\$roundName"
$knownHostsSource = Join-Path $evidenceRoot 'P4\known_hosts.verified'
$verifiedKnownHosts = Join-Path $roundDir 'known_hosts.verified'
$remoteImage = "/tmp/p4-$Mode-$Round.img.gz"
$scriptStart = [DateTimeOffset]::Now
$passiveLimitSeconds = if ($Mode -eq 'observe') { 600 } else { 900 }
$timeline = [System.Collections.Generic.List[string]]::new()
$script:recorderRestartAttempts = 0
$script:sshWaitResolved = $false
$script:sshAvailableDuringPassive = $false
$sshPost300GraceSeconds = 180

New-Item -ItemType Directory -Path $roundDir -Force | Out-Null
if (-not (Test-Path -LiteralPath $verifiedKnownHosts)) {
	$firstRoundKnownHosts = Join-Path $evidenceRoot 'P4\recover-r394088-01\known_hosts.postboot-verified'
	$verifiedHostCandidates = @(Get-ChildItem (Join-Path $evidenceRoot 'P4') -Filter 'known_hosts.verified' -File -Recurse -ErrorAction SilentlyContinue |
		Where-Object { $_.FullName -ne $verifiedKnownHosts } |
		Sort-Object LastWriteTime -Descending)
	if ($verifiedHostCandidates.Count -gt 0) {
		Copy-Item -LiteralPath $verifiedHostCandidates[0].FullName -Destination $verifiedKnownHosts
	} elseif (Test-Path -LiteralPath $firstRoundKnownHosts) {
		Copy-Item -LiteralPath $firstRoundKnownHosts -Destination $verifiedKnownHosts
	} elseif (Test-Path -LiteralPath $knownHostsSource) {
		Copy-Item -LiteralPath $knownHostsSource -Destination $verifiedKnownHosts
	} elseif (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.ssh\known_hosts')) {
		Copy-Item -LiteralPath (Join-Path $env:USERPROFILE '.ssh\known_hosts') -Destination $verifiedKnownHosts
	} else {
		throw 'No verified known_hosts source is available.'
	}
}

function Add-Event([string]$Name, [string]$Detail = '') {
	$line = '[{0}] {1} {2}' -f [DateTimeOffset]::Now.ToString('o'), $Name, $Detail
	$timeline.Add($line)
	[IO.File]::AppendAllText((Join-Path $roundDir 'round.log'), $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
	Write-Host $line
}

function Invoke-SSH([string]$RemoteCommand, [string]$LogFile, [int]$TimeoutSeconds = 20) {
	$sshArgs = @('-T', '-b', '192.168.1.222', '-o', "ConnectTimeout=$TimeoutSeconds", '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes', '-o', "UserKnownHostsFile=$verifiedKnownHosts", '-i', $privateKey, 'root@192.168.1.1', $RemoteCommand)
	$output = @(& $pwsh -NoProfile -File $netRun ssh @sshArgs 2>&1)
	$code = $LASTEXITCODE
	[IO.File]::WriteAllLines($LogFile, [string[]]$output, [Text.UTF8Encoding]::new($false))
	return [PSCustomObject]@{ ExitCode = $code; Output = ($output -join [Environment]::NewLine) }
}

function Invoke-SCP([string[]]$Arguments, [string]$LogFile) {
	$output = @(& $pwsh -NoProfile -File $netRun scp -O -o BindAddress=192.168.1.222 -o ConnectTimeout=10 -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$verifiedKnownHosts" -i $privateKey @Arguments 2>&1)
	$code = $LASTEXITCODE
	[IO.File]::WriteAllLines($LogFile, [string[]]$output, [Text.UTF8Encoding]::new($false))
	if ($code -ne 0) { throw "scp failed ($code); see $LogFile" }
}

function Probe-SSHDuringPassive([double]$ElapsedSeconds) {
	if ($script:sshWaitResolved -or $ElapsedSeconds -lt 300) { return }
	if ($ElapsedSeconds -ge (300 + $sshPost300GraceSeconds)) {
		$script:sshWaitResolved = $true
		Add-Event 'SSH_WAIT_TIMEOUT' "no authenticated SSH within ${sshPost300GraceSeconds}s after T+300s; COM9 fallback is deferred until the passive window ends"
		return
	}
	$probePath = Join-Path $roundDir 'ssh-passive-probe.log'
	$probe = Invoke-SSH 'true' $probePath 5
	if ($probe.ExitCode -eq 0) {
		$script:sshWaitResolved = $true
		$script:sshAvailableDuringPassive = $true
		Add-Event 'SSH_AVAILABLE_DURING_PASSIVE' "T+$([math]::Round($ElapsedSeconds,1))s"
	}
}

function Get-SerialText {
	if (-not (Test-Path -LiteralPath $serialLog)) { throw "COM9 recorder log missing: $serialLog" }
	$stream = [IO.File]::Open($serialLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
	try { $reader = [IO.StreamReader]::new($stream); return $reader.ReadToEnd() } finally { $stream.Dispose() }
}

function Get-RecorderHeartbeatAge {
	$line = Select-String -LiteralPath $serialLog -Pattern '\] INFO HEARTBEAT pid=' | Select-Object -Last 1
	if (-not $line) { return [double]::PositiveInfinity }
	$match = [regex]::Match($line.Line, '^\[(?<stamp>[^\]]+)\]')
	if (-not $match.Success) { return [double]::PositiveInfinity }
	try { return ([DateTimeOffset]::Now - [DateTimeOffset]::Parse($match.Groups['stamp'].Value)).TotalSeconds } catch { return [double]::PositiveInfinity }
}

function Assert-SerialRecorder {
	$heartbeatAge = Get-RecorderHeartbeatAge
	if ($heartbeatAge -gt 30) {
		if ($script:recorderRestartAttempts -ge 1) { throw "COM9 recorder heartbeat stale after one restart attempt (${heartbeatAge}s)." }
		$script:recorderRestartAttempts++
		Add-Event 'COM9_HEARTBEAT_STALE' "age=$([math]::Round($heartbeatAge,1))s; restart attempt 1/1"
		$launcher = Join-Path $PSScriptRoot 'start-com9-recorder.ps1'
		$restartOutput = @(& $pwsh -NoProfile -File $launcher -LogPath $serialLog -CommandDirectory $commandDir -Restart 2>&1)
		[IO.File]::WriteAllLines((Join-Path $roundDir 'com9-recorder-restart.log'), [string[]]$restartOutput, [Text.UTF8Encoding]::new($false))
		Add-Event 'COM9_RECORDER_RESTART_REQUESTED' (($restartOutput -join ' ').Trim())
		$restartWait = [Diagnostics.Stopwatch]::StartNew()
		while ($restartWait.Elapsed.TotalSeconds -lt 35 -and (Get-RecorderHeartbeatAge) -gt 30) { Start-Sleep -Seconds 1 }
		if ((Get-RecorderHeartbeatAge) -gt 30) { throw 'COM9 recorder heartbeat did not recover after one restart attempt.' }
	}
	$dev = $null
	try {
		$dev = Get-PnpDevice -Class Ports -ErrorAction Stop | Where-Object FriendlyName -match '\(COM9\)' | Select-Object -First 1
	} catch {
		# PnP inventory can be denied even while the dedicated recorder owns and reads COM9.
	}
	if ($dev -and $dev.Status -ne 'OK') { throw 'COM9 PnP device is not OK.' }
	$recentErrors = @(Select-String -Path $serialLog -Pattern '\] ERROR ' | Select-Object -Last 4)
	$lastOpen = (Select-String -Path $serialLog -Pattern 'COM9_OPEN=PASS' | Select-Object -Last 1).Line
	if (-not $lastOpen) { throw 'No successful COM9 open record exists.' }
	if ($recentErrors.Count -gt 0) {
		$lastError = $recentErrors[-1].Line
		$lastSuccess = (Select-String -Path $serialLog -Pattern 'COM9_OPEN=PASS' | Select-Object -Last 1).Line
		if ($lastError -and $lastSuccess -and $lastError -gt $lastSuccess) { throw "COM9 recorder reports an unrecovered error: $lastError" }
	}
}

function Send-Serial([string]$Command, [string]$Marker, [int]$TimeoutSeconds = 60) {
	Assert-SerialRecorder
	$before = (Get-Item -LiteralPath $serialLog).Length
	$file = Join-Path $commandDir (('{0:D8}-{1}.cmd' -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds(), [guid]::NewGuid().ToString('N')))
	$split = [Math]::Max(1, [int]($Marker.Length / 2))
	$wireCommand = $Command.Replace($Marker, $Marker.Substring(0, $split) + "''" + $Marker.Substring($split))
	[IO.File]::WriteAllText($file, $wireCommand + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
	$watch = [Diagnostics.Stopwatch]::StartNew()
	while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
		Assert-SerialRecorder
		$tail = Get-SerialText
		if ($tail.Length -gt $before) {
			$delta = $tail.Substring($before)
			$markerSeen = $delta -match "\\r\\n$([regex]::Escape($Marker))\\r\\n|RX $([regex]::Escape($Marker))(?:\\r\\n|$)"
			$hostKeyCommandFinished = $Command.StartsWith('dropbearkey -y -f ') -and $delta.Contains('root@nanopi-k1plus:~#')
			if ($markerSeen -or $hostKeyCommandFinished) {
				$watch.Stop()
				return [PSCustomObject]@{ Offset = $before; Elapsed = $watch.Elapsed.TotalSeconds; Text = $delta }
			}
		}
		Start-Sleep -Milliseconds 250
	}
	throw "COM9 marker not seen within ${TimeoutSeconds}s: $Marker"
}

function Wait-SerialPattern([string]$Pattern, [long]$Offset, [int]$TimeoutSeconds) {
	$watch = [Diagnostics.Stopwatch]::StartNew()
	while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
		Assert-SerialRecorder
		$text = Get-SerialText
		if ($text.Length -gt $Offset) {
			$delta = $text.Substring($Offset)
			if ($delta -match $Pattern) { $watch.Stop(); return [PSCustomObject]@{ Offset = $Offset; Text = $delta; Elapsed = $watch.Elapsed.TotalSeconds } }
		}
		Start-Sleep -Seconds 2
	}
	throw "Timed out waiting for COM9 pattern: $Pattern"
}

function Wait-LinuxBoot([long]$Offset, [int]$TimeoutSeconds = 240) {
	$boot = Wait-SerialPattern 'Booting Linux on physical CPU' $Offset $TimeoutSeconds
	Add-Event 'LINUX_BOOT_SEEN_BEFORE_SERIAL_INPUT' "elapsed=$([math]::Round($boot.Elapsed,1))s"
}

function Get-AfterRebootOffset([string]$Delta, [long]$BaseOffset) {
	$marker = 'reboot: Restarting system'
	$index = $Delta.LastIndexOf($marker, [StringComparison]::Ordinal)
	if ($index -lt 0) { throw 'Cannot locate reboot marker offset in serial delta.' }
	return $BaseOffset + $index + $marker.Length + 4
}

function Wake-SerialConsole {
	Assert-SerialRecorder
	$before = (Get-Item -LiteralPath $serialLog).Length
	$file = Join-Path $commandDir (('{0:D8}-{1}.cmd' -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds(), [guid]::NewGuid().ToString('N')))
	[IO.File]::WriteAllText($file, [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
	$prompt = Wait-SerialPattern 'root@nanopi-k1plus:~#' $before 20
	Add-Event 'SERIAL_CONSOLE_READY' "wake_elapsed=$([math]::Round($prompt.Elapsed,2))s"
}

function Update-VerifiedKnownHost {
	$strictProbe = Invoke-SSH 'true' (Join-Path $roundDir 'preflash-ssh-probe.log') 5
	if ($strictProbe.ExitCode -eq 0) {
		Add-Event 'PREFLASH_SSH_STRICT_HOSTKEY_PASS' 'strict SSH authentication succeeded; COM9 not used for host-key refresh'
		return
	}
	$marker = "P4_HOSTKEY_PRE_$([guid]::NewGuid().ToString('N'))"
	Wake-SerialConsole
	$serialResult = Send-Serial "dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key; echo $marker" $marker 30
	[IO.File]::WriteAllText((Join-Path $roundDir 'hostkey-preflash-com9-transcript.log'), $serialResult.Text, [Text.UTF8Encoding]::new($false))
	$rxPayloads = [regex]::Matches($serialResult.Text, '(?m)^\[[^\]]+\] RX (.*)$') | ForEach-Object { $_.Groups[1].Value }
	$serialOutput = (($rxPayloads -join '') -replace '\\r\\n', ' ')
	if ($serialOutput -notmatch '(ssh-ed25519\s+[A-Za-z0-9+/]+={0,2}\s+[^\s\\]+)') { throw 'COM9 did not return a parseable device ED25519 host key; raw transcript preserved.' }
	$serialPub = $Matches[1].Trim()
	$serialPubPath = Join-Path $roundDir 'device-hostkey-from-com9-preflash.pub'
	[IO.File]::WriteAllText($serialPubPath, $serialPub + "`n", [Text.UTF8Encoding]::new($false))
	$serialFpOutput = @(& $sshKeygen -lf $serialPubPath -E sha256 2>&1)
	$serialFp = [regex]::Match(($serialFpOutput -join ' '), 'SHA256:[A-Za-z0-9+/]+')
	if ($LASTEXITCODE -ne 0 -or -not $serialFp.Success) { throw 'Cannot calculate COM9 device host-key fingerprint.' }
	$tempHosts = Join-Path $roundDir 'known_hosts.preflash-probe'
	$probeArgs = @('-vvv', '-T', '-b', '192.168.1.222', '-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'PreferredAuthentications=none', '-o', 'PubkeyAuthentication=no', '-o', 'PasswordAuthentication=no', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'HashKnownHosts=no', '-o', "UserKnownHostsFile=$tempHosts", 'root@192.168.1.1', 'true')
	$probe = @(& $pwsh -NoProfile -File $netRun ssh @probeArgs 2>&1)
	[IO.File]::WriteAllLines((Join-Path $roundDir 'ssh-hostkey-preflash-probe.log'), [string[]]$probe, [Text.UTF8Encoding]::new($false))
	$sshFp = [regex]::Match(($probe -join "`n"), 'Server host key: ssh-ed25519 (SHA256:[A-Za-z0-9+/]+)')
	$hostLine = Get-Content -LiteralPath $tempHosts -ErrorAction SilentlyContinue | Where-Object { $_ -match '^192\.168\.1\.1\s+ssh-ed25519\s+' } | Select-Object -First 1
	if (-not $sshFp.Success -or -not $hostLine) { throw 'SSH did not provide an ED25519 key in the preflash host-key probe.' }
	if ($sshFp.Groups[1].Value -ne $serialFp.Value) { throw "Host-key mismatch; COM9=$($serialFp.Value), SSH=$($sshFp.Groups[1].Value). known_hosts unchanged." }
	$newKey = [regex]::Match($hostLine, 'ssh-ed25519\s+([A-Za-z0-9+/]+={0,2})')
	if (-not $newKey.Success) { throw 'Cannot parse the SSH ED25519 key line.' }
	[IO.File]::WriteAllText($verifiedKnownHosts, $hostLine + "`n", [Text.ASCIIEncoding]::new())
	'Per-round known_hosts set only after COM9/SSH fingerprint match.' | Set-Content -LiteralPath (Join-Path $roundDir 'known-host-refresh.log')
	Add-Event 'PREFLASH_HOSTKEY_MATCH' "COM9=$($serialFp.Value) SSH=$($sshFp.Groups[1].Value)"
	$authProbe = Invoke-SSH 'true' (Join-Path $roundDir 'preflash-ssh-auth-probe.log') 5
	if ($authProbe.ExitCode -ne 0) {
		$publicKeyPath = "$privateKey.pub"
		if (-not (Test-Path -LiteralPath $publicKeyPath)) { throw "SSH public key missing: $publicKeyPath" }
		$publicKey = (Get-Content -LiteralPath $publicKeyPath -Raw).Trim()
		if ($publicKey -notmatch '^ssh-ed25519\s+[A-Za-z0-9+/]+={0,2}(\s+[^\r\n]+)?$') { throw 'Expected a single-line ED25519 client public key.' }
		$writeMarker = "P4_PREFLASH_KEY_$([guid]::NewGuid().ToString('N'))"
		$null = Send-Serial "printf '%s\n' '$publicKey' > /etc/dropbear/authorized_keys; chown root:root /etc/dropbear /etc/dropbear/authorized_keys; chmod 700 /etc/dropbear; chmod 600 /etc/dropbear/authorized_keys; /etc/init.d/dropbear restart; echo $writeMarker" $writeMarker 90
		$loginWatch = [Diagnostics.Stopwatch]::StartNew()
		while ($loginWatch.Elapsed.TotalSeconds -lt 120) {
			$authProbe = Invoke-SSH 'true' (Join-Path $roundDir 'preflash-ssh-auth-probe.log') 5
			if ($authProbe.ExitCode -eq 0) { break }
			Start-Sleep -Seconds 3
		}
		$loginWatch.Stop()
		if ($authProbe.ExitCode -ne 0) { throw 'SSH authentication remained unavailable after verified COM9 credential repair.' }
		Add-Event 'PREFLASH_SSH_RESTORED' "serial_fallback_elapsed=$([math]::Round($loginWatch.Elapsed.TotalSeconds,1))s"
	}
}

if (-not (Test-Path -LiteralPath $ssh -PathType Leaf) -or -not (Test-Path -LiteralPath $scp -PathType Leaf) -or -not (Test-Path -LiteralPath $sshKeygen -PathType Leaf)) {
	throw 'Required Windows OpenSSH executable is missing.'
}
if (-not (Test-Path -LiteralPath $privateKey -PathType Leaf)) { throw "SSH private key missing: $privateKey" }
Assert-SerialRecorder

$imagePath = if ($Mode -eq 'observe') {
	Join-Path $repo 'artifacts\observe-variant-39416504363\observe-variant-39416504363\work\observe.img.gz'
	} elseif ($Mode -eq 'recover') {
	Join-Path $repo 'artifacts\recover-39408824234\NanoPi-K1-Plus-OpenWrt\immortalwrt-sunxi-cortexa53-friendlyarm_nanopi-k1-plus-squashfs-sdcard.img.gz'
	} else {
	Join-Path $repo 'artifacts\run-38721059332\NanoPi-K1-Plus-OpenWrt\immortalwrt-sunxi-cortexa53-friendlyarm_nanopi-k1-plus-squashfs-sdcard.img.gz'
}
$expectedHash = if ($Mode -eq 'observe') {
	'438f2315a6dc70fd0271c529f17eb9083c6fa2c399cd2320a0a3006efa4752cb'
	} elseif ($Mode -eq 'recover') {
	'79bfeb14fd37d6c258af72dac9ab803bce0dccb7417b8204531b5efa6a60d93b'
	} else {
	'f53866f44c48bdef76c4cc0f72f5ecddfd156e05befb432402e4a2479f256e65'
}
if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) { throw "Image not found: $imagePath" }
$actualHash = (Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash) { throw "Image SHA mismatch: expected $expectedHash, got $actualHash" }
New-Item -ItemType Directory -Path $roundDir -Force | Out-Null
if (-not $ResumeAfterSysupgrade -and -not $ResumePostObservation -and -not $ResumePassiveObservation) { Update-VerifiedKnownHost }
if (-not $ResumePostObservation -and -not $ResumePassiveObservation -and -not $ResumeAfterSysupgrade) {
	$flashed = 6
	$strictRoundLogs = Get-ChildItem (Join-Path $evidenceRoot 'P4') -Filter 'round.log' -Recurse -File -ErrorAction SilentlyContinue |
		Where-Object { $_.Directory.Name -match '^(recover-r394088|observe-r394165)-\d{2}$' }
	foreach ($roundLog in $strictRoundLogs) {
		if (Select-String -LiteralPath $roundLog.FullName -Pattern 'SYSUPGRADE_START' -Quiet) { $flashed++ }
	}
	if ($flashed -ge 24) { throw "24-flash limit reached; current recorded count including P3: $flashed" }
	Add-Event 'ROUND_START' "mode=$Mode round=$Round prior_flash_count=$flashed image_sha256=$actualHash"
	} elseif ($ResumeAfterSysupgrade) {
	$previous = [IO.File]::ReadAllText((Join-Path $roundDir 'round.log'))
	if ($previous -notmatch 'SYSUPGRADE_START' -or $previous -match 'FINAL_REBOOT_SEEN') { throw 'Resume after sysupgrade refused: expected a started flash and no final reboot.' }
	$serialAtResume = Get-SerialText
	if ($serialAtResume.LastIndexOf('Booting Linux on physical CPU', [StringComparison]::Ordinal) -lt 0) { throw 'Resume after sysupgrade refused: no kernel boot record is present in COM9 log.' }
	if ($previous -notmatch 'SYSUPGRADE_REBOOT_SEEN') { Add-Event 'SYSUPGRADE_BOOT_SEEN_REBOOT_PRINTK_MISSING' 'kernel boot record is present; reboot printk line was not captured' }
	Add-Event 'ROUND_RESUME_AFTER_SYSUPGRADE' "mode=$Mode round=$Round; no second flash"
	} elseif ($ResumePassiveObservation) {
	$previous = [IO.File]::ReadAllText((Join-Path $roundDir 'round.log'))
	if ($previous -notmatch 'FINAL_REBOOT_SEEN passive_T0=(\S+)') { throw 'Resume passive observation refused: this round has no recorded final reboot T0.' }
	$bootWall = [DateTimeOffset]::Parse($Matches[1])
	$serialText = Get-SerialText
	$restartIndex = $serialText.LastIndexOf('reboot: Restarting system', [StringComparison]::Ordinal)
	if ($restartIndex -lt 0) { throw 'Resume passive observation refused: reboot marker is absent from COM9 log.' }
	$script:resumeBootOffset = $restartIndex + 'reboot: Restarting system'.Length + 4
	Add-Event 'ROUND_RESUME_PASSIVE_OBSERVATION' "mode=$Mode round=$Round rebootT0=$($bootWall.ToString('o')); no flash or serial command"
	} else {
	$previous = [IO.File]::ReadAllText((Join-Path $roundDir 'round.log'))
	if ($previous -notmatch 'FINAL_REBOOT_SEEN passive_T0=(\S+)') { throw 'Resume refused: this round has no recorded final reboot T0.' }
	$bootWall = [DateTimeOffset]::Parse($Matches[1])
	$serialText = Get-SerialText
	$rebootPattern = '\[(?<wall>2026-[^\]]+)\] RX \[\s*(?<up>\d+\.\d+)\] reboot: Restarting system'
	$finalReboot = $null
	foreach ($candidate in [regex]::Matches($serialText, $rebootPattern)) {
		$candidateWall = [DateTimeOffset]::Parse($candidate.Groups['wall'].Value)
		if ($candidateWall -ge $bootWall.AddSeconds(-30) -and $candidateWall -le $bootWall) { $finalReboot = $candidate }
	}
	if (-not $finalReboot) { throw 'Resume refused: cannot match the final reboot T0 to its COM9 reboot marker.' }
	$script:resumeBootOffset = $finalReboot.Index + $finalReboot.Length + 4
	Add-Event 'ROUND_RESUME_POST_OBSERVATION' "mode=$Mode round=$Round rebootT0=$($bootWall.ToString('o')) marker_uptime=$($finalReboot.Groups['up'].Value.Trim())"
}

	try {
	if ($ResumePostObservation) {
		$boot = [PSCustomObject]@{ Offset = $script:resumeBootOffset; Text = ''; Elapsed = 0 }
		Add-Event "PASSIVE_${passiveLimitSeconds}S_PRIOR_RUN" 'retained; no flash/reboot repeated'
	} elseif ($ResumePassiveObservation) {
		$boot = [PSCustomObject]@{ Offset = $script:resumeBootOffset; Text = ''; Elapsed = 0 }
		Add-Event "PASSIVE_${passiveLimitSeconds}S_RESUMED" "observation restarts from resume; no serial interaction until ${passiveLimitSeconds}s"
		$passive = [Diagnostics.Stopwatch]::StartNew()
		$bootPattern = 'Booting Linux on physical CPU'
		$initialText = Get-SerialText
		$segment = $initialText.Substring([Math]::Min([int]$boot.Offset, $initialText.Length))
		$bootCount = [regex]::Matches($segment, $bootPattern).Count
		while ($passive.Elapsed.TotalSeconds -lt $passiveLimitSeconds) {
			Assert-SerialRecorder
			$tail = Get-SerialText
			if ($tail -match 'Oops:|Kernel panic|Kernel BUG at|BUG: unable to handle kernel|Unable to handle kernel') { throw 'Stop condition: Oops/panic text detected in serial log.' }
			$segment = $tail.Substring([Math]::Min([int]$boot.Offset, $tail.Length))
			$newBootCount = [regex]::Matches($segment, $bootPattern).Count
			if ($newBootCount -gt $bootCount) {
				$bootCount = $newBootCount
				$bootWall = [DateTimeOffset]::Now
				$passive.Restart()
				$script:sshWaitResolved = $false
				$script:sshAvailableDuringPassive = $false
				Add-Event 'PASSIVE_WINDOW_RESTARTED' "new_kernel_boot_count=$bootCount; observing this boot for ${passiveLimitSeconds}s"
			}
			Probe-SSHDuringPassive $passive.Elapsed.TotalSeconds
			Start-Sleep -Seconds ([Math]::Min(10, [Math]::Ceiling($passiveLimitSeconds - $passive.Elapsed.TotalSeconds)))
		}
		$passive.Stop()
		Add-Event "PASSIVE_${passiveLimitSeconds}S_COMPLETE" "elapsed_since_latest_kernel_boot=$([math]::Round($passive.Elapsed.TotalSeconds,1))s; kernel_boots_seen=$bootCount; no serial interaction during resumed window"
	} elseif ($ResumeAfterSysupgrade) {
		Add-Event 'ROUND_RESUME_AFTER_SYSUPGRADE' 'SSH-first; no repeated flash'
		$offset = (Get-Item -LiteralPath $serialLog).Length
		$sshReady = (Invoke-SSH 'true' (Join-Path $roundDir 'ssh-firstboot-probe.log') 8).ExitCode -eq 0
		if ($sshReady) {
			$firstboot = Invoke-SSH 'firstboot -y; sync; reboot' (Join-Path $roundDir 'firstboot-ssh.log') 30
			Add-Event 'FIRSTBOOT_ISSUED_OVER_SSH' "ssh_exit=$($firstboot.ExitCode)"
		} else {
			Add-Event 'SSH_UNAVAILABLE_FIRSTBOOT_FALLBACK' 'using COM9 only after SSH probe failed'
			$serialBeforeFallback = Get-SerialText
			$lastRebootMarker = $serialBeforeFallback.LastIndexOf('reboot: Restarting system', [StringComparison]::Ordinal)
			if ($lastRebootMarker -lt 0) { throw 'Cannot anchor resumed serial fallback to this round reboot marker.' }
			Wait-LinuxBoot ($lastRebootMarker + 'reboot: Restarting system'.Length) 240
			Wake-SerialConsole
			$clearMarker = "P4_CLEAR_$([guid]::NewGuid().ToString('N'))"
			$clear = Send-Serial "firstboot -y; echo $clearMarker" $clearMarker 180
			Add-Event 'FIRSTBOOT_DONE' "channel=COM9 elapsed=$([math]::Round($clear.Elapsed,2))s"
			$rebootMarker = "P4_REBOOT_$([guid]::NewGuid().ToString('N'))"
			$null = Send-Serial "sync; echo $rebootMarker; reboot" $rebootMarker 30
		}
		$boot = Wait-SerialPattern 'reboot: Restarting system' $offset 90
		$boot.Offset = Get-AfterRebootOffset $boot.Text $offset
		$bootWall = [DateTimeOffset]::Now
		Add-Event 'FINAL_REBOOT_SEEN' "passive_T0=$($bootWall.ToString('o')) marker_elapsed=$([math]::Round($boot.Elapsed,2))s"
		$passive = [Diagnostics.Stopwatch]::StartNew()
		$bootPattern = 'Booting Linux on physical CPU'
		$initialText = Get-SerialText
		$segment = $initialText.Substring([Math]::Min([int]$boot.Offset, $initialText.Length))
		$bootCount = [regex]::Matches($segment, $bootPattern).Count
		while ($passive.Elapsed.TotalSeconds -lt $passiveLimitSeconds) {
			Assert-SerialRecorder
			$tail = Get-SerialText
			if ($tail -match 'Oops:|Kernel panic|Kernel BUG at|BUG: unable to handle kernel|Unable to handle kernel') { throw 'Stop condition: Oops/panic text detected in serial log.' }
			$segment = $tail.Substring([Math]::Min([int]$boot.Offset, $tail.Length))
			$newBootCount = [regex]::Matches($segment, $bootPattern).Count
			if ($newBootCount -gt $bootCount) { $bootCount = $newBootCount; $passive.Restart(); $script:sshWaitResolved = $false; $script:sshAvailableDuringPassive = $false; Add-Event 'PASSIVE_WINDOW_RESTARTED' "new_kernel_boot_count=$bootCount; observing this boot for ${passiveLimitSeconds}s" }
			Probe-SSHDuringPassive $passive.Elapsed.TotalSeconds
			Start-Sleep -Seconds ([Math]::Min(10, [math]::Ceiling($passiveLimitSeconds - $passive.Elapsed.TotalSeconds)))
		}
		$passive.Stop()
		Add-Event "PASSIVE_${passiveLimitSeconds}S_COMPLETE" "elapsed_since_latest_kernel_boot=$([math]::Round($passive.Elapsed.TotalSeconds,1))s; kernel_boots_seen=$bootCount"
	} else {
	$preTar = "/tmp/p4-before-$Mode-$Round.tar.gz"
	$backup = Invoke-SSH "tar czf $preTar /root /etc/config 2>/dev/null && sha256sum $preTar" (Join-Path $roundDir 'preflash-backup-create.log')
	if ($backup.ExitCode -ne 0) { throw 'Pre-flash evidence archive creation failed; no flash performed.' }
	Invoke-SCP @("root@192.168.1.1:$preTar", (Join-Path $roundDir 'preflash-root-config.tar.gz')) (Join-Path $roundDir 'preflash-backup-fetch.log')
	Add-Event 'PREFLASH_BACKUP' ((Get-FileHash (Join-Path $roundDir 'preflash-root-config.tar.gz') -Algorithm SHA256).Hash)

	Invoke-SCP @($imagePath, "root@192.168.1.1:$remoteImage") (Join-Path $roundDir 'image-upload.log')
	$check = Invoke-SSH "sha256sum $remoteImage && sysupgrade -T $remoteImage" (Join-Path $roundDir 'sysupgrade-test.log') 30
	if ($check.ExitCode -ne 0 -or $check.Output -notmatch [regex]::Escape($expectedHash)) { throw 'Device SHA-256 or sysupgrade -T failed; no flash performed.' }
	Add-Event 'IMAGE_PRECHECK_PASS' "sha256=$expectedHash sysupgrade_T=0"

	$beforeFlash = (Get-Item -LiteralPath $serialLog).Length
	Add-Event 'SYSUPGRADE_START'
	$flash = Invoke-SSH "sync; sysupgrade -F -n -v $remoteImage" (Join-Path $roundDir 'sysupgrade-flash.log') 20
	Add-Event 'SYSUPGRADE_RETURN' "ssh_exit=$($flash.ExitCode)"
	$boot = Wait-SerialPattern 'reboot: Restarting system' $beforeFlash 240
	$boot.Offset = Get-AfterRebootOffset $boot.Text $beforeFlash
	Add-Event 'SYSUPGRADE_REBOOT_SEEN' "elapsed=$([math]::Round($boot.Elapsed,2))s"
	if ($Mode -eq 'rollback') {
		$bootWall = [DateTimeOffset]::Now
		Add-Event 'ROLLBACK_REBOOT_SEEN' "passive_T0=$($bootWall.ToString('o'))"
	} else {
		$offset = (Get-Item -LiteralPath $serialLog).Length
		$sshReady = (Invoke-SSH 'true' (Join-Path $roundDir 'ssh-firstboot-probe.log') 8).ExitCode -eq 0
		if ($sshReady) {
			$firstboot = Invoke-SSH 'firstboot -y; sync; reboot' (Join-Path $roundDir 'firstboot-ssh.log') 30
			Add-Event 'FIRSTBOOT_ISSUED_OVER_SSH' "ssh_exit=$($firstboot.ExitCode)"
		} else {
			Add-Event 'SSH_UNAVAILABLE_FIRSTBOOT_FALLBACK' 'using COM9 only after SSH probe failed'
			Wait-LinuxBoot $boot.Offset 240
			Wake-SerialConsole
			Add-Event 'FIRST_BOOT_CONSOLE_READY' 'COM9 newline wake and shell prompt verified'
			$clearMarker = "P4_CLEAR_$([guid]::NewGuid().ToString('N'))"
			$clear = Send-Serial "firstboot -y; echo $clearMarker" $clearMarker 180
			Add-Event 'FIRSTBOOT_DONE' "channel=COM9 elapsed=$([math]::Round($clear.Elapsed,2))s"
			$rebootMarker = "P4_REBOOT_$([guid]::NewGuid().ToString('N'))"
			$null = Send-Serial "sync; echo $rebootMarker; reboot" $rebootMarker 30
		}
		$kernel = Wait-SerialPattern 'reboot: Restarting system' $offset 180
		$boot = [PSCustomObject]@{ Offset = (Get-AfterRebootOffset $kernel.Text $offset); Text = $kernel.Text; Elapsed = $kernel.Elapsed }
		$bootWall = [DateTimeOffset]::Now
		Add-Event 'FINAL_REBOOT_SEEN' "passive_T0=$($bootWall.ToString('o')) marker_elapsed=$([math]::Round($kernel.Elapsed,2))s"
	}

	$passive = [Diagnostics.Stopwatch]::StartNew()
	$bootPattern = 'Booting Linux on physical CPU'
	$segment = (Get-SerialText).Substring([Math]::Min([int]$boot.Offset, (Get-SerialText).Length))
	$bootCount = [regex]::Matches($segment, $bootPattern).Count
	while ($passive.Elapsed.TotalSeconds -lt $passiveLimitSeconds) {
		Assert-SerialRecorder
		$tail = Get-SerialText
		if ($tail -match 'Oops:|Kernel panic|Kernel BUG at|BUG: unable to handle kernel|Unable to handle kernel') { throw 'Stop condition: Oops/panic text detected in serial log.' }
		$segment = $tail.Substring([Math]::Min([int]$boot.Offset, $tail.Length))
		$newBootCount = [regex]::Matches($segment, $bootPattern).Count
		if ($newBootCount -gt $bootCount) {
			$bootCount = $newBootCount
			$bootWall = [DateTimeOffset]::Now
			$passive.Restart()
			$script:sshWaitResolved = $false
			$script:sshAvailableDuringPassive = $false
			Add-Event 'PASSIVE_WINDOW_RESTARTED' "new_kernel_boot_count=$bootCount; observing this boot for ${passiveLimitSeconds}s"
		}
		Probe-SSHDuringPassive $passive.Elapsed.TotalSeconds
		Start-Sleep -Seconds ([Math]::Min(10, [math]::Ceiling($passiveLimitSeconds - $passive.Elapsed.TotalSeconds)))
	}
	$passive.Stop()
	Add-Event "PASSIVE_${passiveLimitSeconds}S_COMPLETE" "elapsed_since_latest_kernel_boot=$([math]::Round(([DateTimeOffset]::Now - $bootWall).TotalSeconds,1))s; kernel_boots_seen=$bootCount"
	}
	if ($Mode -eq 'rollback') {
		Wake-SerialConsole
		$rollbackMarker = "P4_ROLLBACK_STATUS_$([guid]::NewGuid().ToString('N'))"
		$status = Send-Serial "echo ROLLBACK_STATUS; cat /etc/openwrt_release; cat /etc/wifi-watchdog.mode 2>/dev/null; iw dev; ubus call network.wireless status; tail -n 30 /root/wifi-diag/watchdog.log 2>/dev/null; echo $rollbackMarker" $rollbackMarker 60
		[IO.File]::WriteAllText((Join-Path $roundDir 'rollback-status-serial.log'), $status.Text, [Text.UTF8Encoding]::new($false))
		Add-Event 'ROLLBACK_STATUS_CAPTURED' "sha256=$expectedHash"
		$summary = [ordered]@{ mode = $Mode; imageSha256 = $actualHash; rebootT0 = $bootWall.ToString('o'); passiveSeconds = [math]::Round($passive.Elapsed.TotalSeconds,1); statusLog = (Join-Path $roundDir 'rollback-status-serial.log') }
		$summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $roundDir 'round.json') -Encoding utf8
		Add-Event 'ROLLBACK_COMPLETE' 'stop condition handled; P4 screening remains stopped'
		Write-Host "ROLLBACK_EVIDENCE=$roundDir"
		return
	}

	if (-not $script:sshAvailableDuringPassive -and $ResumePostObservation) {
		$resumeSsh = Invoke-SSH 'true' (Join-Path $roundDir 'ssh-resume-post-observation.log') 8
		if ($resumeSsh.ExitCode -eq 0) {
			$script:sshAvailableDuringPassive = $true
			Add-Event 'SSH_AVAILABLE_AFTER_OBSERVATION' 'strict host-key and public-key authentication passed; COM9 left passive'
		}
	}
	if (-not $script:sshAvailableDuringPassive) {
	$hostMarker = "P4_HOSTKEY_$([guid]::NewGuid().ToString('N'))"
	Wake-SerialConsole
	$hostRead = Send-Serial "dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key; echo $hostMarker" $hostMarker 30
	if ($hostRead.Text -notmatch '(ssh-ed25519\s+[A-Za-z0-9+/]+={0,2}\s+[^\r\n\\]+)') { throw 'ED25519 public host key not found in COM9 output.' }
	$serialPub = $Matches[1].Trim()
	$serialPubPath = Join-Path $roundDir 'device-hostkey-from-com9.pub'
	[IO.File]::WriteAllText($serialPubPath, $serialPub + "`n", [Text.UTF8Encoding]::new($false))
	$fingerprintOutput = @(& $sshKeygen -lf $serialPubPath -E sha256 2>&1)
	$serialFingerprintMatch = [regex]::Match(($fingerprintOutput -join ' '), 'SHA256:[A-Za-z0-9+/]+')
	if ($LASTEXITCODE -ne 0 -or -not $serialFingerprintMatch.Success) { throw 'Cannot calculate COM9 ED25519 fingerprint.' }
	$serialFingerprint = $serialFingerprintMatch.Value

	$tempKnownHosts = Join-Path $roundDir 'known_hosts.probe'
	$probeArgs = @('-vvv', '-T', '-b', '192.168.1.222', '-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'PreferredAuthentications=none', '-o', 'PubkeyAuthentication=no', '-o', 'PasswordAuthentication=no', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'HashKnownHosts=no', '-o', "UserKnownHostsFile=$tempKnownHosts", 'root@192.168.1.1', 'true')
	$probeOutput = @(& $pwsh -NoProfile -File $netRun ssh @probeArgs 2>&1)
	[IO.File]::WriteAllLines((Join-Path $roundDir 'ssh-hostkey-probe.log'), [string[]]$probeOutput, [Text.UTF8Encoding]::new($false))
	$serverKeyLine = $probeOutput | Where-Object { $_ -match 'Server host key: ssh-ed25519 SHA256:' } | Select-Object -First 1
	$serverFingerprintMatch = [regex]::Match([string]$serverKeyLine, 'SHA256:[A-Za-z0-9+/]+')
	if (-not $serverKeyLine -or -not $serverFingerprintMatch.Success) { throw 'SSH handshake did not report an ED25519 fingerprint; see ssh-hostkey-probe.log.' }
	$scanFingerprint = $serverFingerprintMatch.Value
	$keyscanLine = Get-Content -LiteralPath $tempKnownHosts | Where-Object { $_ -match '^192\.168\.1\.1\s+ssh-ed25519\s+' } | Select-Object -First 1
	if (-not $keyscanLine) { throw 'SSH handshake did not save an ED25519 host key in the temporary known_hosts file.' }
	$scanPath = Join-Path $roundDir 'device-hostkey-from-ssh.pub'
	[IO.File]::WriteAllText($scanPath, ($keyscanLine -replace '^192\.168\.1\.1\s+', '') + "`n", [Text.UTF8Encoding]::new($false))
	$scanFingerprintOutput = @(& $sshKeygen -lf $scanPath -E sha256 2>&1)
	$scanFingerprintMatch = [regex]::Match(($scanFingerprintOutput -join ' '), 'SHA256:[A-Za-z0-9+/]+')
	if ($LASTEXITCODE -ne 0 -or -not $scanFingerprintMatch.Success) { throw 'Cannot calculate fingerprint from SSH handshake key.' }
	if ($scanFingerprintMatch.Value -ne $scanFingerprint) { throw 'SSH debug fingerprint differs from the temporary known_hosts key.' }
	Add-Event 'HOSTKEY_FINGERPRINTS' "COM9=$serialFingerprint SSH=$scanFingerprint"
	if ($serialFingerprint -ne $scanFingerprint) { throw 'Host-key mismatch; known_hosts not changed and no SSH session attempted.' }

	$newKey = [regex]::Match($keyscanLine, 'ssh-ed25519\s+([A-Za-z0-9+/]+={0,2})')
	if (-not $newKey.Success) { throw 'Cannot parse the SSH ED25519 key line.' }
	[IO.File]::WriteAllText($verifiedKnownHosts, $keyscanLine + "`n", [Text.ASCIIEncoding]::new())
	'Per-round known_hosts set only after COM9/SSH fingerprint match.' | Set-Content -LiteralPath (Join-Path $roundDir 'known-host-refresh.log')
	}
	$publicKeyPath = "$privateKey.pub"
	if (-not (Test-Path -LiteralPath $publicKeyPath)) { throw "SSH public key missing: $publicKeyPath" }
	$publicKey = (Get-Content -LiteralPath $publicKeyPath -Raw).Trim()
	if ($publicKey -notmatch '^ssh-ed25519\s+[A-Za-z0-9+/]+={0,2}(\s+[^\r\n]+)?$') { throw 'Expected a single-line ED25519 client public key.' }
	$sshTest = Invoke-SSH 'true' (Join-Path $roundDir 'ssh-test.log') 10
	$sshReady = ($sshTest.ExitCode -eq 0)
	if (-not $sshReady) {
		Add-Event 'SSH_FALLBACK_COM9' 'SSH unavailable after T+300..480 probe window; passive observation has ended'
		$writeMarker = "P4_KEY_WRITTEN_$([guid]::NewGuid().ToString('N'))"
		$writeKey = Send-Serial "printf '%s\n' '$publicKey' > /etc/dropbear/authorized_keys; echo $writeMarker" $writeMarker 60
		Add-Event 'SSH_PUBLIC_KEY_WRITTEN' "serial_elapsed=$([math]::Round($writeKey.Elapsed,2))s"
		$permissionMarker = "P4_KEY_PERMS_$([guid]::NewGuid().ToString('N'))"
		$permissions = Send-Serial "chown root:root /etc/dropbear /etc/dropbear/authorized_keys; chmod 700 /etc/dropbear; chmod 600 /etc/dropbear/authorized_keys; echo $permissionMarker" $permissionMarker 60
		Add-Event 'SSH_KEY_PERMISSIONS_SET' "serial_elapsed=$([math]::Round($permissions.Elapsed,2))s"
		$restartMarker = "P4_DROPBEAR_RESTARTED_$([guid]::NewGuid().ToString('N'))"
		$dropbearRestart = Send-Serial "/etc/init.d/dropbear restart; echo $restartMarker" $restartMarker 60
		Add-Event 'DROPBEAR_RESTARTED' "serial_elapsed=$([math]::Round($dropbearRestart.Elapsed,2))s"
		$loginWatch = [Diagnostics.Stopwatch]::StartNew()
		while ($loginWatch.Elapsed.TotalSeconds -lt 120) {
			$sshTest = Invoke-SSH 'true' (Join-Path $roundDir 'ssh-test.log') 5
			if ($sshTest.ExitCode -eq 0) { $sshReady = $true; break }
			Start-Sleep -Seconds 3
		}
		$loginWatch.Stop()
		Add-Event 'SSH_KEY_INSTALL_LOGIN_WAIT' "elapsed=$([math]::Round($loginWatch.Elapsed.TotalSeconds,1))s"
	}
	$sshAvailableAt = [math]::Round(([DateTimeOffset]::Now - $bootWall).TotalSeconds, 1)
	if (-not $sshReady) { Add-Event 'SSH_FUNCTION_FAIL' "T+${sshAvailableAt}s; no SSH gate or evidence collection"; throw 'SSH remained unavailable; watchdog hash gate and evidence collection were not completed.' }
	Add-Event 'SSH_AVAILABLE' "T+${sshAvailableAt}s"

	$expectedWatchdogHash = '50FCBEC9F1C37F2199F8C4F8802E1FC057DD7C0A3CE5EF16358158A0AED1C780'
	$watchdogGate = Invoke-SSH 'sha256sum /usr/sbin/k1plus-wifi-watchdog; grep -c "stage3 aborted" /usr/sbin/k1plus-wifi-watchdog; echo MODE; cat /etc/wifi-watchdog.mode' (Join-Path $roundDir 'watchdog-gate-ssh.log') 20
	$gateText = $watchdogGate.Output
	if ($watchdogGate.ExitCode -ne 0 -or $gateText -notmatch "(?im)^$expectedWatchdogHash\s+/usr/sbin/k1plus-wifi-watchdog\s*$") {
		Add-Event 'WATCHDOG_HASH_GATE_FAIL' "expected=$expectedWatchdogHash; see watchdog-gate-ssh.log"
		throw 'Watchdog SHA-256 gate failed; stopping this round.'
	}
	$expectedMode = if ($Mode -eq 'rollback') { 'recover' } else { $Mode }
	if ($gateText -notmatch "(?im)^$expectedMode\s*$") {
		Add-Event 'WATCHDOG_MODE_GATE_FAIL' "expected=$expectedMode; see watchdog-gate-ssh.log"
		throw 'Watchdog mode gate failed; stopping this round.'
	}
	if ($Mode -eq 'recover' -and $Round -eq 1 -and $gateText -notmatch '(?m)^\s*[1-9][0-9]*\s*$') {
		Add-Event 'FIRST_RECOVER_WATCHDOG_MARKER_FAIL' 'stage3 aborted source marker count was not positive'
		throw 'First recover round stage3-aborted marker gate failed.'
	}
	Add-Event 'WATCHDOG_HASH_GATE_PASS' "sha256=$expectedWatchdogHash"
	$gateDetails = Invoke-SSH 'echo UPTIME; uptime; cat /proc/uptime; echo IW_DEV; timeout 15 iw dev 2>&1; echo ROOT; ls -l /root /root/wifi-diag; echo STATE_FILES; ls -l /root/WATCHDOG-DISABLED.txt /etc/k1plus-watchdog-last-reboot 2>&1; echo WATCHDOG_LOG; sed -E "s/(psk|password|passphrase|key)[=:][^ ]+/\\1=[REDACTED]/Ig" /root/wifi-diag/watchdog.log 2>/dev/null' (Join-Path $roundDir 'watchdog-gate-details-ssh.log') 25
	Add-Event 'WATCHDOG_GATE_DETAILS_CAPTURED' "ssh_exit=$($gateDetails.ExitCode); see watchdog-gate-details-ssh.log"

	if ($sshReady) {
		$collect = Invoke-SSH 'mkdir -p /tmp/p4-out; tar czf /tmp/p4-out/diag.tgz /root/wifi-diag 2>/dev/null; cp /root/wifi-diag/watchdog.log /tmp/p4-out/watchdog.log 2>/dev/null; { date -Iseconds; date +%s; cat /proc/uptime; echo CONFIG_TIMES; busybox ls -l --full-time /etc/config/wireless /etc/config/network /etc/config/system 2>&1; stat -c "%n %y" /etc/config/wireless /etc/config/network /etc/config/system 2>&1; echo WATCHDOG_GATE; sha256sum /usr/sbin/k1plus-wifi-watchdog; grep -n "stage3 aborted" /usr/sbin/k1plus-wifi-watchdog; echo STATE; uptime; timeout 15 iw phy 2>&1; timeout 15 iw dev 2>&1; ubus call network.wireless status; sed -E "s/(psk|password|passphrase|key)[=:][^ ]+/\\1=[REDACTED]/Ig" /root/wifi-diag/watchdog.log 2>/dev/null; logread | sed -E "s/(psk|password|passphrase|key)[=:][^ ]+/\\1=[REDACTED]/Ig"; } > /tmp/p4-out/state.log' (Join-Path $roundDir 'collect-device.log') 45
		if ($collect.ExitCode -eq 0) {
			Invoke-SCP @('root@192.168.1.1:/tmp/p4-out/diag.tgz', (Join-Path $roundDir 'wifi-diag.tgz')) (Join-Path $roundDir 'diag-fetch.log')
			Invoke-SCP @('root@192.168.1.1:/tmp/p4-out/state.log', (Join-Path $roundDir 'state.log')) (Join-Path $roundDir 'state-fetch.log')
			Invoke-SCP @('root@192.168.1.1:/tmp/p4-out/watchdog.log', (Join-Path $roundDir 'watchdog.log')) (Join-Path $roundDir 'watchdog-fetch.log')
		}
	}
	if ($Mode -eq 'recover' -and $Round -eq 1) {
		$gateState = Get-Content -LiteralPath (Join-Path $roundDir 'state.log') -Raw -ErrorAction Stop
		$expectedWatchdogHash = '50FCBEC9F1C37F2199F8C4F8802E1FC057DD7C0A3CE5EF16358158A0AED1C780'
		if ($gateState -notmatch "(?im)^$expectedWatchdogHash\s+/usr/sbin/k1plus-wifi-watchdog\s*$" -or $gateState -notmatch 'stage3 aborted') {
			Add-Event 'FIRST_RECOVER_WATCHDOG_GATE_FAIL' "expected_sha256=$expectedWatchdogHash; see state.log"
			throw 'First recover round watchdog image gate failed; stopping P4.'
		}
		Add-Event 'FIRST_RECOVER_WATCHDOG_GATE_PASS' "sha256=$expectedWatchdogHash stage3_aborted_source_marker=present"
	}

	$serial = Get-SerialText
	$bootSegment = $serial.Substring([Math]::Min([int]$boot.Offset, $serial.Length))
	$phyMatch = [regex]::Match($bootSegment, '\[\s*([0-9]+(?:\.[0-9]+)?)\].{0,180}(?:wiphy_register\(phy0\)|phy0.*registered)')
	$apMatch = [regex]::Match($bootSegment, '\[\s*([0-9]+(?:\.[0-9]+)?)\].{0,220}phy0-ap0')
	$phyUptime = if ($phyMatch.Success) { $phyMatch.Groups[1].Value } else { 'not-seen' }
	$apUptime = if ($apMatch.Success) { $apMatch.Groups[1].Value } else { 'absent-300s' }
	$statePath = Join-Path $roundDir 'state.log'
	$stateText = if (Test-Path -LiteralPath $statePath) { [IO.File]::ReadAllText($statePath) } else { '' }
	$watchdogLogText = Get-Content -LiteralPath (Join-Path $roundDir 'watchdog.log') -Raw -ErrorAction SilentlyContinue
	$watchdogRows = @($watchdogLogText -split "`r?`n" | Where-Object { $_ -match 'START|HEALTH|THRESHOLD-REACHED|collect tag=|recovery stage [123]:|reboot cooldown|GAVE-UP|stage3 aborted' })
	$healthRows = @($watchdogRows | Where-Object { $_ -match ' HEALTH ' })
	$healthMismatchRows = @($healthRows | Where-Object { $_ -match 'ap_discovery_rc=0' -and $_ -match 'healthy_rc=1' })
	$stage3Aborted = [bool]($watchdogRows | Where-Object { $_ -match 'stage3 aborted' })
	$healthMismatchPath = Join-Path $roundDir 'health-ap-present-healthy-failed.log'
	if ($healthMismatchRows.Count -gt 0) { [IO.File]::WriteAllLines($healthMismatchPath, [string[]]$healthMismatchRows, [Text.UTF8Encoding]::new($false)) }
	else { [IO.File]::WriteAllText($healthMismatchPath, 'none' + [Environment]::NewLine, [Text.UTF8Encoding]::new($false)) }
	$thresholdRow = $watchdogRows | Where-Object { $_ -match 'THRESHOLD-REACHED' } | Select-Object -First 1
	$collectRows = @($watchdogRows | Where-Object { $_ -match 'collect tag=' })
	$stageRows = @($watchdogRows | Where-Object { $_ -match 'recovery stage [123]:|reboot cooldown active|GAVE-UP|stage3 aborted' })
	$wd = if ($stageRows.Count -gt 0) { "stages=$($stageRows -join '; '); collections=$($collectRows -join ', ')" } elseif ($thresholdRow) { "threshold=$thresholdRow; collections=$($collectRows -join ', ')" } else { 'no stage or threshold event in captured state' }
	$apPresent = $apMatch.Success -or $stateText.Contains('Interface phy0-ap0')
	if ($apPresent -and -not $apMatch.Success) { $apUptime = 'not-in-serial-log' }
	$outcome = if ($apPresent) { 'observed-present' } else { "observed-absent-at-${passiveLimitSeconds}s" }
	$rebootPattern = '\[(?<wall>2026-[^\]]+)\] RX \[\s*(?<up>\d+(?:\.\d+)?)\] reboot: Restarting system'
	$rebootRows = @(
		foreach ($candidate in [regex]::Matches($serial, $rebootPattern)) {
			if ([DateTimeOffset]::Parse($candidate.Groups['wall'].Value) -ge $bootWall) {
				$candidate.Groups['up'].Value.Trim()
			}
		}
	)
	$summary = [ordered]@{
		round = $roundName; mode = $Mode; imageSha256 = $actualHash; started = $scriptStart.ToString('o'); rebootT0 = $bootWall.ToString('o')
		phy0Uptime = $phyUptime; phy0Ap0Uptime = $apUptime; watchdog = $wd; stage3Aborted = $stage3Aborted; rebootUptimes = ($rebootRows -join ','); sshAvailableT = $sshAvailableAt; outcome = $outcome
		serialLog = $serialLog; evidenceDirectory = $roundDir
	}
	$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $roundDir 'round.json') -Encoding utf8
	$apResult = if ($apPresent) { "yes / $apUptime" } else { 'no / —' }
	$globalRoundNumber = if ($Mode -eq 'observe') { 6 + $Round } else { $Round }
	$globalRound = 'R{0:d2}' -f $globalRoundNumber
	$line = "| $globalRound | $Mode | $actualHash | $phyUptime | $apResult | $wd | $stage3Aborted | $($rebootRows -join ',') | $sshAvailableAt | $($healthMismatchRows.Count) | ``evidence/P4/$roundName/`` |"
	$trackerText = [IO.File]::ReadAllText($tracker)
	$sectionTitle = '## Strict-pair P4 rounds: recover Run 39408824234, observe Run 39416504363'
	if (-not $trackerText.Contains($sectionTitle)) {
		$trackerText += [Environment]::NewLine + $sectionTitle + [Environment]::NewLine + [Environment]::NewLine + '| Round | Mode | Image SHA-256 | phy0 uptime | phy0-ap0 | Watchdog stages | stage3 aborted | Reboot uptimes | SSH T+ seconds | AP-present HEALTH failures | Evidence |' + [Environment]::NewLine + '|---:|---|---|---:|---|---|---|---|---:|---:|---|' + [Environment]::NewLine
	}
	$pattern = "(?m)^\| $globalRound \| $Mode \|.*$"
	if ([regex]::IsMatch($trackerText, $pattern)) { $trackerText = [regex]::Replace($trackerText, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $line }, 1) }
	else { $trackerText += [Environment]::NewLine + $line + [Environment]::NewLine }
	[IO.File]::WriteAllText($tracker, $trackerText, [Text.UTF8Encoding]::new($false))
	Add-Event 'ROUND_COMPLETE' "outcome=$outcome phy0=$phyUptime phy0-ap0=$apUptime ssh_T=$sshAvailableAt"
	Write-Host "P4_ROW=$line"
} catch {
	Add-Event 'ROUND_STOP' $_.Exception.Message
	throw
}
