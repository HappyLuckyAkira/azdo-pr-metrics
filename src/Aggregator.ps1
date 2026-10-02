# =============================================================================
# Aggregator.ps1
#   API の PR オブジェクトを出力用レコードに変換し、期間別・作成者別に集計する。
#   指標の定義: docs\01_要件定義.md「指標の定義」
#   詳細設計  : docs\05_詳細設計.md「Aggregator.ps1」
# =============================================================================

$script:AllRepositoriesLabel = '(ALL)'

function Test-PullRequestIncluded {
    <#
    .SYNOPSIS
        PR が集計対象かを判定する（期間・Draft・マージ先ブランチ・除外作成者）。
    .OUTPUTS
        対象なら $true
    #>
    param(
        [Parameter(Mandatory)]$PullRequest,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Range
    )

    $basisUtc = Get-PullRequestBasisDateUtc -PullRequest $PullRequest -DateBasis $Config.DateBasis
    if ($null -eq $basisUtc) { return $false }
    if ($basisUtc -lt $Range.FromUtc -or $basisUtc -ge $Range.ToUtcExclusive) { return $false }

    if ($Config.ExcludeDrafts -and $PullRequest.PSObject.Properties['isDraft'] -and $PullRequest.isDraft) { return $false }

    if ($Config.TargetBranches.Count -gt 0 -and $Config.TargetBranches -notcontains [string]$PullRequest.targetRefName) { return $false }

    if ($Config.ExcludeAuthors.Count -gt 0 -and $null -ne $PullRequest.createdBy) {
        foreach ($name in @([string]$PullRequest.createdBy.displayName, [string]$PullRequest.createdBy.uniqueName)) {
            if ($name -and $Config.ExcludeAuthors -contains $name) { return $false }
        }
    }
    return $true
}

function Get-PullRequestBasisDateUtc {
    <# DateBasis に応じて、期間判定に使う日時(UTC)を返す。 #>
    param([Parameter(Mandatory)]$PullRequest, [Parameter(Mandatory)][string]$DateBasis)
    if ($DateBasis -eq 'Closed') { return ConvertTo-UtcDateTime $PullRequest.closedDate }
    return ConvertTo-UtcDateTime $PullRequest.creationDate
}

function Get-PeriodStart {
    <# 日付が属する集計期間の開始日を返す（Day: その日 / Week: 週の開始曜日 / Month: 1日）。 #>
    param(
        [Parameter(Mandatory)][datetime]$LocalDate,
        [Parameter(Mandatory)][string]$Unit,
        [string]$WeekStartDay = 'Monday'
    )
    $date = $LocalDate.Date
    switch ($Unit) {
        'Day' { return $date }
        'Week' {
            $offset = (7 + [int]$date.DayOfWeek - [int][DayOfWeek]$WeekStartDay) % 7
            return $date.AddDays(-$offset)
        }
        'Month' { return New-Object DateTime $date.Year, $date.Month, 1 }
        default { throw "未対応の PeriodUnit: $Unit" }
    }
}

