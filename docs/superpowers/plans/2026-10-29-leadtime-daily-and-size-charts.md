# 日単位・サイズ別（大中小）グラフ追加 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 既存の「クローズまでの時間別 PR 件数」グラフを、全体・大・中・小 × 週単位・日単位の 8 つに拡張し、週次 CSV に `SizeGroup` 列を足し、日次 CSV を新設する。あわせて ADR 2 本と README の「グラフの見方」を書く。

**Architecture:** すべて `src/LeadTimeChart.ps1` 内の変更。集計は「対象の絞り込み → 大中小の振り分け → 期間（週/日）ごとの件数」を共通の内部関数にして週次・日次で使い回す。描画は既存の折れ線 SVG 関数を `-Unit`・`-YMax` で一般化し、描き方の選択は対応表 `$script:LeadTimeChartStyles` と `New-LeadTimeChart` の 1 か所に集める（将来の棒グラフ化などに備える）。

**Tech Stack:** PowerShell（Windows PowerShell 5.1 と PowerShell 7）、インライン SVG、自作テストランナー `tests/Run-Tests.ps1`

**仕様書:** [docs/superpowers/specs/2026-10-29-leadtime-daily-and-size-charts-design.md](../specs/2026-10-29-leadtime-daily-and-size-charts-design.md)

## Global Constraints

- PowerShell 5.1 と 7 の両方で動くこと。`??`・`?.`・三項演算子・`&&`/`||`・`ConvertFrom-Json -AsHashtable`・3 引数以上の `Join-Path` は使わない
- `.ps1` / `.psd1` は UTF-8（BOM 付き）で保存する
- 関数から配列を返すときに `return , $array` を使わない。呼び出し側で `@(...)` で受ける
- `Set-StrictMode` は使わない。空のハッシュテーブル・空配列を受ける引数に `[Parameter(Mandatory)]` を付けない（5.1 では空のコレクションが拒否されることがある）
- 外部ライブラリ・外部通信なし（HTML は単一ファイル、グラフはインライン SVG）
- 設定項目は追加しない
- 大中小: **小 = XS・S / 中 = M / 大 = L・XL**（`SizeCategory` の名前で対応）。区分 ID は `All` / `Large` / `Medium` / `Small`。表示名は 全体 / 大 / 中 / 小
- サイズ不明（`SizeCategory` が空、または XS/S/M/L/XL 以外）の PR は全体にだけ含め、大中小には含めない
- 区分（24 / 72 時間・境界は上側）、対象（`completed` のみ）、`DateBasis='Closed'` のときだけ作る、は既存どおり
- 例に実名を使わない（`contoso` / `SampleProject` / `SampleRepo` / `example.com`）。このリポジトリは公開されている
- コミットメッセージは日本語、`feat:` / `docs:` / `test:` / `refactor:` を付け、末尾に `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## ファイル構成

| ファイル | 変更 |
|---|---|
| `src/LeadTimeChart.ps1` | 大中小の定義・振り分け・範囲表示、集計の共通化と日次集計、SVG の一般化、描き方の対応表、HTML の構成変更 |
| `Invoke-PrMetrics.ps1` | 日次集計・日次 CSV の出力、HTML への週次・日次の受け渡し |
| `tests/Run-Tests.ps1` | テストの追加・既存テストの追従 |
| `docs/adr/`（新規）、`docs/01, 02, 05, 06, 07, 09`、`README.md`、`AGENTS.md` | 資料 |

## テストの実行コマンド（全タスク共通）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
pwsh -NoProfile -File .\tests\Run-Tests.ps1
```

作業前の件数は `結果: 29 件すべて成功`（git がある環境）。Git Bash から実行する場合は `| iconv -f cp932 -t utf-8` を付けると日本語が読める。

---

### Task 1: 大中小の定義・振り分け・範囲表示

**Files:**
- Modify: `src/LeadTimeChart.ps1`（`function Get-LeadTimeBucket { ... }` の直後に追加）
- Modify: `tests/Run-Tests.ps1`

**Interfaces:**
- Consumes: 既存の `$script:PrMetricsDefaultConfig.SizeCategories`（`@{ Name; MaxLines; MaxFiles }` の配列。既定 XS 10/1, S 50/3, M 250/10, L 1000/30, XL $null/$null）、`$Config.SizeMethod`（`Git` / `Api` / `None`）
- Produces:
  - `$script:LeadTimeSizeGroups` — `[pscustomobject]@{ Id; Label; Categories }` の配列。順序 Large, Medium, Small
  - `Get-LeadTimeSizeGroup -SizeCategory <string>` → `'Large'` / `'Medium'` / `'Small'` / `''`
  - `Get-LeadTimeSizeGroupRangeText -GroupId <string> -Config <hashtable>` → 例 `'L・XL：251行〜'`。未知の GroupId は例外

- [ ] **Step 1: 失敗するテストを書く**

`tests/Run-Tests.ps1` の `It 'クローズまでの時間の区分: 境界ちょうどは上側の区分' { ... }` の**直後**に追加する。

```powershell
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

```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`
Expected: 追加した 2 件が `[FAIL]`（関数が認識されない）、`結果: 29 件成功 / 2 件失敗`

- [ ] **Step 3: 実装する**

`src/LeadTimeChart.ps1` の `function Get-LeadTimeBucket { ... }` の直後に追加する。

```powershell

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
```

- [ ] **Step 4: テストが通ることを確認する（5.1 と 7）**

Run: テストの実行コマンド（2 つとも）
Expected: `結果: 31 件すべて成功`

- [ ] **Step 5: コミット**

```bash
git add src/LeadTimeChart.ps1 tests/Run-Tests.ps1
git commit -m "feat: PR サイズの大中小区分と見出し用の範囲表示を追加" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: 集計の共通化・週次に SizeGroup・日次集計

**Files:**
- Modify: `src/LeadTimeChart.ps1`（`Get-LeadTimeWeeklySummary` を置き換え、内部関数と `Get-LeadTimeDailySummary` を追加）
- Modify: `Invoke-PrMetrics.ps1`（HTML に全体の行だけ渡す 1 行）
- Modify: `tests/Run-Tests.ps1`

**Interfaces:**
- Consumes: `Get-LeadTimeSizeGroup`（Task 1）、`Get-LeadTimeBucket`、既存の `Get-PeriodStart -LocalDate -Unit -WeekStartDay`・`Get-PeriodStarts -Range -Unit -WeekStartDay`・`Get-RecordGroups -Records -Repositories`（`src/Aggregator.ps1`）、明細の列 `Repository`・`Status`・`ClosedAt`（`yyyy-MM-dd HH:mm`）・`LeadTimeHours`・`SizeCategory`
- Produces:
  - `$script:LeadTimeSummaryGroupIds = @('All', 'Large', 'Medium', 'Small')`
  - `Get-LeadTimeWeeklySummary -Records -Config -Range` → 行の列: `Repository, SizeGroup, WeekStart, WeekEnd, Days, IsPartial, Under24h, From24To72h, Over72h, Total`。並び: リポジトリ → SizeGroup（All, Large, Medium, Small）→ 週の昇順
  - `Get-LeadTimeDailySummary -Records -Config -Range` → 行の列: `Repository, SizeGroup, Date, Under24h, From24To72h, Over72h, Total`（`Date` は `yyyy-MM-dd`）。並び: リポジトリ → SizeGroup → 日付の昇順
  - 内部: `Get-LeadTimeTargetRecords`、`Get-LeadTimeSizeGroupRecords -Records -GroupId`、`Get-LeadTimeCountsByPeriod -Records -Unit -WeekStartDay`（→ hashtable）、`Get-LeadTimeCountOrZero -Counts -Key`（→ hashtable）

- [ ] **Step 1: テストヘルパーを変更する**

