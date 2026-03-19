[CmdletBinding()]
param(
    [string]$SourceRepositoryRoot,
    [switch]$FailFast,
    [switch]$KeepTemporaryRepositories
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$frameworkRoot = Split-Path -Parent $scriptRoot
if (-not $SourceRepositoryRoot) {
    $SourceRepositoryRoot = Split-Path -Parent $frameworkRoot
}

. (Join-Path $scriptRoot "RepoHealth.TestCommon.ps1")

$results = New-Object System.Collections.Generic.List[object]

function Add-RepoHealthTestResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][double]$DurationSeconds,
        [string]$Details
    )

    $results.Add([PSCustomObject]@{
        name             = $Name
        status           = $Status
        duration_seconds = [Math]::Round($DurationSeconds, 2)
        details          = $Details
    })
}

function Invoke-RepoHealthNamedTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Write-Host ("[TEST] {0}" -f $Name)
    $startedAt = [System.DateTimeOffset]::UtcNow

    try {
        & $Action
        $duration = ([System.DateTimeOffset]::UtcNow - $startedAt).TotalSeconds
        Add-RepoHealthTestResult -Name $Name -Status "PASS" -DurationSeconds $duration
        Write-Host ("[PASS] {0}" -f $Name)
    }
    catch {
        $duration = ([System.DateTimeOffset]::UtcNow - $startedAt).TotalSeconds
        $detail = $_.Exception.Message
        Add-RepoHealthTestResult -Name $Name -Status "FAIL" -DurationSeconds $duration -Details $detail
        Write-Host ("[FAIL] {0}" -f $Name)
        Write-Host ("        {0}" -f $detail)
        if ($FailFast) {
            throw
        }
    }
}

Invoke-RepoHealthNamedTest -Name "Installer renders config, workflows, and gitignore" -Action {
    $tempRepo = New-RepoHealthTestTempDirectory -Prefix "repo-health-selftest-installer"
    try {
        Initialize-RepoHealthTestRepository -Path $tempRepo | Out-Null
        Install-RepoHealthFrameworkIntoTestRepository -SourceRepositoryRoot $SourceRepositoryRoot -TargetRepositoryRoot $tempRepo | Out-Null

        Assert-RepoHealthPathExists -Path (Join-Path $tempRepo "repository-health/analyzer.ps1") -Message "Installer must copy analyzer."
        Assert-RepoHealthPathExists -Path (Join-Path $tempRepo "repository-health/config.json") -Message "Installer must generate config."
        Assert-RepoHealthPathExists -Path (Join-Path $tempRepo ".github/workflows/repo-health-pr.yml") -Message "Installer must create PR workflow."
        Assert-RepoHealthPathExists -Path (Join-Path $tempRepo ".github/workflows/repo-health-push.yml") -Message "Installer must create push workflow."
        Assert-RepoHealthPathExists -Path (Join-Path $tempRepo ".github/workflows/repo-health-schedule.yml") -Message "Installer must create schedule workflow."

        $configText = Get-Content -Path (Join-Path $tempRepo "repository-health/config.json") -Raw
        Assert-RepoHealthNoTemplateTokens -Text $configText -Message "Config must not contain unresolved template tokens."
        Assert-RepoHealthTextContains -Text $configText -Substring '"data_branch_name": "repo-health-data"' -Message "Config must include the default data branch."

        foreach ($workflowPath in @(
            (Join-Path $tempRepo ".github/workflows/repo-health-pr.yml"),
            (Join-Path $tempRepo ".github/workflows/repo-health-push.yml"),
            (Join-Path $tempRepo ".github/workflows/repo-health-schedule.yml")
        )) {
            $workflowText = Get-Content -Path $workflowPath -Raw
            Assert-RepoHealthNoTemplateTokens -Text $workflowText -Message ("Workflow must not contain unresolved template tokens: {0}" -f $workflowPath)
            Assert-RepoHealthTextContains -Text $workflowText -Substring "repository-health" -Message "Workflow must point to the installed framework root."
        }

        $gitIgnoreText = Get-Content -Path (Join-Path $tempRepo ".gitignore") -Raw
        Assert-RepoHealthTextContains -Text $gitIgnoreText -Substring "# BEGIN REPO-HEALTH" -Message "Installer must add repo-health block to .gitignore."
        Assert-RepoHealthTextContains -Text $gitIgnoreText -Substring "/repository-health/outputs/current/*" -Message "Installer must ignore current outputs."
    }
    finally {
        if (-not $KeepTemporaryRepositories) {
            Remove-RepoHealthTestDirectory -Path $tempRepo
        }
    }
}

