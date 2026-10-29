[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EvidenceDir,
    [int]$TargetUptime = 600
)

$ErrorActionPreference = 'Stop'
$netRun = Join-Path $PSScriptRoot 'net-run.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$sshKey = Join-Path $env:USERPROFILE '.ssh\openclaw-server'
$knownHosts = Join-Path $EvidenceDir 'known_hosts.verified'

function Invoke-SSH([string]$Remote, [string]$Name, [int]$Timeout = 15) {
    $args = @('-T','-o',"ConnectTimeout=$Timeout",'-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',"UserKnownHostsFile=$knownHosts",'-i',$sshKey,'root@192.168.1.1',$Remote)
    $out = @(& $pwsh -NoProfile -File $netRun ssh @args 2>&1)
    $code = $LASTEXITCODE
    [IO.File]::WriteAllLines((Join-Path $EvidenceDir "$Name.log"), [string[]]$out, [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ Code = $code; Text = ($out -join "`n") }
}

while ($true) {
    $probe = Invoke-SSH 'cat /proc/uptime' 'uptime-probe'
    $first = ($probe.Text -split '\s+')[0]
    if ($probe.Code -eq 0 -and $first -match '^\d+(\.\d+)?$' -and [double]$first -ge $TargetUptime) {
        $uptime = [double]$first
        break
    }
    Start-Sleep -Seconds 5
}

$remote = @'
echo SNAPSHOT_BEGIN
date
cat /proc/uptime
cat /proc/sys/kernel/random/boot_id
echo CONFIG_TIMES_BEGIN
ls -l --full-time /etc/config/ /root/wifi-diag/ /etc/wifi-release-done 2>&1
echo CONFIG_TIMES_END
echo WIRELESS_BEGIN
sed -E '/(key|psk|sae_password|passphrase)/d' /etc/config/wireless
echo WIRELESS_END
echo PATH_BEGIN
readlink -f /sys/class/ieee80211/phy0/device
echo PATH_END
echo LOGREAD_BEGIN
logread | sed -E 's/((key|psk|password|passphrase|sae_password)[ =:]+)[^ ]+/\1<redacted>/Ig'
echo LOGREAD_END
echo DMESG_BEGIN
dmesg
echo DMESG_END
echo WATCHDOG_BEGIN
sed -E 's/((key|psk|password|passphrase|sae_password)[ =:]+)[^ ]+/\1<redacted>/Ig' /root/wifi-diag/watchdog.log 2>/dev/null
echo WATCHDOG_END
tar czf /tmp/firstboot-wifi-diag.tgz /root/wifi-diag 2>/dev/null
echo SNAPSHOT_END
'@ -replace "`r?`n", '; '
$snapshot = Invoke-SSH $remote 'state-at-target' 45
if ($snapshot.Code -ne 0) { throw "Read-only snapshot failed with rc=$($snapshot.Code)." }

$scpArgs = @('-O','-o','ConnectTimeout=10','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',"UserKnownHostsFile=$knownHosts",'-i',$sshKey,'root@192.168.1.1:/tmp/firstboot-wifi-diag.tgz',(Join-Path $EvidenceDir 'wifi-diag.tgz'))
$scp = @(& $pwsh -NoProfile -File $netRun scp @scpArgs 2>&1)
$scpCode = $LASTEXITCODE
[IO.File]::WriteAllLines((Join-Path $EvidenceDir 'scp-diag.log'), [string[]]$scp, [Text.UTF8Encoding]::new($false))
if ($scpCode -ne 0) { throw "scp -O failed with rc=$scpCode." }
Write-Output "SNAPSHOT_UPTIME=$uptime"
Write-Output "EVIDENCE=$EvidenceDir"
