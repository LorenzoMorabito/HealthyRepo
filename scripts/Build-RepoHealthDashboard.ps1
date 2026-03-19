[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MetricsPath,
    [string]$HistoryCsvPath,
    [string]$TopFilesHistoryCsvPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [int]$RecentRuns = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Convert-RepoHealthValueToDouble {
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return 0.0
    }

    return [double]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-RepoHealthShortCommit {
    param([string]$Commit)

    if ([string]::IsNullOrWhiteSpace($Commit)) {
        return "-"
    }

    if ($Commit.Length -le 7) {
        return $Commit
    }

    return $Commit.Substring(0, 7)
}

function Get-RepoHealthStatusClass {
    param([string]$Status)

    switch ($Status) {
        "FAIL" { return "status-fail" }
        "WARN" { return "status-warn" }
        default { return "status-ok" }
    }
}

function New-RepoHealthSparklineSvg {
    param(
        [double[]]$Values,
        [string]$StrokeColor,
        [string]$FillColor
    )

    if (-not $Values -or $Values.Count -eq 0) {
        return '<svg viewBox="0 0 220 56" class="sparkline" aria-hidden="true"></svg>'
    }

    $width = 220.0
    $height = 56.0
    $padding = 6.0
    $minValue = ($Values | Measure-Object -Minimum).Minimum
    $maxValue = ($Values | Measure-Object -Maximum).Maximum
    $range = $maxValue - $minValue
    if ($range -eq 0) {
        $range = if ($maxValue -eq 0) { 1.0 } else { [Math]::Abs($maxValue) * 0.15 }
        if ($range -eq 0) {
            $range = 1.0
        }
        $minValue -= ($range / 2.0)
        $maxValue += ($range / 2.0)
    }

    $stepX = if ($Values.Count -gt 1) { ($width - ($padding * 2)) / ($Values.Count - 1) } else { 0 }
    $points = New-Object System.Collections.Generic.List[string]

    for ($index = 0; $index -lt $Values.Count; $index++) {
        $x = $padding + ($index * $stepX)
        $normalized = (($Values[$index] - $minValue) / ($maxValue - $minValue))
        $y = $height - $padding - ($normalized * ($height - ($padding * 2)))
        $points.Add(("{0},{1}" -f ([Math]::Round($x, 2).ToString([System.Globalization.CultureInfo]::InvariantCulture)), ([Math]::Round($y, 2).ToString([System.Globalization.CultureInfo]::InvariantCulture))))
    }

    $polyline = $points -join " "
    $areaPoints = @("6,50") + $points + @("214,50")
    $polygon = $areaPoints -join " "
    $lastPoint = $points[$points.Count - 1]

    return @"
<svg viewBox="0 0 220 56" class="sparkline" aria-hidden="true" preserveAspectRatio="none">
  <defs>
    <linearGradient id="spark-fill" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="$FillColor" stop-opacity="0.38" />
      <stop offset="100%" stop-color="$FillColor" stop-opacity="0.02" />
    </linearGradient>
  </defs>
  <line x1="6" y1="50" x2="214" y2="50" stroke="#d7ddd8" stroke-width="1" />
  <polygon points="$polygon" fill="url(#spark-fill)" />
  <polyline points="$polyline" fill="none" stroke="$StrokeColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" />
  <circle cx="$(($lastPoint -split ',')[0])" cy="$(($lastPoint -split ',')[1])" r="3.4" fill="$StrokeColor" />
</svg>
"@
}

function Get-RepoHealthStatusTimeline {
    param([object[]]$Rows)

    if (-not $Rows -or $Rows.Count -eq 0) {
        return '<div class="timeline-empty">No historical runs yet.</div>'
    }

    $segments = foreach ($row in $Rows) {
        $status = [string]$row.status
        $class = Get-RepoHealthStatusClass -Status $status
        $timestamp = [System.Net.WebUtility]::HtmlEncode([string]$row.timestamp)
        $commit = [System.Net.WebUtility]::HtmlEncode((Get-RepoHealthShortCommit -Commit ([string]$row.commit_sha)))
        "<div class=`"timeline-segment $class`" title=`"$timestamp | $commit | $status`"></div>"
    }

    return "<div class=`"status-timeline`">$($segments -join [Environment]::NewLine)</div>"
}

function New-RepoHealthMetricCardHtml {
    param(
        [string]$Title,
        [string]$Value,
        [string]$Caption,
        [double[]]$TrendValues,
        [string]$StrokeColor,
        [string]$FillColor
    )

    $titleEncoded = [System.Net.WebUtility]::HtmlEncode($Title)
    $valueEncoded = [System.Net.WebUtility]::HtmlEncode($Value)
    $captionEncoded = [System.Net.WebUtility]::HtmlEncode($Caption)
    $sparkline = New-RepoHealthSparklineSvg -Values $TrendValues -StrokeColor $StrokeColor -FillColor $FillColor

    return @"
<section class="metric-card">
  <div class="metric-copy">
    <div class="metric-title">$titleEncoded</div>
    <div class="metric-value">$valueEncoded</div>
    <div class="metric-caption">$captionEncoded</div>
  </div>
  $sparkline
</section>
"@
}

function Convert-RepoHealthListToHtml {
    param(
        [object[]]$Items,
        [string]$EmptyMessage
    )

    if (-not $Items -or $Items.Count -eq 0) {
        return "<li>$([System.Net.WebUtility]::HtmlEncode($EmptyMessage))</li>"
    }

    $rows = foreach ($item in $Items) {
        "<li>$([System.Net.WebUtility]::HtmlEncode([string]$item))</li>"
    }

    return ($rows -join [Environment]::NewLine)
}

function Convert-RepoHealthTopFilesToRows {
    param([object[]]$Rows)

    if (-not $Rows -or $Rows.Count -eq 0) {
        return '<tr><td colspan="2">No data available.</td></tr>'
    }

    $htmlRows = foreach ($row in $Rows | Select-Object -First 8) {
        $path = [System.Net.WebUtility]::HtmlEncode([string]$row.path)
        $size = "{0} MB" -f ([string]$row.size_mb).Replace(".", ",")
        "<tr><td class=`"path-cell`">$path</td><td>$size</td></tr>"
    }

    return ($htmlRows -join [Environment]::NewLine)
}

