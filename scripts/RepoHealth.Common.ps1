function Ensure-RepoHealthDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-RepoHealthConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Repo health config not found: $Path"
    }

    return (Get-Content -Path $Path -Raw | ConvertFrom-Json -Depth 20)
}

function Get-RepoHealthTimestampInfo {
    param([string]$RunTimestamp)

    if ([string]::IsNullOrWhiteSpace($RunTimestamp)) {
        $timestampUtc = [System.DateTimeOffset]::UtcNow
    }
    else {
        $timestampUtc = [System.DateTimeOffset]::Parse(
            $RunTimestamp,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
        ).ToUniversalTime()
    }

    return [PSCustomObject]@{
        iso_utc        = $timestampUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
        file_safe_utc  = $timestampUtc.ToString("yyyy-MM-ddTHH-mm-ssZ")
        date_time_utc  = $timestampUtc.UtcDateTime
    }
}

function Get-RepoHealthRepositoryName {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$RepositoryName
    )

    if (-not [string]::IsNullOrWhiteSpace($RepositoryName)) {
        return $RepositoryName
    }

    if ($env:GITHUB_REPOSITORY) {
        return $env:GITHUB_REPOSITORY
    }

    return Split-Path -Leaf $RepoRoot
}

function Invoke-RepoHealthGit {
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
        throw ("Git command failed: git {0}`n{1}" -f ($Arguments -join " "), ($output -join [Environment]::NewLine))
    }

    return @($output)
}

function Convert-RepoHealthBytesToMb {
    param([double]$Bytes)

    if (-not $Bytes) {
        return 0
    }

    return [Math]::Round(($Bytes / 1MB), 2)
}

function Convert-RepoHealthKiBToMb {
    param([double]$KiB)

    if (-not $KiB) {
        return 0
    }

    return [Math]::Round(($KiB / 1024), 2)
}

function Convert-RepoHealthNumberToInvariantString {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }

    return [string]$Value
}

function Get-RepoHealthRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$FullPath
    )

    return ([System.IO.Path]::GetRelativePath($RepoRoot, $FullPath)).Replace("\", "/")
}

function Get-RepoHealthDirectorySizeBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        return 0
    }

    $sum = (Get-ChildItem -Path $Path -Recurse -Force -File | Measure-Object -Property Length -Sum).Sum
    if (-not $sum) {
        return 0
    }

    return [int64]$sum
}

