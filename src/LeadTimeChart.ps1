# =============================================================================
# LeadTimeChart.ps1
#   クローズまでの時間（作成 → 完了）を 3 区分に分け、週ごと・日ごとの件数を
#   全体と 大・中・小 のサイズ別に集計して、折れ線グラフ（SVG を埋め込んだ HTML）を作る。
#   仕様: docs\superpowers\specs\2026-10-09-leadtime-weekly-chart-design.md
#         docs\superpowers\specs\2026-10-29-leadtime-daily-and-size-charts-design.md
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

# 大・中・小（既存の SizeCategory をまとめた区分）。順序が HTML の並び順（大 → 中 → 小）になる。
#   Categories: 対応する SizeCategory の名前（settings.psd1 の SizeCategories の Name）
#   どれにも当たらない SizeCategory（空・独自の名前）は「サイズ不明」として扱う（docs\adr\ADR-0001）
$script:LeadTimeSizeGroups = @(
    [pscustomobject]@{ Id = 'Large';  Label = '大'; Categories = @('L', 'XL') }
    [pscustomobject]@{ Id = 'Medium'; Label = '中'; Categories = @('M') }
    [pscustomobject]@{ Id = 'Small';  Label = '小'; Categories = @('XS', 'S') }
)

function Get-LeadTimeSizeGroup {
    <#
    .SYNOPSIS
        SizeCategory（XS〜XL）を大中小の区分 ID（Large / Medium / Small）に変換する。
        どれにも当たらなければ空文字（サイズ不明）を返す。
    #>
    param([string]$SizeCategory)
    foreach ($group in $script:LeadTimeSizeGroups) {
        if ($SizeCategory -and $group.Categories -contains $SizeCategory) { return $group.Id }
    }
    return ''
}

function Get-LeadTimeSizeGroupRangeText {
    <#
    .SYNOPSIS
        大中小の見出しに出す範囲の文字列を作る（例: 'L・XL：251行〜'）。
    .DESCRIPTION
        設定の SizeCategories の閾値から作るので、閾値を変えると表示も変わる。
        SizeMethod が 'Api' のときはファイル数（MaxFiles）、それ以外は行数（MaxLines）で表示する。
        下限 = 区分の直前（小さい側）の区分の上限 + 1、上限 = 区分の最後の上限（$null は上限なし）。
    #>
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $group = $script:LeadTimeSizeGroups | Where-Object { $_.Id -eq $GroupId } | Select-Object -First 1
    if ($null -eq $group) { throw "未知の大中小の区分です: $GroupId" }

    $names = $group.Categories -join '・'
    $limitKey = 'MaxLines'; $unit = '行'
    if ([string]$Config.SizeMethod -eq 'Api') { $limitKey = 'MaxFiles'; $unit = 'ファイル' }

    $categories = @($Config.SizeCategories)
    $indexes = @(for ($i = 0; $i -lt $categories.Count; $i++) {
            if ($group.Categories -contains [string]$categories[$i].Name) { $i }
        })
    if ($indexes.Count -eq 0) { return $names }

    $lower = $null
    if ($indexes[0] -gt 0 -and $null -ne $categories[$indexes[0] - 1][$limitKey]) {
        $lower = [int]$categories[$indexes[0] - 1][$limitKey] + 1
    }
    $upper = $categories[$indexes[-1]][$limitKey]

    if ($null -eq $lower -and $null -eq $upper) { return $names }
    if ($null -eq $lower) { return ('{0}：〜{1}{2}' -f $names, $upper, $unit) }
    if ($null -eq $upper) { return ('{0}：{1}{2}〜' -f $names, $lower, $unit) }
    return ('{0}：{1}〜{2}{3}' -f $names, $lower, $upper, $unit)
}

# 集計する区分（全体 + 大中小）。順序が CSV の行の並びになる。
$script:LeadTimeSummaryGroupIds = @('All', 'Large', 'Medium', 'Small')

function Get-LeadTimeTargetRecords {
    <# 集計対象（マージ済みで、完了日時とリードタイムがある明細）だけを返す。 #>
    param([object[]]$Records = @())
    @($Records | Where-Object {
            $null -ne $_ -and $_.Status -eq 'completed' -and $null -ne $_.LeadTimeHours -and $_.ClosedAt
        })
}

