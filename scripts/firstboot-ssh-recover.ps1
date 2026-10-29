[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EvidenceDir,
    [string]$SerialLog = 'C:\Users\huangyifei\Documents\Codex\2026-09-20\new-chat\work\nanopi-release-bridge\evidence\com9-20261020-102145.log',
    [string]$CommandDirectory = 'C:\Users\huangyifei\Documents\Codex\2026-09-20\new-chat\work\nanopi-release-bridge\evidence\com9-20261020-102145-commands'
)

$ErrorActionPreference = 'Stop'
$netRun = Join-Path $PSScriptRoot 'net-run.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$sshKey = Join-Path $env:USERPROFILE '.ssh\openclaw-server'
$sshPub = "$sshKey.pub"
$sshKeygen = Join-Path $env:WINDIR 'System32/OpenSSH/ssh-keygen.exe'
$knownHosts = Join-Path $EvidenceDir 'known_hosts.verified'
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null

function Read-From([long]$Offset) {
    $stream = [IO.File]::Open($SerialLog, 'Open', 'Read', 'ReadWrite')
    try {
        if ($Offset -gt $stream.Length) { return '' }
        $stream.Position = $Offset
        $reader = [IO.StreamReader]::new($stream)
        return $reader.ReadToEnd()
    } finally { $stream.Dispose() }
}

