param(
	[Parameter(Mandatory = $true)][string]$LogPath,
	[Parameter(Mandatory = $true)][string]$CommandDirectory,
	[int]$RetryMilliseconds = 1000
)

$ErrorActionPreference = 'Stop'
$logParent = Split-Path -Parent $LogPath
New-Item -ItemType Directory -Path $logParent -Force | Out-Null
New-Item -ItemType Directory -Path $CommandDirectory -Force | Out-Null
$mutex = [System.Threading.Mutex]::new($false, 'Local\CodexCom9Recorder')
if (-not $mutex.WaitOne(0)) { throw 'A COM9 recorder is already running in this session.' }

function Write-Record([string]$Direction, [string]$Text) {
	$escaped = $Text.Replace("`r", '\r').Replace("`n", '\n')
	$line = "[$([DateTimeOffset]::Now.ToString('o'))] $Direction $escaped"
	[System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

$port = $null
$reader = $null
try {
	Write-Record 'INFO' 'RECORDER_START port=COM9 baud=115200 format=8N1'
	while ($true) {
		try {
			if (-not $port -or -not $port.IsOpen) {
				$port = [System.IO.Ports.SerialPort]::new('COM9', 115200, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
				$port.ReadTimeout = 100
				$port.WriteTimeout = 2000
				$port.Open()
				Write-Record 'INFO' 'COM9_OPEN=PASS'
			}

			Get-ChildItem -LiteralPath $CommandDirectory -Filter '*.cmd' -File -ErrorAction SilentlyContinue |
				Sort-Object Name | ForEach-Object {
					$commandFile = $_.FullName
					$command = [System.IO.File]::ReadAllText($commandFile).TrimEnd("`r", "`n")
					if ($command) {
						Write-Record 'TX' $command
						$port.Write($command + "`r`n")
					}
					Remove-Item -LiteralPath $commandFile -Force
				}

			$received = $port.ReadExisting()
			if ($received.Length -gt 0) { Write-Record 'RX' $received }
			Start-Sleep -Milliseconds 50
		} catch {
			Write-Record 'ERROR' ($_.Exception.ToString())
			if ($port) {
				try { if ($port.IsOpen) { $port.Close() } } catch {}
				$port.Dispose()
				$port = $null
			}
			Start-Sleep -Milliseconds $RetryMilliseconds
		}
	}
} finally {
	if ($port) {
		try { if ($port.IsOpen) { $port.Close() } } catch {}
		$port.Dispose()
	}
	Write-Record 'INFO' 'RECORDER_STOP'
	$mutex.ReleaseMutex()
	$mutex.Dispose()
}
