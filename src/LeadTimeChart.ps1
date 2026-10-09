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

function Format-SvgNumber {
    <# SVG の座標を、地域設定に左右されない形式（小数点は .）で文字列にする。 #>
    param([double]$Value)
    return $Value.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
}

function New-LeadTimeMarkerSvg {
    <# 点の形（circle / square / triangle）を SVG 要素の文字列で返す。 #>
    param([string]$Marker, [double]$X, [double]$Y, [string]$Fill, [string]$Stroke)
    $style = 'fill="{0}" stroke="{1}" stroke-width="2"' -f $Fill, $Stroke
    switch ($Marker) {
        'square' { return '<rect x="{0}" y="{1}" width="8" height="8" {2}/>' -f (Format-SvgNumber ($X - 4)), (Format-SvgNumber ($Y - 4)), $style }
        'triangle' {
            $points = '{0},{1} {2},{3} {4},{3}' -f (Format-SvgNumber $X), (Format-SvgNumber ($Y - 5)), (Format-SvgNumber ($X - 5)), (Format-SvgNumber ($Y + 4)), (Format-SvgNumber ($X + 5))
            return '<polygon points="{0}" {1}/>' -f $points, $style
        }
        default { return '<circle cx="{0}" cy="{1}" r="4" {2}/>' -f (Format-SvgNumber $X), (Format-SvgNumber $Y), $style }
    }
}

function New-LeadTimeChartSvg {
    <#
    .SYNOPSIS
        週次集計の行（1 グループ分）から、区分ごとの件数の折れ線グラフを SVG 文字列で作る。
    .DESCRIPTION
        ・横軸: 週の開始日(MM/dd)。最大 12 個になるようラベルを間引く。端の週は「*」を付ける
        ・縦軸: 件数（0 始まり、整数の目盛り）
        ・端の週(IsPartial)の点は白抜き。各点に <title> を付け、マウスを重ねると値が出る
        行が 0 件なら空文字を返す。
    #>
    [CmdletBinding()]
    param(
        [object[]]$Rows = @(),
        [int]$Width = 900,
        [int]$Height = 360
    )

    $items = @($Rows | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { return '' }

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $left = 50; $right = 20; $top = 20; $bottom = 50
    $plotWidth = $Width - $left - $right
    $plotHeight = $Height - $top - $bottom
    $count = $items.Count

    # 縦軸の上限: 目盛り 5 本前後になる整数の刻み
    $maxValue = 0
    foreach ($item in $items) {
        foreach ($bucket in $script:LeadTimeBuckets) {
            if ([int]$item.($bucket.Id) -gt $maxValue) { $maxValue = [int]$item.($bucket.Id) }
        }
    }
    $step = [int][math]::Max(1, [math]::Ceiling($maxValue / 5))
    $yMax = $step * [int][math]::Max(1, [math]::Ceiling($maxValue / $step))

    $xs = New-Object 'double[]' $count
    for ($i = 0; $i -lt $count; $i++) {
        if ($count -eq 1) { $xs[$i] = $left + $plotWidth / 2 }
        else { $xs[$i] = $left + $plotWidth * $i / ($count - 1) }
    }
    $toY = { param([double]$v) $top + $plotHeight - $plotHeight * $v / $yMax }
    $labels = @($items | ForEach-Object { [datetime]::ParseExact([string]$_.WeekStart, 'yyyy-MM-dd', $culture).ToString('MM/dd', $culture) })

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {0} {1}" width="100%" role="img" aria-label="クローズまでの時間別 PR 件数の週次推移" font-family="sans-serif">' -f $Width, $Height))

    # 目盛り線と縦軸ラベル
    for ($v = 0; $v -le $yMax; $v += $step) {
        $y = Format-SvgNumber (& $toY $v)
        [void]$sb.Append(('<line class="grid" x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#e0e0e0"/>' -f $left, $y, ($Width - $right)))
        [void]$sb.Append(('<text class="y-label" x="{0}" y="{1}" text-anchor="end" font-size="12" fill="#616161">{2}</text>' -f ($left - 8), (Format-SvgNumber ((& $toY $v) + 4)), $v))
    }
    [void]$sb.Append(('<line x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#9e9e9e"/>' -f $left, (Format-SvgNumber (& $toY 0)), ($Width - $right)))

    # 横軸ラベル（間引き）
    $labelEvery = [int][math]::Max(1, [math]::Ceiling($count / 12))
    for ($i = 0; $i -lt $count; $i++) {
        if ($i % $labelEvery -ne 0) { continue }
        $text = $labels[$i]
        if ([bool]$items[$i].IsPartial) { $text = $text + '*' }
        [void]$sb.Append(('<text class="x-label" x="{0}" y="{1}" text-anchor="middle" font-size="12" fill="#616161">{2}</text>' -f (Format-SvgNumber $xs[$i]), ($Height - $bottom + 20), $text))
    }

    # 折れ線
    foreach ($bucket in $script:LeadTimeBuckets) {
        $points = for ($i = 0; $i -lt $count; $i++) { '{0},{1}' -f (Format-SvgNumber $xs[$i]), (Format-SvgNumber (& $toY ([int]$items[$i].($bucket.Id)))) }
        [void]$sb.Append(('<polyline class="series series-{0}" fill="none" stroke="{1}" stroke-width="2" points="{2}"/>' -f $bucket.Id, $bucket.Color, ($points -join ' ')))
    }

    # 点（端の週は白抜き）とツールチップ
    foreach ($bucket in $script:LeadTimeBuckets) {
        for ($i = 0; $i -lt $count; $i++) {
            $value = [int]$items[$i].($bucket.Id)
            $partial = [bool]$items[$i].IsPartial
            $class = 'point'; $fill = $bucket.Color
            if ($partial) { $class = 'point partial'; $fill = '#ffffff' }
            $title = [System.Net.WebUtility]::HtmlEncode(('{0} の週 {1}: {2}件' -f $labels[$i], $bucket.Label, $value))
            $shape = New-LeadTimeMarkerSvg -Marker $bucket.Marker -X $xs[$i] -Y (& $toY $value) -Fill $fill -Stroke $bucket.Color
            [void]$sb.Append(('<g class="{0}"><title>{1}</title>{2}</g>' -f $class, $title, $shape))
        }
    }

    [void]$sb.Append('</svg>')
    return $sb.ToString()
}