function Get-PeriodLabel {
    <# 期間開始日を表示用ラベルにする（Month は yyyy-MM、それ以外は yyyy-MM-dd）。 #>
    param([Parameter(Mandatory)][datetime]$PeriodStart, [Parameter(Mandatory)][string]$Unit)
    if ($Unit -eq 'Month') { return $PeriodStart.ToString('yyyy-MM', [Globalization.CultureInfo]::InvariantCulture) }
    return $PeriodStart.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-PeriodStarts {
    <# 集計期間内のすべての期間開始日を返す（PR が 0 件の期間も行として出すため）。 #>
    param(
        [Parameter(Mandatory)]$Range,
        [Parameter(Mandatory)][string]$Unit,
        [string]$WeekStartDay = 'Monday'
    )
    $starts = New-Object System.Collections.Generic.List[datetime]
    $current = Get-PeriodStart -LocalDate $Range.FromLocal -Unit $Unit -WeekStartDay $WeekStartDay
    while ($current -lt $Range.ToLocalExclusive) {
        $starts.Add($current)
        switch ($Unit) {
            'Day' { $current = $current.AddDays(1) }
            'Week' { $current = $current.AddDays(7) }
            'Month' { $current = $current.AddMonths(1) }
        }
    }
    return $starts.ToArray()
}

function Get-Median {
    <# 中央値。$null は除外。値が無ければ $null。 #>
    param([object[]]$Values)
    $sorted = @(@($Values) | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    $mid = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return [math]::Round($sorted[$mid], 2) }
    return [math]::Round(($sorted[$mid - 1] + $sorted[$mid]) / 2, 2)
}

function Get-Average {
    <# 平均値。$null は除外。値が無ければ $null。 #>
    param([object[]]$Values)
    $valid = @(@($Values) | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($valid.Count -eq 0) { return $null }
    return [math]::Round(($valid | Measure-Object -Sum).Sum / $valid.Count, 2)
}

function Get-Sum {
    <# 合計値。$null は除外。値が無ければ $null。 #>
    param([object[]]$Values)
    $valid = @(@($Values) | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($valid.Count -eq 0) { return $null }
    return ($valid | Measure-Object -Sum).Sum
}

function ConvertTo-PrRecord {
    <#
    .SYNOPSIS
        API の PR オブジェクトとサイズ計算結果から、prs.csv の 1 行分のレコードを作る。
        列の定義: docs\06_出力仕様.md「prs.csv」
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$PullRequest,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)]$Size,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][TimeZoneInfo]$TimeZone,
        [Parameter(Mandatory)][string]$WebBaseUrl
    )

    $format = 'yyyy-MM-dd HH:mm'
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $createdUtc = ConvertTo-UtcDateTime $PullRequest.creationDate
    $closedUtc = ConvertTo-UtcDateTime $PullRequest.closedDate
    $basisUtc = Get-PullRequestBasisDateUtc -PullRequest $PullRequest -DateBasis $Config.DateBasis

    $createdLocal = ''; $closedLocal = ''; $period = ''; $leadTimeHours = $null
    if ($createdUtc) { $createdLocal = [TimeZoneInfo]::ConvertTimeFromUtc($createdUtc, $TimeZone).ToString($format, $culture) }
    if ($closedUtc) { $closedLocal = [TimeZoneInfo]::ConvertTimeFromUtc($closedUtc, $TimeZone).ToString($format, $culture) }
    if ($createdUtc -and $closedUtc) { $leadTimeHours = [math]::Round(($closedUtc - $createdUtc).TotalHours, 2) }
    if ($basisUtc) {
        $basisLocal = [TimeZoneInfo]::ConvertTimeFromUtc($basisUtc, $TimeZone)
        $period = Get-PeriodLabel -PeriodStart (Get-PeriodStart -LocalDate $basisLocal -Unit $Config.PeriodUnit -WeekStartDay $Config.WeekStartDay) -Unit $Config.PeriodUnit
    }

    # レビュアーのうちグループ(isContainer)を除いた個人のみ数える。vote: 10=承認, 5=提案付き承認
    $people = @(@($PullRequest.reviewers) | Where-Object { $null -ne $_ -and -not ($_.PSObject.Properties['isContainer'] -and $_.isContainer) })
    $approved = @($people | Where-Object { [int]$_.vote -ge 5 })

    $mergeStrategy = ''
    if ($PullRequest.PSObject.Properties['completionOptions'] -and $null -ne $PullRequest.completionOptions -and
        $PullRequest.completionOptions.PSObject.Properties['mergeStrategy']) {
        $mergeStrategy = [string]$PullRequest.completionOptions.mergeStrategy
    }
    $isDraft = $false
    if ($PullRequest.PSObject.Properties['isDraft']) { $isDraft = [bool]$PullRequest.isDraft }

    $author = ''; $authorId = ''
    if ($null -ne $PullRequest.createdBy) {
        $author = [string]$PullRequest.createdBy.displayName
        $authorId = [string]$PullRequest.createdBy.uniqueName
    }

    [pscustomobject][ordered]@{
        Repository     = $Repository
        PullRequestId  = [int]$PullRequest.pullRequestId
        Title          = [string]$PullRequest.title
        Status         = [string]$PullRequest.status
        IsDraft        = $isDraft
        Author         = $author
        AuthorId       = $authorId
        SourceBranch   = ([string]$PullRequest.sourceRefName) -replace '^refs/heads/', ''
        TargetBranch   = ([string]$PullRequest.targetRefName) -replace '^refs/heads/', ''
        CreatedAt      = $createdLocal
        ClosedAt       = $closedLocal
        Period         = $period
        LeadTimeHours  = $leadTimeHours
        ReviewerCount  = $people.Count
        ApprovedCount  = $approved.Count
        FilesChanged   = $Size.FilesChanged
        LinesAdded     = $Size.LinesAdded
        LinesDeleted   = $Size.LinesDeleted
        LinesChanged   = $Size.LinesChanged
        BinaryFiles    = $Size.BinaryFiles
        ExcludedFiles  = $Size.ExcludedFiles
        SizeCategory   = Get-PrSizeCategory -LinesChanged $Size.LinesChanged -FilesChanged $Size.FilesChanged -Categories $Config.SizeCategories
        SizeSource     = $Size.SizeSource
        SizeNote       = $Size.SizeNote
        MergeStrategy  = $mergeStrategy
        Url            = '{0}/_git/{1}/pullrequest/{2}' -f $WebBaseUrl, [uri]::EscapeDataString($Repository), [int]$PullRequest.pullRequestId
    }
}

