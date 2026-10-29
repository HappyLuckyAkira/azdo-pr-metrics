<#
.SYNOPSIS
    PR メトリクス収集ツールの単体テスト（Azure DevOps への接続不要）。
.DESCRIPTION
    Pester のバージョン差（Windows 標準の 3.4 と 5.x で書き方が違う）を避けるため、
    依存なしの簡易アサートで書いている。PowerShell 5.1 / 7 の両方で実行できる。
    git がある場合は、一時フォルダに実リポジトリを作って Git 方式のサイズ計算も検証する。
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
foreach ($file in @('Config.ps1', 'AzDoClient.ps1', 'SizeCalculator.ps1', 'Aggregator.ps1', 'Output.ps1', 'LeadTimeChart.ps1')) {
    . (Join-Path (Join-Path $toolRoot 'src') $file)
}

$script:passed = 0
$script:failed = New-Object System.Collections.Generic.List[string]

function It {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:passed++; Write-Host "  [PASS] $Name" -ForegroundColor Green }
    catch { $script:failed.Add("$Name : $($_.Exception.Message)"); Write-Host "  [FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if (-not (($null -eq $Expected -and $null -eq $Actual) -or ($null -ne $Expected -and $null -ne $Actual -and $Expected -eq $Actual))) {
        throw "期待値 [$Expected] 実際 [$Actual] $Message"
    }
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Like = '*')
    $thrown = $false
    try { & $Body 2>$null 3>$null } catch { $thrown = $true; if ($_.Exception.Message -notlike $Like) { throw "例外メッセージが想定外: $($_.Exception.Message)" } }
    if (-not $thrown) { throw '例外が発生しませんでした' }
}

function New-TestConfig {
    param([hashtable]$Override = @{})
    $config = @{}
    foreach ($k in $script:PrMetricsDefaultConfig.Keys) { $config[$k] = $script:PrMetricsDefaultConfig[$k] }
    $config.Organization = 'org'; $config.Project = 'proj'; $config.Repositories = @('RepoA')
    foreach ($k in $Override.Keys) { $config[$k] = $Override[$k] }
    return $config
}

$tokyo = [TimeZoneInfo]::FindSystemTimeZoneById('Tokyo Standard Time')

Write-Host '== Config'
It '設定ファイル(settings.psd1)が読み込めて検証を通る' {
    $c = Import-PrMetricsConfig -Path (Join-Path $toolRoot 'config\settings.psd1')
    Assert-Equal 'contoso' $c.Organization
    Assert-Equal 1 @($c.Repositories).Count
}
It '引数の上書きが反映され、空値は無視される' {
    $c = Import-PrMetricsConfig -Path (Join-Path $toolRoot 'config\settings.psd1') -Overrides @{ FromDate = '2026-01-01'; ToDate = ''; Repositories = @(); SizeMethod = 'None' }
    Assert-Equal '2026-01-01' $c.FromDate
    Assert-Equal 'None' $c.SizeMethod
    Assert-Equal 'SampleRepo' $c.Repositories[0]
}
It '不正な設定値はまとめてエラーになる' {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "prm_bad_$([guid]::NewGuid()).psd1"
    Set-Content -LiteralPath $tmp -Value "@{ Organization='o'; Project='p'; Repositories=@('r'); DateBasis='Merged'; FromDate='2026/01/01' }" -Encoding UTF8
    try { Assert-Throws { Import-PrMetricsConfig -Path $tmp } -Like '*DateBasis*FromDate*' } finally { Remove-Item $tmp }
}
It '期間: ToDate はその日を含み、UTC は JST-9時間' {
    $c = New-TestConfig @{ FromDate = '2026-09-01'; ToDate = '2026-09-30' }
    $r = Get-PrMetricsDateRange -Config $c -TimeZone $tokyo
    Assert-Equal 30 $r.Days
    Assert-Equal ([datetime]'2026-08-31T15:00:00') $r.FromUtc
    Assert-Equal ([datetime]'2026-09-30T15:00:00') $r.ToUtcExclusive
}
It '期間: 日付未指定なら今日を含む直近 LastNDays 日' {
    $c = New-TestConfig @{ LastNDays = 7 }
    $r = Get-PrMetricsDateRange -Config $c -TimeZone $tokyo -NowUtc ([datetime]'2026-10-02T01:00:00')
    Assert-Equal ([datetime]'2026-09-26') $r.FromLocal
    Assert-Equal ([datetime]'2026-10-03') $r.ToLocalExclusive
}
It '日時変換: 文字列・DateTime・無効値' {
    Assert-Equal ([datetime]'2026-09-01T02:03:04') (ConvertTo-UtcDateTime '2026-09-01T02:03:04.123Z').AddMilliseconds(-123)
    Assert-Equal ([datetime]'2026-09-01T02:03:04') (ConvertTo-UtcDateTime ([datetime]::SpecifyKind([datetime]'2026-09-01T02:03:04', 'Utc')))
    Assert-Equal $null (ConvertTo-UtcDateTime '0001-01-01T00:00:00')
    Assert-Equal $null (ConvertTo-UtcDateTime $null)
}

