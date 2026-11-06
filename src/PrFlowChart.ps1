# =============================================================================
# PrFlowChart.ps1
#   日ごとの PR の作成数・滞留数・Close 数を集計し、3 本の棒を並べた棒グラフ
#   （SVG を埋め込んだ HTML の 1 節）を作る。
#   仕様: docs\superpowers\specs\2026-11-06-pr-flow-daily-chart-design.md
#   詳細設計: docs\05_詳細設計.md「PrFlowChart.ps1」、判断の記録: docs\adr\ADR-0003
# =============================================================================

function ConvertTo-PrFlowRecord {
    <#
    .SYNOPSIS
        API の PR を、作成・滞留・Close の集計用の記録（作成日時・クローズ日時を設定タイムゾーンで持つ）に変換する。
    .DESCRIPTION
        ・クローズ日時は status が completed（マージ）または abandoned（破棄）のときだけ使う（active はクローズなし）
        ・作成日時が無い PR は数えられないので、何も返さない
    #>
    param(
        [Parameter(Mandatory)]$PullRequest,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][TimeZoneInfo]$TimeZone
    )
    $createdUtc = ConvertTo-UtcDateTime $PullRequest.creationDate
    if ($null -eq $createdUtc) { return }

    $status = [string]$PullRequest.status
    $closedLocal = $null
    if ($status -eq 'completed' -or $status -eq 'abandoned') {
        $closedUtc = ConvertTo-UtcDateTime $PullRequest.closedDate
        if ($null -ne $closedUtc) { $closedLocal = [TimeZoneInfo]::ConvertTimeFromUtc($closedUtc, $TimeZone) }
    }

    [pscustomobject]@{
        Repository    = $Repository
        PullRequestId = [int]$PullRequest.pullRequestId
        Status        = $status
        CreatedLocal  = [TimeZoneInfo]::ConvertTimeFromUtc($createdUtc, $TimeZone)
        ClosedLocal   = $closedLocal
    }
}

function Get-PrFlowDailySummary {
    <#
    .SYNOPSIS
        日ごとの PR の作成数・滞留数・Close 数を数える。
    .DESCRIPTION
        ・Created: その日に作成された PR
        ・Open   : その日の終わり（翌日 0:00）の時点で、作成済みでまだクローズされていない PR（範囲より前に作られた PR も含む）
        ・Closed : その日にクローズ（マージ・破棄）された PR
        毎日 Open(当日) = Open(前日) + Created(当日) - Closed(当日) が成り立つ。
        範囲内のすべての日を出す（0 件の日も）。リポジトリが複数なら (ALL) も出す。
        列の定義: docs\06_出力仕様.md「summary_pr_flow_daily.csv」
    #>
    [CmdletBinding()]
    param(
        [object[]]$Records = @(),
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Range
    )

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $days = @(Get-PeriodStarts -Range $Range -Unit 'Day')
    $targets = @($Records | Where-Object { $null -ne $_ })

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($group in (Get-RecordGroups -Records $targets -Repositories $Config.Repositories)) {
        foreach ($day in $days) {
            $dayEnd = $day.AddDays(1)
            $created = 0; $open = 0; $closed = 0
            foreach ($record in $group.Records) {
                if ($record.CreatedLocal -ge $day -and $record.CreatedLocal -lt $dayEnd) { $created++ }
                if ($null -ne $record.ClosedLocal -and $record.ClosedLocal -ge $day -and $record.ClosedLocal -lt $dayEnd) { $closed++ }
                if ($record.CreatedLocal -lt $dayEnd -and ($null -eq $record.ClosedLocal -or $record.ClosedLocal -ge $dayEnd)) { $open++ }
            }
            $rows.Add([pscustomobject][ordered]@{
                    Repository = $group.Name
                    Date       = $day.ToString('yyyy-MM-dd', $culture)
                    Created    = $created
                    Open       = $open
                    Closed     = $closed
                })
        }
    }
    return $rows.ToArray()
}

# 棒の定義。順序がそのまま 1 日の中の並び（左から）と凡例・表の列の順になる。
# 色は折れ線（緑・オレンジ・赤）と区別できる 3 色。並び順が固定なので白黒でも区別できる。
$script:PrFlowSeries = @(
    [pscustomobject]@{ Id = 'Created'; Label = '作成';  Color = '#1565c0' }
    [pscustomobject]@{ Id = 'Open';    Label = '滞留';  Color = '#8e24aa' }
    [pscustomobject]@{ Id = 'Closed';  Label = 'Close'; Color = '#00897b' }
)

