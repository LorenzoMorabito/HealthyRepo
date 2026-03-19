[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetRepositoryRoot,
    [string]$FrameworkRootRelativePath = "repository-health",
    [string]$DataBranchName,
    [string]$Version,
    [string]$PackageDirectory,
    [string]$PackageZipPath,
    [string]$PackageFeedRoot,
    [string]$ReleaseRepository,
    [string]$GitHubToken,
    [switch]$Force,
    [switch]$SkipWorkflows,
    [switch]$SkipGitIgnoreUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$distributionRoot = Split-Path -Parent $scriptRoot

function Ensure-InstallerDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-NormalizedInstallerRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return $Path.Replace("\", "/").Trim("/")
}

function Write-InstallerUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        Ensure-InstallerDirectory -Path $parent
    }

    Set-Content -Path $Path -Value $Content -Encoding utf8
}

function Get-RenderedInstallerTemplate {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][hashtable]$Tokens
    )

    $content = Get-Content -Path $TemplatePath -Raw
    foreach ($key in $Tokens.Keys) {
        $content = $content.Replace($key, $Tokens[$key])
    }

    return $content
}

function Set-GitIgnoreRepoHealthBlock {
    param(
        [Parameter(Mandatory = $true)][string]$GitIgnorePath,
        [Parameter(Mandatory = $true)][string]$FragmentContent
    )

    $existingContent = if (Test-Path -LiteralPath $GitIgnorePath) { Get-Content -Path $GitIgnorePath -Raw } else { "" }
    $blockPattern = '(?ms)# BEGIN REPO-HEALTH\r?\n.*?# END REPO-HEALTH'

    if ($existingContent -match $blockPattern) {
        $newContent = [regex]::Replace($existingContent, $blockPattern, $FragmentContent)
    }
    elseif ([string]::IsNullOrWhiteSpace($existingContent)) {
        $newContent = $FragmentContent
    }
    else {
        $trimmed = $existingContent.TrimEnd()
        $newContent = $trimmed + [Environment]::NewLine + [Environment]::NewLine + $FragmentContent
    }

    Write-InstallerUtf8File -Path $GitIgnorePath -Content $newContent
}

function Get-InstallerManifest {
    param([Parameter(Mandatory = $true)][string]$Root)

    $manifestPath = Join-Path $Root "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest not found: $manifestPath"
    }

    return Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
}

function Resolve-InstallerPatternValue {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Version
    )

    return $Pattern.Replace("{version}", $Version)
}

function Test-InstallerPackageRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (
        (Test-Path -LiteralPath (Join-Path $Path "manifest.json")) -and
        (Test-Path -LiteralPath (Join-Path $Path "distribution/Install-RepoHealthFramework.ps1")) -and
        (Test-Path -LiteralPath (Join-Path $Path "scripts/RepoHealth.Common.ps1"))
    )
}

function Get-InstallerPackageRootFromExpansion {
    param([Parameter(Mandatory = $true)][string]$ExtractRoot)

    if (Test-InstallerPackageRoot -Path $ExtractRoot) {
        return $ExtractRoot
    }

    foreach ($directory in Get-ChildItem -Path $ExtractRoot -Directory) {
        if (Test-InstallerPackageRoot -Path $directory.FullName) {
            return $directory.FullName
        }
    }

    throw "Unable to locate a valid repository-health package root under: $ExtractRoot"
}

function Expand-InstallerPackageZip {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    if (-not (Test-Path -LiteralPath $ZipPath)) {
        throw "Package zip not found: $ZipPath"
    }

    $extractRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("repo-health-install-" + [guid]::NewGuid().ToString("N"))
    Ensure-InstallerDirectory -Path $extractRoot
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractRoot -Force

    return [PSCustomObject]@{
        extract_root = $extractRoot
        package_root = Get-InstallerPackageRootFromExpansion -ExtractRoot $extractRoot
    }
}

