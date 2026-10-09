# =============================================================================
# LeadTimeChart.ps1
#   クローズまでの時間（作成 → 完了）を 3 区分に分け、週ごとの件数を集計して
#   折れ線グラフ（SVG を埋め込んだ HTML）を作る。
#   仕様: docs\superpowers\specs\2026-10-09-leadtime-weekly-chart-design.md
#   詳細設計: docs\05_詳細設計.md「LeadTimeChart.ps1」
# =============================================================================

# 区分の定義（固定）。順序がそのまま CSV の列順・グラフの線の順になる。
#   Marker: グラフの点の形（白黒印刷でも区別できるように色と形の両方を変える）
$script:LeadTimeBuckets = @(
    [pscustomobject]@{ Id = 'Under24h';    Label = '24時間未満';     Color = '#2e7d32'; Marker = 'circle' }
    [pscustomobject]@{ Id = 'From24To72h'; Label = '24〜72時間未満'; Color = '#ef6c00'; Marker = 'square' }
    [pscustomobject]@{ Id = 'Over72h';     Label = '72時間以上';     Color = '#c62828'; Marker = 'triangle' }
)

function Get-LeadTimeBucket {
    <#
    .SYNOPSIS
        クローズまでの時間（時間）を区分 ID に変換する。境界ちょうど（24 / 72）は上側の区分に入る。
    #>
    param([Parameter(Mandatory)][double]$Hours)
    if ($Hours -lt 24) { return 'Under24h' }
    if ($Hours -lt 72) { return 'From24To72h' }
    return 'Over72h'
}

function Get-LeadTimeWeeklySummary {
    <#
    .SYNOPSIS
        マージ済み PR を完了週 × クローズまでの時間の区分で数える。
    .DESCRIPTION
        ・対象は Status='completed' かつ完了日時(ClosedAt)とリードタイムがある明細だけ
        ・週は ClosedAt（設定タイムゾーン）が属する週。週の始まりは WeekStartDay
        ・範囲内のすべての週を出力する（0 件の週も行を出す）
        ・範囲の端で切れた週は Days < 7、IsPartial = $true
        列の定義: docs\06_出力仕様.md「summary_leadtime_weekly.csv」
    #>
    [CmdletBinding()]
    param(
        [object[]]$Records = @(),
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Range
    )

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $weekStarts = @(Get-PeriodStarts -Range $Range -Unit 'Week' -WeekStartDay $Config.WeekStartDay)
    $rangeLastDay = $Range.ToLocalExclusive.AddDays(-1)
    $targets = @($Records | Where-Object {
            $null -ne $_ -and $_.Status -eq 'completed' -and $null -ne $_.LeadTimeHours -and $_.ClosedAt
        })

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($group in (Get-RecordGroups -Records $targets -Repositories $Config.Repositories)) {
        # 週の開始日(yyyy-MM-dd) → 区分ごとの件数
        $counts = @{}
        foreach ($record in $group.Records) {
            $closedLocal = [datetime]::ParseExact([string]$record.ClosedAt, 'yyyy-MM-dd HH:mm', $culture)
            $key = (Get-PeriodStart -LocalDate $closedLocal -Unit 'Week' -WeekStartDay $Config.WeekStartDay).ToString('yyyy-MM-dd', $culture)
            if (-not $counts.ContainsKey($key)) { $counts[$key] = @{ Under24h = 0; From24To72h = 0; Over72h = 0 } }
            $bucket = Get-LeadTimeBucket -Hours ([double]$record.LeadTimeHours)
            $counts[$key][$bucket] = $counts[$key][$bucket] + 1
        }

        foreach ($start in $weekStarts) {
            $firstDay = $start
            if ($Range.FromLocal -gt $firstDay) { $firstDay = $Range.FromLocal }
            $lastDay = $start.AddDays(6)
            if ($lastDay -gt $rangeLastDay) { $lastDay = $rangeLastDay }
            $days = [int]($lastDay - $firstDay).TotalDays + 1

            $key = $start.ToString('yyyy-MM-dd', $culture)
            $count = @{ Under24h = 0; From24To72h = 0; Over72h = 0 }
            if ($counts.ContainsKey($key)) { $count = $counts[$key] }

            $rows.Add([pscustomobject][ordered]@{
                    Repository  = $group.Name
                    WeekStart   = $key
                    WeekEnd     = $lastDay.ToString('yyyy-MM-dd', $culture)
                    Days        = $days
                    IsPartial   = ($days -lt 7)
                    Under24h    = [int]$count.Under24h
                    From24To72h = [int]$count.From24To72h
                    Over72h     = [int]$count.Over72h
                    Total       = [int]($count.Under24h + $count.From24To72h + $count.Over72h)
                })
        }
    }
    return $rows.ToArray()
}
