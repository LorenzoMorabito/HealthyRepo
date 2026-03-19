[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$WorktreePath,
    [string]$RemoteName = "origin"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$frameworkRoot = Split-Path -Parent $scriptRoot
if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent $frameworkRoot
}

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $frameworkRoot "config.json"
}

. (Join-Path $scriptRoot "RepoHealth.Common.ps1")

$config = Get-RepoHealthConfig -Path $ConfigPath
$dataBranchName = [string]$config.data_branch_name
$historyRootRelativePath = [string]$config.history_root_relative_path
$dataProjectRelativeRoot = Split-Path $historyRootRelativePath -Parent

if (Test-Path $WorktreePath) {
    try {
        Invoke-RepoHealthGit -RepoRoot $RepositoryRoot -Arguments @("worktree", "remove", "--force", $WorktreePath) | Out-Null
    }
    catch {
    }

    if (Test-Path $WorktreePath) {
        Remove-Item -Path $WorktreePath -Recurse -Force
    }
}

$remoteBranchProbe = @(& git -C $RepositoryRoot ls-remote --heads $RemoteName $dataBranchName 2>$null)
$remoteBranchExists = @($remoteBranchProbe).Count -gt 0

if ($remoteBranchExists) {
    Invoke-RepoHealthGit -RepoRoot $RepositoryRoot -Arguments @("fetch", $RemoteName, $dataBranchName) | Out-Null
    Invoke-RepoHealthGit -RepoRoot $RepositoryRoot -Arguments @("worktree", "add", "--force", "--detach", $WorktreePath, "$RemoteName/$dataBranchName") | Out-Null
}
else {
    Invoke-RepoHealthGit -RepoRoot $RepositoryRoot -Arguments @("worktree", "add", "--force", "--detach", $WorktreePath, "HEAD") | Out-Null
    Invoke-RepoHealthGit -RepoRoot $WorktreePath -Arguments @("checkout", "--orphan", $dataBranchName) | Out-Null
    Invoke-RepoHealthGit -RepoRoot $WorktreePath -Arguments @("rm", "-rf", "--ignore-unmatch", ".") | Out-Null

    Get-ChildItem -Path $WorktreePath -Force |
        Where-Object { $_.Name -ne ".git" } |
        Remove-Item -Recurse -Force
}

$historyRootPath = Join-Path $WorktreePath $historyRootRelativePath
$legacyDataRootPath = Join-Path $WorktreePath ".repo-health"
if ($dataProjectRelativeRoot -and ($dataProjectRelativeRoot -ne ".repo-health") -and (Test-Path $legacyDataRootPath)) {
    Remove-Item -Path $legacyDataRootPath -Recurse -Force
}

$historyPaths = Get-RepoHealthHistoryPaths -HistoryRootPath $historyRootPath -Config $config -RunTimestampKey "bootstrap"
Ensure-RepoHealthHistoryStructure -HistoryPaths $historyPaths

$branchReadmePath = Join-Path $WorktreePath ($dataProjectRelativeRoot + "/README.md")
$branchReadme = @"
# Repo Health Data Branch

Questo branch contiene esclusivamente dati storici prodotti dal framework `repo-health`.

Contenuto previsto:

- `latest.json`
- `metrics-history.csv`
- snapshot `runs/*.json`
- snapshot `runs/*.md`
- output raw `git-sizer/*.txt` quando disponibile

Regole:

- nessun codice applicativo
- nessuna PR funzionale
- nessun commit manuale su `main` da questo branch
"@
Write-RepoHealthSummaryFile -Path $branchReadmePath -Content $branchReadme

[PSCustomObject]@{
    branch_name       = $dataBranchName
    worktree_path     = $WorktreePath
    history_root_path = $historyRootPath
    branch_exists     = $remoteBranchExists
}