function Get-InstallerGitHubHeaders {
    param([string]$GitHubToken)

    $headers = @{ "User-Agent" = "repository-health-installer" }
    if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
        $headers["Authorization"] = "Bearer $GitHubToken"
    }

    return $headers
}

function Get-InstallerPackageZipForVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)]$Manifest,
        [string]$PackageFeedRoot,
        [string]$ReleaseRepository,
        [string]$GitHubToken
    )

    $assetPattern = if ($Manifest.PSObject.Properties.Name -contains "package_asset_name_pattern") { [string]$Manifest.package_asset_name_pattern } else { "repository-health-v{version}.zip" }
    $tagPattern = if ($Manifest.PSObject.Properties.Name -contains "release_tag_pattern") { [string]$Manifest.release_tag_pattern } else { "v{version}" }
    $assetName = Resolve-InstallerPatternValue -Pattern $assetPattern -Version $Version
    $tagName = Resolve-InstallerPatternValue -Pattern $tagPattern -Version $Version

    if (-not [string]::IsNullOrWhiteSpace($PackageFeedRoot)) {
        $resolvedFeedRoot = $PackageFeedRoot
    }
    else {
        $resolvedFeedRoot = Join-Path $scriptRoot "packages"
    }

    $candidatePath = Join-Path $resolvedFeedRoot $assetName
    if (Test-Path -LiteralPath $candidatePath) {
        return $candidatePath
    }

    $resolvedReleaseRepository = if (-not [string]::IsNullOrWhiteSpace($ReleaseRepository)) {
        $ReleaseRepository
    }
    elseif ($Manifest.PSObject.Properties.Name -contains "release_repository") {
        [string]$Manifest.release_repository
    }
    else {
        throw "Release repository is not configured. Provide -ReleaseRepository or build a local package feed."
    }

    Ensure-InstallerDirectory -Path $resolvedFeedRoot
    $downloadUrl = "https://github.com/$resolvedReleaseRepository/releases/download/$tagName/$assetName"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $candidatePath -Headers (Get-InstallerGitHubHeaders -GitHubToken $GitHubToken)
    return $candidatePath
}

function Resolve-InstallerPackageSource {
    param(
        [Parameter(Mandatory = $true)][string]$DefaultSourceRoot,
        [Parameter(Mandatory = $true)]$Manifest,
        [string]$Version,
        [string]$PackageDirectory,
        [string]$PackageZipPath,
        [string]$PackageFeedRoot,
        [string]$ReleaseRepository,
        [string]$GitHubToken
    )

    $explicitSourceCount = @(
        $Version,
        $PackageDirectory,
        $PackageZipPath
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }

    if (@($explicitSourceCount).Count -gt 1) {
        throw "Specify only one package source: -Version, -PackageDirectory, or -PackageZipPath."
    }

    if (-not [string]::IsNullOrWhiteSpace($PackageDirectory)) {
        $resolvedPackageDirectory = (Resolve-Path -LiteralPath $PackageDirectory).Path
        if (-not (Test-InstallerPackageRoot -Path $resolvedPackageDirectory)) {
            throw "Package directory is not a valid repository-health package root: $resolvedPackageDirectory"
        }

        return [PSCustomObject]@{
            package_root      = $resolvedPackageDirectory
            package_source    = "package-directory"
            temporary_root    = $null
            package_reference = $resolvedPackageDirectory
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($PackageZipPath)) {
        $expanded = Expand-InstallerPackageZip -ZipPath ((Resolve-Path -LiteralPath $PackageZipPath).Path)
        return [PSCustomObject]@{
            package_root      = $expanded.package_root
            package_source    = "package-zip"
            temporary_root    = $expanded.extract_root
            package_reference = $PackageZipPath
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $packageZip = Get-InstallerPackageZipForVersion -Version $Version -Manifest $Manifest -PackageFeedRoot $PackageFeedRoot -ReleaseRepository $ReleaseRepository -GitHubToken $GitHubToken
        $expanded = Expand-InstallerPackageZip -ZipPath $packageZip
        return [PSCustomObject]@{
            package_root      = $expanded.package_root
            package_source    = "version"
            temporary_root    = $expanded.extract_root
            package_reference = $packageZip
        }
    }

    return [PSCustomObject]@{
        package_root      = $DefaultSourceRoot
        package_source    = "source"
        temporary_root    = $null
        package_reference = $DefaultSourceRoot
    }
}

$resolvedTargetRepositoryRoot = (Resolve-Path -LiteralPath $TargetRepositoryRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $resolvedTargetRepositoryRoot ".git"))) {
    throw "Target repository root does not look like a Git repository: $resolvedTargetRepositoryRoot"
}