Write-Host '== SizeCalculator'
It 'パス除外: 拡張子・フォルダ・区切り文字の違い' {
    $p = @('*.hex', 'Generated/*', '*/lib/*')
    Assert-Equal $true (Test-PathExcluded '/out/app.HEX' $p)
    Assert-Equal $true (Test-PathExcluded 'Generated/a.c' $p)
    Assert-Equal $true (Test-PathExcluded 'src\lib\x.c' $p)
    Assert-Equal $false (Test-PathExcluded 'src/main.c' $p)
    Assert-Equal $false (Test-PathExcluded 'src/main.c' @())
}
It 'リネーム表記を変更後パスにする' {
    Assert-Equal 'src/new/a.c' (Resolve-GitRenamePath 'src/{old => new}/a.c')
    Assert-Equal 'src/a.c' (Resolve-GitRenamePath 'src/{old => }/a.c')
    Assert-Equal 'b.c' (Resolve-GitRenamePath 'a.c => b.c')
    Assert-Equal 'x.c' (Resolve-GitRenamePath 'x.c')
}
It 'numstat 集計: バイナリはファイル数のみ、除外は別計上' {
    $lines = @("10`t2`tsrc/a.c", "-`t-`timg/logo.bin", "5`t0`tout/fw.hex", "3`t3`tsrc/{old => new}/b.c", '')
    $s = ConvertFrom-GitNumstat -Lines $lines -ExcludePatterns @('*.hex')
    Assert-Equal 3 $s.FilesChanged
    Assert-Equal 13 $s.LinesAdded
    Assert-Equal 5 $s.LinesDeleted
    Assert-Equal 1 $s.BinaryFiles
    Assert-Equal 1 $s.ExcludedFiles
}
It 'サイズ区分: 行数優先・ファイル数代替・上限なし・不明' {
    $cats = $script:PrMetricsDefaultConfig.SizeCategories
    Assert-Equal 'XS' (Get-PrSizeCategory -LinesChanged 10 -FilesChanged 99 -Categories $cats)
    Assert-Equal 'S' (Get-PrSizeCategory -LinesChanged 11 -FilesChanged $null -Categories $cats)
    Assert-Equal 'XL' (Get-PrSizeCategory -LinesChanged 100000 -FilesChanged $null -Categories $cats)
    Assert-Equal 'M' (Get-PrSizeCategory -LinesChanged $null -FilesChanged 4 -Categories $cats)
    Assert-Equal '' (Get-PrSizeCategory -LinesChanged $null -FilesChanged $null -Categories $cats)
}

Write-Host '== Aggregator'
It '週の開始日（月曜/日曜始まり）と月の開始日' {
    Assert-Equal ([datetime]'2026-09-28') (Get-PeriodStart -LocalDate ([datetime]'2026-10-04 23:00') -Unit Week -WeekStartDay Monday)
    Assert-Equal ([datetime]'2026-10-04') (Get-PeriodStart -LocalDate ([datetime]'2026-10-04 23:00') -Unit Week -WeekStartDay Sunday)
    Assert-Equal ([datetime]'2026-10-01') (Get-PeriodStart -LocalDate ([datetime]'2026-10-31') -Unit Month)
}
It '中央値・平均（$null 除外）' {
    Assert-Equal 2.5 (Get-Median @(4, 1, $null, 3, 2))
    Assert-Equal 3 (Get-Median @(5, 1, 3))
    Assert-Equal $null (Get-Median @())
    Assert-Equal 2 (Get-Average @(1, $null, 3))
}

# テスト用 PR（API の JSON と同じ形）
function New-FakePr {
    param([int]$Id, [string]$Created, [string]$Closed, [string]$Author = 'Taro', [string]$Target = 'refs/heads/main', [bool]$Draft = $false)
    $json = @{
        pullRequestId = $Id; title = "PR $Id"; status = 'completed'; isDraft = $Draft
        createdBy = @{ displayName = $Author; uniqueName = "$Author@example.com" }
        creationDate = $Created; closedDate = $Closed
        sourceRefName = 'refs/heads/feature'; targetRefName = $Target
        reviewers = @(@{ displayName = 'R1'; vote = 10 }, @{ displayName = 'Team'; vote = 0; isContainer = $true })
    } | ConvertTo-Json -Depth 5
    return ($json | ConvertFrom-Json)
}