`tests/Run-Tests.ps1` の `function New-LeadTimeRecord { ... }` を次に置き換える（`-SizeCategory` を追加）。

```powershell
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
```

`function New-LeadTimeTestData { ... }` の `$records = @( ... )` を次に置き換える（サイズを付ける。値の意味は変えない）。

```powershell
    $records = @(
        New-LeadTimeRecord 1 '2026-09-03T01:00:00Z' 5 -SizeCategory 'XS'     # 8/31 の週・24時間未満・小
        New-LeadTimeRecord 2 '2026-09-04T00:00:00Z' 30 -SizeCategory 'M'     # 8/31 の週・24〜72時間・中
        New-LeadTimeRecord 3 '2026-09-15T00:00:00Z' 100 -SizeCategory 'XL'   # 9/14 の週・72時間以上・大
        New-LeadTimeRecord 4 '2026-09-15T00:00:00Z' 5 -Status 'abandoned' -SizeCategory 'S'   # 数えない
        New-LeadTimeRecord 5 '2026-09-29T00:00:00Z' 72                       # 9/28 の週・72時間以上（境界）・サイズ不明
        $active                                                              # 完了日時なし → 数えない
    )
```

- [ ] **Step 2: 既存テストを新しい行の形に追従させる**

`Get-LeadTimeWeeklySummary` は 1 週につき 4 行（全体・大・中・小）を返すようになる。既存テストの期待値は「全体」の行で確認するよう、取得行を `SizeGroup -eq 'All'` で絞る（期待値自体は変えない）。

`It '週次集計: マージ済みだけ数え、0 件の週と端の週の日数を出す'` の先頭 2 行

```powershell
    $d = New-LeadTimeTestData
    $rows = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range)
```

を次に置き換える。

```powershell
    $d = New-LeadTimeTestData
    $all = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    Assert-Equal 20 $all.Count '（5 週 × 全体・大・中・小）'
    $rows = @($all | Where-Object { $_.SizeGroup -eq 'All' })
```

次のテストの `$rows = @(Get-LeadTimeWeeklySummary ...)` の行の末尾の `)` の直前に ` | Where-Object { $_.SizeGroup -eq 'All' }` を足す（例: `$rows = @(Get-LeadTimeWeeklySummary -Records $records -Config $config -Range $range | Where-Object { $_.SizeGroup -eq 'All' })`）。

- `It '週次集計: 日曜 23:30(日本時間)完了はその週、月曜 00:30 は翌週'`
- `It '週次集計: 複数リポジトリでは (ALL) の行が追加される'`
- `It 'SVG: 折れ線 3 本・端の週の点は白抜き・ツールチップと * 付きラベル'`
- `It 'HTML: 見出し・凡例・グラフ・注記・表があり、記号はエスケープされる'`
- `It 'HTML: 対象の PR が 0 件でもグラフを出し、その旨を表示する'`
- `It 'HTML: 週の始まりの曜日名が設定どおりに日本語で出る（既定は月曜日）'`（2 か所）

- [ ] **Step 3: 新しいテストを書く**

`It '週次集計: 複数リポジトリでは (ALL) の行が追加される' { ... }` の**直後**に追加する。

```powershell
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

```

- [ ] **Step 4: テストが失敗することを確認する**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`
Expected: `SizeGroup` が無い・`Get-LeadTimeDailySummary` が無いため、変更・追加したテストが `[FAIL]` になる（全体 34 件中、成功は 29 件未満）

- [ ] **Step 5: 実装する**

`src/LeadTimeChart.ps1` の `function Get-LeadTimeWeeklySummary { ... }`（関数全体）を、次のコードで置き換える。

```powershell
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
```

`Invoke-PrMetrics.ps1` の次の行

```powershell
            $chartHtml = New-LeadTimeChartHtml -Summary $leadTimeWeekly -Config $config -Range $range
```

を次に置き換える（HTML はまだ全体のグラフしか描かないため、全体の行だけを渡す）。

```powershell
            # HTML は全体のグラフを描くため、全体の行だけを渡す
            $chartHtml = New-LeadTimeChartHtml -Summary @($leadTimeWeekly | Where-Object { $_.SizeGroup -eq 'All' }) -Config $config -Range $range
```

- [ ] **Step 6: テストが通ることを確認する（5.1 と 7）**

Run: テストの実行コマンド（2 つとも）
Expected: `結果: 34 件すべて成功`

- [ ] **Step 7: コミット**

```bash
git add src/LeadTimeChart.ps1 Invoke-PrMetrics.ps1 tests/Run-Tests.ps1
git commit -m "feat: 週次集計にサイズ区分(大中小)を追加し、日次集計を追加" -m "集計を「対象の絞り込み → 大中小の振り分け → 期間ごとの件数」の共通関数にまとめ、週次・日次で使い回す。週次 CSV の行は 1 週につき 全体・大・中・小 の 4 行になる（全体の値は従来と同じ）。" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: SVG の一般化（日単位・縦軸の上限）と描き方の対応表

**Files:**
- Modify: `src/LeadTimeChart.ps1`（`New-LeadTimeChartSvg` を置き換え、`Get-LeadTimeMaxCount`・描き方の対応表・`New-LeadTimeChart` を追加）
- Modify: `tests/Run-Tests.ps1`

**Interfaces:**
- Consumes: `$script:LeadTimeBuckets`、`New-LeadTimeMarkerSvg`、`Format-SvgNumber`（既存）、週次行（`WeekStart`, `IsPartial`, 3 区分）・日次行（`Date`, 3 区分）
- Produces:
  - `Get-LeadTimeMaxCount -Rows <object[]>` → `[int]`（3 区分の件数の最大値、行が無ければ 0）
  - `New-LeadTimeChartSvg -Rows [-Unit Week|Day = 'Week'] [-YMax <int> = 0] [-Width 900] [-Height 360]` → SVG 文字列。`-YMax` は縦軸の上限の最小値（データの最大値の方が大きければそちらを使う）。日単位は端の白抜き・`*` なし、ツールチップ「09/28 24時間未満: 2件」
  - `$script:LeadTimeChartStyles = @{ Week = 'Line'; Day = 'Line' }`
  - `$script:LeadTimeDailySizeGroups = @('All', 'Large', 'Medium', 'Small')`
  - `New-LeadTimeChart -Rows -Unit Week|Day [-YMax <int>]` → 対応表に従って描画関数を選んで SVG を返す。未知の値は例外

- [ ] **Step 1: 失敗するテストを書く**

`tests/Run-Tests.ps1` の `It 'SVG: 週が多いと横軸ラベルを間引く（26 週 → 9 個）' { ... }` の**直後**に追加する。

```powershell
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

```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`
Expected: 追加した 3 件が `[FAIL]`、`結果: 34 件成功 / 3 件失敗`

- [ ] **Step 3: 実装する**

`src/LeadTimeChart.ps1` の `function New-LeadTimeChartSvg { ... }`（関数全体）を、次のコードで置き換える。

```powershell
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
```

- [ ] **Step 4: テストが通ることを確認する（5.1 と 7）**

Run: テストの実行コマンド（2 つとも）
Expected: `結果: 37 件すべて成功`

- [ ] **Step 5: コミット**

```bash
git add src/LeadTimeChart.ps1 tests/Run-Tests.ps1
git commit -m "feat: 折れ線グラフを日単位と縦軸の上限指定に対応し、描き方の対応表を追加" -m "グラフの描き方は \$script:LeadTimeChartStyles と New-LeadTimeChart の 1 か所で決める（日単位の表し方を将来変えやすくするため）。" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: HTML の構成変更（全体・大・中・小 × 週・日）と実行への組み込み

**Files:**
- Modify: `src/LeadTimeChart.ps1`（`New-LeadTimeChartHtml` を置き換え、補助関数を追加）
- Modify: `Invoke-PrMetrics.ps1`（日次集計・日次 CSV・HTML の引数）
- Modify: `tests/Run-Tests.ps1`