$defaultManifest = Get-InstallerManifest -Root $distributionRoot
$packageResolution = $null

try {
    $packageResolution = Resolve-InstallerPackageSource `
        -DefaultSourceRoot $distributionRoot `
        -Manifest $defaultManifest `
        -Version $Version `
        -PackageDirectory $PackageDirectory `
        -PackageZipPath $PackageZipPath `
        -PackageFeedRoot $PackageFeedRoot `
        -ReleaseRepository $ReleaseRepository `
        -GitHubToken $GitHubToken

    $resolvedPackageRoot = $packageResolution.package_root
    $packageManifest = Get-InstallerManifest -Root $resolvedPackageRoot
    $packageVersion = [string]$packageManifest.version

    if (-not [string]::IsNullOrWhiteSpace($Version) -and ($packageVersion -ne $Version)) {
        throw "Resolved package version does not match the requested version. Requested=$Version Resolved=$packageVersion"
    }

    if (-not $PSBoundParameters.ContainsKey("FrameworkRootRelativePath") -and ($packageManifest.PSObject.Properties.Name -contains "default_framework_root")) {
        $FrameworkRootRelativePath = [string]$packageManifest.default_framework_root
    }

    if (-not $PSBoundParameters.ContainsKey("DataBranchName")) {
        if ($packageManifest.PSObject.Properties.Name -contains "default_data_branch") {
            $DataBranchName = [string]$packageManifest.default_data_branch
        }
        else {
            $DataBranchName = "repo-health-data"
        }
    }

    $frameworkRootNormalized = Get-NormalizedInstallerRelativePath -Path $FrameworkRootRelativePath
    $targetFrameworkRoot = Join-Path $resolvedTargetRepositoryRoot $frameworkRootNormalized
    $targetScriptsRoot = Join-Path $targetFrameworkRoot "scripts"
    $targetOutputsCurrent = Join-Path $targetFrameworkRoot "outputs/current"
    $targetOutputsHistory = Join-Path $targetFrameworkRoot "outputs/history"
    $templateRoot = Join-Path $resolvedPackageRoot "distribution/templates"

    $sourceFiles = @(
        "analyzer.ps1",
        "README.md",
        "RUNBOOK.md",
        "manifest.json"
    )

    foreach ($sourceFile in $sourceFiles) {
        $targetPath = Join-Path $targetFrameworkRoot $sourceFile
        if ((Test-Path -LiteralPath $targetPath) -and -not $Force) {
            throw "Target file already exists. Re-run with -Force to overwrite: $targetPath"
        }
    }

    $workflowTargets = @(
        (Join-Path $resolvedTargetRepositoryRoot ".github/workflows/repo-health-pr.yml"),
        (Join-Path $resolvedTargetRepositoryRoot ".github/workflows/repo-health-push.yml"),
        (Join-Path $resolvedTargetRepositoryRoot ".github/workflows/repo-health-schedule.yml")
    )

    if (-not $SkipWorkflows) {
        foreach ($workflowTarget in $workflowTargets) {
            if ((Test-Path -LiteralPath $workflowTarget) -and -not $Force) {
                throw "Target workflow already exists. Re-run with -Force to overwrite: $workflowTarget"
            }
        }
    }

    Ensure-InstallerDirectory -Path $targetFrameworkRoot
    Ensure-InstallerDirectory -Path $targetScriptsRoot
    Ensure-InstallerDirectory -Path $targetOutputsCurrent
    Ensure-InstallerDirectory -Path $targetOutputsHistory

    foreach ($sourceFile in $sourceFiles) {
        Copy-Item -LiteralPath (Join-Path $resolvedPackageRoot $sourceFile) -Destination (Join-Path $targetFrameworkRoot $sourceFile) -Force
    }

    Copy-Item -Path (Join-Path $resolvedPackageRoot "scripts/*.ps1") -Destination $targetScriptsRoot -Force

    $templateTokens = @{
        "__FRAMEWORK_ROOT__"   = $frameworkRootNormalized
        "__DATA_BRANCH_NAME__" = $DataBranchName
    }

    $configTemplatePath = Join-Path $templateRoot "config.template.json"
    $configContent = Get-RenderedInstallerTemplate -TemplatePath $configTemplatePath -Tokens $templateTokens
    Write-InstallerUtf8File -Path (Join-Path $targetFrameworkRoot "config.json") -Content $configContent

    Write-InstallerUtf8File -Path (Join-Path $targetOutputsCurrent ".gitkeep") -Content ""
    Write-InstallerUtf8File -Path (Join-Path $targetOutputsHistory ".gitkeep") -Content ""

    if (-not $SkipGitIgnoreUpdate) {
        $gitIgnoreFragmentTemplate = Join-Path $templateRoot "gitignore.fragment.txt"
        $gitIgnoreFragment = Get-RenderedInstallerTemplate -TemplatePath $gitIgnoreFragmentTemplate -Tokens $templateTokens
        Set-GitIgnoreRepoHealthBlock -GitIgnorePath (Join-Path $resolvedTargetRepositoryRoot ".gitignore") -FragmentContent $gitIgnoreFragment
    }

    if (-not $SkipWorkflows) {
        $workflowTemplateRoot = Join-Path $templateRoot "github-workflows"
        $workflowMap = @{
            "repo-health-pr.yml.template"       = "repo-health-pr.yml"
            "repo-health-push.yml.template"     = "repo-health-push.yml"
            "repo-health-schedule.yml.template" = "repo-health-schedule.yml"
        }

        foreach ($templateName in $workflowMap.Keys) {
            $renderedWorkflow = Get-RenderedInstallerTemplate -TemplatePath (Join-Path $workflowTemplateRoot $templateName) -Tokens $templateTokens
            $targetWorkflowPath = Join-Path $resolvedTargetRepositoryRoot (".github/workflows/" + $workflowMap[$templateName])
            Write-InstallerUtf8File -Path $targetWorkflowPath -Content $renderedWorkflow
        }
    }

    [PSCustomObject]@{
        target_repository_root = $resolvedTargetRepositoryRoot
        framework_root         = $targetFrameworkRoot
        config_path            = Join-Path $targetFrameworkRoot "config.json"
        workflows_installed    = (-not $SkipWorkflows)
        gitignore_updated      = (-not $SkipGitIgnoreUpdate)
        data_branch_name       = $DataBranchName
        installed_version      = $packageVersion
        package_source_type    = $packageResolution.package_source
        package_reference      = $packageResolution.package_reference
        next_steps             = @(
            "Review the generated config.json and adjust excluded_paths if needed.",
            "Commit the installed framework files in the target repository.",
            "Push to main to bootstrap the repo-health-data branch automatically."
        )
    }
}
finally {
    if ($null -ne $packageResolution -and -not [string]::IsNullOrWhiteSpace([string]$packageResolution.temporary_root)) {
        if (Test-Path -LiteralPath $packageResolution.temporary_root) {
            Remove-Item -LiteralPath $packageResolution.temporary_root -Recurse -Force
        }
    }
}

