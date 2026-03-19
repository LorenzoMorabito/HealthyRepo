[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$WorktreePath,
    [Parameter(Mandatory = $true)][string]$CommitMessage,
    [string]$RemoteName = "origin",
    [string]$GitUserName = "github-actions[bot]",
    [string]$GitUserEmail = "41898282+github-actions[bot]@users.noreply.github.com"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$frameworkRoot = Split-Path -Parent $scriptRoot
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $frameworkRoot "config.json"
}

. (Join-Path $scriptRoot "RepoHealth.Common.ps1")

$config = Get-RepoHealthConfig -Path $ConfigPath
$dataBranchName = [string]$config.data_branch_name
$dataProjectRelativeRoot = Split-Path ([string]$config.history_root_relative_path) -Parent

if (-not (Test-Path $WorktreePath)) {
    throw "Repo health data worktree not found: $WorktreePath"
}

Invoke-RepoHealthGit -RepoRoot $WorktreePath -Arguments @("add", $dataProjectRelativeRoot) | Out-Null
$pendingChanges = @(Invoke-RepoHealthGit -RepoRoot $WorktreePath -Arguments @("status", "--short"))

if (@($pendingChanges).Count -eq 0) {
    return [PSCustomObject]@{
        changed     = $false
        branch_name = $dataBranchName
    }
}

Invoke-RepoHealthGit -RepoRoot $WorktreePath -Arguments @(
    "-c", "user.name=$GitUserName",
    "-c", "user.email=$GitUserEmail",
    "commit", "-m", $CommitMessage
) | Out-Null

Invoke-RepoHealthGit -RepoRoot $WorktreePath -Arguments @("push", $RemoteName, "HEAD:$dataBranchName") | Out-Null

[PSCustomObject]@{
    changed     = $true
    branch_name = $dataBranchName
}
