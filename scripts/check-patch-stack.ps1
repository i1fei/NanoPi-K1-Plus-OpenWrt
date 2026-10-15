[CmdletBinding()]
param(
	[string]$ProjectDir = (Split-Path -Parent $PSScriptRoot),
	[string]$SourceDir,
	[ValidateSet('recovery', 'rtl8189es_inert', 'rtl8189es_inert_v3', 'wifi_compat', 'wifi_compat_v2', 'wifi_compat_v3', 'wifi_release_v1')]
	[string]$Mode = 'wifi_release_v1',
	[switch]$FormatOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
$PatchDir = Join-Path $ProjectDir 'patches/nanopi-k1-plus'

function Invoke-Git {
	param(
		[string]$WorkingDirectory,
		[Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
		[string[]]$Arguments
	)

	& git -C $WorkingDirectory @Arguments
	if ($LASTEXITCODE -ne 0) {
		throw "git failed in ${WorkingDirectory}: git $($Arguments -join ' ')"
	}
}

function Get-ModePatches {
	$patches = [System.Collections.Generic.List[string]]::new()
	foreach ($name in @(
		'001-add-k1-plus-dts.patch',
		'002-add-k1-plus-device-profile.patch',
		'003-add-k1-plus-network.patch',
		'004-add-stage-a-console-support.patch',
		'006-restore-k1-plus-hardware-foundation.patch'
	)) { $patches.Add($name) }

	switch ($Mode) {
		'recovery' { }
		'rtl8189es_inert' { $patches.Add('007-stabilize-k1-plus-rtl8189es-radio.patch') }
		'rtl8189es_inert_v3' {
			$patches.Add('007-stabilize-k1-plus-rtl8189es-radio.patch')
			$patches.Add('011-v3-delayed-inert-rtl8189es-wifi.patch')
		}
		'wifi_compat' {
			foreach ($name in @(
				'007-stabilize-k1-plus-rtl8189es-radio.patch',
				'008-fix-k1-plus-runtime-radio-generation.patch',
				'009-add-k1-plus-wifi-compat-policy.patch',
				'010-fix-k1-plus-single-phy-fallback.patch'
			)) { $patches.Add($name) }
		}
		'wifi_compat_v2' {
			foreach ($name in @(
				'007-stabilize-k1-plus-rtl8189es-radio.patch',
				'008-fix-k1-plus-runtime-radio-generation.patch',
				'009-add-k1-plus-wifi-compat-policy.patch',
				'010-fix-k1-plus-single-phy-fallback.patch',
				'012-reuse-k1-plus-existing-wlan0.patch'
			)) { $patches.Add($name) }
		}
		'wifi_compat_v3' {
			foreach ($name in @(
				'007-stabilize-k1-plus-rtl8189es-radio.patch',
				'008-fix-k1-plus-runtime-radio-generation.patch',
				'009-add-k1-plus-wifi-compat-policy.patch',
				'010-fix-k1-plus-single-phy-fallback.patch'
			)) { $patches.Add($name) }
		}
		'wifi_release_v1' {
			foreach ($name in @(
				'007-stabilize-k1-plus-rtl8189es-radio.patch',
				'008-fix-k1-plus-runtime-radio-generation.patch',
				'010-fix-k1-plus-single-phy-fallback.patch'
			)) { $patches.Add($name) }
		}
	}

	return $patches
}

function Get-PatchPath([string]$Name) {
	$path = Join-Path $PatchDir $Name
	if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
		throw "missing patch: $Name"
	}
	return $path
}

function Test-PatchSyntax {
	$files = Get-ChildItem -LiteralPath $PatchDir -Filter '*.patch' -File | Sort-Object Name
	if ($files.Count -eq 0) {
		throw "no patches found in $PatchDir"
	}

	foreach ($file in $files) {
		Invoke-Git $ProjectDir @('apply', '--stat', '--', $file.FullName) | Out-Null
		Write-Output "FORMAT PASS $($file.Name)"
	}

	$runtimePatch = Get-Content -Raw -LiteralPath (Get-PatchPath '008-fix-k1-plus-runtime-radio-generation.patch')
	if ($runtimePatch -match '!!\s*readfile\s*\([^)]*/etc/wifi-release-done') {
		throw '008 still uses !!readfile() for the release marker'
	}
	if ($runtimePatch -notmatch 'readfile\("/etc/wifi-release-done"\)\s*!=\s*null') {
		throw '008 does not use an explicit release-marker existence check'
	}
}

Test-PatchSyntax

if ($FormatOnly) {
	Write-Output "PATCH_FORMAT_CHECK=PASS mode=$Mode"
	exit 0
}

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
	throw '-SourceDir is required unless -FormatOnly is used'
}
$SourceDir = (Resolve-Path -LiteralPath $SourceDir).Path

$worktree = Join-Path ([IO.Path]::GetTempPath()) ('nanopi-k1-plus-patch-check-' + [guid]::NewGuid().ToString('N'))
$worktreeCreated = $false
try {
	Invoke-Git $SourceDir @('worktree', 'add', '--detach', $worktree, 'HEAD')
	$worktreeCreated = $true

	$stagedPatch = Get-PatchPath '001-add-k1-plus-dts.patch'
	$stagedTarget = Join-Path $worktree 'target/linux/sunxi/patches-6.18/950-add-k1-plus-dts.patch'
	New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stagedTarget) | Out-Null
	Copy-Item -LiteralPath $stagedPatch -Destination $stagedTarget -Force

	foreach ($name in (Get-ModePatches | Select-Object -Skip 1)) {
		$patch = Get-PatchPath $name
		# Windows checkouts may expose CRLF patch files; ignore only that EOL difference.
		Invoke-Git $worktree @('apply', '--check', '--ignore-space-change', '--', $patch)
		Invoke-Git $worktree @('apply', '--ignore-space-change', '--', $patch)
		Write-Output "APPLIED $name"
	}

	Invoke-Git $worktree @('diff', '--check')

	$mac80211 = Get-Content -Raw -LiteralPath (Join-Path $worktree 'package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc')
	if ($mac80211 -match '!!\s*readfile\s*\([^)]*/etc/wifi-release-done') {
		throw 'applied stack still contains !!readfile() for the release marker'
	}
	if ($mac80211 -notmatch 'readfile\("/etc/wifi-release-done"\)\s*!=\s*null') {
		throw 'applied stack does not contain the explicit release-marker existence check'
	}

	$policy = Join-Path $ProjectDir 'overlays/wifi_release_v1/files/etc/uci-defaults/99-k1-plus-wifi-release-v1'
	if ((Get-Content -Raw -LiteralPath $policy) -notmatch 'printf ''%s\\n'' done > /etc/wifi-release-done') {
		throw 'firstboot policy does not write a non-empty release marker'
	}

	Write-Output "PATCH_STACK_CHECK=PASS mode=$Mode source=$SourceDir"
}
finally {
	if ($worktreeCreated) {
		try { Invoke-Git $SourceDir @('worktree', 'remove', '--force', $worktree) } catch { Write-Warning $_ }
	}
}
