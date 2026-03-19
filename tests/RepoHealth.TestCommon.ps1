Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-RepoHealthTestTempDirectory {
    param([Parameter(Mandatory = $true)][string]$Prefix)

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + "-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Remove-RepoHealthTestDirectory {
    param([string]$Path)

    if ($Path -and (Test-Path $Path)) {
        Remove-Item -Path $Path -Recurse -Force
    }
}

function Invoke-RepoHealthTestGit {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    Push-Location $RepoRoot
    try {
        $output = & git @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($exitCode -ne 0) {
        throw ("Git command failed in test repo: git {0}`n{1}" -f ($Arguments -join " "), ($output -join [Environment]::NewLine))
    }

    return @($output)
}

function Initialize-RepoHealthTestRepository {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$CreateBareRemote
    )

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    Invoke-RepoHealthTestGit -RepoRoot $Path -Arguments @("init", "--initial-branch=main") | Out-Null
    Invoke-RepoHealthTestGit -RepoRoot $Path -Arguments @("config", "user.name", "Repo Health Test Runner") | Out-Null
    Invoke-RepoHealthTestGit -RepoRoot $Path -Arguments @("config", "user.email", "repo-health-tests@example.com") | Out-Null

    Set-Content -Path (Join-Path $Path "README.md") -Value "# Repo Health Test Repo" -Encoding utf8
    Set-Content -Path (Join-Path $Path "notes.txt") -Value ("alpha" * 2048) -Encoding utf8
    New-Item -ItemType Directory -Path (Join-Path $Path "semantic") -Force | Out-Null
    Set-Content -Path (Join-Path $Path "semantic/en-US.tmdl") -Value ("m" * 65536) -Encoding utf8

    Invoke-RepoHealthTestGit -RepoRoot $Path -Arguments @("add", "README.md", "notes.txt", "semantic/en-US.tmdl") | Out-Null
    Invoke-RepoHealthTestGit -RepoRoot $Path -Arguments @("commit", "-m", "Initial test fixture") | Out-Null

    $remotePath = $null
    if ($CreateBareRemote) {
        $remotePath = New-RepoHealthTestTempDirectory -Prefix "repo-health-bare-remote"
        & git init --bare $remotePath | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to initialize bare remote for repo-health test."
        }
        Invoke-RepoHealthTestGit -RepoRoot $Path -Arguments @("remote", "add", "origin", $remotePath) | Out-Null
        Invoke-RepoHealthTestGit -RepoRoot $Path -Arguments @("push", "-u", "origin", "main") | Out-Null
    }

    return [PSCustomObject]@{
        repo_path   = $Path
        remote_path = $remotePath
    }
}

function Invoke-RepoHealthInstalledScript {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ScriptRelativePath,
        [string[]]$Arguments
    )

    $scriptPath = Join-Path $RepositoryRoot $ScriptRelativePath
    if (-not (Test-Path $scriptPath)) {
        throw "Installed script not found for test invocation: $scriptPath"
    }

    Push-Location $RepositoryRoot
    try {
        $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    return [PSCustomObject]@{
        exit_code = $exitCode
        output    = @($output)
    }
}

function Install-RepoHealthFrameworkIntoTestRepository {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRepositoryRoot,
        [Parameter(Mandatory = $true)][string]$TargetRepositoryRoot
    )

    $installerPath = Join-Path $SourceRepositoryRoot "repository-health/distribution/Install-RepoHealthFramework.ps1"
    if (-not (Test-Path $installerPath)) {
        throw "Installer not found: $installerPath"
    }

    return & $installerPath -TargetRepositoryRoot $TargetRepositoryRoot
}

function Assert-RepoHealthTrue {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-RepoHealthEqual {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Actual -ne $Expected) {
        throw ("{0}`nExpected: {1}`nActual: {2}" -f $Message, $Expected, $Actual)
    }
}

function Assert-RepoHealthPathExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not (Test-Path $Path)) {
        throw ("{0}`nMissing path: {1}" -f $Message, $Path)
    }
}

function Assert-RepoHealthTextContains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Substring,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Text.IndexOf($Substring, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw ("{0}`nMissing substring: {1}" -f $Message, $Substring)
    }
}

function Assert-RepoHealthNoTemplateTokens {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Text -match "__[A-Z0-9_]+__") {
        throw ("{0}`nUnresolved token found: {1}" -f $Message, $Matches[0])
    }
}
