[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^firstboot-0[4-8]$')][string]$Experiment
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$evidenceRoot = Join-Path $repo 'evidence'
$serialLog = 'C:\Users\huangyifei\Documents\Codex\2026-09-20\new-chat\work\nanopi-release-bridge\evidence\com9-20261020-102145.log'
$commandDir = 'C:\Users\huangyifei\Documents\Codex\2026-09-20\new-chat\work\nanopi-release-bridge\evidence\com9-20261020-102145-commands'
$key = Join-Path $env:USERPROFILE '.ssh\openclaw-server'
$knownHosts = Get-ChildItem $evidenceRoot -Directory -Filter 'firstboot-mtime-*' -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ChildItem $_.FullName -File -Filter 'known_hosts.verified' -Recurse -ErrorAction SilentlyContinue } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $evidenceRoot "firstboot-mtime-$Experiment-$stamp"
New-Item -ItemType Directory -Path $outDir | Out-Null

function Invoke-SSH([string]$Remote, [string]$Name, [int]$Timeout = 20) {
    $args = @('-T','-o',"ConnectTimeout=$Timeout",'-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',"UserKnownHostsFile=$knownHosts",'-i',$key,'root@192.168.1.1',$Remote)
    $output = @(& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'net-run.ps1') ssh @args 2>&1)
    $code = $LASTEXITCODE
    [IO.File]::WriteAllLines((Join-Path $outDir "$Name.log"), [string[]]$output, [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ Code = $code; Text = ($output -join "`n") }
}

function Read-SerialFrom([long]$Offset) {
    $stream = [IO.File]::Open($serialLog, 'Open', 'Read', 'ReadWrite')
    try {
        if ($Offset -ge $stream.Length) { return '' }
        $stream.Position = $Offset
        $reader = [IO.StreamReader]::new($stream)
        return $reader.ReadToEnd()
    } finally { $stream.Dispose() }
}

function Send-Serial([string]$Command, [string]$Name, [int]$Timeout = 45) {
    $cursor = (Get-Item -LiteralPath $serialLog).Length
    $marker = "MTIME_${Experiment}_${Name}_$([guid]::NewGuid().ToString('N'))"
    $path = Join-Path $commandDir ("{0:D8}-{1}.cmd" -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds(), $Name)
    [IO.File]::WriteAllText($path, "$Command; echo $marker`n", [Text.UTF8Encoding]::new($false))
    $capture = [Text.StringBuilder]::new()
    $markerPattern = '(?m)^\[[^\r\n]*\] RX (?:' + [regex]::Escape($marker) + '(?:\\r\\n|$)|.*?\\r\\n' + [regex]::Escape($marker) + '(?:\\r\\n|$))'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $Timeout) {
        $chunk = Read-SerialFrom $cursor
        if ($chunk) {
            [void]$capture.Append($chunk)
            $cursor = (Get-Item -LiteralPath $serialLog).Length
            if ([regex]::IsMatch($capture.ToString(), $markerPattern)) {
                $text = $capture.ToString()
                [IO.File]::WriteAllText((Join-Path $outDir "$Name-com9.log"), $text, [Text.UTF8Encoding]::new($false))
                return $text
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "COM9 command marker timed out: $Name"
}

function Wait-Until([double]$Seconds, [Diagnostics.Stopwatch]$Clock) {
    while ($Clock.Elapsed.TotalSeconds -lt $Seconds) { Start-Sleep -Seconds 1 }
}

function Wait-SerialPrompt([int]$Timeout = 120) {
    $cursor = (Get-Item -LiteralPath $serialLog).Length
    $wake = Join-Path $commandDir ("{0:D8}-wake-shell.cmd" -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds())
    [IO.File]::WriteAllText($wake, "`n", [Text.UTF8Encoding]::new($false))
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $Timeout) {
        $text = Read-SerialFrom $cursor
        if ($text -match 'root@[^\r\n]*[#$]') { return }
        $cursor = (Get-Item -LiteralPath $serialLog).Length
        Start-Sleep -Milliseconds 500
    }
    throw "COM9 shell prompt was not observed within $Timeout seconds after a blank line."
}

if (-not $knownHosts) { throw 'No previously verified per-device known_hosts file was found.' }
if (-not (Test-Path -LiteralPath $commandDir)) { throw "COM9 command queue missing: $commandDir" }
$before = Get-Item -LiteralPath $serialLog
Start-Sleep -Seconds 10
$after = Get-Item -LiteralPath $serialLog
if ($after.Length -le $before.Length) { throw 'COM9 recorder log did not grow during the 10-second preflight.' }
@{before_bytes=$before.Length;before_time=$before.LastWriteTime.ToString('o');after_bytes=$after.Length;after_time=$after.LastWriteTime.ToString('o');growth=$after.Length-$before.Length;known_hosts=$knownHosts} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outDir 'preflight.json') -Encoding utf8