Invoke-RepoHealthNamedTest -Name "Analyzer local mode generates expected artifacts" -Action {
    $tempRepo = New-RepoHealthTestTempDirectory -Prefix "repo-health-selftest-local"
    try {
        Initialize-RepoHealthTestRepository -Path $tempRepo | Out-Null
        Install-RepoHealthFrameworkIntoTestRepository -SourceRepositoryRoot $SourceRepositoryRoot -TargetRepositoryRoot $tempRepo | Out-Null

        $run = Invoke-RepoHealthInstalledScript -RepositoryRoot $tempRepo -ScriptRelativePath "repository-health/analyzer.ps1" -Arguments @("-Mode", "local")
        Assert-RepoHealthEqual -Actual $run.exit_code -Expected 0 -Message "Analyzer local mode must succeed."

        $metricsPath = Join-Path $tempRepo "repository-health/outputs/current/metrics.json"
        $summaryPath = Join-Path $tempRepo "repository-health/outputs/current/summary.md"
        $dashboardPath = Join-Path $tempRepo "repository-health/outputs/current/dashboard.html"
        $historyCsvPath = Join-Path $tempRepo "repository-health/outputs/history/metrics-history.csv"
        $topFilesCsvPath = Join-Path $tempRepo "repository-health/outputs/history/top-files-history.csv"

        Assert-RepoHealthPathExists -Path $metricsPath -Message "Analyzer must generate metrics.json."
        Assert-RepoHealthPathExists -Path $summaryPath -Message "Analyzer must generate summary.md."
        Assert-RepoHealthPathExists -Path $dashboardPath -Message "Analyzer must generate dashboard.html."
        Assert-RepoHealthPathExists -Path $historyCsvPath -Message "Analyzer must generate metrics-history.csv."
        Assert-RepoHealthPathExists -Path $topFilesCsvPath -Message "Analyzer must generate top-files-history.csv."

        $metrics = Get-Content -Path $metricsPath -Raw | ConvertFrom-Json -Depth 100
        Assert-RepoHealthTrue -Condition (-not [string]::IsNullOrWhiteSpace([string]$metrics.policy.status)) -Message "Metrics must contain policy status."
        Assert-RepoHealthTrue -Condition (@($metrics.repo.top_current_files).Count -gt 0) -Message "Metrics must contain top current files."

        $summaryText = Get-Content -Path $summaryPath -Raw
        $dashboardText = Get-Content -Path $dashboardPath -Raw
        Assert-RepoHealthTextContains -Text $summaryText -Substring "Repository Health Check" -Message "Summary must contain the standard heading."
        Assert-RepoHealthTextContains -Text $dashboardText -Substring "Repository Health Dashboard" -Message "Dashboard must contain the standard title."
    }
    finally {
        if (-not $KeepTemporaryRepositories) {
            Remove-RepoHealthTestDirectory -Path $tempRepo
        }
    }
}

