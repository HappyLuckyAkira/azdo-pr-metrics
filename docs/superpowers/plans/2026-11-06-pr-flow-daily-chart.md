# PR の作成数・滞留数・Close 数の日次棒グラフ 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 日ごとの PR の作成数・滞留数・Close 数を 3 本の棒（日と日の間に空白）で表すグラフを `leadtime_chart.html` の各リポジトリの最後に追加し、`summary_pr_flow_daily.csv` を出力する。

**Architecture:** 新規 `src/PrFlowChart.ps1` に「API の PR → 記録への変換 → 日ごとの集計 → 棒グラフ SVG → HTML の節」を置く。データはグラフを作るときだけ `Get-AzDoPullRequestsForFlow`（active 全件 ＋ 開始時点以降にクローズした completed/abandoned）で追加取得し、既存の取得・出力は変えない。絞り込み（Draft・ブランチ・作成者）は `Test-PullRequestFilterMatch` に切り出して共通化する。

**Tech Stack:** PowerShell（Windows PowerShell 5.1 と PowerShell 7）、インライン SVG、自作テストランナー `tests/Run-Tests.ps1`

**仕様書:** [docs/superpowers/specs/2026-11-06-pr-flow-daily-chart-design.md](../specs/2026-11-06-pr-flow-daily-chart-design.md)

## Global Constraints

- PowerShell 5.1 と 7 の両方で動くこと。`??`・`?.`・三項演算子・`&&`/`||`・`ConvertFrom-Json -AsHashtable`・3 引数以上の `Join-Path` は使わない
- `.ps1` / `.psd1` は UTF-8（BOM 付き）で保存する（新規ファイルも）
- 関数から配列を返すときに `return , $array` を使わない。呼び出し側で `@(...)` で受ける
- `Set-StrictMode` は使わない。空のコレクションを受ける引数に `[Parameter(Mandatory)]` を付けない
- Azure DevOps へは GET だけ。API 呼び出しは `Get-AzDoPullRequests`（→ `Invoke-AzDoApi`）経由
- 外部ライブラリ・外部通信なし（HTML は単一ファイル、グラフはインライン SVG）
- 設定項目は追加しない。既存の出力（prs.csv・既存の CSV・既存のグラフ）の内容は変えない
- 定義: 作成 `Created` = その日に作成 / 滞留 `Open` = その日の終わり（翌日 0:00）に作成済みかつ未クローズ / Close `Closed` = その日に completed または abandoned。日は設定タイムゾーンの日付。毎日 `Open(当日) = Open(前日) + Created(当日) − Closed(当日)`
- 対象 PR には Draft の除外・マージ先ブランチ・除外する作成者を適用する（期間の絞り込みは使わない）
- 棒の順序と色: 作成 `#1565c0` → 滞留 `#8e24aa` → Close `#00897b`。1 日の枠の 75% に 3 本を隙間なく並べ、25% を日と日の間の空白にする
- 例に実名を使わない（`contoso` / `SampleProject` / `SampleRepo` / `example.com`）。公開リポジトリ
- コミットメッセージは日本語、`feat:` / `docs:` / `test:` / `refactor:` を付け、末尾に `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## ファイル構成

| ファイル | 変更 |
|---|---|
| `src/PrFlowChart.ps1`（新規） | `ConvertTo-PrFlowRecord`、`Get-PrFlowDailySummary`、`$script:PrFlowSeries`、`New-PrFlowBarChartSvg`、`New-PrFlowSectionHtml` |
| `src/Aggregator.ps1` | `Test-PullRequestFilterMatch` を切り出し、`Test-PullRequestIncluded` から呼ぶ |
| `src/AzDoClient.ps1` | `Get-AzDoPullRequestsForFlow` |
| `src/LeadTimeChart.ps1` | 縦軸の共通部品 `Get-ChartYAxis`・`New-ChartYAxisSvg`、`New-LeadTimeChartHtml -FlowSummary` |
| `Invoke-PrMetrics.ps1` | 追加取得・Replay・保存、CSV 出力、HTML への受け渡し |
| `tests/Run-Tests.ps1` | テスト |
| `docs/`・`README.md`・`AGENTS.md` | 資料（ADR-0003 を含む） |

## テストの実行コマンド（全タスク共通）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
pwsh -NoProfile -File .\tests\Run-Tests.ps1
```

作業前の件数は `結果: 42 件すべて成功`（git がある環境）。Git Bash から実行する場合は `| iconv -f cp932 -t utf-8` を付ける。

## BOM の付け方（新規 .ps1 を作ったとき）

```powershell
$p = 'src\PrFlowChart.ps1'
$t = [IO.File]::ReadAllText($p)
[IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding $true))
```

---

### Task 1: 絞り込みの共通化・記録への変換・日次集計

**Files:**
- Create: `src/PrFlowChart.ps1`
- Modify: `src/Aggregator.ps1`（`Test-PullRequestIncluded`）
- Modify: `tests/Run-Tests.ps1`

**Interfaces:**
- Consumes: 既存の `ConvertTo-UtcDateTime`（`src/Config.ps1`）、`Get-PeriodStarts -Range -Unit Day`・`Get-RecordGroups -Records -Repositories`（`src/Aggregator.ps1`）、テストの `New-FakePr`・`New-TestConfig`・`$tokyo`
- Produces:
  - `Test-PullRequestFilterMatch -PullRequest <API の PR> -Config <hashtable>` → `[bool]`（Draft・マージ先ブランチ・除外作成者だけを判定）
  - `ConvertTo-PrFlowRecord -PullRequest -Repository <string> -TimeZone <TimeZoneInfo>` → `[pscustomobject]@{ Repository; PullRequestId [int]; Status; CreatedLocal [datetime]; ClosedLocal [datetime or $null] }`。作成日時が無ければ何も返さない
  - `Get-PrFlowDailySummary -Records -Config -Range` → 行の配列。列 `Repository, Date (yyyy-MM-dd), Created, Open, Closed`。並び: リポジトリ（複数なら最後に `(ALL)`）→ 日付の昇順

- [ ] **Step 1: 新規ファイルを作り、テストの読み込みリストに追加する**

`src/PrFlowChart.ps1` を次の内容で作り、BOM を付ける。

```powershell
# =============================================================================
# PrFlowChart.ps1
#   日ごとの PR の作成数・滞留数・Close 数を集計し、3 本の棒を並べた棒グラフ
#   （SVG を埋め込んだ HTML の 1 節）を作る。
#   仕様: docs\superpowers\specs\2026-11-06-pr-flow-daily-chart-design.md
#   詳細設計: docs\05_詳細設計.md「PrFlowChart.ps1」、判断の記録: docs\adr\ADR-0003
# =============================================================================
```

`tests/Run-Tests.ps1` の読み込みリスト（16 行目付近）を次に変える。

```powershell
foreach ($file in @('Config.ps1', 'AzDoClient.ps1', 'SizeCalculator.ps1', 'Aggregator.ps1', 'Output.ps1', 'LeadTimeChart.ps1', 'PrFlowChart.ps1')) {
```

- [ ] **Step 2: 失敗するテストを書く**

`tests/Run-Tests.ps1` の `Write-Host '== Git 方式（実リポジトリ）'` の**直前**に追加する。

