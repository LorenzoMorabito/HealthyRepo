[CmdletBinding()]
param(
    [string]$SourceRepositoryRoot,
    [string]$OutputRoot,
    [string]$Version,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$distributionRoot = Split-Path -Parent $scriptRoot

function Ensure-RepoHealthPackageDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Test-RepoHealthSourceRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (
        (Test-Path -LiteralPath (Join-Path $Path "manifest.json")) -and
        (Test-Path -LiteralPath (Join-Path $Path "distribution/Install-RepoHealthFramework.ps1")) -and
        (Test-Path -LiteralPath (Join-Path $Path "scripts/RepoHealth.Common.ps1"))
    )
}

function Resolve-RepoHealthSourceRoot {
    param([string]$Path)

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $resolved = (Resolve-Path -LiteralPath $Path).Path
        $candidates.Add($resolved)
        $candidates.Add((Join-Path $resolved "repository-health"))
    }
    else {
        $candidates.Add($distributionRoot)
    }

    foreach ($candidate in $candidates) {
        if (Test-RepoHealthSourceRoot -Path $candidate) {
            return $candidate
        }
    }

    throw "Unable to resolve the repository-health source root."
}

function Get-RepoHealthPackagePatternValue {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Version
    )

    return $Pattern.Replace("{version}", $Version)
}

$resolvedSourceRoot = Resolve-RepoHealthSourceRoot -Path $SourceRepositoryRoot
$manifestPath = Join-Path $resolvedSourceRoot "manifest.json"
$manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
$resolvedVersion = if (-not [string]::IsNullOrWhiteSpace($Version)) { $Version } else { [string]$manifest.version }

if ([string]::IsNullOrWhiteSpace($resolvedVersion)) {
    throw "Manifest version is missing."
}

if ($resolvedVersion -ne [string]$manifest.version) {
    throw "Package version mismatch. Update manifest.json before building a release package. Manifest=$($manifest.version) Requested=$resolvedVersion"
}

$assetPattern = if ($manifest.PSObject.Properties.Name -contains "package_asset_name_pattern") { [string]$manifest.package_asset_name_pattern } else { "repository-health-v{version}.zip" }
$directoryPattern = if ($manifest.PSObject.Properties.Name -contains "package_directory_name_pattern") { [string]$manifest.package_directory_name_pattern } else { "repository-health-v{version}" }
$releaseTagPattern = if ($manifest.PSObject.Properties.Name -contains "release_tag_pattern") { [string]$manifest.release_tag_pattern } else { "v{version}" }

$packageDirectoryName = Get-RepoHealthPackagePatternValue -Pattern $directoryPattern -Version $resolvedVersion
$assetName = Get-RepoHealthPackagePatternValue -Pattern $assetPattern -Version $resolvedVersion
$releaseTag = Get-RepoHealthPackagePatternValue -Pattern $releaseTagPattern -Version $resolvedVersion

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $resolvedSourceRoot "distribution/packages"
}

Ensure-RepoHealthPackageDirectory -Path $OutputRoot
$packageZipPath = Join-Path $OutputRoot $assetName

if ((Test-Path -LiteralPath $packageZipPath) -and -not $Force) {
    throw "Package already exists. Re-run with -Force to overwrite: $packageZipPath"
}

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("repo-health-package-" + [guid]::NewGuid().ToString("N"))
$packageRoot = Join-Path $stagingRoot $packageDirectoryName

try {
    Ensure-RepoHealthPackageDirectory -Path $packageRoot
    Ensure-RepoHealthPackageDirectory -Path (Join-Path $packageRoot "distribution")

    foreach ($file in @("analyzer.ps1", "README.md", "RUNBOOK.md", "manifest.json")) {
        Copy-Item -LiteralPath (Join-Path $resolvedSourceRoot $file) -Destination (Join-Path $packageRoot $file) -Force
    }

    Copy-Item -LiteralPath (Join-Path $resolvedSourceRoot "scripts") -Destination (Join-Path $packageRoot "scripts") -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $resolvedSourceRoot "distribution/templates") -Destination (Join-Path $packageRoot "distribution/templates") -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $resolvedSourceRoot "distribution/Install-RepoHealthFramework.ps1") -Destination (Join-Path $packageRoot "distribution/Install-RepoHealthFramework.ps1") -Force
    Copy-Item -LiteralPath (Join-Path $resolvedSourceRoot "distribution/README.md") -Destination (Join-Path $packageRoot "distribution/README.md") -Force

    if (Test-Path -LiteralPath $packageZipPath) {
        Remove-Item -LiteralPath $packageZipPath -Force
    }

    Compress-Archive -LiteralPath $packageRoot -DestinationPath $packageZipPath -CompressionLevel Optimal -Force
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

[PSCustomObject]@{
    source_root         = $resolvedSourceRoot
    version             = $resolvedVersion
    release_tag         = $releaseTag
    package_directory   = $packageDirectoryName
    asset_name          = $assetName
    package_zip_path    = $packageZipPath
    package_feed_root   = $OutputRoot
}