function Send-Serial([string]$Command, [string]$Label, [int]$Timeout = 120) {
    $cursor = (Get-Item -LiteralPath $SerialLog).Length
    $marker = "FIRSTBOOT_RECOVER_${Label}_$([guid]::NewGuid().ToString('N'))"
    $file = Join-Path $CommandDirectory ("{0:D8}-{1}.cmd" -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds(), $Label)
    [IO.File]::WriteAllText($file, "$Command; echo $marker`n", [Text.UTF8Encoding]::new($false))
    $capture = [Text.StringBuilder]::new()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $markerPattern = '(?m)^\[[^\r\n]*\] RX (?:' + [regex]::Escape($marker) + '(?:\\r\\n|$)|.*?\\r\\n' + [regex]::Escape($marker) + '(?:\\r\\n|$))'
    while ($watch.Elapsed.TotalSeconds -lt $Timeout) {
        $chunk = Read-From $cursor
        if ($chunk.Length) {
            [void]$capture.Append($chunk)
            $cursor = (Get-Item -LiteralPath $SerialLog).Length
            if ([regex]::IsMatch($capture.ToString(), $markerPattern)) {
                $text = $capture.ToString()
                [IO.File]::WriteAllText((Join-Path $EvidenceDir "$Label-com9.log"), $text, [Text.UTF8Encoding]::new($false))
                return $text
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "COM9 command marker timed out: $Label"
}

function Wait-ConsolePrompt([int]$Timeout = 120) {
    $cursor = (Get-Item -LiteralPath $SerialLog).Length
    $wake = Join-Path $CommandDirectory ("{0:D8}-wake-shell.cmd" -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds())
    [IO.File]::WriteAllText($wake, "`n", [Text.UTF8Encoding]::new($false))
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $Timeout) {
        $text = Read-From $cursor
        if ($text -match 'root@[^\r\n]*[#$]') {
            [IO.File]::WriteAllText((Join-Path $EvidenceDir 'console-prompt-com9.log'), $text, [Text.UTF8Encoding]::new($false))
            return
        }
        $cursor = (Get-Item -LiteralPath $SerialLog).Length
        Start-Sleep -Milliseconds 500
    }
    throw "COM9 shell prompt was not observed within $Timeout seconds after a blank line."
}

function Invoke-SSH([string[]]$Arguments, [string]$Label) {
    $out = @(& $pwsh -NoProfile -File $netRun ssh @Arguments 2>&1)
    $code = $LASTEXITCODE
    [IO.File]::WriteAllLines((Join-Path $EvidenceDir "$Label.log"), [string[]]$out, [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ Code = $code; Text = ($out -join "`n") }
}

if (-not (Test-Path -LiteralPath $sshKey) -or -not (Test-Path -LiteralPath $sshPub)) { throw 'SSH client key pair is missing.' }
$pendingCommands = @(Get-ChildItem -LiteralPath $CommandDirectory -Filter '*.cmd' -File -ErrorAction SilentlyContinue)
if ($pendingCommands.Count -gt 0) { throw "COM9 command queue is not empty: $($pendingCommands.Name -join ', ')" }
Wait-ConsolePrompt

$hostText = Send-Serial 'dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key 2>&1' 'hostkey'
$hostMatch = [regex]::Match($hostText, '(?m)(ssh-ed25519\s+[A-Za-z0-9+/]+={0,2}(?:\s+root@[^\s\r\n]+)?)')
if (-not $hostMatch.Success) { throw 'COM9 output did not contain an ED25519 public host key.' }
$hostPub = Join-Path $EvidenceDir 'device-hostkey-from-com9.pub'
[IO.File]::WriteAllText($hostPub, $hostMatch.Groups[1].Value.Trim() + "`n", [Text.ASCIIEncoding]::new())
$serialFingerprint = [regex]::Match((@(& $sshKeygen -lf $hostPub -E sha256 2>&1) -join ' '), 'SHA256:[A-Za-z0-9+/]+').Value
if (-not $serialFingerprint) { throw 'Could not calculate the COM9 host-key fingerprint.' }

$probeKnownHosts = Join-Path $EvidenceDir 'known_hosts.probe'
$probeArgs = @('-vvv','-T','-o','ConnectTimeout=8','-o','BatchMode=yes','-o','PreferredAuthentications=none','-o','PubkeyAuthentication=no','-o','PasswordAuthentication=no','-o','StrictHostKeyChecking=accept-new','-o','HashKnownHosts=no','-o',"UserKnownHostsFile=$probeKnownHosts",'root@192.168.1.1','true')
$sshFingerprint = ''
for ($attempt = 1; $attempt -le 20 -and -not $sshFingerprint; $attempt++) {
    $probe = Invoke-SSH $probeArgs ('ssh-hostkey-probe-{0:D2}' -f $attempt)
    $sshFingerprint = [regex]::Match($probe.Text, 'Server host key: ssh-ed25519 \(?(SHA256:[A-Za-z0-9+/]+)\)?').Groups[1].Value
    if (-not $sshFingerprint -and $attempt -lt 20) { Start-Sleep -Seconds 10 }
}
if (-not $sshFingerprint) { throw 'SSH server host key was not observed after 20 probes.' }
if ($sshFingerprint -ne $serialFingerprint) { throw "Host-key mismatch: COM9=$serialFingerprint SSH=$sshFingerprint" }
[IO.File]::WriteAllText($knownHosts, "192.168.1.1 $($hostMatch.Groups[1].Value.Trim())`n", [Text.ASCIIEncoding]::new())

$publicKey = (Get-Content -Raw -LiteralPath $sshPub).Trim()
$safeKey = $publicKey.Replace("'", "'\\''")
$null = Send-Serial "mkdir -p /etc/dropbear; printf '%s\n' '$safeKey' > /etc/dropbear/authorized_keys" 'ssh-key-write' 90
$null = Send-Serial 'chown root:root /etc/dropbear /etc/dropbear/authorized_keys; chmod 700 /etc/dropbear; chmod 600 /etc/dropbear/authorized_keys; /etc/init.d/dropbear restart' 'ssh-service-restart' 90
Start-Sleep -Seconds 3
$expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($publicKey + "`n"))).ToLowerInvariant()
$keyCheck = Send-Serial 'sha256sum /etc/dropbear/authorized_keys' 'ssh-key-readback' 45
$actualHash = [regex]::Match($keyCheck, '(?m)([a-fA-F0-9]{64})').Groups[1].Value.ToLowerInvariant()
if (-not $actualHash -or $actualHash -ne $expectedHash) { throw "Installed SSH key hash mismatch: expected=$expectedHash actual=$actualHash" }
$loginArgs = @('-T','-o','ConnectTimeout=10','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',"UserKnownHostsFile=$knownHosts",'-i',$sshKey,'root@192.168.1.1','cat /proc/uptime')
$login = Invoke-SSH $loginArgs 'ssh-login'
if ($login.Code -ne 0) { throw "SSH login failed after key installation; see ssh-login.log (rc=$($login.Code))." }

@{ com9_fingerprint = $serialFingerprint; ssh_fingerprint = $sshFingerprint; match = $true; ssh_login_rc = $login.Code } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $EvidenceDir 'hostkey-verification.json') -Encoding utf8
Write-Output "HOSTKEY_MATCH=$serialFingerprint"
Write-Output "SSH_LOGIN=$($login.Text)"
