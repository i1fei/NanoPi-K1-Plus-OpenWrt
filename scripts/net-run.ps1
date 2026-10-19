$ErrorActionPreference = 'Stop'
$CommandName = [string]$args[0]
$CommandArguments = @($args | Select-Object -Skip 1)
if ($CommandName -notin @('gh', 'git', 'ssh', 'scp')) {
	throw "Unsupported command: $CommandName"
}

foreach ($name in @(
	'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
	'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy',
	'GIT_HTTP_PROXY', 'GIT_HTTPS_PROXY', 'git_http_proxy', 'git_https_proxy'
)) {
	[Environment]::SetEnvironmentVariable($name, $null, 'Process')
}

if ($CommandName -in @('ssh', 'scp')) {
	$application = Join-Path $env:WINDIR "System32\OpenSSH\$CommandName.exe"
	if (-not (Test-Path -LiteralPath $application -PathType Leaf)) {
		throw "Required Windows OpenSSH executable not found: $application"
	}
} else {
	$resolved = Get-Command $CommandName -CommandType Application | Select-Object -First 1
	if (-not $resolved) {
		throw "Command not found: $CommandName"
	}
	$application = $resolved.Source
}

& $application @CommandArguments
exit $LASTEXITCODE
