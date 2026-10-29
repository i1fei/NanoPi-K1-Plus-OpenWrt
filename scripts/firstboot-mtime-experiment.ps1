[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^(firstboot-[0-9]{2}|ordinary-reboot)$')][string]$Experiment,
    [int]$ObservationSeconds = 900
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$evidenceRoot = Join-Path $repo 'evidence'
$serialLog = Join-Path (Split-Path -Parent $repo) 'nanopi-release-bridge\evidence\com9-20261020-102145.log'
$commandDir = Join-Path (Split-Path -Parent $repo) 'nanopi-release-bridge\evidence\com9-20261020-102145-commands'
$privateKey = Join-Path $env:USERPROFILE '.ssh\openclaw-server'
$verifiedKnownHosts = Get-ChildItem (Join-Path $evidenceRoot 'firstboot-mtime-*\known_hosts.verified') -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
$knownHosts = if ($verifiedKnownHosts) { $verifiedKnownHosts.FullName } else { Join-Path $repo 'evidence\clean-card-20261024-111524\clean-card-known_hosts' }
$netRun = Join-Path $PSScriptRoot 'net-run.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $evidenceRoot "firstboot-mtime-$Experiment-$stamp"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function Read-Serial {
    $stream = [IO.File]::Open($serialLog, 'Open', 'Read', 'ReadWrite')
    try { $reader = [IO.StreamReader]::new($stream); return $reader.ReadToEnd() }
    finally { $stream.Dispose() }
}

function Read-SerialFrom([long]$Offset) {
    $stream = [IO.File]::Open($serialLog, 'Open', 'Read', 'ReadWrite')
    try {
        if ($Offset -gt $stream.Length) { return '' }
        $stream.Position = $Offset
        $reader = [IO.StreamReader]::new($stream)
        return $reader.ReadToEnd()
    } finally { $stream.Dispose() }
}