Invoke-RepoHealthNamedTest -Name "Analyzer tracks file growth across successive runs" -Action {
    $tempRepo = New-RepoHealthTestTempDirectory -Prefix "repo-health-selftest-growth"
    try {
        Initialize-RepoHealthTestRepository -Path $tempRepo | Out-Null
        Install-RepoHealthFrameworkIntoTestRepository -SourceRepositoryRoot $SourceRepositoryRoot -TargetRepositoryRoot $tempRepo | Out-Null

        $firstRun = Invoke-RepoHealthInstalledScript -RepositoryRoot $tempRepo -ScriptRelativePath "repository-health/analyzer.ps1" -Arguments @("-Mode", "local")
        Assert-RepoHealthEqual -Actual $firstRun.exit_code -Expected 0 -Message "First analyzer run must succeed."

        Add-Content -Path (Join-Path $tempRepo "semantic/en-US.tmdl") -Value ("n" * 65536) -Encoding utf8
        Set-Content -Path (Join-Path $tempRepo "semantic/extra-large.json") -Value ("x" * 70000) -Encoding utf8
        Invoke-RepoHealthTestGit -RepoRoot $tempRepo -Arguments @("add", "semantic/en-US.tmdl", "semantic/extra-large.json") | Out-Null
        Invoke-RepoHealthTestGit -RepoRoot $tempRepo -Arguments @("commit", "-m", "Grow tracked files") | Out-Null

        $secondRun = Invoke-RepoHealthInstalledScript -RepositoryRoot $tempRepo -ScriptRelativePath "repository-health/analyzer.ps1" -Arguments @("-Mode", "local")
        Assert-RepoHealthEqual -Actual $secondRun.exit_code -Expected 0 -Message "Second analyzer run must succeed."

        $metrics = Get-Content -Path (Join-Path $tempRepo "repository-health/outputs/current/metrics.json") -Raw | ConvertFrom-Json -Depth 100
        Assert-RepoHealthTrue -Condition ([bool]$metrics.file_growth.hasBaseline) -Message "Second run must have a file-growth baseline."
        Assert-RepoHealthTrue -Condition (($metrics.file_growth.grown_entries_count -gt 0) -or ($metrics.file_growth.new_entries_count -gt 0)) -Message "File-growth insights must detect at least one changed top file."
        Assert-RepoHealthTrue -Condition (@($metrics.file_growth.changes | Where-Object { $_.change_type -in @("UP", "NEW") }).Count -gt 0) -Message "File-growth changes must contain UP or NEW entries."

        $summaryText = Get-Content -Path (Join-Path $tempRepo "repository-health/outputs/current/summary.md") -Raw
        Assert-RepoHealthTextContains -Text $summaryText -Substring "Current Top File Growth vs Previous Baseline" -Message "Summary must contain the file-growth section."

        $topFilesHistoryRows = @(Import-Csv -Path (Join-Path $tempRepo "repository-health/outputs/history/top-files-history.csv"))
        Assert-RepoHealthTrue -Condition ($topFilesHistoryRows.Count -ge 4) -Message "Top files history must contain rows from multiple runs."
    }
    finally {
        if (-not $KeepTemporaryRepositories) {
            Remove-RepoHealthTestDirectory -Path $tempRepo
        }
    }
}

Invoke-RepoHealthNamedTest -Name "Prepare and publish scripts bootstrap the data branch" -Action {
    $tempRepo = New-RepoHealthTestTempDirectory -Prefix "repo-health-selftest-persist"
    $worktreePath = New-RepoHealthTestTempDirectory -Prefix "repo-health-selftest-worktree"
    $remotePath = $null

    try {
        $repoInfo = Initialize-RepoHealthTestRepository -Path $tempRepo -CreateBareRemote
        $remotePath = $repoInfo.remote_path
        Install-RepoHealthFrameworkIntoTestRepository -SourceRepositoryRoot $SourceRepositoryRoot -TargetRepositoryRoot $tempRepo | Out-Null

        $prepareScript = Join-Path $tempRepo "repository-health/scripts/Prepare-RepoHealthDataBranch.ps1"
        $publishScript = Join-Path $tempRepo "repository-health/scripts/Publish-RepoHealthDataBranch.ps1"

        $prepareResult = & $prepareScript -RepositoryRoot $tempRepo -WorktreePath $worktreePath
        Assert-RepoHealthEqual -Actual $prepareResult.branch_name -Expected "repo-health-data" -Message "Prepare script must target the data branch."
        Assert-RepoHealthPathExists -Path $prepareResult.history_root_path -Message "Prepare script must create the history root."
        Assert-RepoHealthPathExists -Path (Join-Path $prepareResult.worktree_path "repository-health/README.md") -Message "Prepare script must write a branch README."

        $pushRun = Invoke-RepoHealthInstalledScript -RepositoryRoot $tempRepo -ScriptRelativePath "repository-health/analyzer.ps1" -Arguments @("-Mode", "push", "-WriteHistory", "-HistoryRootPath", $prepareResult.history_root_path)
        Assert-RepoHealthEqual -Actual $pushRun.exit_code -Expected 0 -Message "Analyzer push mode must succeed when history root is redirected to the data worktree."

        $publishResult = & $publishScript -WorktreePath $prepareResult.worktree_path -CommitMessage "chore(repo-health): update metrics for tests"
        Assert-RepoHealthTrue -Condition ([bool]$publishResult.changed) -Message "Publish script must commit and push the data branch."

        $remoteHeads = Invoke-RepoHealthTestGit -RepoRoot $tempRepo -Arguments @("ls-remote", "--heads", "origin", "repo-health-data")
        Assert-RepoHealthTrue -Condition (@($remoteHeads).Count -gt 0) -Message "Remote must contain the repo-health-data branch after publish."
    }
    finally {
        if (-not $KeepTemporaryRepositories) {
            Remove-RepoHealthTestDirectory -Path $worktreePath
            Remove-RepoHealthTestDirectory -Path $tempRepo
            Remove-RepoHealthTestDirectory -Path $remotePath
        }
    }
}