**Interfaces:**
- Consumes: Task 1〜3 の関数（`$script:LeadTimeSizeGroups`, `Get-LeadTimeSizeGroupRangeText`, `Get-LeadTimeWeeklySummary`, `Get-LeadTimeDailySummary`, `Get-LeadTimeMaxCount`, `New-LeadTimeChart`, `$script:LeadTimeDailySizeGroups`）、`Export-PrMetricsCsv`・`Export-PrMetricsHtml`（`src/Output.ps1`）
- Produces:
  - `New-LeadTimeChartHtml -WeeklySummary <object[]> -DailySummary <object[]> -Config -Range [-GeneratedAt]` → HTML 文字列（**`-Summary` は廃止**）
  - 補助: `Get-LeadTimeGroupLabel -GroupId`（All → 全体）、`Get-LeadTimeRowsTotal -Rows`、`New-LeadTimeGroupChartsHtml -GroupId -WeeklyRows -DailyRows [-WeeklyYMax] [-DailyYMax]`
  - 出力ファイル `summary_leadtime_daily.csv`

- [ ] **Step 1: 既存の HTML テストを新しい引数に書き換える**

`tests/Run-Tests.ps1` の次の 3 つのテストを、それぞれ次のコードで**置き換える**。

`It 'HTML: 見出し・凡例・グラフ・注記・表があり、記号はエスケープされる'`:

```powershell
It 'HTML: 見出し・凡例・グラフ・注記・表があり、記号はエスケープされる' {
    $d = New-LeadTimeTestData
    $d.Config.Project = 'P<&>'
    $weekly = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    $daily = @(Get-LeadTimeDailySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    $html = New-LeadTimeChartHtml -WeeklySummary $weekly -DailySummary $daily -Config $d.Config -Range $d.Range -GeneratedAt ([datetime]'2026-10-09 10:00')
    Assert-Contains $html '<meta charset="utf-8">'
    Assert-Contains $html '<h1>クローズまでの時間別 PR 件数</h1>'
    Assert-Contains $html '2026-09-03 〜 2026-09-30'
    Assert-Contains $html 'P&lt;&amp;&gt;'
    if ($html.Contains('P<&>')) { throw 'プロジェクト名がエスケープされていない' }
    Assert-Contains $html '<h2>RepoA</h2>'
    Assert-Contains $html '24〜72時間未満'
    Assert-Contains $html '* 08/31 の週は 4 日分'
    Assert-Contains $html '* 09/28 の週は 3 日分'
    Assert-Contains $html '<td class="left">2026-09-14</td>'
    if ($html.Contains('対象の PR がありません')) { throw 'PR があるのに「対象の PR がありません」が出ている' }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) "prm_chart_$([guid]::NewGuid().ToString('N')).html"
    try {
        Export-PrMetricsHtml -Html $html -Path $tmp
        Assert-Equal $html ([IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8))
    }
    finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}
```

`It 'HTML: 対象の PR が 0 件でもグラフを出し、その旨を表示する'`:

```powershell
It 'HTML: 対象の PR が 0 件でもグラフを出し、その旨を表示する' {
    $d = New-LeadTimeTestData
    $weekly = @(Get-LeadTimeWeeklySummary -Records @() -Config $d.Config -Range $d.Range)
    $daily = @(Get-LeadTimeDailySummary -Records @() -Config $d.Config -Range $d.Range)
    $html = New-LeadTimeChartHtml -WeeklySummary $weekly -DailySummary $daily -Config $d.Config -Range $d.Range
    Assert-Contains $html '<h3>全体（0件）</h3>'
    Assert-Contains $html '対象の PR がありません'
    Assert-Contains $html '<svg '
}
```

`It 'HTML: 週の始まりの曜日名が設定どおりに日本語で出る（既定は月曜日）'`:

```powershell
It 'HTML: 週の始まりの曜日名が設定どおりに日本語で出る（既定は月曜日）' {
    $d = New-LeadTimeTestData
    $weekly = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    $daily = @(Get-LeadTimeDailySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    Assert-Contains (New-LeadTimeChartHtml -WeeklySummary $weekly -DailySummary $daily -Config $d.Config -Range $d.Range) '週の始まり: 月曜日'

    $d.Config.WeekStartDay = 'Sunday'
    $weekly = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    $daily = @(Get-LeadTimeDailySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    Assert-Contains (New-LeadTimeChartHtml -WeeklySummary $weekly -DailySummary $daily -Config $d.Config -Range $d.Range) '週の始まり: 日曜日'
}
```

- [ ] **Step 2: 新しいテストを書く**

`It 'HTML: 週の始まりの曜日名が設定どおりに日本語で出る（既定は月曜日）' { ... }` の**直後**に追加する。

```powershell
function New-LeadTimeTestHtml {
    # New-LeadTimeTestData から HTML を作る（$Mutate で明細を書き換えられる）
    param([scriptblock]$Mutate = {})
    $d = New-LeadTimeTestData
    foreach ($record in $d.Records) { & $Mutate $record }
    $weekly = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    $daily = @(Get-LeadTimeDailySummary -Records $d.Records -Config $d.Config -Range $d.Range)
    return (New-LeadTimeChartHtml -WeeklySummary $weekly -DailySummary $daily -Config $d.Config -Range $d.Range)
}

It 'HTML: 全体→大→中→小 の順に、それぞれ週単位→日単位のグラフが並ぶ' {
    $html = New-LeadTimeTestHtml
    Assert-Equal 8 (Measure-Match $html '<svg ')
    Assert-Equal 4 (Measure-Match $html '<h4>週単位</h4>')
    Assert-Equal 4 (Measure-Match $html '<h4>日単位</h4>')
    $headings = @('<h3>全体（4件）</h3>', '<h3>大（L・XL：251行〜）（1件）</h3>', '<h3>中（M：51〜250行）（1件）</h3>', '<h3>小（XS・S：〜50行）（1件）</h3>')
    $positions = @($headings | ForEach-Object { $html.IndexOf($_) })
    for ($i = 0; $i -lt $positions.Count; $i++) { if ($positions[$i] -lt 0) { throw "見出しが無い: $($headings[$i])" } }
    for ($i = 1; $i -lt $positions.Count; $i++) { if ($positions[$i] -le $positions[$i - 1]) { throw "並び順が違う: $($headings[$i])" } }
    $weekPos = $html.IndexOf('<h4>週単位</h4>')
    $dayPos = $html.IndexOf('<h4>日単位</h4>')
    if (-not ($positions[0] -lt $weekPos -and $weekPos -lt $dayPos -and $dayPos -lt $positions[1])) { throw '全体の中が 週単位 → 日単位 の順になっていない' }
}
It 'HTML: サイズ不明の件数を注記する' {
    $html = New-LeadTimeTestHtml
    Assert-Contains $html '※ サイズ不明の 1 件は、サイズ別（大・中・小）のグラフに含まれていません（全体には含まれます）。'
}
It 'HTML: 全件サイズ不明なら大中小のグラフの代わりに案内を出す' {
    $html = New-LeadTimeTestHtml -Mutate { param($r) $r.SizeCategory = '' }
    Assert-Contains $html 'サイズを計算していないため、サイズ別のグラフは表示できません'
    Assert-Equal 2 (Measure-Match $html '<svg ')
    if ($html.Contains('<h3>大')) { throw '全件サイズ不明なのに大のグラフがある' }
    if ($html.Contains('※ サイズ不明')) { throw '案内と注記が両方出ている' }
}
It 'HTML: 数値の表は開閉式（週単位・日単位）' {
    $html = New-LeadTimeTestHtml
    Assert-Equal 2 (Measure-Match $html '<details>')
    Assert-Contains $html '<summary>数値の表（週単位）</summary>'
    Assert-Contains $html '<summary>数値の表（日単位）</summary>'
    Assert-Contains $html '<td class="left">2026-09-30</td><td class="left">小</td>'
}

```