```powershell
Write-Host '== PrFlowChart'
function New-FlowPr {
    # API 形式の PR（状態・作成日時・クローズ日時を指定）
    param([int]$Id, [string]$Created, [string]$Closed = '', [string]$Status = 'completed', [string]$Author = 'Taro', [string]$Target = 'refs/heads/main', [bool]$Draft = $false)
    $pr = New-FakePr $Id $Created $Closed -Author $Author -Target $Target -Draft $Draft
    $pr.status = $Status
    return $pr
}

It '絞り込みの共通化: Draft・マージ先ブランチ・除外作成者だけを見る（期間は見ない）' {
    $c = New-TestConfig @{ TargetBranches = @('refs/heads/main'); ExcludeAuthors = @('Bot') }
    Assert-Equal $true (Test-PullRequestFilterMatch -PullRequest (New-FlowPr 1 '2020-01-01T00:00:00Z' -Status 'active') -Config $c)
    Assert-Equal $false (Test-PullRequestFilterMatch -PullRequest (New-FlowPr 2 '2020-01-01T00:00:00Z' -Status 'active' -Draft $true) -Config $c)
    Assert-Equal $false (Test-PullRequestFilterMatch -PullRequest (New-FlowPr 3 '2020-01-01T00:00:00Z' -Status 'active' -Target 'refs/heads/dev') -Config $c)
    Assert-Equal $false (Test-PullRequestFilterMatch -PullRequest (New-FlowPr 4 '2020-01-01T00:00:00Z' -Status 'active' -Author 'Bot') -Config $c)
}
It '作成・滞留・Close 用の記録: active はクローズなし、破棄はクローズ扱い、作成日時なしは除く' {
    $a = ConvertTo-PrFlowRecord -PullRequest (New-FlowPr 1 '2026-09-05T01:00:00Z' -Status 'active') -Repository 'RepoA' -TimeZone $tokyo
    Assert-Equal ([datetime]'2026-09-05 10:00') $a.CreatedLocal
    Assert-Equal $null $a.ClosedLocal
    $b = ConvertTo-PrFlowRecord -PullRequest (New-FlowPr 2 '2026-09-08T01:00:00Z' '2026-09-08T09:00:00Z' -Status 'abandoned') -Repository 'RepoA' -TimeZone $tokyo
    Assert-Equal ([datetime]'2026-09-08 18:00') $b.ClosedLocal
    Assert-Equal 'RepoA' $b.Repository
    Assert-Equal 2 $b.PullRequestId
    Assert-Equal 'abandoned' $b.Status
    Assert-Equal $null (ConvertTo-PrFlowRecord -PullRequest (New-FlowPr 3 '' -Status 'active') -Repository 'RepoA' -TimeZone $tokyo)
}

function New-FlowTestData {
    # 範囲 2026-09-07〜09-09（日本時間）
    $config = New-TestConfig @{ FromDate = '2026-09-07'; ToDate = '2026-09-09' }
    $range = Get-PrMetricsDateRange -Config $config -TimeZone $tokyo
    $prs = @(
        New-FlowPr 1 '2026-09-05T01:00:00Z' -Status 'active'                              # A: 範囲前に作成・開いたまま
        New-FlowPr 2 '2026-09-07T00:00:00Z' '2026-09-08T06:00:00Z'                          # B: 9/7 作成 → 9/8 マージ
        New-FlowPr 3 '2026-09-08T01:00:00Z' '2026-09-08T09:00:00Z' -Status 'abandoned'      # C: 9/8 作成・同日破棄
        New-FlowPr 4 '2026-09-06T01:00:00Z' '2026-09-07T14:59:00Z'                          # D: 範囲前に作成 → 9/7 23:59 マージ
        New-FlowPr 5 '2026-09-09T00:00:00Z' '2026-09-09T16:00:00Z'                          # E: 9/9 作成 → 9/10 01:00（範囲後）マージ
    )
    $records = @($prs | ForEach-Object { ConvertTo-PrFlowRecord -PullRequest $_ -Repository 'RepoA' -TimeZone $tokyo })
    return @{ Config = $config; Range = $range; Records = $records }
}

It '日次の作成・滞留・Close: 範囲前の PR・同日作成クローズ・範囲後クローズ・日付の境目' {
    $d = New-FlowTestData
    $rows = @(Get-PrFlowDailySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    Assert-Equal 3 $rows.Count
    Assert-Equal 'Repository,Date,Created,Open,Closed' (($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ',')
    Assert-Equal '2026-09-07' $rows[0].Date
    Assert-Equal 1 $rows[0].Created '（9/7: B）'
    Assert-Equal 2 $rows[0].Open '（9/7 の終わり: A, B）'
    Assert-Equal 1 $rows[0].Closed '（9/7: D の 23:59）'
    Assert-Equal 1 $rows[1].Created '（9/8: C）'
    Assert-Equal 1 $rows[1].Open '（9/8 の終わり: A）'
    Assert-Equal 2 $rows[1].Closed '（9/8: B, C）'
    Assert-Equal 1 $rows[2].Created '（9/9: E）'
    Assert-Equal 2 $rows[2].Open '（9/9 の終わり: A, E）'
    Assert-Equal 0 $rows[2].Closed '（E のクローズは 9/10 01:00）'
    for ($i = 1; $i -lt $rows.Count; $i++) {
        Assert-Equal ($rows[$i - 1].Open + $rows[$i].Created - $rows[$i].Closed) $rows[$i].Open '（滞留 = 前日の滞留 + 作成 - Close）'
    }
}
It '日次の作成・滞留・Close: 複数リポジトリでは (ALL) の行が追加される' {
    $config = New-TestConfig @{ FromDate = '2026-09-07'; ToDate = '2026-09-07'; Repositories = @('RepoA', 'RepoB') }
    $range = Get-PrMetricsDateRange -Config $config -TimeZone $tokyo
    $records = @(
        ConvertTo-PrFlowRecord -PullRequest (New-FlowPr 1 '2026-09-01T00:00:00Z' -Status 'active') -Repository 'RepoA' -TimeZone $tokyo
        ConvertTo-PrFlowRecord -PullRequest (New-FlowPr 2 '2026-09-07T01:00:00Z' -Status 'active') -Repository 'RepoB' -TimeZone $tokyo
    )
    $rows = @(Get-PrFlowDailySummary -Records $records -Config $config -Range $range)
    Assert-Equal 3 $rows.Count
    Assert-Equal '(ALL)' $rows[2].Repository
    Assert-Equal 1 $rows[2].Created
    Assert-Equal 2 $rows[2].Open
}

```

- [ ] **Step 3: テストが失敗することを確認する**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`
Expected: 追加した 4 件が `[FAIL]`（関数が認識されない）、`結果: 42 件成功 / 4 件失敗`

- [ ] **Step 4: `Test-PullRequestFilterMatch` を切り出す**

`src/Aggregator.ps1` の `function Test-PullRequestIncluded { ... }`（関数全体）を、次の 2 つの関数で置き換える（`Test-PullRequestIncluded` の動作は変えない）。

```powershell
function Test-PullRequestFilterMatch {
    <#
    .SYNOPSIS
        PR が期間以外の絞り込み（Draft・マージ先ブランチ・除外作成者）に合うか判定する。
        期間の判定が要らない集計（作成・滞留・Close）でも同じ条件を使うため、Test-PullRequestIncluded から切り出している。
    .OUTPUTS
        合えば $true
    #>
    param(
        [Parameter(Mandatory)]$PullRequest,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ($Config.ExcludeDrafts -and $PullRequest.PSObject.Properties['isDraft'] -and $PullRequest.isDraft) { return $false }

    if ($Config.TargetBranches.Count -gt 0 -and $Config.TargetBranches -notcontains [string]$PullRequest.targetRefName) { return $false }

    if ($Config.ExcludeAuthors.Count -gt 0 -and $null -ne $PullRequest.createdBy) {
        foreach ($name in @([string]$PullRequest.createdBy.displayName, [string]$PullRequest.createdBy.uniqueName)) {
            if ($name -and $Config.ExcludeAuthors -contains $name) { return $false }
        }
    }
    return $true
}

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

    return (Test-PullRequestFilterMatch -PullRequest $PullRequest -Config $Config)
}
```

- [ ] **Step 5: 記録への変換と日次集計を実装する**

`src/PrFlowChart.ps1` の末尾に追加する。

```powershell

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
```

- [ ] **Step 6: テストが通ることを確認する（5.1 と 7）**

Run: テストの実行コマンド（2 つとも）
Expected: `結果: 46 件すべて成功`（既存の対象判定のテストもそのまま通ること）

- [ ] **Step 7: コミット**

```bash
git add src/PrFlowChart.ps1 src/Aggregator.ps1 tests/Run-Tests.ps1
git commit -m "feat: PR の作成数・滞留数・Close 数の日次集計を追加" -m "期間以外の絞り込み（Draft・ブランチ・作成者）を Test-PullRequestFilterMatch に切り出して共通化した（Test-PullRequestIncluded の動作は変えない）。" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: 追加取得 `Get-AzDoPullRequestsForFlow`

**Files:**
- Modify: `src/AzDoClient.ps1`（`function Get-AzDoPullRequests { ... }` の直後に追加）
- Modify: `tests/Run-Tests.ps1`

**Interfaces:**
- Consumes: 既存の `Get-AzDoPullRequests -Context -Repository -Status -FromUtc -ToUtcExclusive -DateBasis -PageSize -ServerSideDateFilter`、テストの `New-FlowPr`（Task 1）
- Produces: `Get-AzDoPullRequestsForFlow -Context -Repository <string> -FromUtc <datetime> [-PageSize <int>] [-ServerSideDateFilter <bool>]` → API の PR オブジェクトの配列（`pullRequestId` で重複除去。順序は active → completed → abandoned）