function Get-RepoHealthNormalizedPrefix {
    param([Parameter(Mandatory = $true)][string]$Prefix)

    $normalized = $Prefix.Replace("\", "/").Trim()
    if ($normalized.StartsWith("./")) {
        $normalized = $normalized.Substring(2)
    }
    elseif ($normalized.StartsWith("/")) {
        $normalized = $normalized.Substring(1)
    }

    if (-not $normalized.EndsWith("/")) {
        $normalized += "/"
    }

    return $normalized
}

function Test-RepoHealthPathExcluded {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string[]]$ExcludedPrefixes
    )

    $normalizedPath = $RelativePath.Replace("\", "/")
    if ($normalizedPath.StartsWith("./")) {
        $normalizedPath = $normalizedPath.Substring(2)
    }
    elseif ($normalizedPath.StartsWith("/")) {
        $normalizedPath = $normalizedPath.Substring(1)
    }

    foreach ($prefix in $ExcludedPrefixes) {
        $normalizedPrefix = Get-RepoHealthNormalizedPrefix -Prefix $prefix
        if (
            $normalizedPath.StartsWith($normalizedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalizedPath.IndexOf(("/" + $normalizedPrefix), [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        ) {
            return $true
        }
    }

    return $false
}

function Test-RepoHealthPathAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [string[]]$AllowedPaths
    )

    if (-not $AllowedPaths) {
        return $false
    }

    $normalizedPath = $RelativePath.Replace("\", "/")
    if ($normalizedPath.StartsWith("./")) {
        $normalizedPath = $normalizedPath.Substring(2)
    }
    elseif ($normalizedPath.StartsWith("/")) {
        $normalizedPath = $normalizedPath.Substring(1)
    }

    foreach ($allowedPath in $AllowedPaths) {
        $normalizedAllowedPath = $allowedPath.Replace("\", "/")
        if ($normalizedAllowedPath.StartsWith("./")) {
            $normalizedAllowedPath = $normalizedAllowedPath.Substring(2)
        }
        elseif ($normalizedAllowedPath.StartsWith("/")) {
            $normalizedAllowedPath = $normalizedAllowedPath.Substring(1)
        }

        if ($normalizedPath.Equals($normalizedAllowedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-RepoHealthTrackedFiles {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    return @(Invoke-RepoHealthGit -RepoRoot $RepoRoot -Arguments @("ls-files"))
}

function Get-RepoHealthGitCoreMetrics {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $lines = Invoke-RepoHealthGit -RepoRoot $RepoRoot -Arguments @("count-objects", "-v")
    $parsed = @{}

    foreach ($line in $lines) {
        if ($line -match "^(?<Key>[a-z-]+):\s+(?<Value>.+)$") {
            $parsed[$Matches.Key] = $Matches.Value.Trim()
        }
    }

    $looseObjectCount = [int]($parsed["count"] ?? 0)
    $packedObjectCount = [int]($parsed["in-pack"] ?? 0)

    return [PSCustomObject]@{
        LooseObjectCount  = $looseObjectCount
        PackedObjectCount = $packedObjectCount
        ObjectCount       = ($looseObjectCount + $packedObjectCount)
        PackCount         = [int]($parsed["packs"] ?? 0)
        SizePackKiB       = [double]($parsed["size-pack"] ?? 0)
        SizePackMb        = Convert-RepoHealthKiBToMb -KiB ([double]($parsed["size-pack"] ?? 0))
    }
}

function Get-RepoHealthRepositoryMetrics {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)]$Config
    )

    $gitDir = Join-Path $RepoRoot ".git"
    $gitSizeBytes = Get-RepoHealthDirectorySizeBytes -Path $gitDir
    $trackedFiles = Get-RepoHealthTrackedFiles -RepoRoot $RepoRoot
    $excludedPrefixes = @($Config.excluded_paths | ForEach-Object { Get-RepoHealthNormalizedPrefix -Prefix $_ })
    $allowedTrackedExcludedPaths = @($Config.allowed_tracked_excluded_paths)
    $currentFiles = Get-ChildItem -Path $RepoRoot -Recurse -Force -File | Where-Object {
        $_.FullName -notlike (Join-Path $gitDir "*") -and
        -not (Test-RepoHealthPathExcluded -RelativePath (Get-RepoHealthRelativePath -RepoRoot $RepoRoot -FullPath $_.FullName) -ExcludedPrefixes $excludedPrefixes)
    }

    $topCurrentFiles = @(
        $currentFiles |
            Sort-Object Length -Descending |
            Select-Object -First $Config.top_n |
            ForEach-Object {
                [PSCustomObject]@{
                    path    = Get-RepoHealthRelativePath -RepoRoot $RepoRoot -FullPath $_.FullName
                    size_mb = Convert-RepoHealthBytesToMb -Bytes $_.Length
                    size_b  = [int64]$_.Length
                }
            }
    )

    $forbiddenExtensions = @($Config.forbidden_extensions | ForEach-Object { $_.ToLowerInvariant() })
    $forbiddenFiles = @(
        $currentFiles |
            Where-Object { $forbiddenExtensions -contains $_.Extension.ToLowerInvariant() } |
            Sort-Object Length -Descending |
            ForEach-Object {
                [PSCustomObject]@{
                    path      = Get-RepoHealthRelativePath -RepoRoot $RepoRoot -FullPath $_.FullName
                    size_mb   = Convert-RepoHealthBytesToMb -Bytes $_.Length
                    extension = $_.Extension
                }
            }
    )

    $trackedExcludedFiles = @(
        $trackedFiles |
            Where-Object {
                (Test-RepoHealthPathExcluded -RelativePath $_ -ExcludedPrefixes $excludedPrefixes) -and
                -not (Test-RepoHealthPathAllowed -RelativePath $_ -AllowedPaths $allowedTrackedExcludedPaths)
            } |
            Sort-Object
    )

    return [PSCustomObject]@{
        GitSizeBytes         = $gitSizeBytes
        GitSizeMb            = Convert-RepoHealthBytesToMb -Bytes $gitSizeBytes
        TrackedFileCount     = @($trackedFiles).Count
        WorkingFileCount     = @($currentFiles).Count
        CommitCount          = [int]((Invoke-RepoHealthGit -RepoRoot $RepoRoot -Arguments @("rev-list", "--count", "HEAD"))[0])
        TopCurrentFiles      = $topCurrentFiles
        LargestCurrentFileMb = if ($topCurrentFiles.Count -gt 0) { $topCurrentFiles[0].size_mb } else { 0 }
        ForbiddenFiles       = $forbiddenFiles
        TrackedExcludedFiles = $trackedExcludedFiles
    }
}

function Get-RepoHealthBlobHistoryMetrics {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)]$Config
    )

    $objectLines = @(Invoke-RepoHealthGit -RepoRoot $RepoRoot -Arguments @("rev-list", "--objects", "--all"))
    if ($objectLines.Count -eq 0) {
        return [PSCustomObject]@{
            LargestBlobs         = @()
            MaxBlobMb            = 0
            MaxBlobPath          = $null
            BlobOver1Mb          = 0
            BlobOver5Mb          = 0
            BlobOverConfiguredMb = 0
        }
    }

    Push-Location $RepoRoot
    try {
        $batchLines = @($objectLines | & git "--no-pager" cat-file "--batch-check=%(objectname) %(objecttype) %(objectsize) %(rest)")
        if ($LASTEXITCODE -ne 0) {
            throw "git cat-file batch-check failed."
        }
    }
    finally {
        Pop-Location
    }

    $blobRows = New-Object System.Collections.Generic.List[object]
    foreach ($line in $batchLines) {
        if ($line -match "^(?<Sha>[0-9a-f]{40})\s+(?<Type>\w+)\s+(?<Size>\d+)\s*(?<Path>.*)$" -and $Matches.Type -eq "blob") {
            $sizeBytes = [int64]$Matches.Size
            $blobRows.Add([PSCustomObject]@{
                sha     = $Matches.Sha
                path    = $Matches.Path
                size_b  = $sizeBytes
                size_mb = Convert-RepoHealthBytesToMb -Bytes $sizeBytes
            })
        }
    }

    $largestBlobs = @($blobRows | Sort-Object size_b -Descending | Select-Object -First $Config.top_n)

    return [PSCustomObject]@{
        LargestBlobs         = $largestBlobs
        MaxBlobMb            = if ($largestBlobs.Count -gt 0) { $largestBlobs[0].size_mb } else { 0 }
        MaxBlobPath          = if ($largestBlobs.Count -gt 0) { $largestBlobs[0].path } else { $null }
        BlobOver1Mb          = @($blobRows | Where-Object { $_.size_b -gt 1MB }).Count
        BlobOver5Mb          = @($blobRows | Where-Object { $_.size_b -gt 5MB }).Count
        BlobOverConfiguredMb = @($blobRows | Where-Object { $_.size_mb -gt [double]$Config.max_blob_mb }).Count
    }
}

function Get-RepoHealthBranchName {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    if ($env:GITHUB_REF_NAME) {
        return $env:GITHUB_REF_NAME
    }

    return [string]((@(Invoke-RepoHealthGit -RepoRoot $RepoRoot -Arguments @("rev-parse", "--abbrev-ref", "HEAD")))[0])
}

function Get-RepoHealthCommitSha {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    if ($env:GITHUB_SHA) {
        return $env:GITHUB_SHA
    }

    return [string]((@(Invoke-RepoHealthGit -RepoRoot $RepoRoot -Arguments @("rev-parse", "HEAD")))[0])
}

function Read-RepoHealthPreviousMetrics {
    param([Parameter(Mandatory = $true)][string]$LatestMetricsPath)

    if (-not (Test-Path $LatestMetricsPath)) {
        return $null
    }

    return (Get-Content -Path $LatestMetricsPath -Raw | ConvertFrom-Json -Depth 50)
}

function Get-RepoHealthHistoryPaths {
    param(
        [Parameter(Mandatory = $true)][string]$HistoryRootPath,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$RunTimestampKey
    )

    $runsDirectoryPath = Join-Path $HistoryRootPath $Config.runs_directory_name
    $gitSizerDirectoryPath = Join-Path $HistoryRootPath $Config.git_sizer_directory_name

    return [PSCustomObject]@{
        history_root_path      = $HistoryRootPath
        latest_metrics_path    = Join-Path $HistoryRootPath $Config.latest_metrics_name
        history_csv_path       = Join-Path $HistoryRootPath $Config.history_csv_name
        top_files_history_csv_path = Join-Path $HistoryRootPath $Config.top_files_history_csv_name
        runs_directory_path    = $runsDirectoryPath
        git_sizer_directory_path = $gitSizerDirectoryPath
        run_json_path          = Join-Path $runsDirectoryPath ($RunTimestampKey + ".json")
        run_summary_path       = Join-Path $runsDirectoryPath ($RunTimestampKey + ".md")
        run_git_sizer_path     = Join-Path $gitSizerDirectoryPath ($RunTimestampKey + ".txt")
    }
}

function Ensure-RepoHealthHistoryStructure {
    param(
        [Parameter(Mandatory = $true)]$HistoryPaths
    )

    Ensure-RepoHealthDirectory -Path $HistoryPaths.history_root_path
    Ensure-RepoHealthDirectory -Path $HistoryPaths.runs_directory_path
    Ensure-RepoHealthDirectory -Path $HistoryPaths.git_sizer_directory_path
}

function Get-RepoHealthGrowthPct {
    param(
        [double]$Current,
        [double]$Previous
    )

    if (-not $Previous -or $Previous -le 0) {
        return $null
    }

    return [Math]::Round((($Current - $Previous) / $Previous) * 100, 2)
}

function Get-RepoHealthGrowthMetrics {
    param(
        [Parameter(Mandatory = $true)]$CurrentMetrics,
        $PreviousMetrics
    )

    if (-not $PreviousMetrics) {
        return [PSCustomObject]@{
            hasBaseline        = $false
            size_pack_growth_pct = $null
            git_size_growth_pct  = $null
        }
    }

    return [PSCustomObject]@{
        hasBaseline          = $true
        size_pack_growth_pct = Get-RepoHealthGrowthPct -Current $CurrentMetrics.git_core.size_pack_mb -Previous $PreviousMetrics.git_core.size_pack_mb
        git_size_growth_pct  = Get-RepoHealthGrowthPct -Current $CurrentMetrics.repo.git_size_mb -Previous $PreviousMetrics.repo.git_size_mb
    }
}

function Get-RepoHealthFileGrowthInsights {
    param(
        [Parameter(Mandatory = $true)]$CurrentMetrics,
        $PreviousMetrics
    )

    if (
        -not $PreviousMetrics -or
        -not $PreviousMetrics.repo -or
        -not $PreviousMetrics.repo.top_current_files
    ) {
        return [PSCustomObject]@{
            hasBaseline          = $false
            baseline_commit      = $null
            baseline_timestamp   = $null
            new_entries_count    = 0
            grown_entries_count  = 0
            shrunk_entries_count = 0
            unchanged_count      = 0
            changes              = @()
        }
    }

    $previousByPath = @{}
    $previousRank = 1
    foreach ($item in @($PreviousMetrics.repo.top_current_files)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$item.path)) {
            $previousByPath[[string]$item.path] = [PSCustomObject]@{
                rank    = $previousRank
                size_mb = [double]$item.size_mb
                size_b  = if ($null -ne $item.size_b) { [int64]$item.size_b } else { 0 }
            }
        }
        $previousRank++
    }

    $changes = New-Object System.Collections.Generic.List[object]
    $newEntriesCount = 0
    $grownEntriesCount = 0
    $shrunkEntriesCount = 0
    $unchangedCount = 0
    $currentRank = 1

    foreach ($item in @($CurrentMetrics.repo.top_current_files)) {
        $path = [string]$item.path
        $currentSizeMb = [double]$item.size_mb
        $previousItem = $null
        if ($previousByPath.ContainsKey($path)) {
            $previousItem = $previousByPath[$path]
        }

        $previousSizeMb = if ($previousItem) { [double]$previousItem.size_mb } else { $null }
        $deltaMb = if ($null -ne $previousSizeMb) { [Math]::Round(($currentSizeMb - $previousSizeMb), 2) } else { $null }
        $deltaPct = if ($null -ne $previousSizeMb -and $previousSizeMb -gt 0) { [Math]::Round((($currentSizeMb - $previousSizeMb) / $previousSizeMb) * 100, 2) } else { $null }

        if ($null -eq $previousItem) {
            $changeType = "NEW"
            $newEntriesCount++
        }
        elseif ($currentSizeMb -gt $previousSizeMb) {
            $changeType = "UP"
            $grownEntriesCount++
        }
        elseif ($currentSizeMb -lt $previousSizeMb) {
            $changeType = "DOWN"
            $shrunkEntriesCount++
        }
        else {
            $changeType = "UNCHANGED"
            $unchangedCount++
        }

        $changes.Add([PSCustomObject]@{
            path              = $path
            rank              = $currentRank
            previous_rank     = if ($previousItem) { $previousItem.rank } else { $null }
            current_size_mb   = $currentSizeMb
            previous_size_mb  = $previousSizeMb
            delta_mb          = $deltaMb
            delta_pct         = $deltaPct
            change_type       = $changeType
        })

        $currentRank++
    }

    $baselineCommit = if ($PreviousMetrics.commit) { [string]$PreviousMetrics.commit } else { $null }
    if ($PreviousMetrics.timestamp) {
        if ($PreviousMetrics.timestamp -is [datetimeoffset]) {
            $baselineTimestamp = $PreviousMetrics.timestamp.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        elseif ($PreviousMetrics.timestamp -is [datetime]) {
            $baselineTimestamp = ([datetimeoffset]$PreviousMetrics.timestamp).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        else {
            $baselineTimestamp = [string]$PreviousMetrics.timestamp
        }
    }
    else {
        $baselineTimestamp = $null
    }
    $changesArray = $changes.ToArray()

    return [PSCustomObject]@{
        hasBaseline          = $true
        baseline_commit      = $baselineCommit
        baseline_timestamp   = $baselineTimestamp
        new_entries_count    = $newEntriesCount
        grown_entries_count  = $grownEntriesCount
        shrunk_entries_count = $shrunkEntriesCount
        unchanged_count      = $unchangedCount
        changes              = $changesArray
    }
}

function Get-RepoHealthPolicy {
    param(
        [Parameter(Mandatory = $true)]$Metrics,
        [Parameter(Mandatory = $true)]$Config
    )

    $failReasons = New-Object System.Collections.Generic.List[string]
    $warningReasons = New-Object System.Collections.Generic.List[string]

    if (@($Metrics.repo.forbidden_files).Count -gt 0) {
        $failReasons.Add(("Forbidden extensions detected in working tree: {0}" -f (@($Metrics.repo.forbidden_files | ForEach-Object { $_.path }) -join ", ")))
    }

    if (@($Metrics.repo.tracked_excluded_files).Count -gt 0) {
        $failReasons.Add(("Tracked files found in excluded paths: {0}" -f (@($Metrics.repo.tracked_excluded_files) -join ", ")))
    }

    if ([double]$Metrics.history.max_blob_mb -gt [double]$Config.max_blob_mb) {
        $failReasons.Add(("Largest blob {0} MB exceeds threshold {1} MB." -f $Metrics.history.max_blob_mb, $Config.max_blob_mb))
    }

    if ([double]$Metrics.git_core.size_pack_mb -gt [double]$Config.max_pack_mb) {
        $warningReasons.Add(("Pack size {0} MB exceeds configured threshold {1} MB." -f $Metrics.git_core.size_pack_mb, $Config.max_pack_mb))
    }

    if ($Metrics.growth.hasBaseline) {
        if ($null -ne $Metrics.growth.size_pack_growth_pct -and [double]$Metrics.growth.size_pack_growth_pct -gt [double]$Config.max_growth_pct) {
            $warningReasons.Add(("size-pack grew by {0}% over the previous baseline." -f $Metrics.growth.size_pack_growth_pct))
        }

        if ($null -ne $Metrics.growth.git_size_growth_pct -and [double]$Metrics.growth.git_size_growth_pct -gt [double]$Config.max_growth_pct) {
            $warningReasons.Add(("`.git` size grew by {0}% over the previous baseline." -f $Metrics.growth.git_size_growth_pct))
        }
    }

    if ([double]$Metrics.repo.largest_current_file_mb -gt [double]$Config.warn_current_file_mb) {
        $warningReasons.Add(("Largest current file is {0} MB, above warning threshold {1} MB." -f $Metrics.repo.largest_current_file_mb, $Config.warn_current_file_mb))
    }

    $status = if ($failReasons.Count -gt 0) { "FAIL" } elseif ($warningReasons.Count -gt 0) { "WARN" } else { "OK" }

    return [PSCustomObject]@{
        status          = $status
        fail_reasons    = @($failReasons)
        warning_reasons = @($warningReasons)
    }
}

function Write-RepoHealthJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$InputObject
    )

    $parent = Split-Path $Path -Parent
    Ensure-RepoHealthDirectory -Path $parent
    $json = $InputObject | ConvertTo-Json -Depth 100
    Set-Content -Path $Path -Value $json -Encoding utf8
}

