param(
	[Parameter(Mandatory = $true)][string]$LogPath,
	[Parameter(Mandatory = $true)][string]$CommandDirectory,
	[ValidatePattern('^COM\d+$')][string]$Port = 'COM9',
	[int]$RetryMilliseconds = 1000,
	[ValidateRange(1, 60)][int]$HeartbeatSeconds = 10
)

$ErrorActionPreference = 'Stop'
$logParent = Split-Path -Parent $LogPath
New-Item -ItemType Directory -Path $logParent -Force | Out-Null
New-Item -ItemType Directory -Path $CommandDirectory -Force | Out-Null
$mutex = [System.Threading.Mutex]::new($false, "Local\CodexNanoPiRecorder_$Port")
if (-not $mutex.WaitOne(0)) { throw "A $Port recorder is already running in this session." }

function Write-Record([string]$Direction, [string]$Text) {
	$escaped = $Text.Replace("`r", '\r').Replace("`n", '\n')
	$line = "[$([DateTimeOffset]::Now.ToString('o'))] $Direction $escaped"
	$bytes = [Text.UTF8Encoding]::new($false).GetBytes($line + [Environment]::NewLine)
	$stream = [System.IO.FileStream]::new($LogPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
	try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
}

$serialPort = $null
$exitReason = 'normal-stop'
try {
	Write-Record 'INFO' "RECORDER_START pid=$PID port=$Port baud=115200 format=8N1"
	$lastHeartbeat = [DateTimeOffset]::UtcNow
	while ($true) {
		try {
			if (-not $serialPort -or -not $serialPort.IsOpen) {
				$serialPort = [System.IO.Ports.SerialPort]::new($Port, 115200, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
				$serialPort.ReadTimeout = 100
				$serialPort.WriteTimeout = 2000
				$serialPort.Open()
				Write-Record 'INFO' "${Port}_OPEN=PASS"
			}

			Get-ChildItem -LiteralPath $CommandDirectory -Filter '*.cmd' -File -ErrorAction SilentlyContinue |
				Sort-Object Name | ForEach-Object {
					$commandFile = $_.FullName
					$command = [System.IO.File]::ReadAllText($commandFile).TrimEnd("`r", "`n")
					Write-Record 'TX' $(if ($command) { $command } else { '<blank-line>' })
					$serialPort.Write($command + "`r`n")
					Remove-Item -LiteralPath $commandFile -Force
				}

			$received = $serialPort.ReadExisting()
			if ($received.Length -gt 0) { Write-Record 'RX' $received }
			Start-Sleep -Milliseconds 50
		} catch {
			Write-Record 'ERROR' ($_.Exception.ToString())
			if ($serialPort) {
				try { if ($serialPort.IsOpen) { $serialPort.Close() } } catch {}
				$serialPort.Dispose()
				$serialPort = $null
			}
			Start-Sleep -Milliseconds $RetryMilliseconds
		}
		if (([DateTimeOffset]::UtcNow - $lastHeartbeat).TotalSeconds -ge $HeartbeatSeconds) {
			Write-Record 'INFO' "HEARTBEAT pid=$PID"
			$lastHeartbeat = [DateTimeOffset]::UtcNow
		}
	}
} catch {
	$exitReason = 'exception={0}: {1}' -f $_.Exception.GetType().FullName, $_.Exception.Message
	Write-Record 'ERROR' $exitReason
	throw
} finally {
	if ($serialPort) {
		try { if ($serialPort.IsOpen) { $serialPort.Close() } } catch {}
		$serialPort.Dispose()
	}
	Write-Record 'INFO' "RECORDER_EXIT pid=$PID reason=$exitReason"
	$mutex.ReleaseMutex()
	$mutex.Dispose()
}