Invoke-RepoHealthNamedTest -Name "Analyzer blocks forbidden files when threshold enforcement is enabled" -Action {
    $tempRepo = New-RepoHealthTestTempDirectory -Prefix "repo-health-selftest-fail"
    try {
        Initialize-RepoHealthTestRepository -Path $tempRepo | Out-Null
        Install-RepoHealthFrameworkIntoTestRepository -SourceRepositoryRoot $SourceRepositoryRoot -TargetRepositoryRoot $tempRepo | Out-Null

        Set-Content -Path (Join-Path $tempRepo "forbidden.pbix") -Value "placeholder" -Encoding utf8
        $run = Invoke-RepoHealthInstalledScript -RepositoryRoot $tempRepo -ScriptRelativePath "repository-health/analyzer.ps1" -Arguments @("-Mode", "local", "-FailOnThresholdBreach")
        Assert-RepoHealthEqual -Actual $run.exit_code -Expected 1 -Message "Analyzer must fail when forbidden files are present and threshold enforcement is enabled."

        $metrics = Get-Content -Path (Join-Path $tempRepo "repository-health/outputs/current/metrics.json") -Raw | ConvertFrom-Json -Depth 100
        Assert-RepoHealthEqual -Actual $metrics.policy.status -Expected "FAIL" -Message "Metrics must record FAIL status for forbidden files."
        Assert-RepoHealthTrue -Condition (@($metrics.repo.forbidden_files).Count -gt 0) -Message "Forbidden files must be listed in metrics."
    }
    finally {
        if (-not $KeepTemporaryRepositories) {
            Remove-RepoHealthTestDirectory -Path $tempRepo
        }
    }
}

$passCount = @($results | Where-Object { $_.status -eq "PASS" }).Count
$failCount = @($results | Where-Object { $_.status -eq "FAIL" }).Count

Write-Host ""
Write-Host "Repository Health Self-Tests"
Write-Host ("  Passed: {0}" -f $passCount)
Write-Host ("  Failed: {0}" -f $failCount)

foreach ($result in $results) {
    Write-Host ("  - [{0}] {1} ({2}s)" -f $result.status, $result.name, $result.duration_seconds)
    if ($result.details) {
        Write-Host ("      {0}" -f $result.details)
    }
}

if ($env:GITHUB_STEP_SUMMARY) {
    $summaryLines = New-Object System.Collections.Generic.List[string]
    $summaryLines.Add("## Repository Health Self-Tests")
    $summaryLines.Add("")
    $summaryLines.Add("| Test | Status | Duration (s) |")
    $summaryLines.Add("| --- | --- | ---: |")
    foreach ($result in $results) {
        $summaryLines.Add(("| {0} | {1} | {2} |" -f $result.name, $result.status, $result.duration_seconds))
    }
    $summaryLines.Add("")
    $summaryLines.Add(("Passed: {0}" -f $passCount))
    $summaryLines.Add(("Failed: {0}" -f $failCount))
    ($summaryLines -join [Environment]::NewLine) | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
}

if ($failCount -gt 0) {
    exit 1
}