function Get-RecordGroups {
    <# リポジトリ別のグループを返す。リポジトリが複数なら全体(ALL)も加える。 #>
    param([object[]]$Records, [string[]]$Repositories)
    $groups = New-Object System.Collections.Generic.List[object]
    foreach ($repo in $Repositories) {
        $groups.Add([pscustomobject]@{ Name = $repo; Records = @($Records | Where-Object { $_.Repository -eq $repo }) })
    }
    if ($Repositories.Count -gt 1) {
        $groups.Add([pscustomobject]@{ Name = $script:AllRepositoriesLabel; Records = @($Records) })
    }
    return $groups.ToArray()
}

function Get-PeriodSummary {
    <#
    .SYNOPSIS
        期間(日/週/月)ごとの集計表を作る。PR が 0 件の期間も 0 として出力する。
        列の定義: docs\06_出力仕様.md「summary_by_period.csv」
    #>
    [CmdletBinding()]
    param(
        [object[]]$Records = @(),
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Range
    )

    $periodStarts = Get-PeriodStarts -Range $Range -Unit $Config.PeriodUnit -WeekStartDay $Config.WeekStartDay
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($group in (Get-RecordGroups -Records $Records -Repositories $Config.Repositories)) {
        foreach ($start in $periodStarts) {
            $label = Get-PeriodLabel -PeriodStart $start -Unit $Config.PeriodUnit
            $items = @($group.Records | Where-Object { $_.Period -eq $label })

            $row = [ordered]@{
                Repository         = $group.Name
                Period             = $label
                PrCount            = $items.Count
                AuthorCount        = @($items | ForEach-Object { $_.AuthorId } | Sort-Object -Unique).Count
                LeadTimeMedianH    = Get-Median ($items | ForEach-Object { $_.LeadTimeHours })
                LeadTimeAvgH       = Get-Average ($items | ForEach-Object { $_.LeadTimeHours })
                FilesChangedMedian = Get-Median ($items | ForEach-Object { $_.FilesChanged })
                LinesChangedMedian = Get-Median ($items | ForEach-Object { $_.LinesChanged })
                LinesChangedAvg    = Get-Average ($items | ForEach-Object { $_.LinesChanged })
                LinesChangedTotal  = Get-Sum ($items | ForEach-Object { $_.LinesChanged })
            }
            foreach ($category in $Config.SizeCategories) {
                $row["Size_$($category.Name)"] = @($items | Where-Object { $_.SizeCategory -eq $category.Name }).Count
            }
            $row['SizeUnknown'] = @($items | Where-Object { -not $_.SizeCategory }).Count
            $rows.Add([pscustomobject]$row)
        }
    }
    return $rows.ToArray()
}

function Get-AuthorSummary {
    <#
    .SYNOPSIS
        作成者ごとの集計表を作る（PR 件数の多い順）。
        列の定義: docs\06_出力仕様.md「summary_by_author.csv」
    #>
    [CmdletBinding()]
    param(
        [object[]]$Records = @(),
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Range
    )

    $weeks = $Range.Days / 7
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($group in (Get-RecordGroups -Records $Records -Repositories $Config.Repositories)) {
        $byAuthor = @($group.Records | Group-Object -Property AuthorId)
        $authorRows = foreach ($authorGroup in $byAuthor) {
            $items = @($authorGroup.Group)
            [pscustomobject][ordered]@{
                Repository         = $group.Name
                Author             = $items[0].Author
                AuthorId           = $items[0].AuthorId
                PrCount            = $items.Count
                PrPerWeek          = [math]::Round($items.Count / $weeks, 2)
                LeadTimeMedianH    = Get-Median ($items | ForEach-Object { $_.LeadTimeHours })
                LinesChangedMedian = Get-Median ($items | ForEach-Object { $_.LinesChanged })
                LinesChangedTotal  = Get-Sum ($items | ForEach-Object { $_.LinesChanged })
                FilesChangedMedian = Get-Median ($items | ForEach-Object { $_.FilesChanged })
            }
        }
        foreach ($row in @($authorRows | Sort-Object -Property @{ Expression = 'PrCount'; Descending = $true }, Author)) {
            $rows.Add($row)
        }
    }
    return $rows.ToArray()
}