function Get-RepoHealthHistoryRow {
    param([Parameter(Mandatory = $true)]$Metrics)

    return [PSCustomObject]@{
        timestamp               = $Metrics.timestamp
        repository              = $Metrics.repository
        branch                  = $Metrics.branch
        commit_sha              = $Metrics.commit
        commit_count            = $Metrics.repo.commit_count
        size_pack_mb            = Convert-RepoHealthNumberToInvariantString -Value $Metrics.git_core.size_pack_mb
        git_size_mb             = Convert-RepoHealthNumberToInvariantString -Value $Metrics.repo.git_size_mb
        max_blob_mb             = Convert-RepoHealthNumberToInvariantString -Value $Metrics.history.max_blob_mb
        blob_over_1mb           = $Metrics.history.blob_over_1mb
        blob_over_5mb           = $Metrics.history.blob_over_5mb
        current_largest_file_mb = Convert-RepoHealthNumberToInvariantString -Value $Metrics.repo.largest_current_file_mb
        forbidden_file_count    = @($Metrics.repo.forbidden_files).Count
        status                  = $Metrics.policy.status
    }
}

function Get-RepoHealthTopFilesHistoryRows {
    param([Parameter(Mandatory = $true)]$Metrics)

    $rank = 1
    $rows = foreach ($item in @($Metrics.repo.top_current_files)) {
        [PSCustomObject]@{
            timestamp   = $Metrics.timestamp
            repository  = $Metrics.repository
            branch      = $Metrics.branch
            commit_sha  = $Metrics.commit
            mode        = $Metrics.mode
            status      = $Metrics.policy.status
            rank        = $rank
            path        = [string]$item.path
            size_mb     = Convert-RepoHealthNumberToInvariantString -Value $item.size_mb
            size_b      = [string]$item.size_b
        }
        $rank++
    }

    return @($rows)
}