function New-PrFlowBarChartSvg {
    <#
    .SYNOPSIS
        日次の作成・滞留・Close の行から、1 日 3 本の棒を並べた棒グラフを SVG 文字列で作る。
    .DESCRIPTION
        ・1 日の枠の 75% に 3 本の棒を隙間なく並べ、残り 25% を日と日の間の空白にする
        ・横軸: 日付(MM/dd)。最大 12 個になるようラベルを間引く。縦軸: 件数（0 始まり、整数の目盛り）
        ・各棒に <title> を付け、マウスを重ねると値が出る
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

    $maxValue = 0
    foreach ($item in $items) {
        foreach ($series in $script:PrFlowSeries) {
            if ([int]$item.($series.Id) -gt $maxValue) { $maxValue = [int]$item.($series.Id) }
        }
    }
    $yAxis = Get-ChartYAxis -MaxValue $maxValue
    $yMaxValue = $yAxis.Max
    $toY = { param([double]$v) $top + $plotHeight - $plotHeight * $v / $yMaxValue }.GetNewClosure()

    $slotWidth = $plotWidth / $count
    $groupWidth = $slotWidth * 0.75
    $barWidth = $groupWidth / $script:PrFlowSeries.Count
    $labels = @($items | ForEach-Object { [datetime]::ParseExact([string]$_.Date, 'yyyy-MM-dd', $culture).ToString('MM/dd', $culture) })

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {0} {1}" width="100%" role="img" aria-label="PR の作成・滞留・Close の日次推移" font-family="sans-serif">' -f $Width, $Height))
    [void]$sb.Append((New-ChartYAxisSvg -YAxis $yAxis -ToY $toY -Left $left -Right $right -Width $Width))

    # 横軸ラベル（間引き）。1 日の枠の中央に置く
    $labelEvery = [int][math]::Max(1, [math]::Ceiling($count / 12))
    for ($i = 0; $i -lt $count; $i++) {
        if ($i % $labelEvery -ne 0) { continue }
        [void]$sb.Append(('<text class="x-label" x="{0}" y="{1}" text-anchor="middle" font-size="12" fill="#616161">{2}</text>' -f (Format-SvgNumber ($left + $slotWidth * ($i + 0.5))), ($Height - $bottom + 20), $labels[$i]))
    }

    # 棒（日ごとに 作成 → 滞留 → Close）
    $baseY = & $toY 0
    for ($i = 0; $i -lt $count; $i++) {
        $groupLeft = $left + $slotWidth * $i + ($slotWidth - $groupWidth) / 2
        for ($k = 0; $k -lt $script:PrFlowSeries.Count; $k++) {
            $series = $script:PrFlowSeries[$k]
            $value = [int]$items[$i].($series.Id)
            $y = & $toY $value
            $title = [System.Net.WebUtility]::HtmlEncode(('{0} {1}: {2}件' -f $labels[$i], $series.Label, $value))
            [void]$sb.Append(('<rect class="bar bar-{0}" x="{1}" y="{2}" width="{3}" height="{4}" fill="{5}"><title>{6}</title></rect>' -f `
                        $series.Id, (Format-SvgNumber ($groupLeft + $barWidth * $k)), (Format-SvgNumber $y), (Format-SvgNumber $barWidth), (Format-SvgNumber ($baseY - $y)), $series.Color, $title))
        }
    }

    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

function New-PrFlowSectionHtml {
    <#
    .SYNOPSIS
        leadtime_chart.html の各リポジトリの最後に入れる「PR の作成・滞留・Close（日単位）」の節を作る。
        -Available が $false のとき（データを取得できなかったとき）は、表示できない旨だけを出す。
    #>
    param(
        [object[]]$Rows = @(),
        [bool]$Available = $true
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<h3>PR の作成・滞留・Close（日単位）</h3>')
    if (-not $Available) {
        [void]$sb.Append('<p class="unknown">PR の作成・滞留・Close のデータを取得できなかったため、このグラフは表示できません。</p>')
        return $sb.ToString()
    }

    [void]$sb.Append('<p class="note">作成: その日に作成された PR ／ 滞留: その日の終わりに開いている PR ／ Close: その日にマージまたは破棄された PR（Draft・マージ先ブランチ・作成者の絞り込みは設定どおり）</p>')
    [void]$sb.Append('<ul class="legend">')
    foreach ($series in $script:PrFlowSeries) {
        [void]$sb.Append(('<li><span class="swatch" style="background:{0};height:10px"></span>{1}</li>' -f $series.Color, $series.Label))
    }
    [void]$sb.Append('</ul><div class="chart">')
    [void]$sb.Append((New-PrFlowBarChartSvg -Rows $Rows))
    [void]$sb.Append('</div>')

    [void]$sb.Append('<details><summary>数値の表（PR の作成・滞留・Close）</summary><table><thead><tr><th class="left">日付</th>')
    foreach ($series in $script:PrFlowSeries) { [void]$sb.Append(('<th>{0}</th>' -f $series.Label)) }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($row in @($Rows | Where-Object { $null -ne $_ })) {
        [void]$sb.Append(('<tr><td class="left">{0}</td>' -f $row.Date))
        foreach ($series in $script:PrFlowSeries) { [void]$sb.Append(('<td>{0}</td>' -f $row.($series.Id))) }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></details>')
    return $sb.ToString()
}