It '対象判定: 期間・Draft・ブランチ・除外作成者' {
    $c = New-TestConfig @{ FromDate = '2026-09-01'; ToDate = '2026-09-30'; TargetBranches = @('refs/heads/main'); ExcludeAuthors = @('Bot') }
    $r = Get-PrMetricsDateRange -Config $c -TimeZone $tokyo
    # 9/30 23:30 JST = 9/30 14:30Z → 対象 / 10/1 00:30 JST = 9/30 15:30Z → 対象外
    Assert-Equal $true (Test-PullRequestIncluded (New-FakePr 1 '2026-09-20T00:00:00Z' '2026-09-30T14:30:00Z') $c $r)
    Assert-Equal $false (Test-PullRequestIncluded (New-FakePr 2 '2026-09-20T00:00:00Z' '2026-09-30T15:30:00Z') $c $r)
    Assert-Equal $false (Test-PullRequestIncluded (New-FakePr 3 '2026-09-20T00:00:00Z' '2026-09-10T00:00:00Z' -Draft $true) $c $r)
    Assert-Equal $false (Test-PullRequestIncluded (New-FakePr 4 '2026-09-20T00:00:00Z' '2026-09-10T00:00:00Z' -Target 'refs/heads/dev') $c $r)
    Assert-Equal $false (Test-PullRequestIncluded (New-FakePr 5 '2026-09-20T00:00:00Z' '2026-09-10T00:00:00Z' -Author 'Bot') $c $r)
}
It 'レコード化: JST 表示・リードタイム・レビュアー(グループ除外)' {
    $c = New-TestConfig
    $size = New-PrSizeResult -FilesChanged 2 -LinesAdded 30 -LinesDeleted 5 -SizeSource 'git:target..merge'
    $rec = ConvertTo-PrRecord -PullRequest (New-FakePr 7 '2026-09-01T00:00:00Z' '2026-09-02T06:00:00Z') -Repository 'RepoA' -Size $size -Config $c -TimeZone $tokyo -WebBaseUrl 'https://dev.azure.com/org/proj'
    Assert-Equal '2026-09-01 09:00' $rec.CreatedAt
    Assert-Equal 30 $rec.LeadTimeHours
    Assert-Equal '2026-08-31' $rec.Period
    Assert-Equal 1 $rec.ReviewerCount
    Assert-Equal 1 $rec.ApprovedCount
    Assert-Equal 35 $rec.LinesChanged
    Assert-Equal 'S' $rec.SizeCategory
    Assert-Equal 'main' $rec.TargetBranch
    Assert-Equal 'https://dev.azure.com/org/proj/_git/RepoA/pullrequest/7' $rec.Url
}
It '期間別サマリー: 0 件の週も出る・サイズ区分の列がある' {
    $c = New-TestConfig @{ FromDate = '2026-09-01'; ToDate = '2026-09-30' }
    $r = Get-PrMetricsDateRange -Config $c -TimeZone $tokyo
    $size = New-PrSizeResult -FilesChanged 1 -LinesAdded 5 -LinesDeleted 0
    $recs = @(
        ConvertTo-PrRecord -PullRequest (New-FakePr 1 '2026-09-01T00:00:00Z' '2026-09-02T00:00:00Z') -Repository 'RepoA' -Size $size -Config $c -TimeZone $tokyo -WebBaseUrl 'x'
        ConvertTo-PrRecord -PullRequest (New-FakePr 2 '2026-09-01T00:00:00Z' '2026-09-03T00:00:00Z') -Repository 'RepoA' -Size $size -Config $c -TimeZone $tokyo -WebBaseUrl 'x'
    )
    $rows = @(Get-PeriodSummary -Records $recs -Config $c -Range $r)
    Assert-Equal 5 $rows.Count '（8/31,9/7,9/14,9/21,9/28 の 5 週）'
    Assert-Equal 2 $rows[0].PrCount
    Assert-Equal 36 $rows[0].LeadTimeMedianH
    Assert-Equal 0 $rows[1].PrCount
    Assert-Equal 2 $rows[0].Size_XS
    $authors = @(Get-AuthorSummary -Records $recs -Config $c -Range $r)
    Assert-Equal 1 $authors.Count
    Assert-Equal ([math]::Round(2 / (30 / 7), 2)) $authors[0].PrPerWeek
}
It '複数リポジトリでは (ALL) 行が追加される' {
    $c = New-TestConfig @{ FromDate = '2026-09-01'; ToDate = '2026-09-07'; Repositories = @('RepoA', 'RepoB') }
    $r = Get-PrMetricsDateRange -Config $c -TimeZone $tokyo
    $rows = @(Get-PeriodSummary -Records @() -Config $c -Range $r)
    Assert-Equal 6 $rows.Count '（2 週 × (RepoA, RepoB, ALL)）'
    Assert-Equal '(ALL)' $rows[-1].Repository
}