function Test-RepoHealthCsvSchemaMatches {
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [Parameter(Mandatory = $true)]$ExpectedRow
    )

    if (-not (Test-Path $CsvPath)) {
        return $true
    }

    $headerLine = (Get-Content -Path $CsvPath -TotalCount 1)
    if ([string]::IsNullOrWhiteSpace($headerLine)) {
        return $true
    }

    $existingColumns = @(
        $headerLine.Trim('"').Split('","') |
            ForEach-Object { $_.Trim() }
    )
    $expectedColumns = @($ExpectedRow.PSObject.Properties.Name)

    if ($existingColumns.Count -ne $expectedColumns.Count) {
        return $false
    }

    for ($index = 0; $index -lt $expectedColumns.Count; $index++) {
        if ($existingColumns[$index] -ne $expectedColumns[$index]) {
            return $false
        }
    }

    return $true
}

function Update-RepoHealthHistoryStore {
    param(
        [Parameter(Mandatory = $true)]$Metrics,
        [Parameter(Mandatory = $true)]$HistoryPaths,
        [Parameter(Mandatory = $true)][string]$SummaryMarkdown,
        [string]$GitSizerRuntimePath
    )

    Ensure-RepoHealthHistoryStructure -HistoryPaths $HistoryPaths

    $row = Get-RepoHealthHistoryRow -Metrics $Metrics
    if (-not (Test-RepoHealthCsvSchemaMatches -CsvPath $HistoryPaths.history_csv_path -ExpectedRow $row)) {
        $legacyPath = "{0}.legacy-{1}.csv" -f $HistoryPaths.history_csv_path, ([DateTime]::UtcNow.ToString("yyyyMMddHHmmss"))
        Move-Item -Path $HistoryPaths.history_csv_path -Destination $legacyPath -Force
    }

    if (Test-Path $HistoryPaths.history_csv_path) {
        $row | Export-Csv -Path $HistoryPaths.history_csv_path -NoTypeInformation -Append
    }
    else {
        $row | Export-Csv -Path $HistoryPaths.history_csv_path -NoTypeInformation
    }

    $topFilesRows = @(Get-RepoHealthTopFilesHistoryRows -Metrics $Metrics)
    if ($topFilesRows.Count -gt 0) {
        $topFilesSchemaProbe = $topFilesRows[0]
        if (-not (Test-RepoHealthCsvSchemaMatches -CsvPath $HistoryPaths.top_files_history_csv_path -ExpectedRow $topFilesSchemaProbe)) {
            $legacyTopFilesPath = "{0}.legacy-{1}.csv" -f $HistoryPaths.top_files_history_csv_path, ([DateTime]::UtcNow.ToString("yyyyMMddHHmmss"))
            Move-Item -Path $HistoryPaths.top_files_history_csv_path -Destination $legacyTopFilesPath -Force
        }

        if (Test-Path $HistoryPaths.top_files_history_csv_path) {
            $topFilesRows | Export-Csv -Path $HistoryPaths.top_files_history_csv_path -NoTypeInformation -Append
        }
        else {
            $topFilesRows | Export-Csv -Path $HistoryPaths.top_files_history_csv_path -NoTypeInformation
        }
    }

    Write-RepoHealthJsonFile -Path $HistoryPaths.latest_metrics_path -InputObject $Metrics
    Write-RepoHealthJsonFile -Path $HistoryPaths.run_json_path -InputObject $Metrics
    Write-RepoHealthSummaryFile -Path $HistoryPaths.run_summary_path -Content $SummaryMarkdown

    if ($GitSizerRuntimePath -and (Test-Path $GitSizerRuntimePath)) {
        Copy-Item -Path $GitSizerRuntimePath -Destination $HistoryPaths.run_git_sizer_path -Force
    }
}