- [ ] **Step 3: テストが失敗することを確認する**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`
Expected: `-WeeklySummary` が無いため、書き換えた 3 件と追加した 4 件が `[FAIL]`、`結果: 34 件成功 / 7 件失敗`

- [ ] **Step 4: 実装する**

`src/LeadTimeChart.ps1` の `function New-LeadTimeChartHtml { ... }`（関数全体）を、次のコードで置き換える。CSS は波かっこを含むので `-f` を使わず、単一引用符のヒアストリングでそのまま追加する（閉じの `'@` は行頭）。

```powershell
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
```

- [ ] **Step 5: テストが通ることを確認する（5.1 と 7）**

Run: テストの実行コマンド（2 つとも）
Expected: `結果: 41 件すべて成功`

- [ ] **Step 6: `Invoke-PrMetrics.ps1` を更新する**

次の 3 行（Task 2 で変えた行を含む）

```powershell
            $leadTimeWeekly = Get-LeadTimeWeeklySummary -Records $sortedRecords -Config $config -Range $range
            Export-PrMetricsCsv -Data $leadTimeWeekly -Path (Join-Path $outputDir 'summary_leadtime_weekly.csv')
            # HTML は全体のグラフを描くため、全体の行だけを渡す
            $chartHtml = New-LeadTimeChartHtml -Summary @($leadTimeWeekly | Where-Object { $_.SizeGroup -eq 'All' }) -Config $config -Range $range
```

を次に置き換える。

```powershell
            $leadTimeWeekly = Get-LeadTimeWeeklySummary -Records $sortedRecords -Config $config -Range $range
            $leadTimeDaily = Get-LeadTimeDailySummary -Records $sortedRecords -Config $config -Range $range
            Export-PrMetricsCsv -Data $leadTimeWeekly -Path (Join-Path $outputDir 'summary_leadtime_weekly.csv')
            Export-PrMetricsCsv -Data $leadTimeDaily -Path (Join-Path $outputDir 'summary_leadtime_daily.csv')
            $chartHtml = New-LeadTimeChartHtml -WeeklySummary $leadTimeWeekly -DailySummary $leadTimeDaily -Config $config -Range $range
```

テストを再実行し、`結果: 41 件すべて成功`（5.1 と 7）を確認する。

- [ ] **Step 7: 通し実行（`-ReplayDir`、5.1 と 7）**

`$env:TEMP\prm_e2e` を空にしてから、次の 2 ファイルを作る。

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
- `完了: 6 件` で終わり、警告が出ない
- 最新の出力フォルダに `summary_leadtime_weekly.csv`、`summary_leadtime_daily.csv`、`leadtime_chart.html` がある
- `summary_leadtime_weekly.csv` は 20 行（5 週 × 4 区分）。`SizeGroup = All` の 5 行は次の値。`Large`・`Medium`・`Small` の行はすべて 0（`SizeMethod=None` で全件サイズ不明のため）

| WeekStart | Days | Under24h | From24To72h | Over72h |
|---|---|---|---|---|
| 2026-08-31 | 4 | 1 | 1 | 0 |
| 2026-09-07 | 7 | 1 | 0 | 0 |
| 2026-09-14 | 7 | 0 | 0 | 1 |
| 2026-09-21 | 7 | 0 | 1 | 0 |
| 2026-09-28 | 3 | 1 | 0 | 0 |

- `summary_leadtime_daily.csv` は 112 行（28 日 × 4 区分）。`SizeGroup = All` の行のうち `Total` が 1 の日は 2026-09-03, 09-04, 09-08, 09-15, 09-22, 09-28 の 6 日だけ
- `leadtime_chart.html` に「サイズを計算していないため、サイズ別のグラフは表示できません」があり、`<svg ` は 2 個

- [ ] **Step 8: 見た目確認用の HTML を作る（大中小あり）**

`$env:TEMP\prm_e2e\visual.ps1` を次の内容で作り（UTF-8 BOM 付き）、5.1 で実行する。`visual_check.html` の絶対パスを報告する（見た目の確認はコントローラーが行う）。

```powershell
# 見た目確認用: 架空の明細（3 か月・大中小とサイズ不明を含む）から HTML を作る
$root = 'D:\Work\AzureDevOps\pr-metrics'
foreach ($f in 'Config.ps1', 'Aggregator.ps1', 'Output.ps1', 'LeadTimeChart.ps1') { . (Join-Path (Join-Path $root 'src') $f) }
$config = @{}
foreach ($k in $script:PrMetricsDefaultConfig.Keys) { $config[$k] = $script:PrMetricsDefaultConfig[$k] }
$config.Organization = 'contoso'; $config.Project = 'SampleProject'; $config.Repositories = @('SampleRepo')
$config.FromDate = '2026-07-01'; $config.ToDate = '2026-09-30'
$tz = [TimeZoneInfo]::FindSystemTimeZoneById($config.TimeZoneId)
$range = Get-PrMetricsDateRange -Config $config -TimeZone $tz
$culture = [Globalization.CultureInfo]::InvariantCulture
$rnd = New-Object System.Random 7
$categories = @('XS', 'S', 'M', 'L', 'XL', '')
$records = for ($i = 0; $i -lt 150; $i++) {
    $closed = $range.FromLocal.AddMinutes($rnd.Next(0, 92 * 24 * 60))
    [pscustomobject]@{
        Repository = 'SampleRepo'; Status = 'completed'
        ClosedAt = $closed.ToString('yyyy-MM-dd HH:mm', $culture)
        LeadTimeHours = [math]::Round($rnd.NextDouble() * 150, 2)
        SizeCategory = $categories[$rnd.Next(0, $categories.Count)]
    }
}
$weekly = @(Get-LeadTimeWeeklySummary -Records $records -Config $config -Range $range)
$daily = @(Get-LeadTimeDailySummary -Records $records -Config $config -Range $range)
$path = Join-Path $PSScriptRoot 'visual_check.html'
Export-PrMetricsHtml -Html (New-LeadTimeChartHtml -WeeklySummary $weekly -DailySummary $daily -Config $config -Range $range) -Path $path
$path
```

- [ ] **Step 9: コミット**

```bash
git add src/LeadTimeChart.ps1 Invoke-PrMetrics.ps1 tests/Run-Tests.ps1
git commit -m "feat: グラフを全体・大・中・小 × 週・日の 8 つにし、日次 CSV を出力" -m "大中小は縦軸の上限をそろえる。サイズ不明の PR は全体にだけ含め、件数を注記する（全件不明なら案内）。数値の表は開閉式にする。" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: 資料（ADR・README・設計資料・AGENTS.md）

**Files:**
- Create: `docs/adr/README.md`, `docs/adr/ADR-0001-サイズ不明のPRの扱い.md`, `docs/adr/ADR-0002-日単位グラフの表し方.md`
- Modify: `docs/01_要件定義.md`, `docs/02_基本設計.md`, `docs/05_詳細設計.md`, `docs/06_出力仕様.md`, `docs/07_動作確認手順.md`, `docs/09_GitHubCopilot活用ガイド.md`, `README.md`, `AGENTS.md`

**Interfaces:**
- Consumes: Task 1〜4 で決まった関数名・定数名・列名・出力ファイル名・HTML の文言
- Produces: なし

- [ ] **Step 1: `docs/adr/README.md` を作る**

```markdown
# ADR（設計判断の記録）

このツールの設計で「なぜそうしたか」を、1 つの判断につき 1 ファイルで記録する。

