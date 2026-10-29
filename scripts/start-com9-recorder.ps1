param(
	[Parameter(Mandatory = $true)][string]$LogPath,
	[Parameter(Mandatory = $true)][string]$CommandDirectory,
	[ValidatePattern('^COM\d+$')][string]$Port = 'COM9',
	[switch]$Restart
)

$ErrorActionPreference = 'Stop'
$taskName = "Codex-NanoPi-$Port-Recorder"
$recorder = Join-Path $PSScriptRoot 'com9-recorder.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$logPath = [IO.Path]::GetFullPath($LogPath)
$commandDirectory = [IO.Path]::GetFullPath($CommandDirectory)
New-Item -ItemType Directory -Path (Split-Path -Parent $logPath) -Force | Out-Null
New-Item -ItemType Directory -Path $commandDirectory -Force | Out-Null

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
	$actionText = $existing.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }
	if (($actionText -join "`n") -notlike "*$recorder*") { throw "Task name collision: $taskName" }
	if ($Restart) {
		Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
		Start-Sleep -Seconds 2
	}
} else {
	$arguments = '-NoProfile -NonInteractive -File "{0}" -LogPath "{1}" -CommandDirectory "{2}" -Port "{3}"' -f $recorder, $logPath, $commandDirectory, $Port
	$action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
	$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
	$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
	$task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings
	Register-ScheduledTask -TaskName $taskName -InputObject $task | Out-Null
}

Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2
$state = (Get-ScheduledTask -TaskName $taskName).State
if ($state -ne 'Running') { throw "Scheduled recorder did not enter Running state: $state" }
"TASK=$taskName STATE=$state LOG=$logPath"
