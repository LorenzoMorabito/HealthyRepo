[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetRepositoryRoot,
    [string]$FrameworkRootRelativePath = "repository-health",
    [string]$DataBranchName = "repo-health-data",
    [switch]$Force,
    [switch]$SkipWorkflows,
    [switch]$SkipGitIgnoreUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-InstallerDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
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

    $existingContent = if (Test-Path $GitIgnorePath) { Get-Content -Path $GitIgnorePath -Raw } else { "" }
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

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$distributionRoot = Split-Path -Parent $scriptRoot
$templateRoot = Join-Path $scriptRoot "templates"

$resolvedTargetRepositoryRoot = (Resolve-Path $TargetRepositoryRoot).Path
if (-not (Test-Path (Join-Path $resolvedTargetRepositoryRoot ".git"))) {
    throw "Target repository root does not look like a Git repository: $resolvedTargetRepositoryRoot"
}

$frameworkRootNormalized = Get-NormalizedInstallerRelativePath -Path $FrameworkRootRelativePath
$targetFrameworkRoot = Join-Path $resolvedTargetRepositoryRoot $frameworkRootNormalized
$targetScriptsRoot = Join-Path $targetFrameworkRoot "scripts"
$targetOutputsCurrent = Join-Path $targetFrameworkRoot "outputs/current"
$targetOutputsHistory = Join-Path $targetFrameworkRoot "outputs/history"

$sourceFiles = @(
    "analyzer.ps1",
    "README.md",
    "RUNBOOK.md",
    "manifest.json"
)

foreach ($sourceFile in $sourceFiles) {
    $targetPath = Join-Path $targetFrameworkRoot $sourceFile
    if ((Test-Path $targetPath) -and -not $Force) {
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
        if ((Test-Path $workflowTarget) -and -not $Force) {
            throw "Target workflow already exists. Re-run with -Force to overwrite: $workflowTarget"
        }
    }
}

Ensure-InstallerDirectory -Path $targetFrameworkRoot
Ensure-InstallerDirectory -Path $targetScriptsRoot
Ensure-InstallerDirectory -Path $targetOutputsCurrent
Ensure-InstallerDirectory -Path $targetOutputsHistory

foreach ($sourceFile in $sourceFiles) {
    Copy-Item -Path (Join-Path $distributionRoot $sourceFile) -Destination (Join-Path $targetFrameworkRoot $sourceFile) -Force
}

Copy-Item -Path (Join-Path $distributionRoot "scripts/*.ps1") -Destination $targetScriptsRoot -Force

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
    next_steps             = @(
        "Review the generated config.json and adjust excluded_paths if needed.",
        "Commit the installed framework files in the target repository.",
        "Push to main to bootstrap the repo-health-data branch automatically."
    )
}
