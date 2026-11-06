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