function Convert-RepoHealthHistoryRowsToHtml {
    param([object[]]$Rows)

    if (-not $Rows -or $Rows.Count -eq 0) {
        return '<tr><td colspan="6">No historical runs available.</td></tr>'
    }

    $htmlRows = foreach ($row in $Rows) {
        $status = [string]$row.status
        $statusClass = Get-RepoHealthStatusClass -Status $status
        $timestamp = [System.Net.WebUtility]::HtmlEncode([string]$row.timestamp)
        $commit = [System.Net.WebUtility]::HtmlEncode((Get-RepoHealthShortCommit -Commit ([string]$row.commit_sha)))
        $sizePack = ("{0} MB" -f [string]$row.size_pack_mb).Replace(".", ",")
        $gitSize = ("{0} MB" -f [string]$row.git_size_mb).Replace(".", ",")
        $maxBlob = ("{0} MB" -f [string]$row.max_blob_mb).Replace(".", ",")
        "<tr><td>$timestamp</td><td><code>$commit</code></td><td><span class=`"status-pill $statusClass`">$status</span></td><td>$sizePack</td><td>$gitSize</td><td>$maxBlob</td></tr>"
    }

    return ($htmlRows -join [Environment]::NewLine)
}

function Convert-RepoHealthFileGrowthRowsToHtml {
    param([object[]]$Rows)

    if (-not $Rows -or $Rows.Count -eq 0) {
        return '<tr><td colspan="6">No file growth baseline available yet.</td></tr>'
    }

    $htmlRows = foreach ($row in $Rows | Select-Object -First 8) {
        $path = [System.Net.WebUtility]::HtmlEncode([string]$row.path)
        $changeType = [System.Net.WebUtility]::HtmlEncode([string]$row.change_type)
        $currentSize = ("{0} MB" -f ([string]$row.current_size_mb)).Replace(".", ",")
        $previousSize = if ($null -ne $row.previous_size_mb -and -not [string]::IsNullOrWhiteSpace([string]$row.previous_size_mb)) {
            ("{0} MB" -f ([string]$row.previous_size_mb)).Replace(".", ",")
        }
        else {
            "-"
        }
        $deltaText = if ($null -ne $row.delta_mb -and -not [string]::IsNullOrWhiteSpace([string]$row.delta_mb)) {
            $delta = [double]$row.delta_mb
            $prefix = if ($delta -gt 0) { "+" } elseif ($delta -lt 0) { "" } else { "" }
            "{0}{1} MB" -f $prefix, ([string]$row.delta_mb).Replace(".", ",")
        }
        else {
            "new in top N"
        }
        $deltaPctText = if ($null -ne $row.delta_pct -and -not [string]::IsNullOrWhiteSpace([string]$row.delta_pct)) {
            $deltaPct = [double]$row.delta_pct
            $prefix = if ($deltaPct -gt 0) { "+" } elseif ($deltaPct -lt 0) { "" } else { "" }
            "{0}{1}%" -f $prefix, ([string]$row.delta_pct).Replace(".", ",")
        }
        else {
            "-"
        }
        "<tr><td class=`"path-cell`">$path</td><td>$changeType</td><td>$currentSize</td><td>$previousSize</td><td>$deltaText</td><td>$deltaPctText</td></tr>"
    }

    return ($htmlRows -join [Environment]::NewLine)
}

