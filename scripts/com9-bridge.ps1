param(
	[Parameter(Mandatory = $true)]
	[string]$LogPath,
	[int]$HeartbeatSeconds = 15
)

$ErrorActionPreference = 'Stop'
$port = [System.IO.Ports.SerialPort]::new('COM9', 115200, [System.IO.Ports.Parity]::None, 8,
	[System.IO.Ports.StopBits]::One)
$port.ReadTimeout = 100
$port.WriteTimeout = 2000
$port.NewLine = "`n"
$writer = $null

function Write-Log([string]$Text) {
	$line = "[$([DateTime]::UtcNow.ToString('o'))] $Text"
	$line | Out-File -LiteralPath $LogPath -Append -Encoding utf8
	Write-Host $line
}

try {
	$parent = Split-Path -Parent $LogPath
	New-Item -ItemType Directory -Path $parent -Force | Out-Null
	$port.Open()
	Write-Log 'COM9_OPEN=PASS (115200 8N1; exclusive reader active)'
	$lastData = [DateTime]::UtcNow
	$lastHeartbeat = $lastData
	$lineBuffer = ''
	while ($port.IsOpen) {
		try {
			$data = $port.ReadExisting()
			if ($data.Length -gt 0) {
				$timestamp = [DateTime]::UtcNow.ToString('o')
				$record = "[$timestamp] RX $data"
				$record | Out-File -LiteralPath $LogPath -Append -Encoding utf8 -NoNewline
				[Console]::Write($data)
				$lastData = [DateTime]::UtcNow
				$lastHeartbeat = $lastData
			}
		} catch {
			Write-Log "SERIAL_READ_EXCEPTION: $($_.Exception.ToString())"
			Start-Sleep -Milliseconds 500
		}

		if ([DateTime]::UtcNow - $lastHeartbeat -ge [TimeSpan]::FromSeconds($HeartbeatSeconds)) {
			$idle = [int]([DateTime]::UtcNow - $lastData).TotalSeconds
			Write-Log "HEARTBEAT no serial data for ${idle}s"
			$lastHeartbeat = [DateTime]::UtcNow
		}

		while ([Console]::KeyAvailable) {
			$key = [Console]::ReadKey($true)
			if ($key.Key -eq [ConsoleKey]::Enter) {
				[Console]::WriteLine()
				if ($lineBuffer.StartsWith('!')) {
					$command = $lineBuffer.Substring(1)
					Write-Log "TX $command"
					foreach ($character in ($command + "`r`n").ToCharArray()) {
						$port.Write([char]$character)
						Start-Sleep -Milliseconds 2
					}
				}
				$lineBuffer = ''
			} elseif ($key.Key -eq [ConsoleKey]::Backspace) {
				if ($lineBuffer.Length -gt 0) { $lineBuffer = $lineBuffer.Substring(0, $lineBuffer.Length - 1) }
			} elseif (-not [char]::IsControl($key.KeyChar)) {
				$lineBuffer += $key.KeyChar
				[Console]::Write($key.KeyChar)
			}
		}
		Start-Sleep -Milliseconds 100
	}
} catch {
	Write-Log "BRIDGE_EXCEPTION: $($_.Exception.ToString())"
	throw
} finally {
	if ($port.IsOpen) { $port.Close() }
	Write-Log 'COM9_CLOSED'
}