Write-Host '== LeadTimeChart'
It 'クローズまでの時間の区分: 境界ちょうどは上側の区分' {
    Assert-Equal 'Under24h' (Get-LeadTimeBucket -Hours 0)
    Assert-Equal 'Under24h' (Get-LeadTimeBucket -Hours 23.99)
    Assert-Equal 'From24To72h' (Get-LeadTimeBucket -Hours 24)
    Assert-Equal 'From24To72h' (Get-LeadTimeBucket -Hours 71.99)
    Assert-Equal 'Over72h' (Get-LeadTimeBucket -Hours 72)
    Assert-Equal 'Over72h' (Get-LeadTimeBucket -Hours 500)
}
It '大中小: XS・S は小、M は中、L・XL は大、それ以外はサイズ不明' {
    Assert-Equal 'Small' (Get-LeadTimeSizeGroup -SizeCategory 'XS')
    Assert-Equal 'Small' (Get-LeadTimeSizeGroup -SizeCategory 'S')
    Assert-Equal 'Medium' (Get-LeadTimeSizeGroup -SizeCategory 'M')
    Assert-Equal 'Large' (Get-LeadTimeSizeGroup -SizeCategory 'L')
    Assert-Equal 'Large' (Get-LeadTimeSizeGroup -SizeCategory 'XL')
    Assert-Equal '' (Get-LeadTimeSizeGroup -SizeCategory '')
    Assert-Equal '' (Get-LeadTimeSizeGroup -SizeCategory 'XXL')
}
It '大中小の範囲表示: 設定の閾値から作る（Git は行数、Api はファイル数）' {
    $c = New-TestConfig
    Assert-Equal 'L・XL：251行〜' (Get-LeadTimeSizeGroupRangeText -GroupId 'Large' -Config $c)
    Assert-Equal 'M：51〜250行' (Get-LeadTimeSizeGroupRangeText -GroupId 'Medium' -Config $c)
    Assert-Equal 'XS・S：〜50行' (Get-LeadTimeSizeGroupRangeText -GroupId 'Small' -Config $c)
    $c.SizeMethod = 'Api'
    Assert-Equal 'L・XL：11ファイル〜' (Get-LeadTimeSizeGroupRangeText -GroupId 'Large' -Config $c)
    Assert-Equal 'M：4〜10ファイル' (Get-LeadTimeSizeGroupRangeText -GroupId 'Medium' -Config $c)
    Assert-Equal 'XS・S：〜3ファイル' (Get-LeadTimeSizeGroupRangeText -GroupId 'Small' -Config $c)
    Assert-Throws { Get-LeadTimeSizeGroupRangeText -GroupId 'Huge' -Config $c } -Like '*Huge*'
}