- 判断を変えるときは、元の ADR を書き換えずに新しい ADR を作り、元の ADR の「状態」を「置き換え（ADR-xxxx）」にする。
- 古い設計判断（D-01〜D-09）は `docs/02_基本設計.md` の 5 章にある。今後の判断はここに追加し、02 の 5 章には要点とリンクだけを書く。

| 番号 | タイトル | 状態 | 日付 |
|---|---|---|---|
| [ADR-0001](ADR-0001-サイズ不明のPRの扱い.md) | サイズ不明の PR の扱い | 採用 | 2026-10-29 |
| [ADR-0002](ADR-0002-日単位グラフの表し方.md) | 日単位グラフの表し方 | 採用 | 2026-10-29 |
```

- [ ] **Step 2: `docs/adr/ADR-0001-サイズ不明のPRの扱い.md` を作る**

```markdown
# ADR-0001: サイズ不明の PR の扱い

- 状態: 採用
- 日付: 2026-10-29
- 関係: [仕様書](../superpowers/specs/2026-10-29-leadtime-daily-and-size-charts-design.md) 2.3

## 背景

「クローズまでの時間別 PR 件数」のグラフを、PR のサイズ（大・中・小）ごとにも出すことにした。
大・中・小は既存の `SizeCategory`（XS〜XL）をまとめたもの（小 = XS・S / 中 = M / 大 = L・XL）だが、次の PR は `SizeCategory` が決まらない。

- `SizeMethod = 'None'` で実行したとき（サイズを計算しないので全件）
- サイズ計算に失敗した PR（`SizeSource = 'unavailable'`。例: マージコミットが clone から取得できない）
- `SizeCategories` 設定で区分名を変えたり増やしたりして、XS/S/M/L/XL のどれにも当たらない PR

## 決定

1. サイズ不明の PR は**「全体」には含め、大・中・小には含めない**。
2. 小のグラフの後に「※ サイズ不明の N 件は、サイズ別（大・中・小）のグラフに含まれていません（全体には含まれます）。」と注記する（N = 0 なら出さない）。
3. 全体が 1 件以上で大・中・小がすべて 0 件（＝全件サイズ不明）のときは、大・中・小のグラフを描かず、「サイズを計算していないため、サイズ別のグラフは表示できません（`SizeMethod` を `Git` または `Api` にして実行してください）。」と表示する。
4. CSV（`summary_leadtime_weekly.csv` / `summary_leadtime_daily.csv`）では、`SizeGroup = All` の行にだけ含まれる。そのため「All の件数 − 大中小の件数の合計 = サイズ不明の件数」になる。

## 理由

- **全体の件数を実際の件数と一致させるため。** サイズが分からなくても「マージされた PR」であることは確かなので、全体から除くと頻度の数字が実態より少なくなる。
- **傾向を歪めないため。** サイズ不明の PR を大・中・小のどれかに入れると（例: 「中」とみなす）、その区分の傾向が根拠なく変わる。
- **気付けるようにするため。** 除外した件数を注記するので、サイズ別グラフの合計が全体と合わない理由が分かる。全件不明のときに空のグラフを 3 つ並べると「PR が無い」と誤解されるので、案内に置き換える。

## 検討した代替案

| 案 | 採らなかった理由 |
|---|---|
| 全体からも除く | 全体の件数が実態より少なくなり、既存の週次グラフ（全体）の数字も変わってしまう |
| 「サイズ不明」のグラフを 4 つ目として出す | 原因が設定や取得の失敗であり、傾向を見る対象ではない。件数の注記で足りる |
| `SizeMethod = 'None'` のときはサイズ別を出力しない（見出しも出さない） | 何も出ないと、なぜ無いのか分からない。案内を出す方が親切 |

## 影響

- サイズ不明が多いと、大・中・小の合計が全体より小さくなる。サイズ不明が多い場合は、`prs.csv` の `SizeSource` / `SizeNote` で原因を確認する（[08 トラブルシューティング](../08_トラブルシューティング.md)）。
- `SizeCategories` の区分名を変える場合は、`src/LeadTimeChart.ps1` の `$script:LeadTimeSizeGroups` の `Categories` も合わせて変える必要がある。

## 見直しの目安

- サイズ不明の割合が恒常的に大きい（例: 1 割以上）なら、取得方法（Q-3）の改修か、「不明」のグラフ追加を検討する。
```

- [ ] **Step 3: `docs/adr/ADR-0002-日単位グラフの表し方.md` を作る**

```markdown
# ADR-0002: 日単位グラフの表し方

- 状態: 採用
- 日付: 2026-10-29
- 関係: [仕様書](../superpowers/specs/2026-10-29-leadtime-daily-and-size-charts-design.md) 2.2・6.2

## 背景

クローズまでの時間別 PR 件数のグラフに、週単位に加えて日単位を追加する（全体・大・中・小のそれぞれ）。
実装前に架空データ（3 か月分）で見本を作ったところ、日単位を週単位と同じ折れ線にすると次の弱点があった。

- 土日は必ず 0 件になるため、線が毎週 0 まで落ちてギザギザになる
- 1 日あたりの件数が少ない（0〜3 件程度）ため、3 本の線と点が重なり、色の見分けが難しい
- 大・中・小に分けるとさらに件数が減り、0 件の日が大半になる

## 決定

**日単位も、週単位と同じ折れ線（3 本・点付き）で表す。**（利用者が見本を確認したうえで選んだ）

ただし、後から表し方を変えやすいように、コードを次の形にしておく。

- グラフの描き方は `src/LeadTimeChart.ps1` の対応表 `$script:LeadTimeChartStyles = @{ Week = 'Line'; Day = 'Line' }` と、描画関数を選ぶ `New-LeadTimeChart` の 1 か所で決める。HTML（`New-LeadTimeChartHtml`）は描画関数を直接呼ばない。
- 日単位のグラフを出す区分は `$script:LeadTimeDailySizeGroups = @('All', 'Large', 'Medium', 'Small')` で決める。

## 理由

- 週単位と同じ見た目なので、読み方を新しく覚えなくてよい。
- 日ごとの細かい値は、ツールチップと「数値の表（日単位）」でも確認できる。
- 実データで使ってみてから判断したい。変更しやすい形にしておけば、後から変えるコストは小さい。

## 代替案と切り替え手順

| 案 | 内容 | 長所 | 短所 |
|---|---|---|---|
| A | 日単位を**積み上げ棒グラフ**にする（1 日 1 本、3 色に塗り分け） | 線が重ならない。0 件の日は棒が無いだけでギザギザにならない。1 日の合計も見える | 区分ごとの推移（線の上下）は追いにくい |
| B | 日単位は**点を描かない細い折れ線**にする | 少し見やすくなる。変更が最小 | 重なりとギザギザは残る |
| C | 日単位は**全体だけ**にする（大中小は週単位だけ） | グラフが 8 → 5 つに減り、ページが短くなる | 大中小の日ごとの動きは見られない（CSV にはある） |

### 案 A に切り替える

1. `src/LeadTimeChart.ps1` に `New-LeadTimeBarChartSvg -Rows -Unit -YMax` を追加する。
   - 横軸・縦軸・ラベルの間引き・`<title>` の文言は `New-LeadTimeChartSvg` と同じ規則にする（共通部分は関数に切り出す）。
   - 縦軸の上限は「3 区分の合計（`Total`）の最大値」と `-YMax` の大きい方にする（積み上げなので合計が高さになる）。HTML 側の大中小の上限も `Get-LeadTimeMaxCount` ではなく `Total` の最大値で求めるよう変える。
   - 棒の色・凡例は `$script:LeadTimeBuckets` の `Color` を使う。