function Get-LeadTimeSizeGroupRecords {
    <# 区分 ID（All / Large / Medium / Small）に当たる明細だけを返す。All は全件（サイズ不明を含む）。 #>
    param(
        [object[]]$Records = @(),
        [Parameter(Mandatory)][string]$GroupId
    )
    if ($GroupId -eq 'All') { return @($Records) }
    @($Records | Where-Object { (Get-LeadTimeSizeGroup -SizeCategory ([string]$_.SizeCategory)) -eq $GroupId })
}

function Get-LeadTimeCountsByPeriod {
    <#
    .SYNOPSIS
        明細を「期間の開始日(yyyy-MM-dd) → 区分ごとの件数」のハッシュテーブルにする。
        期間は ClosedAt（設定タイムゾーン）が属する週（Unit=Week）または日（Unit=Day）。
    #>
    param(
        [object[]]$Records = @(),
        [Parameter(Mandatory)][ValidateSet('Week', 'Day')][string]$Unit,
        [string]$WeekStartDay = 'Monday'
    )
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $counts = @{}
    foreach ($record in @($Records | Where-Object { $null -ne $_ })) {
        $closedLocal = [datetime]::ParseExact([string]$record.ClosedAt, 'yyyy-MM-dd HH:mm', $culture)
        $key = (Get-PeriodStart -LocalDate $closedLocal -Unit $Unit -WeekStartDay $WeekStartDay).ToString('yyyy-MM-dd', $culture)
        if (-not $counts.ContainsKey($key)) { $counts[$key] = @{ Under24h = 0; From24To72h = 0; Over72h = 0 } }
        $bucket = Get-LeadTimeBucket -Hours ([double]$record.LeadTimeHours)
        $counts[$key][$bucket] = $counts[$key][$bucket] + 1
    }
    return $counts
}

function Get-LeadTimeCountOrZero {
    <# 期間キーの件数を返す。その期間に PR が無ければ 0 件を返す。 #>
    param(
        [hashtable]$Counts = @{},
        [Parameter(Mandatory)][string]$Key
    )
    if ($Counts.ContainsKey($Key)) { return $Counts[$Key] }
    return @{ Under24h = 0; From24To72h = 0; Over72h = 0 }
}