function Get-RepoHealthObservedFileTrends {
    param([object[]]$Rows)

    if (-not $Rows -or $Rows.Count -eq 0) {
        return @()
    }

    $trends = foreach ($group in ($Rows | Group-Object path)) {
        $ordered = @($group.Group | Sort-Object timestamp)
        $first = $ordered[0]
        $last = $ordered[$ordered.Count - 1]
        $firstSizeMb = Convert-RepoHealthValueToDouble $first.size_mb
        $lastSizeMb = Convert-RepoHealthValueToDouble $last.size_mb
        [PSCustomObject]@{
            path          = [string]$group.Name
            first_size_mb = [Math]::Round($firstSizeMb, 2)
            latest_size_mb = [Math]::Round($lastSizeMb, 2)
            delta_mb      = [Math]::Round(($lastSizeMb - $firstSizeMb), 2)
            observations  = @($ordered).Count
            first_seen    = [string]$first.timestamp
            latest_seen   = [string]$last.timestamp
        }
    }

    return @(
        $trends |
            Sort-Object @{ Expression = { [Math]::Abs([double]$_.delta_mb) } } -Descending |
            Select-Object -First 8
    )
}

function Convert-RepoHealthObservedTrendsToHtml {
    param([object[]]$Rows)

    if (-not $Rows -or $Rows.Count -eq 0) {
        return '<tr><td colspan="5">No observed per-file trend data yet.</td></tr>'
    }

    $htmlRows = foreach ($row in $Rows) {
        $path = [System.Net.WebUtility]::HtmlEncode([string]$row.path)
        $firstSize = ("{0} MB" -f ([string]$row.first_size_mb)).Replace(".", ",")
        $latestSize = ("{0} MB" -f ([string]$row.latest_size_mb)).Replace(".", ",")
        $delta = [double]$row.delta_mb
        $deltaPrefix = if ($delta -gt 0) { "+" } elseif ($delta -lt 0) { "" } else { "" }
        $deltaText = "{0}{1} MB" -f $deltaPrefix, ([string]$row.delta_mb).Replace(".", ",")
        "<tr><td class=`"path-cell`">$path</td><td>$firstSize</td><td>$latestSize</td><td>$deltaText</td><td>$($row.observations)</td></tr>"
    }

    return ($htmlRows -join [Environment]::NewLine)
}

if (-not (Test-Path $MetricsPath)) {
    throw "Metrics file not found: $MetricsPath"
}

$metrics = Get-Content -Path $MetricsPath -Raw | ConvertFrom-Json -Depth 100
$historyRows = @()
if ($HistoryCsvPath -and (Test-Path $HistoryCsvPath)) {
    $historyRows = @(Import-Csv -Path $HistoryCsvPath | Sort-Object timestamp)
}
$topFilesHistoryRows = @()
if ($TopFilesHistoryCsvPath -and (Test-Path $TopFilesHistoryCsvPath)) {
    $topFilesHistoryRows = @(Import-Csv -Path $TopFilesHistoryCsvPath | Sort-Object timestamp, rank)
}

$recentHistory = @($historyRows | Select-Object -Last $RecentRuns)
$statusClass = Get-RepoHealthStatusClass -Status ([string]$metrics.policy.status)
$warningReasons = @($metrics.policy.warning_reasons)
$failReasons = @($metrics.policy.fail_reasons)
$topCurrentFiles = @($metrics.repo.top_current_files)
$fileGrowthChanges = @($metrics.file_growth.changes)
$largestBlobs = @($metrics.history.largest_blobs)
$statusTimeline = Get-RepoHealthStatusTimeline -Rows $recentHistory
$largestCurrentFilePath = if ($topCurrentFiles.Count -gt 0) { [string]$topCurrentFiles[0].path } else { "(none)" }
$largestBlobPath = if (-not [string]::IsNullOrWhiteSpace([string]$metrics.history.max_blob_path)) { [string]$metrics.history.max_blob_path } else { "(none)" }
$observedFileTrends = @(Get-RepoHealthObservedFileTrends -Rows $topFilesHistoryRows)

$sizePackTrend = @($recentHistory | ForEach-Object { Convert-RepoHealthValueToDouble $_.size_pack_mb })
$gitSizeTrend = @($recentHistory | ForEach-Object { Convert-RepoHealthValueToDouble $_.git_size_mb })
$maxBlobTrend = @($recentHistory | ForEach-Object { Convert-RepoHealthValueToDouble $_.max_blob_mb })
$largestCurrentTrend = @($recentHistory | ForEach-Object { Convert-RepoHealthValueToDouble $_.current_largest_file_mb })
$trackedFileTrend = @()
$commitCountTrend = @($recentHistory | ForEach-Object { Convert-RepoHealthValueToDouble $_.commit_count })

$insightItems = New-Object System.Collections.Generic.List[string]
$insightItems.Add(("Current status is {0} on branch {1}." -f $metrics.policy.status, $metrics.branch))
$insightItems.Add(("Largest blob is {0} MB in {1}." -f ([string]$metrics.history.max_blob_mb).Replace(".", ","), $largestBlobPath))
$insightItems.Add(("Largest current file is {0} MB in {1}." -f ([string]$metrics.repo.largest_current_file_mb).Replace(".", ","), $largestCurrentFilePath))
$insightItems.Add(("Forbidden files detected: {0}." -f @($metrics.repo.forbidden_files).Count))

if ($metrics.growth.hasBaseline) {
    $insightItems.Add(("Growth vs previous baseline: size-pack {0}%, .git size {1}%." -f ([string]$metrics.growth.size_pack_growth_pct).Replace(".", ","), ([string]$metrics.growth.git_size_growth_pct).Replace(".", ",")))
}
else {
    $insightItems.Add("No previous baseline available yet.")
}

if ($metrics.file_growth.hasBaseline) {
    $largestMovement = @(
        $fileGrowthChanges |
            Sort-Object @{ Expression = { if ($null -ne $_.delta_mb -and -not [string]::IsNullOrWhiteSpace([string]$_.delta_mb)) { [Math]::Abs([double]$_.delta_mb) } else { [double]$_.current_size_mb } } } -Descending |
            Select-Object -First 1
    )
    if ($largestMovement.Count -gt 0) {
        $largestMovementItem = $largestMovement[0]
        $deltaText = if ($null -ne $largestMovementItem.delta_mb -and -not [string]::IsNullOrWhiteSpace([string]$largestMovementItem.delta_mb)) {
            $delta = [double]$largestMovementItem.delta_mb
            $prefix = if ($delta -gt 0) { "+" } elseif ($delta -lt 0) { "" } else { "" }
            "{0}{1} MB" -f $prefix, ([string]$largestMovementItem.delta_mb).Replace(".", ",")
        }
        else {
            "new in top N"
        }

        $baselineCommit = Get-RepoHealthShortCommit -Commit ([string]$metrics.file_growth.baseline_commit)
        $insightItems.Add(("Largest file movement vs baseline {0}: {1} ({2})." -f $baselineCommit, [string]$largestMovementItem.path, $deltaText))
    }
}

$warningListHtml = Convert-RepoHealthListToHtml -Items $warningReasons -EmptyMessage "No warning reasons."
$failListHtml = Convert-RepoHealthListToHtml -Items $failReasons -EmptyMessage "No blocking findings."
$insightListHtml = Convert-RepoHealthListToHtml -Items $insightItems -EmptyMessage "No insights available."
$topCurrentRowsHtml = Convert-RepoHealthTopFilesToRows -Rows $topCurrentFiles
$fileGrowthRowsHtml = Convert-RepoHealthFileGrowthRowsToHtml -Rows @(
    $fileGrowthChanges |
        Sort-Object @{ Expression = { if ($null -ne $_.delta_mb -and -not [string]::IsNullOrWhiteSpace([string]$_.delta_mb)) { [Math]::Abs([double]$_.delta_mb) } else { [double]$_.current_size_mb } } } -Descending
)
$observedTrendsRowsHtml = Convert-RepoHealthObservedTrendsToHtml -Rows $observedFileTrends
$largestBlobRowsHtml = Convert-RepoHealthTopFilesToRows -Rows $largestBlobs
$historyRowsHtml = Convert-RepoHealthHistoryRowsToHtml -Rows (@($recentHistory | Sort-Object timestamp -Descending))
$fileGrowthSubtitle = if ($metrics.file_growth.hasBaseline) {
    "Compared with baseline commit {0} at {1}." -f ([System.Net.WebUtility]::HtmlEncode((Get-RepoHealthShortCommit -Commit ([string]$metrics.file_growth.baseline_commit)))), ([System.Net.WebUtility]::HtmlEncode([string]$metrics.file_growth.baseline_timestamp))
}
else {
    "No baseline available yet. Run the analyzer again after a future change to start tracking deltas."
}

$metricCards = @(
    (New-RepoHealthMetricCardHtml -Title "Size Pack" -Value ("{0} MB" -f ([string]$metrics.git_core.size_pack_mb).Replace(".", ",")) -Caption "Git pack size" -TrendValues $sizePackTrend -StrokeColor "#116466" -FillColor "#6cc3bf"),
    (New-RepoHealthMetricCardHtml -Title ".git Size" -Value ("{0} MB" -f ([string]$metrics.repo.git_size_mb).Replace(".", ",")) -Caption "Total Git directory" -TrendValues $gitSizeTrend -StrokeColor "#2e6f40" -FillColor "#84c78f"),
    (New-RepoHealthMetricCardHtml -Title "Largest Blob" -Value ("{0} MB" -f ([string]$metrics.history.max_blob_mb).Replace(".", ",")) -Caption "Historical max blob" -TrendValues $maxBlobTrend -StrokeColor "#8a5a00" -FillColor "#f0c674"),
    (New-RepoHealthMetricCardHtml -Title "Largest Current File" -Value ("{0} MB" -f ([string]$metrics.repo.largest_current_file_mb).Replace(".", ",")) -Caption "Working tree max file" -TrendValues $largestCurrentTrend -StrokeColor "#9d3d3d" -FillColor "#ef9a9a"),
    (New-RepoHealthMetricCardHtml -Title "Tracked Files" -Value ([string]$metrics.repo.tracked_file_count) -Caption "Tracked in repository" -TrendValues $trackedFileTrend -StrokeColor "#44566c" -FillColor "#a6bdd6"),
    (New-RepoHealthMetricCardHtml -Title "Commit Count" -Value ([string]$metrics.repo.commit_count) -Caption "Current branch history" -TrendValues $commitCountTrend -StrokeColor "#5f4b8b" -FillColor "#c9b6e4")
)

$title = [System.Net.WebUtility]::HtmlEncode("Repository Health Dashboard")
$repositoryName = [System.Net.WebUtility]::HtmlEncode([string]$metrics.repository)
$branchName = [System.Net.WebUtility]::HtmlEncode([string]$metrics.branch)
$commitShort = [System.Net.WebUtility]::HtmlEncode((Get-RepoHealthShortCommit -Commit ([string]$metrics.commit)))
$generatedAt = [System.Net.WebUtility]::HtmlEncode([string]$metrics.timestamp)

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>$title</title>
  <style>
    :root {
      --bg: #f3efe8;
      --panel: rgba(255,255,255,0.86);
      --ink: #21312b;
      --muted: #5f6d66;
      --line: #d8ddd7;
      --ok: #2e7d57;
      --warn: #b36a00;
      --fail: #b42318;
      --shadow: 0 18px 40px rgba(33, 49, 43, 0.08);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Segoe UI", "Segoe UI Variable", Tahoma, sans-serif;
      color: var(--ink);
      background:
        radial-gradient(circle at top right, rgba(183, 218, 198, 0.45), transparent 28%),
        radial-gradient(circle at left bottom, rgba(246, 211, 167, 0.42), transparent 24%),
        linear-gradient(180deg, #f6f2eb 0%, var(--bg) 100%);
    }
    .shell { max-width: 1360px; margin: 0 auto; padding: 28px; }
    .hero { display: grid; grid-template-columns: 1.6fr 1fr; gap: 20px; margin-bottom: 22px; }
    .hero-panel, .panel {
      background: var(--panel);
      border: 1px solid rgba(216, 221, 215, 0.9);
      border-radius: 22px;
      box-shadow: var(--shadow);
      backdrop-filter: blur(8px);
    }
    .hero-panel { padding: 26px; min-height: 180px; position: relative; overflow: hidden; }
    .hero-panel::after {
      content: "";
      position: absolute;
      inset: auto -28px -42px auto;
      width: 220px;
      height: 220px;
      border-radius: 999px;
      background: rgba(17, 100, 102, 0.07);
    }
    .eyebrow { font-size: 12px; letter-spacing: 0.18em; text-transform: uppercase; color: var(--muted); margin-bottom: 14px; }
    h1 { margin: 0 0 10px; font-size: 38px; line-height: 1.05; font-weight: 700; }
    .hero-copy { max-width: 760px; font-size: 15px; color: var(--muted); line-height: 1.6; }
    .status-strip { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 18px; }
    .status-pill {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 8px 12px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.04em;
      text-transform: uppercase;
      border: 1px solid transparent;
    }
    .status-ok { background: rgba(46, 125, 87, 0.12); color: var(--ok); border-color: rgba(46, 125, 87, 0.18); }
    .status-warn { background: rgba(179, 106, 0, 0.12); color: var(--warn); border-color: rgba(179, 106, 0, 0.2); }
    .status-fail { background: rgba(180, 35, 24, 0.12); color: var(--fail); border-color: rgba(180, 35, 24, 0.18); }
    .meta-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
    .meta-card { padding: 18px; background: rgba(255,255,255,0.82); border: 1px solid var(--line); border-radius: 16px; }
    .meta-label { font-size: 11px; text-transform: uppercase; letter-spacing: 0.16em; color: var(--muted); margin-bottom: 8px; }
    .meta-value { font-size: 18px; font-weight: 700; line-height: 1.3; }
    .grid { display: grid; gap: 20px; }
    .metrics-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); }
    .metric-card {
      background: var(--panel);
      border: 1px solid rgba(216, 221, 215, 0.9);
      border-radius: 20px;
      box-shadow: var(--shadow);
      padding: 18px;
      min-height: 186px;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      gap: 14px;
    }
    .metric-title { font-size: 12px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--muted); margin-bottom: 8px; }
    .metric-value { font-size: 31px; font-weight: 700; line-height: 1.1; margin-bottom: 6px; }
    .metric-caption { font-size: 13px; color: var(--muted); }
    .sparkline { width: 100%; height: 64px; }
    .two-col { grid-template-columns: 1.1fr 0.9fr; }
    .panel { padding: 22px; }
    .panel h2 { margin: 0 0 14px; font-size: 20px; line-height: 1.2; }
    .panel-subtitle { margin: 0 0 18px; color: var(--muted); font-size: 14px; line-height: 1.5; }
    .panel ul { margin: 0; padding-left: 18px; color: var(--ink); }
    .panel li { margin-bottom: 10px; line-height: 1.5; }
    .status-timeline { display: grid; grid-template-columns: repeat(auto-fit, minmax(18px, 1fr)); gap: 6px; margin-top: 8px; }
    .timeline-segment { height: 16px; border-radius: 999px; border: 1px solid rgba(0,0,0,0.04); }
    .timeline-empty { color: var(--muted); font-size: 13px; }
    table { width: 100%; border-collapse: collapse; font-size: 14px; }
    th, td { text-align: left; padding: 10px 0; border-bottom: 1px solid var(--line); vertical-align: top; }
    th { font-size: 12px; letter-spacing: 0.12em; text-transform: uppercase; color: var(--muted); font-weight: 700; }
    .path-cell { padding-right: 16px; word-break: break-word; }
    code { font-family: Consolas, "SFMono-Regular", monospace; font-size: 12px; background: rgba(33, 49, 43, 0.06); padding: 2px 6px; border-radius: 6px; }
    .footer-note { margin-top: 22px; color: var(--muted); font-size: 13px; }
    @media (max-width: 1080px) {
      .hero, .metrics-grid, .two-col { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <main class="shell">
    <section class="hero">
      <div class="hero-panel">
        <div class="eyebrow">Repository Health</div>
        <h1>$title</h1>
        <div class="hero-copy">
          Static dashboard generated from the current repo-health outputs. It summarizes the present state of the repository, highlights policy findings, and shows how the main repository metrics are moving over time.
        </div>
        <div class="status-strip">
          <span class="status-pill $statusClass">$($metrics.policy.status)</span>
          <span class="status-pill">branch $branchName</span>
          <span class="status-pill">commit $commitShort</span>
        </div>
      </div>
      <div class="hero-panel">
        <div class="meta-grid">
          <div class="meta-card">
            <div class="meta-label">Repository</div>
            <div class="meta-value">$repositoryName</div>
          </div>
          <div class="meta-card">
            <div class="meta-label">Generated At</div>
            <div class="meta-value">$generatedAt</div>
          </div>
          <div class="meta-card">
            <div class="meta-label">Tracked Files</div>
            <div class="meta-value">$($metrics.repo.tracked_file_count)</div>
          </div>
          <div class="meta-card">
            <div class="meta-label">Commits</div>
            <div class="meta-value">$($metrics.repo.commit_count)</div>
          </div>
        </div>
      </div>
    </section>
    <section class="grid metrics-grid">
      $($metricCards -join [Environment]::NewLine)
    </section>
    <section class="grid two-col" style="margin-top:20px;">
      <section class="panel">
        <h2>Current Insights</h2>
        <p class="panel-subtitle">Short textual takeaways derived from the current snapshot and the previous available baseline.</p>
        <ul>
          $insightListHtml
        </ul>
      </section>
      <section class="panel">
        <h2>Status Timeline</h2>
        <p class="panel-subtitle">Recent run statuses taken from the historical CSV.</p>
        $statusTimeline
      </section>
    </section>
    <section class="grid two-col" style="margin-top:20px;">
      <section class="panel">
        <h2>Warnings</h2>
        <p class="panel-subtitle">Findings that do not block the repository today but deserve monitoring.</p>
        <ul>
          $warningListHtml
        </ul>
      </section>
      <section class="panel">
        <h2>Blocking Findings</h2>
        <p class="panel-subtitle">Blocking policy findings. Empty is the healthy state.</p>
        <ul>
          $failListHtml
        </ul>
      </section>
    </section>
    <section class="grid two-col" style="margin-top:20px;">
      <section class="panel">
        <h2>Top Current Files</h2>
        <p class="panel-subtitle">Largest files in the current working tree after excluded paths are filtered out.</p>
        <table>
          <thead>
            <tr><th>Path</th><th>Size</th></tr>
          </thead>
          <tbody>
            $topCurrentRowsHtml
          </tbody>
        </table>
      </section>
      <section class="panel">
        <h2>Largest Historical Blobs</h2>
        <p class="panel-subtitle">Largest blobs seen in repository history.</p>
        <table>
          <thead>
            <tr><th>Path</th><th>Size</th></tr>
          </thead>
          <tbody>
            $largestBlobRowsHtml
          </tbody>
        </table>
      </section>
    </section>
    <section class="grid two-col" style="margin-top:20px;">
      <section class="panel">
        <h2>Current File Growth vs Previous Baseline</h2>
        <p class="panel-subtitle">$fileGrowthSubtitle</p>
        <table>
          <thead>
            <tr><th>Path</th><th>Change</th><th>Current</th><th>Previous</th><th>Delta</th><th>Delta %</th></tr>
          </thead>
          <tbody>
            $fileGrowthRowsHtml
          </tbody>
        </table>
      </section>
      <section class="panel">
        <h2>Observed File Trends</h2>
        <p class="panel-subtitle">Aggregate view of the top-file history captured over multiple runs.</p>
        <table>
          <thead>
            <tr><th>Path</th><th>First</th><th>Latest</th><th>Delta</th><th>Obs.</th></tr>
          </thead>
          <tbody>
            $observedTrendsRowsHtml
          </tbody>
        </table>
      </section>
    </section>
    <section class="panel" style="margin-top:20px;">
      <h2>Recent Historical Runs</h2>
      <p class="panel-subtitle">Most recent runs from the local or persisted repo-health history store.</p>
      <table>
        <thead>
          <tr>
            <th>Timestamp</th>
            <th>Commit</th>
            <th>Status</th>
            <th>Size Pack</th>
            <th>.git Size</th>
            <th>Largest Blob</th>
          </tr>
        </thead>
        <tbody>
          $historyRowsHtml
        </tbody>
      </table>
      <div class="footer-note">
        This HTML dashboard is static and lightweight by design. It reuses the existing repo-health outputs and does not introduce extra runtime dependencies.
      </div>
    </section>
  </main>
</body>
</html>
"@

$outputParent = Split-Path -Parent $OutputPath
if ($outputParent) {
    New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}

Set-Content -Path $OutputPath -Value $html -Encoding utf8
Write-Host ("Repo health dashboard written to {0}" -f $OutputPath)
