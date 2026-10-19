param(
	[Parameter(Mandatory = $true)]
	[string]$CommandName,
	[string[]]$CommandArguments = @()
)

$ErrorActionPreference = 'Stop'
foreach ($name in @(
	'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'GIT_HTTP_PROXY', 'GIT_HTTPS_PROXY',
	'http_proxy', 'https_proxy', 'all_proxy', 'git_http_proxy', 'git_https_proxy'
)) {
	[Environment]::SetEnvironmentVariable($name, $null, 'Process')
}

$application = Get-Command $CommandName -CommandType Application | Select-Object -First 1
if (-not $application) {
	throw "Command not found: $CommandName"
}

& $application.Source @CommandArguments
exit $LASTEXITCODE
