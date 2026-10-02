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
foreach ($file in @('Config.ps1', 'AzDoClient.ps1', 'SizeCalculator.ps1', 'Aggregator.ps1', 'Output.ps1')) {
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
