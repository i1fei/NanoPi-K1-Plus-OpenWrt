[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string[]]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Get-FirstUptime([string[]]$Lines, [string]$Pattern) {
    foreach ($line in $Lines) {
        if ($line -match '\[\s*(?<up>\d+(?:\.\d+)?)\].*' + $Pattern) { return [double]$Matches.up }
    }
    return $null
}

function Get-Matches([string[]]$Lines, [string]$Pattern) {
    $out = @()
    foreach ($line in $Lines) {
        if ($line -match '\[\s*(?<up>\d+(?:\.\d+)?)\].*' + $Pattern) {
            $out += [pscustomobject]@{ Uptime = [double]$Matches.up; Line = $line }
        }
    }
    return $out
}

$rows = @()
foreach ($source in $InputPath) {
    $lines = Get-Content -LiteralPath $source
    $starts = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'U-Boot SPL|U-Boot 20\d{2}') { $starts += $i }
    }
    if ($starts.Count -eq 0) {
        $starts = @(0)
    }
    for ($n = 0; $n -lt $starts.Count; $n++) {
        $begin = $starts[$n]
        $end = if ($n + 1 -lt $starts.Count) { $starts[$n + 1] - 1 } else { $lines.Count - 1 }
        $segment = @($lines[$begin..$end])
        $base = [IO.Path]::GetFileNameWithoutExtension($source)
        $name = '{0}-boot-{1:D2}.log' -f $base, ($n + 1)
        $out = Join-Path $OutputDirectory $name
        [IO.File]::WriteAllLines($out, [string[]]$segment, [Text.UTF8Encoding]::new($false))
        $health = Get-Matches $segment 'HEALTH hostapd_rc='
        $stages = Get-Matches $segment 'recovery stage [123]|reboot cooldown|recovery limit exceeded'
        $reboots = Get-Matches $segment 'reboot: Restarting system'
        $rows += [pscustomobject]@{
            Source = $source
            Segment = $out
            Phy0Uptime = Get-FirstUptime $segment 'rtw_wiphy_register\(phy0\)'
            ApUptime = Get-FirstUptime $segment 'rtw_ndev_init\(phy0-ap0\)'
            HealthLines = @($health | ForEach-Object { $_.Line })
            StageLines = @($stages | ForEach-Object { $_.Line })
            RebootLines = @($reboots | ForEach-Object { $_.Line })
        }
    }
}

$json = Join-Path $OutputDirectory 'segment-summary.json'
$rows | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $json -Encoding utf8
$rows | Select-Object Source,Segment,Phy0Uptime,ApUptime | Export-Csv -NoTypeInformation -Encoding utf8 -LiteralPath (Join-Path $OutputDirectory 'segment-summary.csv')
$rows | ConvertTo-Json -Depth 6