2. `New-LeadTimeChart` の `switch` に `'Bar' { return New-LeadTimeBarChartSvg -Rows $Rows -Unit $Unit -YMax $YMax }` を追加する。
3. `$script:LeadTimeChartStyles.Day = 'Bar'` にする。
4. テスト: 棒の数（日数 × 3 区分、0 件は高さ 0 または描かない）、ツールチップ、`-YMax`、`New-LeadTimeChart` が `Bar` を選ぶこと。
5. 資料: この ADR の状態を「置き換え（ADR-xxxx）」にし、新しい ADR を作る。`docs/06_出力仕様.md` の HTML の節、`README.md` の「グラフの見方」を更新する。

### 案 B に切り替える

1. `New-LeadTimeChartSvg` に `[switch]$NoMarkers` を追加し、指定時は点（`<g class="point">`）を描かず、線の太さを 1 にする。ツールチップが無くなるので、代わりに `<polyline>` に `<title>`（区分名）を付ける。
2. `New-LeadTimeChart` の `switch` に `'LineNoMarker' { return New-LeadTimeChartSvg -Rows $Rows -Unit $Unit -YMax $YMax -NoMarkers }` を追加し、`$script:LeadTimeChartStyles.Day = 'LineNoMarker'` にする。
3. テスト・資料は案 A と同様。

### 案 C に切り替える

1. `$script:LeadTimeDailySizeGroups = @('All')` にする（大中小の見出しの下は週単位だけになる）。
2. テスト: 「全体→大→中→小、各 週→日」のテストの `<svg ` 数・`<h4>日単位</h4>` 数の期待値を 5・1 に変える（仕様変更なので期待値の変更が正しい）。
3. 資料は案 A と同様。CSV（日次）は変わらない。

Copilot に依頼するときのプロンプト例: [docs/09 の 3.9](../09_GitHubCopilot活用ガイド.md)

## 見直しの目安

- 実データで日単位のグラフを見て、「どの線か分からない」「ほぼ 0 で読めない」と感じたら、まず案 A（積み上げ棒）を試す。
- 日単位の大中小をほとんど見ないなら、案 C でページを短くする。
```

- [ ] **Step 4: `docs/02_基本設計.md` に D-10・D-11 を追加する**

`## 6. セキュリティ設計` の**直前**に追加する。

```markdown
### D-10. サイズ不明の PR は全体にだけ含める（ADR-0001）
- **要点**: サイズ別（大・中・小）のグラフ・CSV からは除き、全体には含める。件数を注記し、全件不明なら案内を出す。
- **詳細**: [ADR-0001](adr/ADR-0001-サイズ不明のPRの扱い.md)

### D-11. 日単位のグラフも折れ線にし、描き方は 1 か所で切り替えられるようにする（ADR-0002）
- **要点**: 日単位も週単位と同じ折れ線。描き方は `$script:LeadTimeChartStyles` と `New-LeadTimeChart` で決め、積み上げ棒などに変えやすくしてある。
- **詳細**: [ADR-0002](adr/ADR-0002-日単位グラフの表し方.md)

```

- [ ] **Step 5: `README.md` を更新する**

出力ファイルの表の次の 2 行

```markdown
| `summary_leadtime_weekly.csv` | マージ済み PR の、クローズまでの時間（24時間未満 / 24〜72時間未満 / 72時間以上）別の週次件数 |
| `leadtime_chart.html` | 上記の折れ線グラフ（ブラウザで開く） |
```

を次の 3 行に置き換える。

```markdown
| `summary_leadtime_weekly.csv` | マージ済み PR の、クローズまでの時間（24時間未満 / 24〜72時間未満 / 72時間以上）別の週次件数（全体・大・中・小） |
| `summary_leadtime_daily.csv` | 同じく日次件数（全体・大・中・小） |
| `leadtime_chart.html` | 上記の折れ線グラフ（ブラウザで開く。下の「グラフの見方」を参照） |
```

`## よくある変更` の**直前**に、次の節を追加する。

````markdown
## グラフの見方（leadtime_chart.html）

### 開き方

実行が終わったら、出力フォルダ（実行の最後に表示される `完了: N 件 → ...` のフォルダ）の `leadtime_chart.html` をダブルクリックします。
最新の出力のグラフをコマンドで開く場合:

```powershell
Invoke-Item (Join-Path (Get-ChildItem .\output -Directory | Sort-Object Name | Select-Object -Last 1).FullName 'leadtime_chart.html')
```

ファイル 1 つで完結していて外部に接続しないので、社内ネットワークでもそのまま表示でき、メールなどで共有もできます。

### 並び

リポジトリごとに、次の順でグラフが並びます。

| 見出し | 対象 | グラフ |
|---|---|---|
| 全体 | マージ済みのすべての PR | 週単位 → 日単位 |
| 大 | サイズ区分 L・XL（既定 251 行〜） | 週単位 → 日単位 |
| 中 | サイズ区分 M（既定 51〜250 行） | 週単位 → 日単位 |
| 小 | サイズ区分 XS・S（既定 〜50 行） | 週単位 → 日単位 |

- 大・中・小の範囲は設定の `SizeCategories` に従います（見出しに実際の範囲が表示されます）。
- 大・中・小のグラフは縦軸の目盛りがそろっているので、線の高さで件数を比べられます（全体は別の目盛り）。
- 数値は、ページの最後の「数値の表（週単位）」「数値の表（日単位）」をクリックすると開きます（CSV と同じ値）。

### 記号の意味

| 表示 | 意味 |
|---|---|
| 緑の線・丸 | クローズまで 24 時間未満の PR の件数 |
| オレンジの線・四角 | 24 時間以上 72 時間未満 |
| 赤の線・三角 | 72 時間以上 |
| 白抜きの点、横軸の `*` | その週は集計範囲の端で、7 日分そろっていない（グラフの下に何日分かを注記） |
| 点にマウスを重ねる | 「09/28 の週 24時間未満: 5件」のように値を表示 |

### サイズが分からない PR

`SizeMethod = 'None'` で実行した場合や、サイズの計算に失敗した PR は、サイズ（大・中・小）が分かりません。

- そうした PR は**「全体」のグラフには含まれ、大・中・小のグラフには含まれません。** 件数は「※ サイズ不明の N 件は…」として表示されます。
- 全件のサイズが分からない場合は、大・中・小のグラフの代わりに「サイズを計算していないため…」と表示されます。`SizeMethod` を `Git` または `Api` にして実行してください。
- こう決めた理由は [ADR-0001](docs/adr/ADR-0001-サイズ不明のPRの扱い.md) を参照してください。

### グラフが作られないとき

グラフと 2 つの CSV（週次・日次）は、設定の `DateBasis` が `'Closed'`（既定）のときだけ作られます。それ以外では警告が表示され、ほかの出力だけが作られます。

---

````

フォルダ構成の次の行

```
├─ docs/                       … 設計資料
```

を次に置き換える。

```
├─ docs/                       … 設計資料（docs/adr/ は設計判断の記録）
```

- [ ] **Step 6: `docs/01_要件定義.md` を更新する**

見出し `### 3.4 クローズまでの時間区分別の週次件数` を `### 3.4 クローズまでの時間区分別の件数（週次・日次・サイズ別）` に変える。

同じ表の次の 2 行

```markdown
| 週 | 完了日時（設定タイムゾーン）が属する週。週の始まりは `WeekStartDay`。横軸は常に週単位 |
```

```markdown
| 出力 | `summary_leadtime_weekly.csv` と折れ線グラフ `leadtime_chart.html` |
```

を、それぞれ次に置き換える。

```markdown
| 週 | 完了日時（設定タイムゾーン）が属する週。週の始まりは `WeekStartDay` |
| 日 | 完了日時（設定タイムゾーン）の日付。範囲内のすべての日（土日・0 件の日も）を出す |
| サイズ別 | 既存の `SizeCategory` をまとめた 大（L・XL）／ 中（M）／ 小（XS・S）ごとにも数える。サイズ不明の PR は全体にだけ含める（[ADR-0001](adr/ADR-0001-サイズ不明のPRの扱い.md)） |
```