function Get-RepoHealthSummaryMarkdown {
    param([Parameter(Mandatory = $true)]$Metrics)

    $largestBlobPath = if ($Metrics.history.max_blob_path) { $Metrics.history.max_blob_path } else { "(none)" }
    $largestCurrentFilePath = if (@($Metrics.repo.top_current_files).Count -gt 0) { $Metrics.repo.top_current_files[0].path } else { "(none)" }
    $largestCurrentFileMb = if (@($Metrics.repo.top_current_files).Count -gt 0) { $Metrics.repo.top_current_files[0].size_mb } else { 0 }
    $commitText = [string]$Metrics.commit
    $shortCommit = if ($commitText.Length -gt 7) { $commitText.Substring(0, 7) } else { $commitText }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("## Repository Health Check")
    $lines.Add("")
    $lines.Add("| Metric | Value |")
    $lines.Add("| --- | --- |")
    $lines.Add("| Status | $($Metrics.policy.status) |")
    $lines.Add("| Repository | $($Metrics.repository) |")
    $lines.Add("| Branch | $($Metrics.branch) |")
    $lines.Add(("| Commit | `{0}` |" -f $shortCommit))
    $lines.Add("| Size pack | $($Metrics.git_core.size_pack_mb) MB |")
    $lines.Add("| Object count | $($Metrics.git_core.object_count) |")
    $lines.Add("| Packed object count | $($Metrics.git_core.packed_object_count) |")
    $lines.Add("| Pack count | $($Metrics.git_core.pack_count) |")
    $lines.Add("| .git size | $($Metrics.repo.git_size_mb) MB |")
    $lines.Add("| Tracked file count | $($Metrics.repo.tracked_file_count) |")
    $lines.Add("| Commit count | $($Metrics.repo.commit_count) |")
    $lines.Add(("| Largest blob | {0} MB (`{1}`) |" -f $Metrics.history.max_blob_mb, $largestBlobPath))
    $lines.Add("| Blob > 1 MB | $($Metrics.history.blob_over_1mb) |")
    $lines.Add("| Blob > 5 MB | $($Metrics.history.blob_over_5mb) |")
    $lines.Add(("| Largest current file | {0} MB (`{1}`) |" -f $largestCurrentFileMb, $largestCurrentFilePath))
    $lines.Add("| Forbidden files | $(@($Metrics.repo.forbidden_files).Count) |")
    $lines.Add("")

    if ($Metrics.growth.hasBaseline) {
        $lines.Add("### Growth vs Previous Baseline")
        $lines.Add("")
        $lines.Add("| Metric | Growth |")
        $lines.Add("| --- | --- |")
        $lines.Add("| size-pack | $($Metrics.growth.size_pack_growth_pct)% |")
        $lines.Add("| .git size | $($Metrics.growth.git_size_growth_pct)% |")
        $lines.Add("")
    }

    if ($Metrics.file_growth.hasBaseline) {
        $baselineCommit = if ($Metrics.file_growth.baseline_commit) {
            $baselineCommitText = [string]$Metrics.file_growth.baseline_commit
            if ($baselineCommitText.Length -gt 7) { $baselineCommitText.Substring(0, 7) } else { $baselineCommitText }
        }
        else {
            "-"
        }

        $lines.Add("### Current Top File Growth vs Previous Baseline")
        $lines.Add("")
        $lines.Add(("Baseline: `{0}` at {1}" -f $baselineCommit, $Metrics.file_growth.baseline_timestamp))
        $lines.Add("")
        $lines.Add("| Path | Change | Current | Previous | Delta |")
        $lines.Add("| --- | --- | --- | --- | --- |")

        $changedRows = @(
            @($Metrics.file_growth.changes) |
                Sort-Object @{ Expression = { if ($null -ne $_.delta_mb) { [Math]::Abs([double]$_.delta_mb) } else { [double]$_.current_size_mb } } } -Descending |
                Select-Object -First 5
        )

        foreach ($change in $changedRows) {
            $currentSize = ("{0} MB" -f ([string]$change.current_size_mb).Replace(".", ","))
            $previousSize = if ($null -ne $change.previous_size_mb) { ("{0} MB" -f ([string]$change.previous_size_mb).Replace(".", ",")) } else { "-" }
            $deltaText = if ($null -ne $change.delta_mb) {
                $deltaPrefix = if ([double]$change.delta_mb -gt 0) { "+" } elseif ([double]$change.delta_mb -lt 0) { "" } else { "" }
                "{0}{1} MB" -f $deltaPrefix, ([string]$change.delta_mb).Replace(".", ",")
            }
            else {
                "new in top N"
            }
            $lines.Add(("| `{0}` | {1} | {2} | {3} | {4} |" -f $change.path, $change.change_type, $currentSize, $previousSize, $deltaText))
        }

        $lines.Add("")
    }

    if (@($Metrics.policy.fail_reasons).Count -gt 0) {
        $lines.Add("### Blocking Findings")
        $lines.Add("")
        foreach ($reason in @($Metrics.policy.fail_reasons)) {
            $lines.Add("- $reason")
        }
        $lines.Add("")
    }

    if (@($Metrics.policy.warning_reasons).Count -gt 0) {
        $lines.Add("### Warnings")
        $lines.Add("")
        foreach ($reason in @($Metrics.policy.warning_reasons)) {
            $lines.Add("- $reason")
        }
        $lines.Add("")
    }

    return ($lines -join [Environment]::NewLine)
}

function Write-RepoHealthSummaryFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path $Path -Parent
    Ensure-RepoHealthDirectory -Path $parent
    Set-Content -Path $Path -Value $Content -Encoding utf8
}

function Invoke-RepoHealthGitSizer {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $command = Get-Command git-sizer -ErrorAction SilentlyContinue
    if (-not $command) {
        Write-RepoHealthSummaryFile -Path $OutputPath -Content "git-sizer not available on this runner."
        return [PSCustomObject]@{
            available   = $false
            output_path = $OutputPath
        }
    }

    Push-Location $RepoRoot
    try {
        $lines = @(& git-sizer --verbose 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($exitCode -ne 0) {
        Write-RepoHealthSummaryFile -Path $OutputPath -Content ($lines -join [Environment]::NewLine)
        throw "git-sizer execution failed."
    }

    Write-RepoHealthSummaryFile -Path $OutputPath -Content ($lines -join [Environment]::NewLine)
    return [PSCustomObject]@{
        available   = $true
        output_path = $OutputPath
    }
}