function New-LeadTimeRecord {
    # 完了日時(UTC 文字列)とクローズまでの時間(時間)から明細レコードを作る
    param([int]$Id, [string]$ClosedUtc, [double]$Hours, [string]$Repo = 'RepoA', [string]$Status = 'completed', [string]$SizeCategory = '')
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $closed = [datetime]::Parse($ClosedUtc, $culture, [Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal')
    $created = $closed.AddHours(-$Hours).ToString('yyyy-MM-ddTHH:mm:ssZ', $culture)
    $rec = ConvertTo-PrRecord -PullRequest (New-FakePr $Id $created $ClosedUtc) -Repository $Repo -Size (New-PrSizeResult) `
        -Config (New-TestConfig) -TimeZone $tokyo -WebBaseUrl 'x'
    $rec.Status = $Status
    $rec.SizeCategory = $SizeCategory
    return $rec
}

function New-LeadTimeTestData {
    # 範囲 2026-09-03(木)〜09-30(水)。週(月曜始まり): 8/31(4日分), 9/7, 9/14, 9/21, 9/28(3日分)
    $config = New-TestConfig @{ FromDate = '2026-09-03'; ToDate = '2026-09-30' }
    $range = Get-PrMetricsDateRange -Config $config -TimeZone $tokyo
    $active = ConvertTo-PrRecord -PullRequest (New-FakePr 6 '2026-09-10T00:00:00Z' '') -Repository 'RepoA' -Size (New-PrSizeResult) `
        -Config $config -TimeZone $tokyo -WebBaseUrl 'x'
    $active.Status = 'active'
    $records = @(
        New-LeadTimeRecord 1 '2026-09-03T01:00:00Z' 5 -SizeCategory 'XS'     # 8/31 の週・24時間未満・小
        New-LeadTimeRecord 2 '2026-09-04T00:00:00Z' 30 -SizeCategory 'M'     # 8/31 の週・24〜72時間・中
        New-LeadTimeRecord 3 '2026-09-15T00:00:00Z' 100 -SizeCategory 'XL'   # 9/14 の週・72時間以上・大
        New-LeadTimeRecord 4 '2026-09-15T00:00:00Z' 5 -Status 'abandoned' -SizeCategory 'S'   # 数えない
        New-LeadTimeRecord 5 '2026-09-29T00:00:00Z' 72                       # 9/28 の週・72時間以上（境界）・サイズ不明
        $active                                                              # 完了日時なし → 数えない
    )
    return @{ Config = $config; Range = $range; Records = $records }
}

It '週次集計: マージ済みだけ数え、0 件の週と端の週の日数を出す' {
    $d = New-LeadTimeTestData
    $all = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    Assert-Equal 20 $all.Count '（5 週 × 全体・大・中・小）'
    $rows = @($all | Where-Object { $_.SizeGroup -eq 'All' })
    Assert-Equal 5 $rows.Count
    Assert-Equal 'RepoA' $rows[0].Repository
    Assert-Equal '2026-08-31' $rows[0].WeekStart
    Assert-Equal '2026-09-06' $rows[0].WeekEnd
    Assert-Equal 4 $rows[0].Days
    Assert-Equal $true $rows[0].IsPartial
    Assert-Equal 1 $rows[0].Under24h
    Assert-Equal 1 $rows[0].From24To72h
    Assert-Equal 0 $rows[0].Over72h
    Assert-Equal 2 $rows[0].Total
    Assert-Equal '2026-09-13' $rows[1].WeekEnd
    Assert-Equal 7 $rows[1].Days
    Assert-Equal $false $rows[1].IsPartial
    Assert-Equal 0 $rows[1].Total
    Assert-Equal 0 $rows[2].Under24h '（abandoned は数えない）'
    Assert-Equal 1 $rows[2].Over72h
    Assert-Equal '2026-09-30' $rows[4].WeekEnd
    Assert-Equal 3 $rows[4].Days
    Assert-Equal 1 $rows[4].Over72h
}
It '週次集計: 日曜 23:30(日本時間)完了はその週、月曜 00:30 は翌週' {
    $config = New-TestConfig @{ FromDate = '2026-09-07'; ToDate = '2026-09-20' }
    $range = Get-PrMetricsDateRange -Config $config -TimeZone $tokyo
    $records = @(
        New-LeadTimeRecord 1 '2026-09-13T14:30:00Z' 1   # 9/13(日) 23:30 JST
        New-LeadTimeRecord 2 '2026-09-13T15:30:00Z' 1   # 9/14(月) 00:30 JST
    )
    $rows = @(Get-LeadTimeWeeklySummary -Records $records -Config $config -Range $range | Where-Object { $_.SizeGroup -eq 'All' })
    Assert-Equal 2 $rows.Count
    Assert-Equal 1 $rows[0].Under24h
    Assert-Equal 1 $rows[1].Under24h
}
It '週次集計: 複数リポジトリでは (ALL) の行が追加される' {
    $config = New-TestConfig @{ FromDate = '2026-09-07'; ToDate = '2026-09-13'; Repositories = @('RepoA', 'RepoB') }
    $range = Get-PrMetricsDateRange -Config $config -TimeZone $tokyo
    $records = @(
        New-LeadTimeRecord 1 '2026-09-08T00:00:00Z' 1 -Repo 'RepoA'
        New-LeadTimeRecord 2 '2026-09-08T00:00:00Z' 30 -Repo 'RepoB'
    )
    $rows = @(Get-LeadTimeWeeklySummary -Records $records -Config $config -Range $range | Where-Object { $_.SizeGroup -eq 'All' })
    Assert-Equal 3 $rows.Count
    Assert-Equal 'RepoA' $rows[0].Repository
    Assert-Equal 1 $rows[0].Total
    Assert-Equal 'RepoB' $rows[1].Repository
    Assert-Equal 1 $rows[1].From24To72h
    Assert-Equal '(ALL)' $rows[2].Repository
    Assert-Equal 2 $rows[2].Total
}
It '週次集計: 全体・大・中・小の行があり、サイズ不明は全体だけに入る' {
    $d = New-LeadTimeTestData
    $all = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    Assert-Equal 'Repository,SizeGroup,WeekStart,WeekEnd,Days,IsPartial,Under24h,From24To72h,Over72h,Total' (($all[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ',')
    Assert-Equal 'All,Large,Medium,Small' ((@($all | ForEach-Object { $_.SizeGroup } | Select-Object -Unique)) -join ',')
    $week1 = @($all | Where-Object { $_.WeekStart -eq '2026-08-31' })
    Assert-Equal 2 @($week1 | Where-Object { $_.SizeGroup -eq 'All' })[0].Total
    Assert-Equal 0 @($week1 | Where-Object { $_.SizeGroup -eq 'Large' })[0].Total
    Assert-Equal 1 @($week1 | Where-Object { $_.SizeGroup -eq 'Medium' })[0].From24To72h
    Assert-Equal 1 @($week1 | Where-Object { $_.SizeGroup -eq 'Small' })[0].Under24h
    Assert-Equal 1 @($all | Where-Object { $_.WeekStart -eq '2026-09-14' -and $_.SizeGroup -eq 'Large' })[0].Over72h
    $week5 = @($all | Where-Object { $_.WeekStart -eq '2026-09-28' })
    Assert-Equal 1 @($week5 | Where-Object { $_.SizeGroup -eq 'All' })[0].Over72h '（サイズ不明でも全体には入る）'
    Assert-Equal 0 (($week5 | Where-Object { $_.SizeGroup -ne 'All' } | Measure-Object -Property Total -Sum).Sum) '（サイズ不明は大中小に入らない）'
}
It '日次集計: 範囲内の全日を出し、日本時間の日付で数える' {
    $config = New-TestConfig @{ FromDate = '2026-09-07'; ToDate = '2026-09-13' }
    $range = Get-PrMetricsDateRange -Config $config -TimeZone $tokyo
    $records = @(
        New-LeadTimeRecord 1 '2026-09-08T14:59:00Z' 5 -SizeCategory 'S'    # 9/8 23:59 JST
        New-LeadTimeRecord 2 '2026-09-08T15:00:00Z' 30 -SizeCategory 'L'   # 9/9 00:00 JST
    )
    $all = @(Get-LeadTimeDailySummary -Records $records -Config $config -Range $range)
    Assert-Equal 28 $all.Count '（7 日 × 全体・大・中・小）'
    Assert-Equal 'Repository,SizeGroup,Date,Under24h,From24To72h,Over72h,Total' (($all[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ',')
    $rows = @($all | Where-Object { $_.SizeGroup -eq 'All' })
    Assert-Equal 7 $rows.Count
    Assert-Equal '2026-09-07' $rows[0].Date
    Assert-Equal '2026-09-13' $rows[6].Date
    Assert-Equal 0 $rows[0].Total '（0 件の日も出る）'
    Assert-Equal 1 $rows[1].Under24h '（9/8 23:59 は 9/8）'
    Assert-Equal 1 $rows[2].From24To72h '（9/9 00:00 は 9/9）'
    Assert-Equal 1 @($all | Where-Object { $_.SizeGroup -eq 'Small' -and $_.Date -eq '2026-09-08' })[0].Under24h
    Assert-Equal 1 @($all | Where-Object { $_.SizeGroup -eq 'Large' -and $_.Date -eq '2026-09-09' })[0].From24To72h
}
It '日次集計: 複数リポジトリでは (ALL) の行が追加される' {
    $config = New-TestConfig @{ FromDate = '2026-09-07'; ToDate = '2026-09-07'; Repositories = @('RepoA', 'RepoB') }
    $range = Get-PrMetricsDateRange -Config $config -TimeZone $tokyo
    $records = @(
        New-LeadTimeRecord 1 '2026-09-07T01:00:00Z' 1 -Repo 'RepoA'
        New-LeadTimeRecord 2 '2026-09-07T01:00:00Z' 30 -Repo 'RepoB'
    )
    $rows = @(Get-LeadTimeDailySummary -Records $records -Config $config -Range $range | Where-Object { $_.SizeGroup -eq 'All' })
    Assert-Equal 3 $rows.Count
    Assert-Equal '(ALL)' $rows[2].Repository
    Assert-Equal 2 $rows[2].Total
}

function Measure-Match {
    param([string]$Text, [string]$Pattern)
    return ([regex]::Matches($Text, $Pattern)).Count
}

It 'SVG: 折れ線 3 本・端の週の点は白抜き・ツールチップと * 付きラベル' {
    $d = New-LeadTimeTestData
    $rows = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range | Where-Object { $_.SizeGroup -eq 'All' })
    $svg = New-LeadTimeChartSvg -Rows $rows
    Assert-Equal 3 (Measure-Match $svg '<polyline ')
    Assert-Equal 15 (Measure-Match $svg 'class="point( partial)?"') '（5 週 × 3 本）'
    Assert-Equal 6 (Measure-Match $svg 'class="point partial"') '（端の週 2 つ × 3 本）'
    if (-not $svg.Contains('<title>08/31 の週 24時間未満: 1件</title>')) { throw 'ツールチップが無い' }
    if (-not $svg.Contains('>09/28*</text>')) { throw '端の週のラベルに * が無い' }
    Assert-Equal '' (New-LeadTimeChartSvg -Rows @())
}
It 'SVG: 週が多いと横軸ラベルを間引く（26 週 → 9 個）' {
    $rows = @(1..26 | ForEach-Object {
            [pscustomobject]@{
                WeekStart = ([datetime]'2026-01-05').AddDays(7 * ($_ - 1)).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
                Days = 7; IsPartial = $false; Under24h = $_; From24To72h = 0; Over72h = 0; Total = $_
            }
        })
    Assert-Equal 9 (Measure-Match (New-LeadTimeChartSvg -Rows $rows) 'class="x-label"')
}
It 'SVG(日単位): 日付ラベルとツールチップ（「の週」が付かない）・白抜きなし' {
    $rows = @(1..3 | ForEach-Object {
            [pscustomobject]@{ Date = ('2026-09-0{0}' -f $_); Under24h = $_; From24To72h = 0; Over72h = 0; Total = $_ }
        })
    $svg = New-LeadTimeChartSvg -Rows $rows -Unit Day
    if (-not $svg.Contains('<title>09/02 24時間未満: 2件</title>')) { throw 'ツールチップが日単位の形式になっていない' }
    if ($svg.Contains('の週')) { throw '日単位なのに「の週」が付いている' }
    if (-not $svg.Contains('>09/01</text>')) { throw '日付ラベルが無い' }
    if (-not $svg.Contains('日次推移')) { throw 'aria-label が日次になっていない' }
    Assert-Equal 0 (Measure-Match $svg 'class="point partial"')
    Assert-Equal 9 (Measure-Match $svg 'class="point"')
}
It 'SVG: -YMax で縦軸の上限をそろえられる（データの方が大きければデータに合わせる）' {
    $small = [pscustomobject]@{ WeekStart = '2026-09-07'; Days = 7; IsPartial = $false; Under24h = 1; From24To72h = 0; Over72h = 0; Total = 1 }
    $big = [pscustomobject]@{ WeekStart = '2026-09-14'; Days = 7; IsPartial = $false; Under24h = 12; From24To72h = 0; Over72h = 0; Total = 12 }
    Assert-Equal 1 (Measure-Match (New-LeadTimeChartSvg -Rows @($small) -YMax 8) 'class="y-label"[^>]*>8</text>')
    Assert-Equal 0 (Measure-Match (New-LeadTimeChartSvg -Rows @($small)) 'class="y-label"[^>]*>8</text>')
    Assert-Equal 1 (Measure-Match (New-LeadTimeChartSvg -Rows @($big) -YMax 3) 'class="y-label"[^>]*>12</text>')
    Assert-Equal 12 (Get-LeadTimeMaxCount -Rows @($small, $big))
    Assert-Equal 0 (Get-LeadTimeMaxCount -Rows @())
}
It '描き方の切り替え: 対応表どおりの描画関数を使い、未知の値は例外' {
    $rows = @([pscustomobject]@{ Date = '2026-09-01'; Under24h = 1; From24To72h = 0; Over72h = 0; Total = 1 })
    Assert-Equal (New-LeadTimeChartSvg -Rows $rows -Unit Day -YMax 4) (New-LeadTimeChart -Rows $rows -Unit Day -YMax 4)
    Assert-Equal 'Line' $script:LeadTimeChartStyles.Week
    Assert-Equal 'Line' $script:LeadTimeChartStyles.Day
    Assert-Equal 'All,Large,Medium,Small' ($script:LeadTimeDailySizeGroups -join ',')
    $saved = $script:LeadTimeChartStyles.Day
    try {
        $script:LeadTimeChartStyles.Day = 'Bogus'
        Assert-Throws { New-LeadTimeChart -Rows $rows -Unit Day } -Like '*Bogus*'
    }
    finally { $script:LeadTimeChartStyles.Day = $saved }
}
function Assert-Contains {
    param([string]$Text, [string]$Expected)
    if (-not $Text.Contains($Expected)) { throw "[$Expected] が含まれていない" }
}

It 'HTML: 見出し・凡例・グラフ・注記・表があり、記号はエスケープされる' {
    $d = New-LeadTimeTestData
    $d.Config.Project = 'P<&>'
    $rows = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range | Where-Object { $_.SizeGroup -eq 'All' })
    $html = New-LeadTimeChartHtml -Summary $rows -Config $d.Config -Range $d.Range -GeneratedAt ([datetime]'2026-10-09 10:00')
    Assert-Contains $html '<meta charset="utf-8">'
    Assert-Contains $html '<h1>クローズまでの時間別 PR 件数（週次）</h1>'
    Assert-Contains $html '2026-09-03 〜 2026-09-30'
    Assert-Contains $html 'P&lt;&amp;&gt;'
    if ($html.Contains('P<&>')) { throw 'プロジェクト名がエスケープされていない' }
    Assert-Contains $html '<h2>RepoA</h2>'
    Assert-Contains $html '24〜72時間未満'
    Assert-Contains $html '<svg '
    Assert-Contains $html '* 08/31 の週は 4 日分'
    Assert-Contains $html '* 09/28 の週は 3 日分'
    Assert-Contains $html '<table>'
    Assert-Contains $html '<td class="left">2026-09-14</td>'
    if ($html.Contains('対象の PR がありません')) { throw 'PR があるのに「対象の PR がありません」が出ている' }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) "prm_chart_$([guid]::NewGuid().ToString('N')).html"
    try {
        Export-PrMetricsHtml -Html $html -Path $tmp
        Assert-Equal $html ([IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8))
    }
    finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}
It 'HTML: 対象の PR が 0 件でもグラフを出し、その旨を表示する' {
    $d = New-LeadTimeTestData
    $rows = @(Get-LeadTimeWeeklySummary -Records @() -Config $d.Config -Range $d.Range | Where-Object { $_.SizeGroup -eq 'All' })
    $html = New-LeadTimeChartHtml -Summary $rows -Config $d.Config -Range $d.Range
    Assert-Contains $html '対象の PR がありません'
    Assert-Contains $html '<svg '
}

It 'HTML: 週の始まりの曜日名が設定どおりに日本語で出る（既定は月曜日）' {
    $d = New-LeadTimeTestData
    $rows = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range | Where-Object { $_.SizeGroup -eq 'All' })
    Assert-Contains (New-LeadTimeChartHtml -Summary $rows -Config $d.Config -Range $d.Range) '週の始まり: 月曜日'

    $d.Config.WeekStartDay = 'Sunday'
    $rows = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range | Where-Object { $_.SizeGroup -eq 'All' })
    Assert-Contains (New-LeadTimeChartHtml -Summary $rows -Config $d.Config -Range $d.Range) '週の始まり: 日曜日'
}

It 'グラフは DateBasis=Closed のときだけ作る' {
    Assert-Equal $true (Test-LeadTimeChartEnabled -Config (New-TestConfig))
    Assert-Equal $false (Test-LeadTimeChartEnabled -Config (New-TestConfig @{ DateBasis = 'Created' }))
}

Write-Host '== Git 方式（実リポジトリ）'
$gitAvailable = $false
try { $gitAvailable = (Invoke-Git -Arguments @('--version')).ExitCode -eq 0 } catch { }
if (-not $gitAvailable) {
    Write-Host '  [SKIP] git が無いためスキップ' -ForegroundColor Yellow
}
else {
    $repoDir = Join-Path ([IO.Path]::GetTempPath()) "prm_git_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $repoDir | Out-Null
    # param を書かない関数にして、-q や -A などを git の引数として $args で受け取る
    function G { $r = Invoke-Git -RepoPath $repoDir -Arguments (@('-c', 'user.name=t', '-c', 'user.email=t@t') + $args); if ($r.ExitCode -ne 0) { throw "git $args : $($r.Error)" }; return ($r.Output -join "`n") }
    function Write-Lines { param([string]$Name, [int]$Count) $p = Join-Path $repoDir $Name; New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null; [IO.File]::WriteAllLines($p, [string[]](1..$Count | ForEach-Object { "line $_" })) }
    try {
        G init -q -b main | Out-Null
        Write-Lines 'src/a.c' 10; G add -A | Out-Null; G commit -q -m init | Out-Null
        $base = G rev-parse HEAD

        # feature: a.c に 5 行追加、b.c 新規 3 行、fw.hex 100 行（除外対象）
        G checkout -q -b feature | Out-Null
        Write-Lines 'src/a.c' 15; Write-Lines 'src/b.c' 3; Write-Lines 'out/fw.hex' 100
        G add -A | Out-Null; G commit -q -m feature | Out-Null
        $source = G rev-parse HEAD

        # main 側も別ファイルが進む（PR の差分に含めてはいけない）
        G checkout -q main | Out-Null
        Write-Lines 'docs/readme.txt' 50; G add -A | Out-Null; G commit -q -m 'main moves' | Out-Null
        $target = G rev-parse HEAD

        # 通常マージ
        G merge -q --no-ff feature -m 'Merge PR' | Out-Null
        $merge = G rev-parse HEAD

        $pr = [pscustomobject]@{
            pullRequestId         = 1
            lastMergeTargetCommit = [pscustomobject]@{ commitId = $target }
            lastMergeSourceCommit = [pscustomobject]@{ commitId = $source }
            lastMergeCommit       = [pscustomobject]@{ commitId = $merge }
        }
        It 'マージコミット方式: PR の変更だけを数える（main 側の変更・除外ファイルは含めない）' {
            $s = Get-PrSizeFromGit -RepoPath $repoDir -PullRequest $pr -ExcludePatterns @('*.hex') -FetchMissing $false
            Assert-Equal 'git:target..merge' $s.SizeSource
            Assert-Equal 2 $s.FilesChanged
            Assert-Equal 8 $s.LinesAdded
            Assert-Equal 0 $s.LinesDeleted
            Assert-Equal 1 $s.ExcludedFiles
        }
        It 'マージコミットが無い場合は共通祖先方式にフォールバック' {
            $pr2 = [pscustomobject]@{ pullRequestId = 2; lastMergeTargetCommit = $pr.lastMergeTargetCommit; lastMergeSourceCommit = $pr.lastMergeSourceCommit
                lastMergeCommit = [pscustomobject]@{ commitId = '0123456789abcdef0123456789abcdef01234567' } }
            $s = Get-PrSizeFromGit -RepoPath $repoDir -PullRequest $pr2 -ExcludePatterns @('*.hex') -FetchMissing $false
            Assert-Equal 'git:base...source' $s.SizeSource
            Assert-Equal 8 $s.LinesAdded
            if ($s.SizeNote -notlike '*target..merge*') { throw "SizeNote にフォールバック理由が無い: $($s.SizeNote)" }
        }
        It 'どのコミットも無ければ unavailable' {
            $none = [pscustomobject]@{ commitId = 'ffffffffffffffffffffffffffffffffffffffff' }
            $pr3 = [pscustomobject]@{ pullRequestId = 3; lastMergeTargetCommit = $none; lastMergeSourceCommit = $none; lastMergeCommit = $none }
            $s = Get-PrSizeFromGit -RepoPath $repoDir -PullRequest $pr3 -FetchMissing $false
            Assert-Equal 'unavailable' $s.SizeSource
            Assert-Equal $null $s.LinesChanged
        }
    }
    finally {
        Remove-Item -LiteralPath $repoDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($script:failed.Count -gt 0) {
    Write-Host "結果: $($script:passed) 件成功 / $($script:failed.Count) 件失敗" -ForegroundColor Red
    $script:failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "結果: $($script:passed) 件すべて成功" -ForegroundColor Green
exit 0