- [ ] **Step 1: 失敗するテストを書く**

`tests/Run-Tests.ps1` の `It '日次の作成・滞留・Close: 複数リポジトリでは (ALL) の行が追加される' { ... }` の**直後**に追加する。テスト内で `Get-AzDoPullRequests` を同じ名前の関数で差し替え、呼び出し条件を記録する（PowerShell は呼び出し元のスコープの関数を優先して探すため、テストの中だけで差し替わる）。

```powershell
It '追加取得: active は期間なし、completed・abandoned はクローズが開始以降（上限は実行時点より先）、重複は除く' {
    $calls = New-Object System.Collections.Generic.List[string]
    function Get-AzDoPullRequests {
        param($Context, $Repository, $Status, $FromUtc, $ToUtcExclusive, $DateBasis, $PageSize, $ServerSideDateFilter)
        $calls.Add(('{0}|{1}|{2}|{3}' -f $Status, $DateBasis, $ServerSideDateFilter, ($ToUtcExclusive -gt [datetime]::UtcNow)))
        switch ($Status) {
            'active' { New-FlowPr 4 '2026-09-01T00:00:00Z' -Status 'active' }
            'completed' {
                New-FlowPr 1 '2026-09-01T00:00:00Z' '2026-09-02T00:00:00Z'
                New-FlowPr 2 '2026-09-01T00:00:00Z' '2026-09-03T00:00:00Z'
            }
            'abandoned' {
                New-FlowPr 2 '2026-09-01T00:00:00Z' '2026-09-03T00:00:00Z' -Status 'abandoned'
                New-FlowPr 3 '2026-09-01T00:00:00Z' '2026-09-04T00:00:00Z' -Status 'abandoned'
            }
        }
    }
    $prs = @(Get-AzDoPullRequestsForFlow -Context ([pscustomobject]@{ Name = 'dummy' }) -Repository 'RepoA' -FromUtc ([datetime]'2026-09-01') -PageSize 50 -ServerSideDateFilter $true)
    Assert-Equal '4,1,2,3' (($prs | ForEach-Object { $_.pullRequestId }) -join ',')
    Assert-Equal 'active|Created|False|True,completed|Closed|True|True,abandoned|Closed|True|True' ($calls -join ',')
}

```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`
Expected: 追加した 1 件が `[FAIL]`、`結果: 46 件成功 / 1 件失敗`

- [ ] **Step 3: 実装する**

`src/AzDoClient.ps1` の `function Get-AzDoPullRequests { ... }` の直後に追加する。

```powershell