$pre = Invoke-SSH 'cat /proc/sys/kernel/random/boot_id; date; cat /proc/uptime; iw dev' 'pre-state'
if ($pre.Code -ne 0) { throw 'Pre-reboot SSH check failed.' }
$offset = (Get-Item -LiteralPath $serialLog).Length
$reboot = Invoke-SSH 'firstboot -y; sync; reboot' 'firstboot-reboot-command' 30
$reboot.Text | Set-Content -LiteralPath (Join-Path $outDir 'firstboot-reboot-output.txt') -Encoding utf8

$cursor = $offset
$seen = [Text.StringBuilder]::new()
$rebootTimer = [Diagnostics.Stopwatch]::StartNew()
while ($rebootTimer.Elapsed.TotalSeconds -lt 180) {
    $chunk = Read-SerialFrom $cursor
    if ($chunk) {
        [void]$seen.Append($chunk)
        $cursor = (Get-Item -LiteralPath $serialLog).Length
        if ($seen.ToString().Contains('reboot: Restarting system')) { break }
    }
    Start-Sleep -Seconds 1
}
if (-not $seen.ToString().Contains('reboot: Restarting system')) { throw 'COM9 did not record the reboot marker within 180 seconds.' }
[IO.File]::WriteAllText((Join-Path $outDir 'reboot-marker-com9.log'), $seen.ToString(), [Text.UTF8Encoding]::new($false))
$clock = [Diagnostics.Stopwatch]::StartNew()

Wait-Until 240 $clock
$snapshot240 = "date; cat /proc/uptime; ls -l --full-time /etc/config/ /root/wifi-diag/ /etc/wifi-release-done 2>&1; sed -E '/(key|psk|sae_password|passphrase)/d' /etc/config/wireless"
try {
    Wait-SerialPrompt 90
    $null = Send-Serial $snapshot240 'snapshot-240' 60
}
catch { $_.Exception.ToString() | Set-Content -LiteralPath (Join-Path $outDir 'snapshot-240-error.txt') -Encoding utf8 }

Wait-Until 315 $clock
$recoverDir = Join-Path $outDir 'ssh-recovery'
& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'firstboot-ssh-recover.ps1') -EvidenceDir $recoverDir
if ($LASTEXITCODE -ne 0) { throw "SSH recovery failed with exit code $LASTEXITCODE." }
$verified = Join-Path $recoverDir 'known_hosts.verified'
Copy-Item -LiteralPath $verified -Destination (Join-Path $outDir 'known_hosts.verified')
$knownHosts = $verified

& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'firstboot-collect-state.ps1') -EvidenceDir $outDir -TargetUptime 360
if ($LASTEXITCODE -ne 0) { throw "SSH collection failed with exit code $LASTEXITCODE." }

Wait-Until 600 $clock
$state600 = Invoke-SSH "date; cat /proc/uptime; ls -l --full-time /etc/config/ /root/wifi-diag/ /etc/wifi-release-done 2>&1; sed -E '/(key|psk|sae_password|passphrase)/d' /etc/config/wireless; readlink -f /sys/class/ieee80211/phy0/device; cat /proc/sys/kernel/random/boot_id" 'state-at-600'
if ($state600.Code -ne 0) { throw "SSH state read at 600s failed (rc=$($state600.Code))." }

$endOffset = (Get-Item -LiteralPath $serialLog).Length
$segment = Read-SerialFrom $offset
[IO.File]::WriteAllText((Join-Path $outDir 'com9-boot-segment.log'), $segment, [Text.UTF8Encoding]::new($false))
$meta = [ordered]@{experiment=$Experiment;started=$stamp;pre_boot_id=($pre.Text -split "`n")[0];reboot_marker_seen=$true;reboot_marker_elapsed_seconds=[math]::Round($rebootTimer.Elapsed.TotalSeconds,2);serial_start_offset=$offset;serial_end_offset=$endOffset;serial_log=$serialLog;ssh_360_and_600=true;status='COMPLETE'}
$meta | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outDir 'experiment.json') -Encoding utf8
Write-Output "EVIDENCE=$outDir"