function Get-LeadTimeWeeklySummary {
    <#
    .SYNOPSIS
        マージ済み PR を 完了週 × クローズまでの時間の区分 で数える（全体・大・中・小）。
    .DESCRIPTION
        ・対象は Status='completed' かつ完了日時(ClosedAt)とリードタイムがある明細だけ
        ・週は ClosedAt（設定タイムゾーン）が属する週。週の始まりは WeekStartDay
        ・範囲内のすべての週を出力する（0 件の週も行を出す）
        ・範囲の端で切れた週は Days < 7、IsPartial = $true
        ・SizeGroup: All（全件。サイズ不明を含む）/ Large / Medium / Small（docs\adr\ADR-0001）
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
    $targets = @(Get-LeadTimeTargetRecords -Records $Records)

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($group in (Get-RecordGroups -Records $targets -Repositories $Config.Repositories)) {
        foreach ($sizeGroupId in $script:LeadTimeSummaryGroupIds) {
            $groupRecords = @(Get-LeadTimeSizeGroupRecords -Records $group.Records -GroupId $sizeGroupId)
            $counts = Get-LeadTimeCountsByPeriod -Records $groupRecords -Unit 'Week' -WeekStartDay $Config.WeekStartDay

            foreach ($start in $weekStarts) {
                $firstDay = $start
                if ($Range.FromLocal -gt $firstDay) { $firstDay = $Range.FromLocal }
                $lastDay = $start.AddDays(6)
                if ($lastDay -gt $rangeLastDay) { $lastDay = $rangeLastDay }
                $days = [int]($lastDay - $firstDay).TotalDays + 1

                $key = $start.ToString('yyyy-MM-dd', $culture)
                $count = Get-LeadTimeCountOrZero -Counts $counts -Key $key

                $rows.Add([pscustomobject][ordered]@{
                        Repository  = $group.Name
                        SizeGroup   = $sizeGroupId
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
    }
    return $rows.ToArray()
}

function Get-LeadTimeDailySummary {
    <#
    .SYNOPSIS
        マージ済み PR を 完了日 × クローズまでの時間の区分 で数える（全体・大・中・小）。
    .DESCRIPTION
        ・対象・区分・SizeGroup の扱いは Get-LeadTimeWeeklySummary と同じ
        ・日は ClosedAt（設定タイムゾーン）の日付。範囲内のすべての日（土日・0 件の日も）を出力する
        列の定義: docs\06_出力仕様.md「summary_leadtime_daily.csv」
    #>
    [CmdletBinding()]
    param(
        [object[]]$Records = @(),
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Range
    )

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $days = @(Get-PeriodStarts -Range $Range -Unit 'Day')
    $targets = @(Get-LeadTimeTargetRecords -Records $Records)

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($group in (Get-RecordGroups -Records $targets -Repositories $Config.Repositories)) {
        foreach ($sizeGroupId in $script:LeadTimeSummaryGroupIds) {
            $groupRecords = @(Get-LeadTimeSizeGroupRecords -Records $group.Records -GroupId $sizeGroupId)
            $counts = Get-LeadTimeCountsByPeriod -Records $groupRecords -Unit 'Day'

            foreach ($day in $days) {
                $key = $day.ToString('yyyy-MM-dd', $culture)
                $count = Get-LeadTimeCountOrZero -Counts $counts -Key $key
                $rows.Add([pscustomobject][ordered]@{
                        Repository  = $group.Name
                        SizeGroup   = $sizeGroupId
                        Date        = $key
                        Under24h    = [int]$count.Under24h
                        From24To72h = [int]$count.From24To72h
                        Over72h     = [int]$count.Over72h
                        Total       = [int]($count.Under24h + $count.From24To72h + $count.Over72h)
                    })
            }
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

function Get-LeadTimeMaxCount {
    <# 行の 3 区分の件数の最大値を返す（縦軸の上限をそろえるために使う）。行が無ければ 0。 #>
    param([object[]]$Rows = @())
    $max = 0
    foreach ($row in @($Rows | Where-Object { $null -ne $_ })) {
        foreach ($bucket in $script:LeadTimeBuckets) {
            if ([int]$row.($bucket.Id) -gt $max) { $max = [int]$row.($bucket.Id) }
        }
    }
    return $max
}

function New-LeadTimeChartSvg {
    <#
    .SYNOPSIS
        週次または日次の集計行（1 グループ分）から、区分ごとの件数の折れ線グラフを SVG 文字列で作る。
    .DESCRIPTION
        ・横軸: 週の開始日（Unit=Week、WeekStart 列）または日付（Unit=Day、Date 列）を MM/dd で。
          最大 12 個になるようラベルを間引く。週単位の端の週は「*」を付ける
        ・縦軸: 件数（0 始まり、整数の目盛り）。-YMax を指定すると、上限を少なくともその値にする
          （大中小のグラフで目盛りをそろえるため）。データの最大値の方が大きければデータに合わせる
        ・週単位の端の週(IsPartial)の点は白抜き。各点に <title> を付け、マウスを重ねると値が出る
        行が 0 件なら空文字を返す。
    #>
    [CmdletBinding()]
    param(
        [object[]]$Rows = @(),
        [ValidateSet('Week', 'Day')][string]$Unit = 'Week',
        [int]$YMax = 0,
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

    $dateField = 'WeekStart'; $unitText = '週次'; $titleFormat = '{0} の週 {1}: {2}件'
    if ($Unit -eq 'Day') { $dateField = 'Date'; $unitText = '日次'; $titleFormat = '{0} {1}: {2}件' }

    # 縦軸の上限: 目盛り 5 本前後になる整数の刻み
    $maxValue = [math]::Max([math]::Max(0, $YMax), (Get-LeadTimeMaxCount -Rows $items))
    $step = [int][math]::Max(1, [math]::Ceiling($maxValue / 5))
    $yMaxValue = $step * [int][math]::Max(1, [math]::Ceiling($maxValue / $step))

    $xs = New-Object 'double[]' $count
    for ($i = 0; $i -lt $count; $i++) {
        if ($count -eq 1) { $xs[$i] = $left + $plotWidth / 2 }
        else { $xs[$i] = $left + $plotWidth * $i / ($count - 1) }
    }
    $toY = { param([double]$v) $top + $plotHeight - $plotHeight * $v / $yMaxValue }
    $labels = @($items | ForEach-Object { [datetime]::ParseExact([string]$_.$dateField, 'yyyy-MM-dd', $culture).ToString('MM/dd', $culture) })
    # 端の週の扱い（白抜き・*）は週単位だけ
    $partials = @($items | ForEach-Object { ($Unit -eq 'Week') -and [bool]$_.IsPartial })

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {0} {1}" width="100%" role="img" aria-label="クローズまでの時間別 PR 件数の{2}推移" font-family="sans-serif">' -f $Width, $Height, $unitText))

    # 目盛り線と縦軸ラベル
    for ($v = 0; $v -le $yMaxValue; $v += $step) {
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
        if ($partials[$i]) { $text = $text + '*' }
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
            $class = 'point'; $fill = $bucket.Color
            if ($partials[$i]) { $class = 'point partial'; $fill = '#ffffff' }
            $title = [System.Net.WebUtility]::HtmlEncode(($titleFormat -f $labels[$i], $bucket.Label, $value))
            $shape = New-LeadTimeMarkerSvg -Marker $bucket.Marker -X $xs[$i] -Y (& $toY $value) -Fill $fill -Stroke $bucket.Color
            [void]$sb.Append(('<g class="{0}"><title>{1}</title>{2}</g>' -f $class, $title, $shape))
        }
    }

    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

# グラフの描き方の対応表（単位 → 描き方）。HTML は描画関数を直接呼ばず、必ず New-LeadTimeChart を通す。
# 日単位の表し方を変えるときは、ここと New-LeadTimeChart の switch だけを変える（docs\adr\ADR-0002）。
#   'Line' : 折れ線（New-LeadTimeChartSvg）
$script:LeadTimeChartStyles = @{ Week = 'Line'; Day = 'Line' }

# 日単位のグラフを出す区分。日単位を全体だけにするなら @('All') にする（docs\adr\ADR-0002 の案 C）。
$script:LeadTimeDailySizeGroups = @('All', 'Large', 'Medium', 'Small')

function New-LeadTimeChart {
    <#
    .SYNOPSIS
        $script:LeadTimeChartStyles の対応表に従って描画関数を選び、グラフの SVG を返す。
    #>
    param(
        [object[]]$Rows = @(),
        [Parameter(Mandatory)][ValidateSet('Week', 'Day')][string]$Unit,
        [int]$YMax = 0
    )
    $style = [string]$script:LeadTimeChartStyles[$Unit]
    switch ($style) {
        'Line' { return New-LeadTimeChartSvg -Rows $Rows -Unit $Unit -YMax $YMax }
        default { throw "未対応のグラフの描き方です: $Unit = '$style'（`$script:LeadTimeChartStyles を確認してください）" }
    }
}

function Get-LeadTimeGroupLabel {
    <# 区分 ID の表示名を返す（All は「全体」、大中小は $script:LeadTimeSizeGroups の Label）。 #>
    param([Parameter(Mandatory)][string]$GroupId)
    if ($GroupId -eq 'All') { return '全体' }
    foreach ($group in $script:LeadTimeSizeGroups) { if ($group.Id -eq $GroupId) { return $group.Label } }
    throw "未知の区分です: $GroupId"
}

function Get-LeadTimeRowsTotal {
    <# 行の Total の合計を返す。 #>
    param([object[]]$Rows = @())
    $total = 0
    foreach ($row in @($Rows | Where-Object { $null -ne $_ })) { $total += [int]$row.Total }
    return $total
}

function New-LeadTimeGroupChartsHtml {
    <#
    .SYNOPSIS
        1 つの区分（全体・大・中・小）の「週単位グラフ ＋ 端の週の注記 ＋ 日単位グラフ」の HTML を作る。
        日単位は $script:LeadTimeDailySizeGroups に含まれる区分だけ出す。
    #>
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [object[]]$WeeklyRows = @(),
        [object[]]$DailyRows = @(),
        [int]$WeeklyYMax = 0,
        [int]$DailyYMax = 0
    )
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $sb = New-Object System.Text.StringBuilder

    [void]$sb.Append('<h4>週単位</h4><div class="chart">')
    [void]$sb.Append((New-LeadTimeChart -Rows $WeeklyRows -Unit 'Week' -YMax $WeeklyYMax))
    [void]$sb.Append('</div>')
    foreach ($row in @($WeeklyRows | Where-Object { $null -ne $_ })) {
        if (-not [bool]$row.IsPartial) { continue }
        $label = [datetime]::ParseExact([string]$row.WeekStart, 'yyyy-MM-dd', $culture).ToString('MM/dd', $culture)
        [void]$sb.Append(('<p class="note">* {0} の週は {1} 日分（集計範囲の端のため）</p>' -f $label, $row.Days))
    }

    if ($script:LeadTimeDailySizeGroups -contains $GroupId) {
        [void]$sb.Append('<h4>日単位</h4><div class="chart">')
        [void]$sb.Append((New-LeadTimeChart -Rows $DailyRows -Unit 'Day' -YMax $DailyYMax))
        [void]$sb.Append('</div>')
    }
    return $sb.ToString()
}

function New-LeadTimeChartHtml {
    <#
    .SYNOPSIS
        週次・日次の集計結果から、見出し・凡例・グラフ（全体・大・中・小 × 週・日）・注記・表をまとめた単一の HTML を作る。
    .DESCRIPTION
        ・並び: 全体（週 → 日）→ 大（週 → 日）→ 中（週 → 日）→ 小（週 → 日）
        ・大中小の縦軸は同じ上限（週は週どうし、日は日どうし）。全体は自分のデータだけで決める
        ・サイズ不明の PR は全体にだけ含まれる。件数を注記し、全件サイズ不明なら大中小の代わりに案内を出す（docs\adr\ADR-0001）
        ・数値の表は <details> で開閉式にし、最初は閉じておく
        外部リソースは読み込まない（社内ネットワークでも表示できるように）。埋め込む文字列は HTML エスケープする。
        出力仕様: docs\06_出力仕様.md「leadtime_chart.html」
    #>
    [CmdletBinding()]
    param(
        [object[]]$WeeklySummary = @(),
        [object[]]$DailySummary = @(),
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Range,
        [datetime]$GeneratedAt = (Get-Date)
    )

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $weeklyRows = @($WeeklySummary | Where-Object { $null -ne $_ })
    $dailyRows = @($DailySummary | Where-Object { $null -ne $_ })
    $repositories = @($weeklyRows | ForEach-Object { $_.Repository } | Select-Object -Unique)
    $sizeGroupIds = @($script:LeadTimeSizeGroups | ForEach-Object { $_.Id })
    # 曜日名は固定の配列から引く（ja-JP カルチャに依存すると、PowerShell 7 の
    # invariant-globalization モードなどでカルチャが使えず日本語にならないため）
    $dayNames = @('日曜日', '月曜日', '火曜日', '水曜日', '木曜日', '金曜日', '土曜日')
    $weekStartName = $dayNames[[int][DayOfWeek]$Config.WeekStartDay]
    $fromText = $Range.FromLocal.ToString('yyyy-MM-dd', $culture)
    $toText = $Range.ToLocalExclusive.AddDays(-1).ToString('yyyy-MM-dd', $culture)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<!DOCTYPE html><html lang="ja"><head><meta charset="utf-8">')
    [void]$sb.Append('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.Append('<title>クローズまでの時間別 PR 件数</title><style>')
    [void]$sb.Append(@'
body { font-family: "Yu Gothic UI", "Meiryo", sans-serif; margin: 24px; color: #212121; background: #ffffff; }
h1 { font-size: 20px; margin-bottom: 8px; }
h2 { font-size: 16px; margin-top: 32px; }
h3 { font-size: 15px; margin: 32px 0 4px; padding-top: 12px; border-top: 2px solid #e0e0e0; }
h4 { font-size: 13px; color: #424242; margin: 14px 0 0; }
.meta { color: #616161; font-size: 13px; margin: 2px 0; }
.legend { list-style: none; padding: 0; display: flex; gap: 16px; flex-wrap: wrap; font-size: 13px; }
.swatch { display: inline-block; width: 16px; height: 3px; vertical-align: middle; margin-right: 6px; }
.chart { max-width: 960px; }
.note { font-size: 12px; color: #616161; margin: 2px 0; }
.empty { color: #c62828; font-size: 13px; }
.unknown { color: #6d4c41; font-size: 13px; }
details { margin-top: 20px; font-size: 13px; }
summary { cursor: pointer; }
table { border-collapse: collapse; font-size: 13px; margin-top: 12px; }
th, td { border: 1px solid #e0e0e0; padding: 4px 10px; text-align: right; }
th { background: #f5f5f5; }
.left { text-align: left; }
'@)
    [void]$sb.Append('</style></head><body>')

    # 見出し
    [void]$sb.Append('<h1>クローズまでの時間別 PR 件数</h1>')
    [void]$sb.Append(('<p class="meta">組織 / プロジェクト: {0} / {1}</p>' -f [System.Net.WebUtility]::HtmlEncode([string]$Config.Organization), [System.Net.WebUtility]::HtmlEncode([string]$Config.Project)))
    [void]$sb.Append(('<p class="meta">集計範囲: {0} 〜 {1}（完了日、{2}）／ 週の始まり: {3}</p>' -f $fromText, $toText, [System.Net.WebUtility]::HtmlEncode([string]$Config.TimeZoneId), $weekStartName))
    [void]$sb.Append('<p class="meta">対象: マージ済み（completed）の PR ／ クローズまでの時間 = 完了日時 − 作成日時</p>')
    [void]$sb.Append(('<p class="meta">作成日時: {0}</p>' -f $GeneratedAt.ToString('yyyy-MM-dd HH:mm', $culture)))

    foreach ($repository in $repositories) {
        $repoWeekly = @($weeklyRows | Where-Object { $_.Repository -eq $repository })
        $repoDaily = @($dailyRows | Where-Object { $_.Repository -eq $repository })
        [void]$sb.Append(('<section><h2>{0}</h2>' -f [System.Net.WebUtility]::HtmlEncode([string]$repository)))

        # 凡例（線の意味はすべてのグラフで同じなので 1 回だけ）
        [void]$sb.Append('<ul class="legend">')
        foreach ($bucket in $script:LeadTimeBuckets) {
            [void]$sb.Append(('<li><span class="swatch" style="background:{0}"></span>{1}</li>' -f $bucket.Color, $bucket.Label))
        }
        [void]$sb.Append('</ul>')

        $allWeekly = @($repoWeekly | Where-Object { $_.SizeGroup -eq 'All' })
        $allDaily = @($repoDaily | Where-Object { $_.SizeGroup -eq 'All' })
        $sizeWeekly = @($repoWeekly | Where-Object { $sizeGroupIds -contains $_.SizeGroup })
        $sizeDaily = @($repoDaily | Where-Object { $sizeGroupIds -contains $_.SizeGroup })
        $allTotal = Get-LeadTimeRowsTotal -Rows $allWeekly
        $sizeTotal = Get-LeadTimeRowsTotal -Rows $sizeWeekly
        $unknownTotal = $allTotal - $sizeTotal

        # 全体
        [void]$sb.Append(('<h3>全体（{0}件）</h3>' -f $allTotal))
        if ($allTotal -eq 0) { [void]$sb.Append('<p class="empty">対象の PR がありません</p>') }
        [void]$sb.Append((New-LeadTimeGroupChartsHtml -GroupId 'All' -WeeklyRows $allWeekly -DailyRows $allDaily))

        # 大・中・小（縦軸の上限をそろえる）
        if ($allTotal -gt 0 -and $sizeTotal -eq 0) {
            [void]$sb.Append('<p class="unknown">サイズを計算していないため、サイズ別のグラフは表示できません（<code>SizeMethod</code> を <code>Git</code> または <code>Api</code> にして実行してください）。</p>')
        }
        else {
            $weeklyYMax = Get-LeadTimeMaxCount -Rows $sizeWeekly
            $dailyYMax = Get-LeadTimeMaxCount -Rows $sizeDaily
            foreach ($group in $script:LeadTimeSizeGroups) {
                $groupWeekly = @($repoWeekly | Where-Object { $_.SizeGroup -eq $group.Id })
                $groupDaily = @($repoDaily | Where-Object { $_.SizeGroup -eq $group.Id })
                $rangeText = [System.Net.WebUtility]::HtmlEncode((Get-LeadTimeSizeGroupRangeText -GroupId $group.Id -Config $Config))
                [void]$sb.Append(('<h3>{0}（{1}）（{2}件）</h3>' -f $group.Label, $rangeText, (Get-LeadTimeRowsTotal -Rows $groupWeekly)))
                [void]$sb.Append((New-LeadTimeGroupChartsHtml -GroupId $group.Id -WeeklyRows $groupWeekly -DailyRows $groupDaily -WeeklyYMax $weeklyYMax -DailyYMax $dailyYMax))
            }
            if ($unknownTotal -gt 0) {
                [void]$sb.Append(('<p class="unknown">※ サイズ不明の {0} 件は、サイズ別（大・中・小）のグラフに含まれていません（全体には含まれます）。</p>' -f $unknownTotal))
            }
        }

        # 数値の表（週単位）
        [void]$sb.Append('<details><summary>数値の表（週単位）</summary><table><thead><tr><th class="left">週の開始日</th><th class="left">期間</th><th>日数</th><th class="left">区分</th>')
        foreach ($bucket in $script:LeadTimeBuckets) { [void]$sb.Append(('<th>{0}</th>' -f $bucket.Label)) }
        [void]$sb.Append('<th>合計</th></tr></thead><tbody>')
        foreach ($row in $repoWeekly) {
            $first = [datetime]::ParseExact([string]$row.WeekStart, 'yyyy-MM-dd', $culture)
            if ($Range.FromLocal -gt $first) { $first = $Range.FromLocal }
            $last = [datetime]::ParseExact([string]$row.WeekEnd, 'yyyy-MM-dd', $culture)
            [void]$sb.Append(('<tr><td class="left">{0}</td><td class="left">{1}〜{2}</td><td>{3}</td><td class="left">{4}</td>' -f $row.WeekStart, $first.ToString('MM/dd', $culture), $last.ToString('MM/dd', $culture), $row.Days, (Get-LeadTimeGroupLabel -GroupId $row.SizeGroup)))
            foreach ($bucket in $script:LeadTimeBuckets) { [void]$sb.Append(('<td>{0}</td>' -f $row.($bucket.Id))) }
            [void]$sb.Append(('<td>{0}</td></tr>' -f $row.Total))
        }
        [void]$sb.Append('</tbody></table></details>')

        # 数値の表（日単位）
        [void]$sb.Append('<details><summary>数値の表（日単位）</summary><table><thead><tr><th class="left">日付</th><th class="left">区分</th>')
        foreach ($bucket in $script:LeadTimeBuckets) { [void]$sb.Append(('<th>{0}</th>' -f $bucket.Label)) }
        [void]$sb.Append('<th>合計</th></tr></thead><tbody>')
        foreach ($row in $repoDaily) {
            [void]$sb.Append(('<tr><td class="left">{0}</td><td class="left">{1}</td>' -f $row.Date, (Get-LeadTimeGroupLabel -GroupId $row.SizeGroup)))
            foreach ($bucket in $script:LeadTimeBuckets) { [void]$sb.Append(('<td>{0}</td>' -f $row.($bucket.Id))) }
            [void]$sb.Append(('<td>{0}</td></tr>' -f $row.Total))
        }
        [void]$sb.Append('</tbody></table></details></section>')
    }

    [void]$sb.Append('</body></html>')
    return $sb.ToString()
}

function Test-LeadTimeChartEnabled {
    <#
    .SYNOPSIS
        クローズまでの時間のグラフ（週次・日次）と週次・日次 CSV を作るか判定する。DateBasis='Closed' のときだけ作る。
        'Created' だと「範囲内に作成された PR を完了週で数える」ことになり、意味がずれるため。
    #>
    param([Parameter(Mandatory)][hashtable]$Config)
    return ([string]$Config.DateBasis -eq 'Closed')
}
