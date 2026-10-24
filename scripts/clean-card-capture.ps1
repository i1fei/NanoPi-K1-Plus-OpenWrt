param(
    [string]$SerialLog = 'C:\Users\huangyifei\Documents\Codex\2026-09-20\new-chat\work\nanopi-release-bridge\evidence\com9-20261020-102145.log',
    [string]$CommandDirectory = 'C:\Users\huangyifei\Documents\Codex\2026-09-20\new-chat\work\nanopi-release-bridge\evidence\com9-20261020-102145-commands',
    [string]$EvidenceRoot = 'C:\Users\huangyifei\Documents\Codex\2026-09-20\new-chat\work\nanopi-release-bridge-wdguard\evidence'
)

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $EvidenceRoot "clean-card-$stamp"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function Read-SerialLog {
    $stream = [IO.File]::Open($SerialLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $reader = [IO.StreamReader]::new($stream); return $reader.ReadToEnd() } finally { $stream.Dispose() }
}

function Redact([string]$Text) {
    $Text -replace '(?im)^([^\r\n]*(?:wpa_passphrase|psk|sae_password|passphrase|password|key)[^\r\n]*)$', '$1' |
        ForEach-Object { $_ -replace '(?i)((?:wpa_passphrase|psk|sae_password|passphrase|password|key)[=:][^\s\r\n]+)', '$1=[REDACTED]' }
}

function Send-Command([string]$Command, [string]$Label, [int]$TimeoutSeconds = 180) {
    $before = (Get-Item -LiteralPath $SerialLog).Length
    $marker = "CLEAN_CARD_${Label}_$([guid]::NewGuid().ToString('N'))"
    $file = Join-Path $CommandDirectory ("{0:D8}-{1}.cmd" -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds(), $Label)
    $wire = "$Command; echo $marker"
    [IO.File]::WriteAllText($file, $wire + "`n", [Text.UTF8Encoding]::new($false))
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $text = Read-SerialLog
        if ($text.Length -gt $before) {
            $delta = $text.Substring($before)
            if ($delta.Contains($marker)) {
                $watch.Stop()
                $path = Join-Path $outDir "$Label.log"
                [IO.File]::WriteAllText($path, (Redact $delta), [Text.UTF8Encoding]::new($false))
                return [PSCustomObject]@{ Text = $delta; Elapsed = $watch.Elapsed.TotalSeconds; Path = $path }
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Timed out waiting for $Label marker"
}

function Get-Uptime {
    $text = Read-SerialLog
    $matches = [regex]::Matches($text, '(?m)\[\s*(?<up>\d+(?:\.\d+)?)\]')
    if ($matches.Count -eq 0) { return $null }
    return [double]$matches[$matches.Count - 1].Groups['up'].Value
}

function Snapshot-Command([int]$Target) {
    @(
        "echo CLEAN_CARD_SNAPSHOT=$Target",
        'cat /proc/uptime',
        'echo LOGREAD_BEGIN; logread; echo LOGREAD_END',
        'echo UBUS_LIST_BEGIN; ubus list; echo UBUS_LIST_END',
        'echo WIRELESS_STATUS_BEGIN; ubus call network.wireless status; echo WIRELESS_STATUS_END',
        'echo IW_PHY_BEGIN; iw phy; echo IW_PHY_END',
        'echo IW_DEV_BEGIN; iw dev; echo IW_DEV_END',
        'echo PS_BEGIN; ps w; echo PS_END',
        'echo RUN_FILES_BEGIN; ls -l /var/run/hostapd* /var/run/wpa_supplicant* /var/run/hostapd/ 2>&1; ls -l /var/run /tmp/run 2>&1; echo RUN_FILES_END',
        'echo HOSTAPD_CONF_BEGIN; if [ -f /var/run/hostapd-phy0.conf ]; then grep -Ev "wpa_passphrase|psk|sae_password|key" /var/run/hostapd-phy0.conf; else echo ABSENT; fi; echo HOSTAPD_CONF_END',
        'date; echo PROC_UPTIME_END; cat /proc/uptime'
    ) -join '; '
}

Write-Output "CLEAN_CARD_DIR=$outDir"
$targets = @(30, 90, 240)
$done = @{}
$sshInstallDone = $false
while ($true) {
    $up = Get-Uptime
    if ($null -ne $up) {
        foreach ($target in $targets) {
            if (-not $done.ContainsKey($target) -and $up -ge $target) {
                $result = Send-Command (Snapshot-Command $target) "snapshot-$target"
                $done[$target] = $true
                Add-Content -LiteralPath (Join-Path $outDir 'timeline.log') -Value ("snapshot={0} device_uptime={1} elapsed={2}" -f $target,$up,[math]::Round($result.Elapsed,1))
                Write-Output "SNAPSHOT target=$target uptime=$up path=$($result.Path)"
            }
        }
        if (-not $sshInstallDone -and $up -ge 300) {
            $sshInstallDone = $true
            $publicKeyPath = Join-Path $env:USERPROFILE '.ssh\openclaw-server.pub'
            if (Test-Path -LiteralPath $publicKeyPath) {
                $publicKey = (Get-Content -LiteralPath $publicKeyPath -Raw).Trim()
                $safeKey = $publicKey.Replace("'", "'\\''")
                $install = "printf '%s\\n' '$safeKey' > /etc/dropbear/authorized_keys; chown root:root /etc/dropbear /etc/dropbear/authorized_keys; chmod 700 /etc/dropbear; chmod 600 /etc/dropbear/authorized_keys; /etc/init.d/dropbear restart"
                $result = Send-Command $install 'ssh-install' 120
                Add-Content -LiteralPath (Join-Path $outDir 'timeline.log') -Value ("ssh_install device_uptime={0} elapsed={1}" -f $up,[math]::Round($result.Elapsed,1))
                Write-Output "SSH_INSTALL uptime=$up path=$($result.Path)"
            } else {
                Add-Content -LiteralPath (Join-Path $outDir 'timeline.log') -Value 'ssh_install NOT_EXECUTED: client public key missing'
                Write-Output 'SSH_INSTALL NOT_EXECUTED: client public key missing'
            }
        }
        if ($up -ge 900 -and $done.Count -eq 3) { break }
    }
    Start-Sleep -Seconds 2
}

@{
    condition = 'raw TF image; empty overlay; non-sysupgrade'
    snapshot_targets = $targets
    observation_end_uptime = 900
    evidence = $outDir
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outDir 'clean-card.json') -Encoding utf8
Write-Output "CLEAN_CARD_COMPLETE=$outDir"