function Invoke-SSH([string]$Command, [string]$Name, [int]$Timeout = 20) {
    $args = @('-T','-o',"ConnectTimeout=$Timeout",'-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',"UserKnownHostsFile=$knownHosts",'-i',$privateKey,'root@192.168.1.1',$Command)
    $output = @(& $pwsh -NoProfile -File $netRun ssh @args 2>&1)
    $code = $LASTEXITCODE
    [IO.File]::WriteAllLines((Join-Path $outDir "$Name.log"), [string[]]$output, [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ Code = $code; Text = ($output -join "`n") }
}

function Invoke-Net([string]$Tool, [string[]]$CommandArgs, [string]$OutFile) {
    $output = @(& $pwsh -NoProfile -File $netRun $Tool @CommandArgs 2>&1)
    $code = $LASTEXITCODE
    [IO.File]::WriteAllLines($OutFile, [string[]]$output, [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ Code = $code; Text = ($output -join "`n") }
}

function Establish-VerifiedSSH {
    $hostKey = Send-Serial 'dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key 2>&1' 'hostkey' 90
    [IO.File]::WriteAllText((Join-Path $outDir 'hostkey-com9.log'), $hostKey.Text, [Text.UTF8Encoding]::new($false))
    $m = [regex]::Match($hostKey.Text, '(?m)(ssh-ed25519\s+[A-Za-z0-9+/]+={0,2}(?:\s+[^\s\r\n]+)?)')
    if (-not $m.Success) { throw 'ED25519 host key not found in COM9 output.' }
    $pubFile = Join-Path $outDir 'device-hostkey-from-com9.pub'
    [IO.File]::WriteAllText($pubFile, $m.Groups[1].Value.Trim() + "`n", [Text.ASCIIEncoding]::new())
    $fp = @(& (Join-Path $env:WINDIR 'System32/OpenSSH/ssh-keygen.exe') -lf $pubFile -E sha256 2>&1) -join ' '
    $serialFp = [regex]::Match($fp, 'SHA256:[A-Za-z0-9+/]+').Value
    if (-not $serialFp) { throw 'Unable to calculate COM9 host-key fingerprint.' }

    $installKey = (Get-Content -Raw -LiteralPath "$env:USERPROFILE\.ssh\openclaw-server.pub").Trim()
    $safeKey = $installKey.Replace("'", "'\\''")
    $install = Send-Serial "mkdir -p /etc/dropbear; printf '%s\\n' '$safeKey' > /etc/dropbear/authorized_keys; chown root:root /etc/dropbear /etc/dropbear/authorized_keys; chmod 700 /etc/dropbear; chmod 600 /etc/dropbear/authorized_keys; /etc/init.d/dropbear restart" 'ssh-install' 150
    [IO.File]::WriteAllText((Join-Path $outDir 'ssh-install.log'), $install.Text, [Text.UTF8Encoding]::new($false))
    Start-Sleep -Seconds 3

    $knownHosts = Join-Path $outDir 'known_hosts.verified'
    $probeArgs = @('-vvv','-T','-o','ConnectTimeout=10','-o','BatchMode=yes','-o','PreferredAuthentications=none','-o','PubkeyAuthentication=no','-o','PasswordAuthentication=no','-o','StrictHostKeyChecking=accept-new','-o','HashKnownHosts=no','-o',"UserKnownHostsFile=$knownHosts",'root@192.168.1.1','true')
    $probe = Invoke-Net 'ssh' $probeArgs (Join-Path $outDir 'ssh-hostkey-probe.log')
    $sshFp = [regex]::Match($probe.Text, 'Server host key: ssh-ed25519 \((SHA256:[A-Za-z0-9+/]+)\)').Groups[1].Value
    if (-not $sshFp -or $sshFp -ne $serialFp) { throw "Host-key mismatch or probe failure: COM9=$serialFp SSH=$sshFp rc=$($probe.Code)" }
    @{serial_fingerprint=$serialFp; ssh_fingerprint=$sshFp; match=$true} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outDir 'hostkey-verification.json') -Encoding utf8
}

function Send-Serial([string]$Command, [string]$Name, [int]$Timeout = 90) {
    $before = (Get-Item -LiteralPath $serialLog).Length
    $cursor = $before
    $capture = [Text.StringBuilder]::new()
    $marker = "MTIME_${Experiment}_${Name}_$([guid]::NewGuid().ToString('N'))"
    $file = Join-Path $commandDir ("{0:D8}-{1}.cmd" -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds(), $Name)
    [IO.File]::WriteAllText($file, "$Command; echo $marker`n", [Text.UTF8Encoding]::new($false))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Timeout) {
        $text = Read-SerialFrom $cursor
        if ($text.Length) {
            [void]$capture.Append($text)
            $cursor = (Get-Item -LiteralPath $serialLog).Length
            if ($capture.ToString().Contains($marker)) {
                $delta = $capture.ToString()
                [IO.File]::WriteAllText((Join-Path $outDir "$Name-com9.log"), $delta, [Text.UTF8Encoding]::new($false))
                return [pscustomobject]@{ Code = 0; Text = $delta; Marker = $marker }
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "COM9 marker timeout: $Name"
}

function Get-Uptime([string]$Text) {
    $m = [regex]::Match($Text, '(?m)^\s*(\d+(?:\.\d+)?)\s+\d+(?:\.\d+)?\s*$')
    if ($m.Success) { return [double]$m.Groups[1].Value }
    return $null
}

function Snapshot-Command {
    return @'
echo SNAPSHOT_BEGIN
date
cat /proc/uptime
echo LS_BEGIN
ls -l --full-time /etc/config/ /root/wifi-diag/ /etc/wifi-release-done 2>&1
echo LS_END
echo WIRELESS_BEGIN
sed -E '/(key|psk|sae_password|passphrase)/d' /etc/config/wireless
echo WIRELESS_END
echo LOGREAD_BEGIN
logread | sed -E 's/((key|psk|password|passphrase|sae_password)[ =:]+)[^ ]+/\1<redacted>/Ig'
echo LOGREAD_END
echo DMESG_BEGIN
dmesg
echo DMESG_END
echo PHY_BEGIN
readlink -f /sys/class/ieee80211/phy0/device
cat /proc/uptime
echo PHY_END
echo SNAPSHOT_END
'@ -replace "`r?`n", '; '
}

if (-not (Test-Path -LiteralPath $serialLog)) { throw "COM9 log missing: $serialLog" }
if (-not (Test-Path -LiteralPath $commandDir)) { throw "COM9 command directory missing: $commandDir" }

$meta = [ordered]@{ experiment = $Experiment; started = [DateTimeOffset]::Now.ToString('o'); serialLog = $serialLog; status = 'STARTED' }
$meta | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outDir 'experiment.json') -Encoding utf8

$pre = Invoke-SSH 'cat /proc/sys/kernel/random/boot_id; cat /proc/uptime; iw dev' 'pre-state' 15
if ($pre.Code -ne 0) { throw 'Initial SSH read failed.' }
$serialStart = (Get-Item -LiteralPath $serialLog).Length

if ($Experiment -eq 'ordinary-reboot') {
    $reboot = Invoke-SSH 'sync; reboot' 'reboot-command' 15
} else {
    $reboot = Invoke-SSH 'firstboot -y; sync; reboot' 'firstboot-reboot-command' 20
}

$bootSw = [Diagnostics.Stopwatch]::StartNew()
$bootCursor = $serialStart
$bootCapture = [Text.StringBuilder]::new()
while ($bootSw.Elapsed.TotalSeconds -lt 180) {
    $text = Read-SerialFrom $bootCursor
    if ($text.Length) {
        [void]$bootCapture.Append($text)
        $bootCursor = (Get-Item -LiteralPath $serialLog).Length
        if ($bootCapture.ToString() -match 'reboot: Restarting system') { break }
    }
    Start-Sleep -Seconds 1
}
$bootSw.Stop()
if ($bootSw.Elapsed.TotalSeconds -ge 180) { throw 'Reboot marker not observed.' }

$timeline = [System.Collections.Generic.List[string]]::new()
$timeline.Add("reboot_marker_elapsed=$([math]::Round($bootSw.Elapsed.TotalSeconds,2))")
$wait = 240 - [math]::Floor($bootSw.Elapsed.TotalSeconds)
if ($wait -gt 0) { Start-Sleep -Seconds $wait }
try {
    $snap = Send-Serial (Snapshot-Command) 'snapshot-240' 120
    $up = Get-Uptime $snap.Text
    $timeline.Add("snapshot=240 channel=COM9 uptime=$up")
} catch {
    $timeline.Add("snapshot=240 channel=COM9 error=$($_.Exception.Message)")
}

$wait = 300 - [math]::Floor($bootSw.Elapsed.TotalSeconds)
if ($wait -gt 0) { Start-Sleep -Seconds $wait }

$sshInstalled = $false
try {
    $key = Get-Content -Raw -LiteralPath "$env:USERPROFILE\.ssh\openclaw-server.pub"
    $safeKey = $key.Trim().Replace("'", "'\\''")
    $install = Send-Serial "printf '%s\\n' '$safeKey' > /etc/dropbear/authorized_keys; chown root:root /etc/dropbear /etc/dropbear/authorized_keys; chmod 700 /etc/dropbear; chmod 600 /etc/dropbear/authorized_keys; /etc/init.d/dropbear restart" 'ssh-install' 150
    $sshInstalled = $true
} catch {
    [IO.File]::WriteAllText((Join-Path $outDir 'ssh-install-error.txt'), $_.Exception.ToString(), [Text.UTF8Encoding]::new($false))
}

if ($sshInstalled) {
    Establish-VerifiedSSH
    $wait = 600 - [math]::Floor($bootSw.Elapsed.TotalSeconds)
    if ($wait -gt 0) { Start-Sleep -Seconds $wait }
    $post = Invoke-SSH ("date; cat /proc/uptime; cat /proc/sys/kernel/random/boot_id; echo WATCHDOG_BEGIN; sed -E 's/((key|psk|password|passphrase|sae_password)[ =:]+)[^ ]+/\1<redacted>/Ig' /root/wifi-diag/watchdog.log 2>/dev/null; echo WATCHDOG_END; echo CONFIG_BEGIN; ls -l --full-time /etc/config/ /root/wifi-diag/ /etc/wifi-release-done 2>&1; echo CONFIG_END; echo WIRELESS_BEGIN; sed -E '/(key|psk|sae_password|passphrase)/d' /etc/config/wireless; echo WIRELESS_END; echo LOGREAD_BEGIN; logread | sed -E 's/((key|psk|password|passphrase|sae_password)[ =:]+)[^ ]+/\1<redacted>/Ig'; echo LOGREAD_END; echo DMESG_BEGIN; dmesg; echo DMESG_END; echo PHY_BEGIN; readlink -f /sys/class/ieee80211/phy0/device; echo PHY_END") 'post-ssh-state' 40
}

$meta.status = 'COMPLETE'
$meta.completed = [DateTimeOffset]::Now.ToString('o')
$meta | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outDir 'experiment.json') -Encoding utf8
[IO.File]::WriteAllText((Join-Path $outDir 'com9-boot-segment.log'), (Read-SerialFrom $serialStart), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllLines((Join-Path $outDir 'timeline.txt'), [string[]]$timeline, [Text.UTF8Encoding]::new($false))
Write-Output "EVIDENCE=$outDir"