```markdown
| 出力 | `summary_leadtime_weekly.csv`（`SizeGroup` 列付き）、`summary_leadtime_daily.csv`、折れ線グラフ `leadtime_chart.html`（全体・大・中・小 × 週単位・日単位） |
```

機能要件の表の `| F-10 | ... |` の行の後に追加する。

```markdown
| F-11 | F-10 の件数を日単位でも数え、PR のサイズ（大・中・小）ごとにも数えて、CSV とグラフに出力する |
```

- [ ] **Step 7: `docs/05_詳細設計.md` の 7 章を置き換える**

`## 7. LeadTimeChart.ps1` から、その後の `---` の直前までを、次の内容に置き換える。

```markdown
## 7. LeadTimeChart.ps1

クローズまでの時間区分別の件数（週次・日次 × 全体・大・中・小）と、その折れ線グラフ（HTML）を作る。
仕様: `docs/superpowers/specs/2026-10-09-leadtime-weekly-chart-design.md`、`docs/superpowers/specs/2026-10-29-leadtime-daily-and-size-charts-design.md`

| 関数 / 定義 | 内容 |
|---|---|
| `$script:LeadTimeBuckets` | 区分の定義（`Id`・`Label`・`Color`・`Marker`）。順序が CSV の列順・線の順 |
| `Get-LeadTimeBucket -Hours` | `< 24` → `Under24h`、`< 72` → `From24To72h`、それ以外 → `Over72h` |
| `$script:LeadTimeSizeGroups` | 大中小の定義（`Id`・`Label`・`Categories`）。順序 Large, Medium, Small が HTML の並び |
| `Get-LeadTimeSizeGroup -SizeCategory` | XS・S → `Small`、M → `Medium`、L・XL → `Large`、それ以外 → `''`（サイズ不明） |
| `Get-LeadTimeSizeGroupRangeText -GroupId -Config` | 見出しの範囲表示（例 `L・XL：251行〜`）。`SizeCategories` の閾値から作り、`SizeMethod='Api'` ならファイル数 |
| `$script:LeadTimeSummaryGroupIds` | 集計する区分 `All, Large, Medium, Small`（CSV の行の並び） |
| `Get-LeadTimeTargetRecords` / `Get-LeadTimeSizeGroupRecords` / `Get-LeadTimeCountsByPeriod` / `Get-LeadTimeCountOrZero` | 集計の共通部（対象の絞り込み → 大中小の振り分け → 期間キーごとの件数）。週次・日次で使い回す |
| `Get-LeadTimeWeeklySummary -Records -Config -Range` | 週 × 区分 × SizeGroup の件数。範囲内の全週を出す。`Days` は範囲で切れた日数（1〜7） |
| `Get-LeadTimeDailySummary -Records -Config -Range` | 日 × 区分 × SizeGroup の件数。範囲内の全日を出す |
| `Get-LeadTimeMaxCount -Rows` | 3 区分の件数の最大値（大中小の縦軸をそろえるのに使う） |
| `New-LeadTimeChartSvg -Rows [-Unit Week\|Day] [-YMax] [-Width] [-Height]` | 折れ線グラフの SVG。縦軸の上限は `-YMax` とデータの最大値の大きい方。横軸ラベルは最大 12 個。週単位の端の週は白抜き・`*`。ツールチップは週「09/28 の週 …」、日「09/28 …」 |
| `$script:LeadTimeChartStyles` / `New-LeadTimeChart -Rows -Unit [-YMax]` | 描き方の対応表（既定 `Week='Line'; Day='Line'`）と、それに従って描画関数を選ぶ関数。HTML は必ずこれを通す（ADR-0002） |
| `$script:LeadTimeDailySizeGroups` | 日単位のグラフを出す区分（既定 全区分）。`@('All')` にすると日単位は全体だけ |
| `New-LeadTimeChartHtml -WeeklySummary -DailySummary -Config -Range [-GeneratedAt]` | 単一 HTML。全体 → 大 → 中 → 小（各 週 → 日）。大中小は縦軸をそろえる。サイズ不明の注記・全件不明の案内（ADR-0001）。数値の表は `<details>`。文字列は `WebUtility.HtmlEncode` |
| `Get-LeadTimeGroupLabel` / `Get-LeadTimeRowsTotal` / `New-LeadTimeGroupChartsHtml` | HTML の補助（区分の表示名、件数の合計、1 区分分の「週グラフ＋注記＋日グラフ」） |
| `Test-LeadTimeChartEnabled -Config` | `DateBasis='Closed'` なら `$true` |

`Invoke-PrMetrics.ps1` は既存 CSV の出力後に、`Test-LeadTimeChartEnabled` が `$true` なら週次・日次集計 → `summary_leadtime_weekly.csv`・`summary_leadtime_daily.csv` → `leadtime_chart.html`（`Export-PrMetricsHtml`）を出力する。例外は警告にして処理を続ける。`$false` なら警告だけ出す。

日単位の表し方を変える手順は [ADR-0002](adr/ADR-0002-日単位グラフの表し方.md) を参照。

```

`## 8. テスト` の表の `| LeadTimeChart | ... |` の行を次に置き換える。

```markdown
| LeadTimeChart | 区分の境界、大中小の振り分けと範囲表示、マージ済みのみ、週次（0 件の週・端の週の日数・週の境目・`SizeGroup` の 4 行）、日次（全日・日付の境目）、`(ALL)` 行、SVG（線 3 本・白抜き・ラベル間引き・日単位・`-YMax`）、描き方の切り替え、HTML（並び順・範囲表示・サイズ不明の注記・全件不明の案内・`<details>`・エスケープ・0 件表示）、DateBasis による作成可否 |
```

- [ ] **Step 8: `docs/06_出力仕様.md` を更新する**

冒頭のファイル一覧表の `| summary_leadtime_weekly.csv | ... |` の行の**後**に追加する。

```markdown
| `summary_leadtime_daily.csv` | UTF-8 BOM 付き | `DateBasis='Closed'` のとき | クローズまでの時間区分別の日次件数 |
```

`## 4. summary_leadtime_weekly.csv` の節の本文の 1 行目

```markdown
（リポジトリ × 週）= 1 行。範囲内のすべての週を出力する（0 件の週も含む）。リポジトリが複数のときは `(ALL)` の行も出す。
```

を次に置き換える。

```markdown
（リポジトリ × SizeGroup × 週）= 1 行。範囲内のすべての週を出力する（0 件の週も含む）。リポジトリが複数のときは `(ALL)` の行も出す。
並びはリポジトリ → SizeGroup（All, Large, Medium, Small）→ 週の昇順。サイズ不明の PR は `All` にだけ含まれる（[ADR-0001](adr/ADR-0001-サイズ不明のPRの扱い.md)）。
```

同じ節の表の `| Repository | ... |` の行の**後**に追加する。

```markdown
| `SizeGroup` | `All` | `All`（全体）/ `Large`（大: L・XL）/ `Medium`（中: M）/ `Small`（小: XS・S） |
```

見出し `## 7. Excel での活用例` を `## 8. Excel での活用例`、`## 6. run_info.json` を `## 7. run_info.json`、`## 5. leadtime_chart.html` を `## 6. leadtime_chart.html` に変え、`## 6. leadtime_chart.html`（旧 5）の**直前**に次の節を挿入する。

