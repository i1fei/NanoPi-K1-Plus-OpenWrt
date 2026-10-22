$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$roundScript = Join-Path $PSScriptRoot 'p4-round-v2.ps1'
$stabilityScript = Join-Path $PSScriptRoot 'p4-v2-stability.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$evidence = Join-Path $repo 'evidence\P4'
$table = Join-Path $repo 'evidence\P3-P4-20261022-v2.md'

for ($round = 1; $round -le 6; $round++) {
	$roundDir = Join-Path $evidence ('recover-v2-r397106-{0:d2}' -f $round)
	New-Item -ItemType Directory -Path $roundDir -Force | Out-Null
	$consoleLog = Join-Path $roundDir 'runner-console.log'
	& $pwsh -NoProfile -File $roundScript -Mode recover -Round $round 2>&1 | Tee-Object -FilePath $consoleLog -Append
	if ($LASTEXITCODE -ne 0) { throw "P4 stopped at recover round $round with exit code $LASTEXITCODE; see $consoleLog" }
	if ($round -in @(3, 6)) {
		$completed = @(Get-ChildItem $evidence -Directory -Filter 'recover-v2-r397106-*' | Where-Object { Test-Path (Join-Path $_.FullName 'round.log') -and (Select-String -LiteralPath (Join-Path $_.FullName 'round.log') -Pattern 'ROUND_COMPLETE' -Quiet) }).Count
		"P4_PROGRESS completed_rounds=$completed flash_count=$((16 + $completed))/30 table=$table"
	}
}

$knownHosts = Join-Path $evidence 'recover-v2-r397106-06\known_hosts.verified'
& $pwsh -NoProfile -File $stabilityScript -KnownHosts $knownHosts
if ($LASTEXITCODE -ne 0) { throw "Two-hour stability observation failed with exit code $LASTEXITCODE." }