function Get-AzDoPullRequestsForFlow {
    <#
    .SYNOPSIS
        PR の作成・滞留・Close のグラフ用に、集計範囲のどこかの日に開いていた・作成された・クローズされた PR をすべて取得する。
    .DESCRIPTION
        ・いま開いている PR（active）: 期間の指定なしで全件
        ・クローズ済み（completed / abandoned）: クローズ日時が FromUtc 以降のもの。上限は実行時点より先にして、
          範囲の後にクローズした PR（範囲中は開いていた PR）も含める
        同じ pullRequestId は最初の 1 件だけ残す。既存の取得（Get-AzDoPullRequests の呼び出し）には影響しない。
        判断の記録: docs\adr\ADR-0003
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][datetime]$FromUtc,
        [int]$PageSize = 100,
        [bool]$ServerSideDateFilter = $true
    )

    $untilUtc = [datetime]::UtcNow.AddDays(1)
    $batches = @(
        @{ Status = 'active';    DateBasis = 'Created'; ServerSide = $false }
        @{ Status = 'completed'; DateBasis = 'Closed';  ServerSide = $ServerSideDateFilter }
        @{ Status = 'abandoned'; DateBasis = 'Closed';  ServerSide = $ServerSideDateFilter }
    )

    $seen = @{}
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($batch in $batches) {
        $prs = @(Get-AzDoPullRequests -Context $Context -Repository $Repository -Status $batch.Status -FromUtc $FromUtc `
                -ToUtcExclusive $untilUtc -DateBasis $batch.DateBasis -PageSize $PageSize -ServerSideDateFilter $batch.ServerSide)
        foreach ($pr in $prs) {
            if ($null -eq $pr) { continue }
            $key = [string]$pr.pullRequestId
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $result.Add($pr)
        }
    }
    return $result.ToArray()
}
```

- [ ] **Step 4: テストが通ることを確認する（5.1 と 7）**

Run: テストの実行コマンド（2 つとも）
Expected: `結果: 47 件すべて成功`

- [ ] **Step 5: コミット**

```bash
git add src/AzDoClient.ps1 tests/Run-Tests.ps1
git commit -m "feat: PR の作成・滞留・Close のグラフ用の追加取得を追加" -m "active は全件、completed・abandoned は集計範囲の開始以降にクローズしたものを取得し、重複を除く。" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: 棒グラフ・HTML の節・縦軸の共通化

**Files:**
- Modify: `src/LeadTimeChart.ps1`（縦軸の共通部品を追加して `New-LeadTimeChartSvg` で使う、`New-LeadTimeChartHtml` に `-FlowSummary`）
- Modify: `src/PrFlowChart.ps1`（棒グラフと HTML の節）
- Modify: `tests/Run-Tests.ps1`

**Interfaces:**
- Consumes: `Format-SvgNumber`（`src/LeadTimeChart.ps1`）、`Get-PrFlowDailySummary` の行（Task 1）、テストの `Measure-Match`・`Assert-Contains`・`New-LeadTimeTestData`
- Produces:
  - `Get-ChartYAxis -MaxValue <int>` → `[pscustomobject]@{ Step [int]; Max [int] }`（目盛り 5 本前後の整数刻み。上限は 1 以上）
  - `New-ChartYAxisSvg -YAxis -ToY <scriptblock> -Left <int> -Right <int> -Width <int>` → 目盛り線・縦軸ラベル・0 の線の SVG 文字列
  - `$script:PrFlowSeries` — `[pscustomobject]@{ Id; Label; Color }` の配列（Created・Open・Closed の順）
  - `New-PrFlowBarChartSvg -Rows [-Width 900] [-Height 360]` → 棒グラフの SVG（行が無ければ空文字）。棒は `<rect class="bar bar-{Id}" x=".." y=".." width=".." height=".." fill=".."><title>MM/dd {Label}: N件</title></rect>`（属性はこの順）、日ごとに Created → Open → Closed の順で出す
  - `New-PrFlowSectionHtml -Rows [-Available <bool>]` → HTML の節（`<h3>PR の作成・滞留・Close（日単位）</h3>` から表まで）
  - `New-LeadTimeChartHtml ... [-FlowSummary <object[]>]` — 指定したときだけ、各リポジトリの最後（数値の表の後）に節を入れる。そのリポジトリの行が無ければ「表示できません」

- [ ] **Step 1: 失敗するテストを書く**

`tests/Run-Tests.ps1` の `It '追加取得: active は期間なし、…' { ... }` の**直後**に追加する。

```powershell
function Get-SvgBars {
    # 棒（<rect class="bar ...">）の x と width を数値で取り出す
    param([string]$Svg)
    $culture = [Globalization.CultureInfo]::InvariantCulture
    foreach ($m in [regex]::Matches($Svg, '<rect class="bar[^"]*" x="([\d.]+)" y="[\d.]+" width="([\d.]+)"')) {
        [pscustomobject]@{ X = [double]::Parse($m.Groups[1].Value, $culture); W = [double]::Parse($m.Groups[2].Value, $culture) }
    }
}

It '棒グラフ: 1 日 3 本（作成・滞留・Close）を隙間なく並べ、日と日の間に空白を入れる' {
    $rows = @(
        [pscustomobject]@{ Repository = 'RepoA'; Date = '2026-09-07'; Created = 1; Open = 2; Closed = 1 }
        [pscustomobject]@{ Repository = 'RepoA'; Date = '2026-09-08'; Created = 1; Open = 1; Closed = 2 }
        [pscustomobject]@{ Repository = 'RepoA'; Date = '2026-09-09'; Created = 0; Open = 2; Closed = 0 }
    )
    $svg = New-PrFlowBarChartSvg -Rows $rows
    $bars = @(Get-SvgBars $svg)
    Assert-Equal 9 $bars.Count '（3 日 × 3 本）'
    if ([math]::Abs(($bars[0].X + $bars[0].W) - $bars[1].X) -gt 0.02) { throw '同じ日の 1 本目と 2 本目の間に隙間がある' }
    if ([math]::Abs(($bars[1].X + $bars[1].W) - $bars[2].X) -gt 0.02) { throw '同じ日の 2 本目と 3 本目の間に隙間がある' }
    $gap = $bars[3].X - ($bars[2].X + $bars[2].W)
    if ($gap -lt 10) { throw "日と日の間の空白が小さい: $gap" }
    Assert-Contains $svg 'class="bar bar-Created"'
    Assert-Contains $svg '<title>09/07 滞留: 2件</title>'
    Assert-Contains $svg '<title>09/08 Close: 2件</title>'
    Assert-Contains $svg '>09/09</text>'
    Assert-Equal '' (New-PrFlowBarChartSvg -Rows @())
}
It 'HTML: 作成・滞留・Close の棒グラフは各リポジトリの最後（数値の表の後）に入る' {
    $d = New-LeadTimeTestData
    $weekly = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    $daily = @(Get-LeadTimeDailySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    $flow = @(
        [pscustomobject]@{ Repository = 'RepoA'; Date = '2026-09-03'; Created = 2; Open = 5; Closed = 1 }
        [pscustomobject]@{ Repository = 'RepoA'; Date = '2026-09-04'; Created = 0; Open = 4; Closed = 1 }
    )
    $html = New-LeadTimeChartHtml -WeeklySummary $weekly -DailySummary $daily -Config $d.Config -Range $d.Range -FlowSummary $flow
    $flowPos = $html.IndexOf('<h3>PR の作成・滞留・Close（日単位）</h3>')
    if ($flowPos -lt 0) { throw '見出しが無い' }
    if ($flowPos -lt $html.IndexOf('<summary>数値の表（日単位）</summary>')) { throw '数値の表より前にある' }
    if ($flowPos -gt $html.IndexOf('</section>')) { throw 'リポジトリの節の外にある' }
    Assert-Contains $html '作成</li>'
    Assert-Contains $html '滞留</li>'
    Assert-Contains $html 'Close</li>'
    Assert-Contains $html '<summary>数値の表（PR の作成・滞留・Close）</summary>'
    Assert-Contains $html '<td class="left">2026-09-03</td><td>2</td><td>5</td><td>1</td>'
    Assert-Equal 6 (Measure-Match $html '<rect class="bar')
}
It 'HTML: 作成・滞留・Close のデータが無いときは表示できない旨を出し、指定しなければ節を出さない' {
    $d = New-LeadTimeTestData
    $weekly = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    $daily = @(Get-LeadTimeDailySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    $html = New-LeadTimeChartHtml -WeeklySummary $weekly -DailySummary $daily -Config $d.Config -Range $d.Range -FlowSummary @()
    Assert-Contains $html 'PR の作成・滞留・Close のデータを取得できなかったため、このグラフは表示できません。'
    Assert-Equal 0 (Measure-Match $html '<rect class="bar')
    $html2 = New-LeadTimeChartHtml -WeeklySummary $weekly -DailySummary $daily -Config $d.Config -Range $d.Range
    if ($html2.Contains('PR の作成・滞留・Close')) { throw '指定していないのに節がある' }
}

```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`
Expected: 追加した 3 件が `[FAIL]`、`結果: 47 件成功 / 3 件失敗`

- [ ] **Step 3: 縦軸の部品を共通化する（`src/LeadTimeChart.ps1`）**

`function Get-LeadTimeMaxCount { ... }` の**直前**に追加する。

```powershell
function Get-ChartYAxis {
    <# 縦軸の刻みと上限を決める（目盛り 5 本前後になる整数の刻み。0 件でも上限は 1 以上）。 #>
    param([int]$MaxValue)
    $step = [int][math]::Max(1, [math]::Ceiling($MaxValue / 5))
    [pscustomobject]@{ Step = $step; Max = $step * [int][math]::Max(1, [math]::Ceiling($MaxValue / $step)) }
}

function New-ChartYAxisSvg {
    <# 目盛り線・縦軸ラベル・0 の線（横軸）を SVG 文字列で返す。折れ線と棒グラフで共通。 #>
    param(
        [Parameter(Mandatory)]$YAxis,
        [Parameter(Mandatory)][scriptblock]$ToY,
        [int]$Left,
        [int]$Right,
        [int]$Width
    )
    $sb = New-Object System.Text.StringBuilder
    for ($v = 0; $v -le $YAxis.Max; $v += $YAxis.Step) {
        $y = Format-SvgNumber (& $ToY $v)
        [void]$sb.Append(('<line class="grid" x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#e0e0e0"/>' -f $Left, $y, ($Width - $Right)))
        [void]$sb.Append(('<text class="y-label" x="{0}" y="{1}" text-anchor="end" font-size="12" fill="#616161">{2}</text>' -f ($Left - 8), (Format-SvgNumber ((& $ToY $v) + 4)), $v))
    }
    [void]$sb.Append(('<line x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#9e9e9e"/>' -f $Left, (Format-SvgNumber (& $ToY 0)), ($Width - $Right)))
    return $sb.ToString()
}

```

`New-LeadTimeChartSvg` の中で、次の 2 行

```powershell
    $step = [int][math]::Max(1, [math]::Ceiling($maxValue / 5))
    $yMaxValue = $step * [int][math]::Max(1, [math]::Ceiling($maxValue / $step))
```

を次に置き換える。

```powershell
    $yAxis = Get-ChartYAxis -MaxValue $maxValue
    $yMaxValue = $yAxis.Max
```

同じ関数の次の行

```powershell
    $toY = { param([double]$v) $top + $plotHeight - $plotHeight * $v / $yMaxValue }
```

を次に置き換える（別の関数に渡すので、変数を取り込んだクロージャにする）。

```powershell
    $toY = { param([double]$v) $top + $plotHeight - $plotHeight * $v / $yMaxValue }.GetNewClosure()
```

同じ関数の `# 目盛り線と縦軸ラベル` の行から、その後の `[void]$sb.Append(('<line x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#9e9e9e"/>' ...` の行までを、次の 2 行に置き換える。

```powershell
    # 目盛り線と縦軸ラベル
    [void]$sb.Append((New-ChartYAxisSvg -YAxis $yAxis -ToY $toY -Left $left -Right $right -Width $Width))
```

テストを実行し、既存のテスト（折れ線グラフを含む）が変わらず通ることを確認する（新しい 3 件だけが失敗のまま）。

- [ ] **Step 4: 棒グラフと HTML の節を実装する（`src/PrFlowChart.ps1` の末尾）**

```powershell

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
```

- [ ] **Step 5: `New-LeadTimeChartHtml` に `-FlowSummary` を追加する（`src/LeadTimeChart.ps1`）**

`New-LeadTimeChartHtml` の param の次の行

```powershell
        [datetime]$GeneratedAt = (Get-Date)
```

を次に置き換える。

```powershell
        [datetime]$GeneratedAt = (Get-Date),
        # 指定したときだけ、各リポジトリの最後に「PR の作成・滞留・Close（日単位）」の節を入れる（Get-PrFlowDailySummary の行）。
        # 空配列を渡すと「データを取得できなかった」として扱う。
        [object[]]$FlowSummary
```

同じ関数の次の行

```powershell
        [void]$sb.Append('</tbody></table></details></section>')
```

を次に置き換える。

```powershell
        [void]$sb.Append('</tbody></table></details>')

        # PR の作成・滞留・Close（日単位）
        if ($PSBoundParameters.ContainsKey('FlowSummary')) {
            $flowRows = @($FlowSummary | Where-Object { $null -ne $_ -and $_.Repository -eq $repository })
            [void]$sb.Append((New-PrFlowSectionHtml -Rows $flowRows -Available ($flowRows.Count -gt 0)))
        }
        [void]$sb.Append('</section>')
```

同じ関数の `.DESCRIPTION` の最後の行（`出力仕様: docs\06_出力仕様.md「leadtime_chart.html」`）の直前に、次の 1 行を足す。

```
        ・-FlowSummary を指定したときは、各リポジトリの最後に PR の作成・滞留・Close の棒グラフを入れる（src\PrFlowChart.ps1）
```

- [ ] **Step 6: テストが通ることを確認する（5.1 と 7）**

Run: テストの実行コマンド（2 つとも）
Expected: `結果: 50 件すべて成功`

- [ ] **Step 7: コミット**

```bash
git add src/LeadTimeChart.ps1 src/PrFlowChart.ps1 tests/Run-Tests.ps1
git commit -m "feat: PR の作成・滞留・Close の日次棒グラフと HTML の節を追加" -m "1 日 3 本の棒を隙間なく並べ、日と日の間に空白を入れる。縦軸の目盛りの描画は折れ線と共通の部品にした。" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: 実行への組み込みと通し確認

**Files:**
- Modify: `Invoke-PrMetrics.ps1`
- 通し確認用のファイル（リポジトリの外。コミットしない）

**Interfaces:**
- Consumes: `Test-PullRequestFilterMatch`・`ConvertTo-PrFlowRecord`・`Get-PrFlowDailySummary`（Task 1）、`Get-AzDoPullRequestsForFlow`（Task 2）、`New-LeadTimeChartHtml -FlowSummary`（Task 3）、既存の `Import-PrMetricsRawJson`・`Export-PrMetricsJson`・`Export-PrMetricsCsv`・`Test-LeadTimeChartEnabled`、既存の変数 `$config`・`$range`・`$timeZone`・`$context`・`$outputDir`・`$repo`・`$ReplayDir`
- Produces: 出力ファイル `summary_pr_flow_daily.csv`（`SaveRawJson=$true` なら `raw_pullrequests_flow_{repo}.json` も）

- [ ] **Step 1: 読み込みリストに追加する**

54 行目付近を次に変える。

```powershell
foreach ($file in @('Config.ps1', 'AzDoClient.ps1', 'SizeCalculator.ps1', 'Aggregator.ps1', 'Output.ps1', 'LeadTimeChart.ps1', 'PrFlowChart.ps1')) {
```

- [ ] **Step 2: 記録の入れ物を用意する**

次の行

```powershell
    $repoStats = New-Object System.Collections.Generic.List[object]
```

の**直後**に追加する。

```powershell
    # PR の作成・滞留・Close のグラフ用（追加取得した PR の記録）。1 つでも取得に失敗したらグラフは「表示できません」にする
    $flowRecords = New-Object System.Collections.Generic.List[object]
    $flowAvailable = $true
```

- [ ] **Step 3: リポジトリごとに追加取得する**

次の行

```powershell
        Write-Log "[$repo] 取得 $(@($rawPrs).Count) 件 → 対象 $($targetPrs.Count) 件"
```

の**直後**に追加する。

```powershell

        # ---- 2b. PR の作成・滞留・Close のグラフ用の追加取得（グラフを作るときだけ。既存の集計には使わない）----
        if ($flowAvailable -and (Test-LeadTimeChartEnabled -Config $config)) {
            try {
                $flowFileName = "raw_pullrequests_flow_$repo.json"
                if ($ReplayDir) {
                    $flowReplayPath = Join-Path $ReplayDir $flowFileName
                    if (-not (Test-Path -LiteralPath $flowReplayPath)) {
                        throw "$flowReplayPath がありません（SaveRawJson=`$true で実行した出力フォルダを -ReplayDir に指定してください）"
                    }
                    $flowRaw = @(Import-PrMetricsRawJson -Path $flowReplayPath)
                }
                else {
                    $flowRaw = @(Get-AzDoPullRequestsForFlow -Context $context -Repository $repo -FromUtc $range.FromUtc `
                            -PageSize $config.PageSize -ServerSideDateFilter $config.UseServerSideDateFilter)
                    if ($config.SaveRawJson) { Export-PrMetricsJson -Data $flowRaw -Path (Join-Path $outputDir $flowFileName) }
                }
                foreach ($pr in $flowRaw) {
                    if (-not (Test-PullRequestFilterMatch -PullRequest $pr -Config $config)) { continue }
                    $flowRecord = ConvertTo-PrFlowRecord -PullRequest $pr -Repository $repo -TimeZone $timeZone
                    if ($null -ne $flowRecord) { $flowRecords.Add($flowRecord) }
                }
                Write-Log "[$repo] 作成・滞留・Close 用に $($flowRaw.Count) 件を取得"
            }
            catch {
                $flowAvailable = $false
                Write-Warning "[$repo] PR の作成・滞留・Close のグラフ用のデータを取得できませんでした（他の出力には影響しません）: $($_.Exception.Message)"
            }
        }
```

- [ ] **Step 4: CSV と HTML に渡す**

次の行

```powershell
            $chartHtml = New-LeadTimeChartHtml -WeeklySummary $leadTimeWeekly -DailySummary $leadTimeDaily -Config $config -Range $range
```

を次に置き換える。

```powershell
            $flowSummary = @()
            if ($flowAvailable) {
                $flowSummary = @(Get-PrFlowDailySummary -Records $flowRecords.ToArray() -Config $config -Range $range)
                Export-PrMetricsCsv -Data $flowSummary -Path (Join-Path $outputDir 'summary_pr_flow_daily.csv')
            }
            $chartHtml = New-LeadTimeChartHtml -WeeklySummary $leadTimeWeekly -DailySummary $leadTimeDaily -Config $config -Range $range -FlowSummary $flowSummary
```

テストを実行し、`結果: 50 件すべて成功`（5.1 と 7）を確認する。

- [ ] **Step 5: 通し実行（`-ReplayDir`、5.1 と 7）**

`$env:TEMP\prm_e2e` を空にしてから、次の 3 ファイルを作る。

`$env:TEMP\prm_e2e\replay\raw_pullrequests_SampleRepo.json`（UTF-8）

```json
[
 {"pullRequestId":1,"title":"機能A","status":"completed","isDraft":false,"createdBy":{"displayName":"Taro","uniqueName":"taro@example.com"},"creationDate":"2026-09-03T00:00:00Z","closedDate":"2026-09-03T05:00:00Z","sourceRefName":"refs/heads/f1","targetRefName":"refs/heads/main","reviewers":[]},
 {"pullRequestId":2,"title":"機能B","status":"completed","isDraft":false,"createdBy":{"displayName":"Hanako","uniqueName":"hanako@example.com"},"creationDate":"2026-09-02T00:00:00Z","closedDate":"2026-09-04T06:00:00Z","sourceRefName":"refs/heads/f2","targetRefName":"refs/heads/main","reviewers":[]},
 {"pullRequestId":3,"title":"修正C","status":"completed","isDraft":false,"createdBy":{"displayName":"Taro","uniqueName":"taro@example.com"},"creationDate":"2026-09-08T00:00:00Z","closedDate":"2026-09-08T03:00:00Z","sourceRefName":"refs/heads/f3","targetRefName":"refs/heads/main","reviewers":[]},
 {"pullRequestId":4,"title":"修正D","status":"completed","isDraft":false,"createdBy":{"displayName":"Hanako","uniqueName":"hanako@example.com"},"creationDate":"2026-09-10T00:00:00Z","closedDate":"2026-09-15T00:00:00Z","sourceRefName":"refs/heads/f4","targetRefName":"refs/heads/main","reviewers":[]},
 {"pullRequestId":5,"title":"改善E","status":"completed","isDraft":false,"createdBy":{"displayName":"Taro","uniqueName":"taro@example.com"},"creationDate":"2026-09-21T00:00:00Z","closedDate":"2026-09-22T12:00:00Z","sourceRefName":"refs/heads/f5","targetRefName":"refs/heads/main","reviewers":[]},
 {"pullRequestId":6,"title":"改善F","status":"completed","isDraft":false,"createdBy":{"displayName":"Hanako","uniqueName":"hanako@example.com"},"creationDate":"2026-09-28T00:00:00Z","closedDate":"2026-09-28T02:00:00Z","sourceRefName":"refs/heads/f6","targetRefName":"refs/heads/main","reviewers":[]}
]
```

`$env:TEMP\prm_e2e\replay\raw_pullrequests_flow_SampleRepo.json`（UTF-8。上の 6 件に、範囲前から開いている PR 7 と、範囲内に破棄された PR 8 を加えたもの）

```json
[
 {"pullRequestId":7,"title":"検討G","status":"active","isDraft":false,"createdBy":{"displayName":"Taro","uniqueName":"taro@example.com"},"creationDate":"2026-08-30T00:00:00Z","sourceRefName":"refs/heads/f7","targetRefName":"refs/heads/main","reviewers":[]},
 {"pullRequestId":1,"title":"機能A","status":"completed","isDraft":false,"createdBy":{"displayName":"Taro","uniqueName":"taro@example.com"},"creationDate":"2026-09-03T00:00:00Z","closedDate":"2026-09-03T05:00:00Z","sourceRefName":"refs/heads/f1","targetRefName":"refs/heads/main","reviewers":[]},
 {"pullRequestId":2,"title":"機能B","status":"completed","isDraft":false,"createdBy":{"displayName":"Hanako","uniqueName":"hanako@example.com"},"creationDate":"2026-09-02T00:00:00Z","closedDate":"2026-09-04T06:00:00Z","sourceRefName":"refs/heads/f2","targetRefName":"refs/heads/main","reviewers":[]},
 {"pullRequestId":3,"title":"修正C","status":"completed","isDraft":false,"createdBy":{"displayName":"Taro","uniqueName":"taro@example.com"},"creationDate":"2026-09-08T00:00:00Z","closedDate":"2026-09-08T03:00:00Z","sourceRefName":"refs/heads/f3","targetRefName":"refs/heads/main","reviewers":[]},
 {"pullRequestId":4,"title":"修正D","status":"completed","isDraft":false,"createdBy":{"displayName":"Hanako","uniqueName":"hanako@example.com"},"creationDate":"2026-09-10T00:00:00Z","closedDate":"2026-09-15T00:00:00Z","sourceRefName":"refs/heads/f4","targetRefName":"refs/heads/main","reviewers":[]},
 {"pullRequestId":5,"title":"改善E","status":"completed","isDraft":false,"createdBy":{"displayName":"Taro","uniqueName":"taro@example.com"},"creationDate":"2026-09-21T00:00:00Z","closedDate":"2026-09-22T12:00:00Z","sourceRefName":"refs/heads/f5","targetRefName":"refs/heads/main","reviewers":[]},
 {"pullRequestId":6,"title":"改善F","status":"completed","isDraft":false,"createdBy":{"displayName":"Hanako","uniqueName":"hanako@example.com"},"creationDate":"2026-09-28T00:00:00Z","closedDate":"2026-09-28T02:00:00Z","sourceRefName":"refs/heads/f6","targetRefName":"refs/heads/main","reviewers":[]},
 {"pullRequestId":8,"title":"試行H","status":"abandoned","isDraft":false,"createdBy":{"displayName":"Hanako","uniqueName":"hanako@example.com"},"creationDate":"2026-09-05T00:00:00Z","closedDate":"2026-09-06T00:00:00Z","sourceRefName":"refs/heads/f8","targetRefName":"refs/heads/main","reviewers":[]}
]
```

`$env:TEMP\prm_e2e\settings.e2e.psd1`（UTF-8 BOM 付き。`OutputDir` は実際のパスにする）

```powershell
@{
    Organization = 'contoso'; Project = 'SampleProject'; Repositories = @('SampleRepo')
    FromDate = '2026-09-03'; ToDate = '2026-09-30'
    SizeMethod = 'None'
    OutputDir = 'C:\Users\<ユーザー>\AppData\Local\Temp\prm_e2e\out'
}
```

Run（5.1 と 7 の両方）:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-PrMetrics.ps1 -ConfigPath $env:TEMP\prm_e2e\settings.e2e.psd1 -ReplayDir $env:TEMP\prm_e2e\replay
pwsh -NoProfile -File .\Invoke-PrMetrics.ps1 -ConfigPath $env:TEMP\prm_e2e\settings.e2e.psd1 -ReplayDir $env:TEMP\prm_e2e\replay
```

Expected:
- `完了: 6 件` で終わり、警告が出ない。「作成・滞留・Close 用に 8 件を取得」のログが出る
- 最新の出力フォルダに `summary_pr_flow_daily.csv` があり、28 行（9/3〜9/30）。次の日の値になる

| Date | Created | Open | Closed |
|---|---|---|---|
| 2026-09-03 | 1 | 2 | 1 |
| 2026-09-04 | 0 | 1 | 1 |
| 2026-09-05 | 1 | 2 | 0 |
| 2026-09-06 | 0 | 1 | 1 |
| 2026-09-10 | 1 | 2 | 0 |
| 2026-09-30 | 0 | 1 | 0 |

- `Created` の合計 6、`Closed` の合計 7
- `summary_leadtime_weekly.csv`・`summary_leadtime_daily.csv` は変更前と同じ（週次 20 行・日次 112 行）
- `leadtime_chart.html` に `<h3>PR の作成・滞留・Close（日単位）</h3>` があり、`<rect class="bar` が 84 個（28 日 × 3）

- [ ] **Step 6: 取得できない場合の確認**

`raw_pullrequests_flow_SampleRepo.json` を別名に変えて（例: `.bak`）、5.1 で同じコマンドを実行する。
Expected: 「PR の作成・滞留・Close のグラフ用のデータを取得できませんでした」の警告が出て `完了: 6 件` で終わる。最新の出力フォルダに `summary_pr_flow_daily.csv` が無く、`leadtime_chart.html` に「このグラフは表示できません。」がある。確認後にファイル名を戻し、もう一度 5.1 で実行して正常な出力フォルダを最新にしておく。その `leadtime_chart.html` の絶対パスを報告する（見た目の確認はコントローラーが行う）。

- [ ] **Step 7: コミット**

```bash
git add Invoke-PrMetrics.ps1
git commit -m "feat: 実行時に PR の作成・滞留・Close の日次 CSV と棒グラフを出力" -m "グラフを作るときだけ追加取得し（Replay 時は raw_pullrequests_flow_{repo}.json）、失敗しても警告にして他の出力は続ける。" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: 資料（ADR-0003・README・設計資料・AGENTS.md）

**Files:**
- Create: `docs/adr/ADR-0003-PRの作成・滞留・Closeの数え方.md`
- Modify: `docs/adr/README.md`, `docs/01_要件定義.md`, `docs/02_基本設計.md`, `docs/03_AzureDevOps_API仕様.md`, `docs/05_詳細設計.md`, `docs/06_出力仕様.md`, `docs/07_動作確認手順.md`, `docs/08_トラブルシューティング.md`, `README.md`, `AGENTS.md`

**Interfaces:**
- Consumes: Task 1〜4 で決まった関数名・ファイル名・列名・HTML と警告の文言
- Produces: なし

- [ ] **Step 1: `docs/adr/ADR-0003-PRの作成・滞留・Closeの数え方.md` を作る**

```markdown
# ADR-0003: PR の作成・滞留・Close の数え方とデータの取得

- 状態: 採用
- 日付: 2026-11-06
- 関係: [仕様書](../superpowers/specs/2026-11-06-pr-flow-daily-chart-design.md)

## 背景

日ごとの PR の作成数・滞留数・Close 数を棒グラフで出すことにした。
既存のツールは「集計範囲内にマージされた PR」しか取得していないため、開いたままの PR、範囲より前に作られた PR、破棄された PR が無く、このままでは作成数と滞留数を正しく数えられない。

## 決定

1. **数え方**
   - 作成（Created）: その日に作成された PR（状態を問わない）
   - 滞留（Open）: その日の終わり（翌日 0:00）の時点で、作成済みでまだクローズされていない PR（範囲より前に作られた PR も含む）
   - Close（Closed）: その日にクローズされた PR。**マージ（completed）と破棄（abandoned）の両方**
   - 日は設定タイムゾーンの日付。Draft の除外・マージ先ブランチ・除外する作成者は既存と同じく適用する
2. **データの取得**: グラフを作るときだけ、リポジトリごとに次を**追加で取得**する（既存の取得・出力は変えない）
   - いま開いている PR（active）を全件
   - 集計範囲の開始時点以降にクローズした PR（completed・abandoned。上限は実行時点）
3. 追加取得に失敗した場合は警告にし、グラフの位置に「表示できません」と出す。他の出力は通常どおり作る。

## 理由

- **Close に破棄を含める**と、毎日「滞留（当日）＝ 滞留（前日）＋ 作成 − Close」が成り立ち、3 つの数字のつじつまが合う。破棄された PR は破棄した日に滞留から外れるので、Close に数えないと、どこにも数えられずに消えることになる。
- **滞留を「その日の終わりの在庫」にする**のは、レビュー待ちが溜まっているかを見るための一般的な指標で、前の日から残っている PR も含めて把握できるから。
- **追加取得にする**のは、既存の出力（prs.csv・既存のグラフ）の数字を変えないため。追加取得の範囲は「範囲内のどこかで開いていた・作成された・クローズされた PR」をすべて含む最小の条件にしている。

## 検討した代替案

| 案 | 採らなかった理由 |
|---|---|
| メインの取得そのものを広げ、既存の出力はそこから絞り込む | `Statuses` 設定などの絞り込みを作り直す必要があり、既存の出力の数字が変わるおそれがある |
| 既存のデータ（範囲内にマージされた PR）だけで近い値を出す | 開いたままの PR・範囲前の PR・破棄された PR が抜け、作成数と滞留数が実際より少なくなる |
| Close はマージだけにする | 破棄された PR が滞留から外れても Close に数えられず、関係式が成り立たない |
| 滞留を「一定時間以上開いている PR の数」にする | 時間のしきい値の決め方が別に必要になる。滞留の長さはクローズまでの時間のグラフで見られる |

## 影響

- グラフを作るとき、リポジトリごとに API 呼び出しが増える（active 全件、範囲開始以降のクローズ分）。`UseServerSideDateFilter = $false` の環境ではクローズ済みを全件取得するため遅くなる。
- Draft は PR の**現在の状態**で判定するので、`ExcludeDrafts = $true` のとき、いま Draft の PR は作成・滞留に入らない。
- `-ReplayDir` で再集計するには、`SaveRawJson = $true` で保存した `raw_pullrequests_flow_{リポジトリ}.json` が必要。

## 見直しの目安

- 「Draft のまま長く置かれている PR」も滞留として見たい場合は、Draft の扱い（このグラフだけ Draft を含める）を見直す。
```

- [ ] **Step 2: `docs/adr/README.md` に追加する**

表の `| [ADR-0002](...) | ... |` の行の後に追加する。

```markdown
| [ADR-0003](ADR-0003-PRの作成・滞留・Closeの数え方.md) | PR の作成・滞留・Close の数え方とデータの取得 | 採用 | 2026-11-06 |
```

- [ ] **Step 3: `docs/02_基本設計.md` に D-12 を追加する**

`## 6. セキュリティ設計` の**直前**に追加する。

```markdown
### D-12. PR の作成・滞留・Close はグラフ用に追加取得して数える（ADR-0003）
- **要点**: Close はマージ＋破棄、滞留はその日の終わりに開いている数。既存の出力を変えないよう、グラフを作るときだけ active 全件と範囲開始以降のクローズ分を追加取得する。
- **詳細**: [ADR-0003](adr/ADR-0003-PRの作成・滞留・Closeの数え方.md)

```

- [ ] **Step 4: `docs/01_要件定義.md` を更新する**

`## 4. 機能要件` の**直前**に追加する。

```markdown
### 3.5 PR の作成数・滞留数・Close 数（日次）

| 項目 | 定義 |
|---|---|
| 作成 | その日に作成された PR の数（状態を問わない） |
| 滞留 | その日の終わり（翌日 0:00）の時点で、作成済みでまだクローズされていない PR の数（範囲より前に作られた PR も含む） |
| Close | その日にクローズされた PR の数（マージと破棄の両方） |
| 日 | 完了日時ではなく、それぞれの日時（作成日時・クローズ日時）の、設定タイムゾーンでの日付 |
| 対象 | Draft の除外・マージ先ブランチ・除外する作成者は既存と同じ。期間の絞り込みは使わない |
| 出力 | `summary_pr_flow_daily.csv` と、`leadtime_chart.html` の各リポジトリの最後の棒グラフ（1 日 3 本、日と日の間に空白） |

- 毎日「滞留（当日）＝ 滞留（前日）＋ 作成 − Close」が成り立つ。
- `DateBasis = 'Closed'` のときだけ出力する。数え方と取得方法の理由は [ADR-0003](adr/ADR-0003-PRの作成・滞留・Closeの数え方.md)。

```

機能要件の表の `| F-11 | ... |` の行の後に追加する。

```markdown
| F-12 | 日ごとの PR の作成数・滞留数・Close 数を数え、CSV と棒グラフ（HTML）に出力する |
```

- [ ] **Step 5: `docs/03_AzureDevOps_API仕様.md` に追加取得を書く**

`## 4. PR 個別取得` の**直前**に追加する。

```markdown
### 3.3 作成・滞留・Close のグラフ用の追加取得

`leadtime_chart.html` を作るとき（`DateBasis='Closed'`）だけ、リポジトリごとに同じ PR 一覧 API を次の条件で追加で呼ぶ（`Get-AzDoPullRequestsForFlow`）。既存の取得とは別で、既存の出力には使わない。

| 呼び出し | `searchCriteria.status` | 期間の指定 |
|---|---|---|
| 1 | `active` | なし（全件） |
| 2 | `completed` | `queryTimeRangeType=closed`、`minTime` = 集計範囲の開始、`maxTime` = 実行時点の翌日 |
| 3 | `abandoned` | 2 と同じ |

- 同じ `pullRequestId` は 1 件にまとめる。
- `UseServerSideDateFilter=$false` のときは 2・3 も期間を指定せず全件取得する（遅くなるが、数え方は変わらない）。
- 理由: [ADR-0003](adr/ADR-0003-PRの作成・滞留・Closeの数え方.md)

```

- [ ] **Step 6: `docs/05_詳細設計.md` に章を追加する**

`## 8. テスト（tests/Run-Tests.ps1）` を `## 9. テスト（tests/Run-Tests.ps1）` に変え、その**直前**に次の章を挿入する（7 章の最後の `---` の後）。

```markdown
## 8. PrFlowChart.ps1

日ごとの PR の作成数・滞留数・Close 数と、その棒グラフ（HTML の 1 節）を作る。仕様: `docs/superpowers/specs/2026-11-06-pr-flow-daily-chart-design.md`、判断: [ADR-0003](adr/ADR-0003-PRの作成・滞留・Closeの数え方.md)

| 関数 / 定義 | 内容 |
|---|---|
| `ConvertTo-PrFlowRecord -PullRequest -Repository -TimeZone` | API の PR を `Repository, PullRequestId, Status, CreatedLocal, ClosedLocal` の記録にする。クローズ日時は completed・abandoned のときだけ。作成日時が無ければ何も返さない |
| `Get-PrFlowDailySummary -Records -Config -Range` | 日ごとに Created（その日に作成）・Open（翌日 0:00 に作成済みかつ未クローズ）・Closed（その日にクローズ）を数える。範囲内の全日、`(ALL)` 行 |
| `$script:PrFlowSeries` | 棒の定義（`Id`・`Label`・`Color`）。Created → Open → Closed の順が、1 日の中の並び・凡例・表の列の順 |
| `New-PrFlowBarChartSvg -Rows [-Width] [-Height]` | 1 日の枠の 75% に 3 本の棒を隙間なく並べ、25% を日と日の間の空白にする。横軸ラベルは最大 12 個。各棒に `<title>` |
| `New-PrFlowSectionHtml -Rows [-Available]` | `<h3>PR の作成・滞留・Close（日単位）</h3>`、定義の説明、凡例、棒グラフ、開閉式の表。`-Available $false` なら「表示できません」だけ |

関係する他のファイルの関数:

| 関数 | 内容 |
|---|---|
| `Test-PullRequestFilterMatch`（Aggregator.ps1） | 期間以外の絞り込み（Draft・ブランチ・作成者）。`Test-PullRequestIncluded` もこれを使う |
| `Get-AzDoPullRequestsForFlow`（AzDoClient.ps1） | active 全件 ＋ 範囲開始以降にクローズした completed・abandoned を取得し、重複を除く |
| `Get-ChartYAxis` / `New-ChartYAxisSvg`（LeadTimeChart.ps1） | 縦軸の刻み・目盛り線の描画。折れ線と棒グラフで共通 |
| `New-LeadTimeChartHtml -FlowSummary`（LeadTimeChart.ps1） | 指定したときだけ、各リポジトリの最後（数値の表の後）に `New-PrFlowSectionHtml` の節を入れる。そのリポジトリの行が無ければ「表示できません」 |

`Invoke-PrMetrics.ps1` は、グラフを作るとき（`DateBasis='Closed'`）だけリポジトリごとに追加取得し（`-ReplayDir` 時は `raw_pullrequests_flow_{repo}.json`、`SaveRawJson=$true` なら保存）、`Test-PullRequestFilterMatch` で絞り込んで記録にする。1 つでも失敗したら警告にして、HTML には「表示できません」を出す。成功したら `summary_pr_flow_daily.csv` を出力し、HTML に `-FlowSummary` で渡す。

---

```

`## 9. テスト` の表の `| Git 方式 | ... |` の行の**前**に追加する。

```markdown
| PrFlowChart | 絞り込みの共通化、記録への変換（active・破棄・作成日時なし）、日次の作成・滞留・Close（範囲前の PR・同日作成クローズ・範囲後クローズ・日付の境目・関係式・`(ALL)`）、追加取得（API 呼び出しの差し替えで条件と重複除外）、棒グラフ（本数・日の間の空白・ツールチップ）、HTML（位置・凡例・表・表示できない場合・指定しない場合） |
```

- [ ] **Step 7: `docs/06_出力仕様.md` を更新する**

冒頭のファイル一覧表の `| summary_leadtime_daily.csv | ... |` の行の**後**に追加する。

```markdown
| `summary_pr_flow_daily.csv` | UTF-8 BOM 付き | `DateBasis='Closed'` で追加取得に成功したとき | PR の作成数・滞留数・Close 数（日次） |
```

同じ表の `| raw_pullrequests_{リポジトリ}.json | ... |` の行の**後**に追加する。

```markdown
| `raw_pullrequests_flow_{リポジトリ}.json` | UTF-8 | `SaveRawJson=$true` かつ `DateBasis='Closed'` のとき | 作成・滞留・Close 用に追加取得した PR 一覧（`-ReplayDir` で再利用） |
```

見出し `## 8. Excel での活用例` を `## 9. Excel での活用例`、`## 7. run_info.json` を `## 8. run_info.json`、`## 6. leadtime_chart.html` を `## 7. leadtime_chart.html` に変え、`## 7. leadtime_chart.html`（旧 6）の**直前**に次の節を挿入する。

```markdown
## 6. summary_pr_flow_daily.csv

（リポジトリ × 日）= 1 行。範囲内のすべての日を出力する。リポジトリが複数のときは `(ALL)` の行も出す。定義は [ADR-0003](adr/ADR-0003-PRの作成・滞留・Closeの数え方.md)。

| 列 | 例 | 説明 |
|---|---|---|
| `Repository` | `SampleRepo` | リポジトリ名 または `(ALL)` |
| `Date` | `2026-09-28` | 日付（設定タイムゾーン） |
| `Created` | `3` | その日に作成された PR の数 |
| `Open` | `12` | その日の終わりに開いている PR の数（滞留） |
| `Closed` | `4` | その日にクローズ（マージ・破棄）された PR の数 |

毎日 `Open(当日) = Open(前日) + Created(当日) - Closed(当日)` が成り立つ。

```

`## 7. leadtime_chart.html`（旧 6）の箇条書きの最後（`- 日単位の表し方（折れ線）を変える場合は …` の行）の**後**に追加する。

```markdown
- 各リポジトリの最後（数値の表の後）に「PR の作成・滞留・Close（日単位）」の棒グラフ: 1 日に 作成（青）・滞留（紫）・Close（緑がかった青）の 3 本を隙間なく並べ、日と日の間に空白。ツールチップ「09/28 滞留: 12件」。開閉式の数値の表付き。追加取得に失敗したときは「PR の作成・滞留・Close のデータを取得できなかったため、このグラフは表示できません。」
```

- [ ] **Step 8: `docs/07_動作確認手順.md` を更新する**

Step 5 の期待結果の次の 2 行

```markdown
- `output\yyyyMMdd_HHmmss\` に CSV 5 つ（`summary_leadtime_weekly.csv`・`summary_leadtime_daily.csv` を含む）、`leadtime_chart.html`、`run_info.json` ができる
  （`summary_leadtime_weekly.csv`・`summary_leadtime_daily.csv`・`leadtime_chart.html` は `DateBasis = 'Closed'`（既定）のときだけ作られる）
```

を次に置き換える。

```markdown
- `output\yyyyMMdd_HHmmss\` に CSV 6 つ（`summary_leadtime_weekly.csv`・`summary_leadtime_daily.csv`・`summary_pr_flow_daily.csv` を含む）、`leadtime_chart.html`、`run_info.json` ができる
  （この 3 つの CSV と `leadtime_chart.html` は `DateBasis = 'Closed'`（既定）のときだけ作られる）
```

確認表の `| 5-8 | ... |` の行の後に追加する。

```markdown
| 5-9 | 作成・滞留・Close の棒グラフ | `leadtime_chart.html` の最後に棒グラフがあり、1 日 3 本で日と日の間に空白があること。任意の 1 日について、Azure DevOps の画面（Pull requests の All）で、その日に作成・クローズされた PR の数と `summary_pr_flow_daily.csv` の `Created`・`Closed` を比べる |
```

- [ ] **Step 9: `docs/08_トラブルシューティング.md` に警告を追加する**

エラー一覧の表の `| E-16 | ... |` の行の後に追加する。

```markdown
| E-17 | `PR の作成・滞留・Close のグラフ用のデータを取得できませんでした` | 追加取得（active 全件・範囲開始以降のクローズ分）の API エラー、または `-ReplayDir` に `raw_pullrequests_flow_{リポジトリ}.json` が無い | 他の出力は作られている。API エラーなら E-01〜E-06 を参照。Replay なら `SaveRawJson=$true` で実行した出力フォルダを指定する |
```

- [ ] **Step 10: `README.md` を更新する**

出力ファイルの表の `| summary_leadtime_daily.csv | ... |` の行の**後**に追加する。

```markdown
| `summary_pr_flow_daily.csv` | 日ごとの PR の作成数・滞留数・Close 数 |
```

「グラフの見方」の `### グラフが作られないとき` の**直前**に追加する。

```markdown
### PR の作成・滞留・Close（棒グラフ）

各リポジトリの最後に、日ごとに 3 本の棒が並んだグラフがあります（日と日の間は空白）。

| 棒（左から） | 意味 |
|---|---|
| 作成（青） | その日に作成された PR の数 |
| 滞留（紫） | その日の終わりに開いている（まだマージも破棄もされていない）PR の数。前の日から残っている PR も含みます |
| Close（緑がかった青） | その日にマージまたは破棄された PR の数 |

- 「滞留」が日を追って増えているときは、作成のペースにレビュー・マージが追いついていないサインです。
- 数え方と、このグラフのために追加で PR を取得している理由は [ADR-0003](docs/adr/ADR-0003-PRの作成・滞留・Closeの数え方.md) を参照してください。
- データを取得できなかったときは、グラフの代わりに「このグラフは表示できません」と表示されます（他のグラフには影響しません）。

```

`### グラフが作られないとき` の本文の「グラフと 2 つの CSV（週次・日次）は」を「グラフと 3 つの CSV（週次・日次・作成/滞留/Close）は」に変える。

フォルダ構成の次の行

```
│   └─ LeadTimeChart.ps1       … クローズまでの時間区分別の集計（週次・日次 × 全体・大中小）・グラフ
```

を次の 2 行に置き換える。

```
│   ├─ LeadTimeChart.ps1       … クローズまでの時間区分別の集計（週次・日次 × 全体・大中小）・グラフ
│   └─ PrFlowChart.ps1         … PR の作成・滞留・Close の日次集計・棒グラフ
```

- [ ] **Step 11: `AGENTS.md` を更新する**

「構成」の表の `| src/LeadTimeChart.ps1 | ... |` の行の**後**に追加する。

```markdown
| `src/PrFlowChart.ps1` | PR の作成・滞留・Close の日次集計・棒グラフ（SVG/HTML の節） | docs/05 8 章 |
```

同じ表の `| tests/Run-Tests.ps1 | 単体テスト（自作の簡易ランナー） | docs/05 8 章 |` の `8 章` を `9 章` に変える。

- [ ] **Step 12: 確認する**

- `git diff` で、実在の組織名・人名などが含まれていないことを確認する
- 追加・変更した Markdown のリンク先ファイルが存在することを確認する（各ファイルの場所からの相対パス）
- 他の資料に「docs/05 8 章（テスト）」や `06_出力仕様.md` の旧番号への参照が残っていないか確認する
- テストの実行コマンド（2 つとも）で `結果: 50 件すべて成功`

- [ ] **Step 13: コミット**

```bash
git add docs/adr docs/01_要件定義.md docs/02_基本設計.md docs/03_AzureDevOps_API仕様.md docs/05_詳細設計.md docs/06_出力仕様.md docs/07_動作確認手順.md docs/08_トラブルシューティング.md README.md AGENTS.md
git commit -m "docs: PR の作成・滞留・Close の棒グラフの資料と ADR-0003 を追加" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