```markdown
## 5. summary_leadtime_daily.csv

（リポジトリ × SizeGroup × 日）= 1 行。範囲内のすべての日（土日・0 件の日も）を出力する。対象・区分・SizeGroup の扱いは週次と同じ。

| 列 | 例 | 説明 |
|---|---|---|
| `Repository` | `SampleRepo` | リポジトリ名 または `(ALL)` |
| `SizeGroup` | `Small` | `All` / `Large` / `Medium` / `Small` |
| `Date` | `2026-09-28` | 完了日（設定タイムゾーン） |
| `Under24h` | `2` | クローズまで 24 時間未満の件数 |
| `From24To72h` | `1` | 24 時間以上 72 時間未満の件数 |
| `Over72h` | `0` | 72 時間以上の件数 |
| `Total` | `3` | 3 区分の合計 |

```

`## 6. leadtime_chart.html`（旧 5）の本文（箇条書き）を、次に置き換える。

```markdown
ブラウザで開く単一の HTML。外部リソースを読み込まないので、社内ネットワークでも表示できる。

- 見出し: 組織 / プロジェクト、集計範囲、週の始まり、対象の条件、作成日時
- リポジトリごとに: 凡例（1 回）、次の順のグラフ、注記、開閉式の数値の表 2 つ（週単位・日単位）
  1. 全体（N件）: 週単位 → 日単位
  2. 大（L・XL：251行〜）（N件）: 週単位 → 日単位
  3. 中（M：51〜250行）（N件）: 週単位 → 日単位
  4. 小（XS・S：〜50行）（N件）: 週単位 → 日単位
- 大中小の範囲表示は `SizeCategories` の閾値から作る（`SizeMethod='Api'` ならファイル数）
- 大中小のグラフは縦軸の上限がそろう（週は週どうし、日は日どうし）
- グラフ: 縦軸は件数。24時間未満（緑・丸）、24〜72時間未満（オレンジ・四角）、72時間以上（赤・三角）
- 週単位: 横軸は週の開始日（`MM/dd`）。端の週は点が白抜き・横軸ラベルに `*`・グラフの下に「* 09/28 の週は 3 日分（集計範囲の端のため）」。ツールチップ「09/28 の週 24時間未満: 5件」
- 日単位: 横軸は日付（`MM/dd`）。ツールチップ「09/28 24時間未満: 2件」
- サイズ不明の PR がある場合「※ サイズ不明の N 件は、サイズ別（大・中・小）のグラフに含まれていません（全体には含まれます）。」。全件サイズ不明なら大中小のグラフの代わりに「サイズを計算していないため、サイズ別のグラフは表示できません…」（[ADR-0001](adr/ADR-0001-サイズ不明のPRの扱い.md)）
- 対象の PR が 0 件のときは「対象の PR がありません」と表示する
- 日単位の表し方（折れ線）を変える場合は [ADR-0002](adr/ADR-0002-日単位グラフの表し方.md)
```

- [ ] **Step 9: `docs/07_動作確認手順.md` を更新する**

Step 5 の期待結果の次の 2 行

```markdown
- `output\yyyyMMdd_HHmmss\` に CSV 4 つ（`summary_leadtime_weekly.csv` を含む）、`leadtime_chart.html`、`run_info.json` ができる
  （`summary_leadtime_weekly.csv` と `leadtime_chart.html` は `DateBasis = 'Closed'`（既定）のときだけ作られる）
```

を次に置き換える。

```markdown
- `output\yyyyMMdd_HHmmss\` に CSV 5 つ（`summary_leadtime_weekly.csv`・`summary_leadtime_daily.csv` を含む）、`leadtime_chart.html`、`run_info.json` ができる
  （`summary_leadtime_weekly.csv`・`summary_leadtime_daily.csv`・`leadtime_chart.html` は `DateBasis = 'Closed'`（既定）のときだけ作られる）
```

確認表の `| 5-6 | ... |` の行を次に置き換え、`| 5-7 | ... |` の行の後に 5-8 を追加する。

```markdown
| 5-6 | グラフが表示されるか | `leadtime_chart.html` をブラウザで開く。全体の週単位・日単位のグラフ、凡例、数値の表（クリックで開く）が表示され、日本語が化けていない。`-SizeMethod None` の実行では大中小の代わりに「サイズを計算していないため…」が出る |
```

```markdown
| 5-8 | サイズ別のグラフ（Step 6・7 の実行後） | `SizeMethod` が `Api` / `Git` の実行結果で、大・中・小のグラフが出ていること。大中小の件数の合計 ＋ サイズ不明の件数 ＝ 全体の件数 になっていること |
```

チェックリストの `- [ ] Step 5: 件数・日時・境界・文字化け・週次グラフを確認` を `- [ ] Step 5: 件数・日時・境界・文字化け・グラフ（週単位・日単位）を確認` に変える。

- [ ] **Step 10: `docs/09_GitHubCopilot活用ガイド.md` にプロンプト例を追加する**

`## 4. 不具合調査のプロンプト集` の**直前**に追加する。

````markdown
### 3.9 日単位グラフの表し方を変える（ADR-0002）

日単位のグラフが読みにくいと感じたら、[ADR-0002](adr/ADR-0002-日単位グラフの表し方.md) の案から選んで依頼する。

**案 A（積み上げ棒グラフ）**

```
#file:AGENTS.md #file:docs/adr/ADR-0002-日単位グラフの表し方.md #file:src/LeadTimeChart.ps1 #file:tests/Run-Tests.ps1
ADR-0002 の「案 A に切り替える」の手順で、日単位のグラフを積み上げ棒グラフにしてください。
- 先にテストを書いて失敗を確認してから実装してください
- 週単位のグラフは折れ線のまま変えないでください
- ADR-0002 の状態を「置き換え」にし、新しい ADR を作ってください。docs/06 と README の「グラフの見方」も更新してください
- 最後に 5.1 と 7 の両方でテストを実行し、結果を見せてください
```

**案 B（点なしの細い折れ線）／ 案 C（日単位は全体だけ）**

```
#file:AGENTS.md #file:docs/adr/ADR-0002-日単位グラフの表し方.md #file:src/LeadTimeChart.ps1 #file:tests/Run-Tests.ps1
ADR-0002 の「案 <B または C> に切り替える」の手順で変更してください。
条件は案 A のときと同じです（テスト先行、ADR と資料の更新、5.1 と 7 でのテスト）。
```

````

- [ ] **Step 11: `AGENTS.md` を更新する**

「構成」の表の `| docs/01〜09 | ... |` の行の**後**に追加する。

```markdown
| `docs/adr/` | 設計判断の記録（ADR）。1 判断 1 ファイル | — |
```

同じ表の `src/LeadTimeChart.ps1` の行の役割 `クローズまでの時間区分別の週次集計・折れ線グラフ（SVG/HTML）` を `クローズまでの時間区分別の集計（週次・日次 × 全体・大中小）・折れ線グラフ（SVG/HTML）` に変える。

「変更内容ごとに更新するもの」の表の `| ファイル構成の変更 | ... |` の行の**後**に追加する。

```markdown
| 設計判断の追加・変更 | `docs/adr/` に ADR を追加し `docs/adr/README.md` の一覧に載せる（既存の判断を変えるときは元の ADR の状態を「置き換え」にして新しい ADR を作る）。`docs/02_基本設計.md` 5 章に D-xx として要点とリンクを書く |
```

- [ ] **Step 12: 確認する**

- `git diff` で、実在の組織名・人名などが含まれていないことを確認する
- 追加・変更した Markdown のリンク先ファイル（`adr/...`、`../superpowers/...`、`../08_...` など）が存在することを確認する
- テストの実行コマンド（2 つとも）で `結果: 41 件すべて成功`

- [ ] **Step 13: コミット**

```bash
git add docs/adr docs/01_要件定義.md docs/02_基本設計.md docs/05_詳細設計.md docs/06_出力仕様.md docs/07_動作確認手順.md docs/09_GitHubCopilot活用ガイド.md README.md AGENTS.md
git commit -m "docs: ADR(サイズ不明の扱い・日単位グラフの表し方)と README のグラフの見方を追加し、資料を更新" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
