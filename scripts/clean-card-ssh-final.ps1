param(
    [Parameter(Mandatory=$true)][string]$EvidenceDir,
    [string]$SerialLog = 'C:\Users\huangyifei\Documents\Codex\2026-09-20\new-chat\work\nanopi-release-bridge\evidence\com9-20261020-102145.log',
    [string]$CommandDirectory = 'C:\Users\huangyifei\Documents\Codex\2026-09-20\new-chat\work\nanopi-release-bridge\evidence\com9-20261020-102145-commands'
)

$ErrorActionPreference = 'Stop'
$netRun = Join-Path $PSScriptRoot 'net-run.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$key = Join-Path $env:USERPROFILE '.ssh\openclaw-server'
$pub = "$key.pub"
$sshKeygen = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
$known = Join-Path $EvidenceDir 'clean-card-known_hosts'
$hostTranscript = Join-Path $EvidenceDir 'hostkey-com9-transcript.log'
$probeLog = Join-Path $EvidenceDir 'ssh-hostkey-probe.log'
$sshLog = Join-Path $EvidenceDir 'ssh-final.log'
$scpLog = Join-Path $EvidenceDir 'scp-diag.log'
$diagTar = Join-Path $EvidenceDir 'wifi-diag.tgz'

function Read-SerialLog {
    $s=[IO.File]::Open($SerialLog,'Open','Read','ReadWrite'); try {$r=[IO.StreamReader]::new($s);$r.ReadToEnd()} finally {$s.Dispose()}
}
function Send-Serial([string]$Command,[string]$Label,[int]$Timeout=60) {
    $before=(Get-Item -LiteralPath $SerialLog).Length
    $marker="CLEAN_CARD_FINAL_${Label}_$([guid]::NewGuid().ToString('N'))"
    $file=Join-Path $CommandDirectory ("{0:D8}-{1}.cmd" -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds(),$Label)
    [IO.File]::WriteAllText($file,"$Command; echo $marker`n",[Text.UTF8Encoding]::new($false))
    $sw=[Diagnostics.Stopwatch]::StartNew()
    while($sw.Elapsed.TotalSeconds -lt $Timeout){$all=Read-SerialLog;if($all.Length -gt $before){$d=$all.Substring($before);if($d.Contains($marker)){[IO.File]::WriteAllText($hostTranscript,$d,[Text.UTF8Encoding]::new($false));return $d}};Start-Sleep -Milliseconds 500}
    throw "COM9 marker timeout: $Label"
}
function Invoke-Net([string]$Tool,[string[]]$CommandArgs,[string]$OutFile) {
    $out=@(& $pwsh -NoProfile -File $netRun $Tool @CommandArgs 2>&1); $code=$LASTEXITCODE
    [IO.File]::WriteAllLines($OutFile,[string[]]$out,[Text.UTF8Encoding]::new($false))
    return [PSCustomObject]@{Code=$code;Text=($out -join "`n")}
}

if(-not(Test-Path -LiteralPath $key)){throw "SSH private key missing: $key"}
$serial=Send-Serial 'dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key' 'HOSTKEY'
$m=[regex]::Match($serial,'(ssh-ed25519\s+[A-Za-z0-9+/]+={0,2}(?:\s+[^\s\\]+)?)')
if(-not $m.Success){throw 'ED25519 host key not found in COM9 output'}
$serialPub=Join-Path $EvidenceDir 'device-hostkey-from-com9.pub'
[IO.File]::WriteAllText($serialPub,$m.Groups[1].Value.Trim()+"`n",[Text.ASCIIEncoding]::new())
$fpOut=@(& $sshKeygen -lf $serialPub -E sha256 2>&1); $serialFp=[regex]::Match(($fpOut -join ' '),'SHA256:[A-Za-z0-9+/]+').Value
if(-not $serialFp){throw 'Unable to calculate COM9 host-key fingerprint'}

$probeArgs=@('-vvv','-T','-o','ConnectTimeout=5','-o','BatchMode=yes','-o','PreferredAuthentications=none','-o','PubkeyAuthentication=no','-o','PasswordAuthentication=no','-o','StrictHostKeyChecking=accept-new','-o','HashKnownHosts=no','-o',"UserKnownHostsFile=$known",'root@192.168.1.1','true')
$probe=Invoke-Net 'ssh' $probeArgs $probeLog
$sshFp=[regex]::Match($probe.Text,'Server host key: ssh-ed25519 (SHA256:[A-Za-z0-9+/]+)').Groups[1].Value
if($probe.Code -ne 0 -and -not $sshFp){throw "SSH host-key probe failed; see $probeLog"}
if($sshFp -ne $serialFp){throw "Host-key mismatch COM9=$serialFp SSH=$sshFp"}

$sshArgs=@('-T','-o','ConnectTimeout=10','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',"UserKnownHostsFile=$known",'-i',$key,'root@192.168.1.1','tar czf /tmp/clean-card-wifi-diag.tgz /root/wifi-diag 2>/dev/null')
$sshResult=Invoke-Net 'ssh' $sshArgs $sshLog
if($sshResult.Code -ne 0){throw "SSH evidence command failed; see $sshLog"}

$scpArgs=@('-O','-o','ConnectTimeout=10','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',"UserKnownHostsFile=$known",'-i',$key,'root@192.168.1.1:/tmp/clean-card-wifi-diag.tgz',$diagTar)
$scpResult=Invoke-Net 'scp' $scpArgs $scpLog
if($scpResult.Code -ne 0){throw "scp -O failed; see $scpLog"}

@{com9_fingerprint=$serialFp;ssh_fingerprint=$sshFp;fingerprints_match=$true;diag_tar=$diagTar}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $EvidenceDir 'ssh-final.json') -Encoding utf8
Write-Output "HOSTKEY_MATCH=$serialFp"
Write-Output "DIAG_TAR=$diagTar"
