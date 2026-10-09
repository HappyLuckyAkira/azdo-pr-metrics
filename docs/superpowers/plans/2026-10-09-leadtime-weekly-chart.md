# クローズまでの時間別 PR 件数の週次グラフ 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** マージ済み PR を完了週ごとに「24時間未満 / 24〜72時間未満 / 72時間以上」で数え、週次 CSV と折れ線グラフ（HTML）を既存の実行で出力する。

**Architecture:** 新規ファイル `src/LeadTimeChart.ps1` に「区分判定 → 週次集計 → SVG 生成 → HTML 生成」の純粋関数を置き、`Invoke-PrMetrics.ps1` が既存 CSV 出力のあとに呼び出してファイルに書き出す。週の計算とグループ分けは既存の `Get-PeriodStart` / `Get-PeriodStarts` / `Get-RecordGroups`（`src/Aggregator.ps1`）を再利用する。

**Tech Stack:** PowerShell（Windows PowerShell 5.1 と PowerShell 7）、インライン SVG、自作テストランナー `tests/Run-Tests.ps1`

**仕様書:** [docs/superpowers/specs/2026-10-09-leadtime-weekly-chart-design.md](../specs/2026-10-09-leadtime-weekly-chart-design.md)

## Global Constraints

- PowerShell 5.1 と 7 の両方で動くこと。`??`・`?.`・三項演算子・`&&`/`||`・`ConvertFrom-Json -AsHashtable`・3 引数以上の `Join-Path` は使わない
- `.ps1` / `.psd1` は UTF-8（BOM 付き）で保存する（新規ファイルも）
- 関数から配列を返すときに `return , $array` を使わない。呼び出し側で `@(...)` で受ける
- `Set-StrictMode` は使わない
- 外部ライブラリ・外部通信なし（HTML は単一ファイル、グラフはインライン SVG）
- 設定項目は追加しない
- 区分は固定: `Under24h`（0 ≤ 時間 < 24）/ `From24To72h`（24 ≤ 時間 < 72）/ `Over72h`（72 ≤ 時間）。境界ちょうどは上側
- 対象は `Status = 'completed'` かつ完了日時がある明細のみ
- 週は完了日時（設定タイムゾーン）で決め、週の始まりは既存の `WeekStartDay`
- グラフと週次 CSV は `DateBasis = 'Closed'` のときだけ作る
- テストは 5.1 / 7 の両方で全件成功させる。例に実名を使わない（`contoso` / `SampleProject` / `SampleRepo`）
- コミットメッセージは日本語、`feat:` / `docs:` / `test:` を付け、末尾に `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## ファイル構成

| ファイル | 種別 | 責務 |
|---|---|---|
| `src/LeadTimeChart.ps1` | 新規 | 区分の定義、`Get-LeadTimeBucket`、`Get-LeadTimeWeeklySummary`、`New-LeadTimeChartSvg`、`New-LeadTimeChartHtml`、`Test-LeadTimeChartEnabled` |
| `src/Output.ps1` | 変更 | `Export-PrMetricsHtml` を追加 |
| `Invoke-PrMetrics.ps1` | 変更 | `LeadTimeChart.ps1` の読み込み、週次 CSV と HTML の出力 |
| `tests/Run-Tests.ps1` | 変更 | `LeadTimeChart.ps1` の読み込み、テスト追加 |
| `docs/01, 05, 06, 07`, `README.md`, `AGENTS.md` | 変更 | 資料の更新 |

## テストの実行コマンド（全タスク共通）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
pwsh -NoProfile -File .\tests\Run-Tests.ps1
```

作業前の件数は `結果: 19 件すべて成功`（git がある環境）。各タスクの期待件数はこれを基準に書いている。

## BOM の付け方（新規 .ps1 を作ったとき）

```powershell
$p = 'src\LeadTimeChart.ps1'
$t = [IO.File]::ReadAllText($p)
[IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding $true))
```

---

### Task 1: 区分判定 `Get-LeadTimeBucket`

**Files:**
- Create: `src/LeadTimeChart.ps1`
- Modify: `tests/Run-Tests.ps1`（読み込みリスト・テスト追加）

**Interfaces:**
- Consumes: なし
- Produces:
  - `$script:LeadTimeBuckets` — 区分定義の配列。各要素は `[pscustomobject]@{ Id; Label; Color; Marker }`。順序は `Under24h`, `From24To72h`, `Over72h`
  - `Get-LeadTimeBucket -Hours <double>` → `[string]`（`'Under24h'` / `'From24To72h'` / `'Over72h'`）

- [ ] **Step 1: 空のファイルを作り、テストの読み込みリストに追加する**

`src/LeadTimeChart.ps1` を次の内容で作成し、BOM を付ける（上記「BOM の付け方」）。

```powershell
# =============================================================================
# LeadTimeChart.ps1
#   クローズまでの時間（作成 → 完了）を 3 区分に分け、週ごとの件数を集計して
#   折れ線グラフ（SVG を埋め込んだ HTML）を作る。
#   仕様: docs\superpowers\specs\2026-10-09-leadtime-weekly-chart-design.md
#   詳細設計: docs\05_詳細設計.md「LeadTimeChart.ps1」
# =============================================================================
```

`tests/Run-Tests.ps1` の読み込みリスト（16 行目付近）を変更する。

```powershell
foreach ($file in @('Config.ps1', 'AzDoClient.ps1', 'SizeCalculator.ps1', 'Aggregator.ps1', 'Output.ps1', 'LeadTimeChart.ps1')) {
```

- [ ] **Step 2: 失敗するテストを書く**

`tests/Run-Tests.ps1` の `Write-Host '== Git 方式（実リポジトリ）'` の**直前**に追加する。

```powershell
Write-Host '== LeadTimeChart'
It 'クローズまでの時間の区分: 境界ちょうどは上側の区分' {
    Assert-Equal 'Under24h' (Get-LeadTimeBucket -Hours 0)
    Assert-Equal 'Under24h' (Get-LeadTimeBucket -Hours 23.99)
    Assert-Equal 'From24To72h' (Get-LeadTimeBucket -Hours 24)
    Assert-Equal 'From24To72h' (Get-LeadTimeBucket -Hours 71.99)
    Assert-Equal 'Over72h' (Get-LeadTimeBucket -Hours 72)
    Assert-Equal 'Over72h' (Get-LeadTimeBucket -Hours 500)
}

```

- [ ] **Step 3: テストが失敗することを確認する**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`
Expected: `[FAIL] クローズまでの時間の区分...`（`Get-LeadTimeBucket` が認識されない）、`結果: 19 件成功 / 1 件失敗`

- [ ] **Step 4: 実装する**

`src/LeadTimeChart.ps1` の末尾に追加する。

```powershell

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
```

- [ ] **Step 5: テストが通ることを確認する（5.1 と 7）**

Run: テストの実行コマンド（2 つとも）
Expected: `結果: 20 件すべて成功`

- [ ] **Step 6: コミット**

```bash
git add src/LeadTimeChart.ps1 tests/Run-Tests.ps1
git commit -m "feat: クローズまでの時間の区分判定を追加" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: 週次集計 `Get-LeadTimeWeeklySummary`

**Files:**
- Modify: `src/LeadTimeChart.ps1`
- Modify: `tests/Run-Tests.ps1`

**Interfaces:**
- Consumes: `Get-LeadTimeBucket`（Task 1）、既存の `Get-PeriodStart -LocalDate -Unit -WeekStartDay`、`Get-PeriodStarts -Range -Unit -WeekStartDay`、`Get-RecordGroups -Records -Repositories`（`src/Aggregator.ps1`）、明細レコード（`ConvertTo-PrRecord` の出力。使う列は `Repository`, `Status`, `ClosedAt`（`yyyy-MM-dd HH:mm`、設定タイムゾーン）, `LeadTimeHours`）
- Produces: `Get-LeadTimeWeeklySummary -Records <object[]> -Config <hashtable> -Range <object>` → 行の配列。各行は順序付きの `[pscustomobject]`:
  `Repository [string]`, `WeekStart [string yyyy-MM-dd]`, `WeekEnd [string yyyy-MM-dd]`, `Days [int]`, `IsPartial [bool]`, `Under24h [int]`, `From24To72h [int]`, `Over72h [int]`, `Total [int]`
  並びはグループ（リポジトリ順、最後に `(ALL)`）→ 週の昇順。

- [ ] **Step 1: テスト用ヘルパーと失敗するテストを書く**

`tests/Run-Tests.ps1` の Task 1 で追加した `It 'クローズまでの時間の区分...' { ... }` の**直後**に追加する。

```powershell
function New-LeadTimeRecord {
    # 完了日時(UTC 文字列)とクローズまでの時間(時間)から明細レコードを作る
    param([int]$Id, [string]$ClosedUtc, [double]$Hours, [string]$Repo = 'RepoA', [string]$Status = 'completed')
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $closed = [datetime]::Parse($ClosedUtc, $culture, [Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal')
    $created = $closed.AddHours(-$Hours).ToString('yyyy-MM-ddTHH:mm:ssZ', $culture)
    $rec = ConvertTo-PrRecord -PullRequest (New-FakePr $Id $created $ClosedUtc) -Repository $Repo -Size (New-PrSizeResult) `
        -Config (New-TestConfig) -TimeZone $tokyo -WebBaseUrl 'x'
    $rec.Status = $Status
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
        New-LeadTimeRecord 1 '2026-09-03T01:00:00Z' 5      # 8/31 の週・24時間未満
        New-LeadTimeRecord 2 '2026-09-04T00:00:00Z' 30     # 8/31 の週・24〜72時間
        New-LeadTimeRecord 3 '2026-09-15T00:00:00Z' 100    # 9/14 の週・72時間以上
        New-LeadTimeRecord 4 '2026-09-15T00:00:00Z' 5 -Status 'abandoned'   # 数えない
        New-LeadTimeRecord 5 '2026-09-29T00:00:00Z' 72     # 9/28 の週・72時間以上（境界）
        $active                                            # 完了日時なし → 数えない
    )
    return @{ Config = $config; Range = $range; Records = $records }
}

It '週次集計: マージ済みだけ数え、0 件の週と端の週の日数を出す' {
    $d = New-LeadTimeTestData
    $rows = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range)
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
    $rows = @(Get-LeadTimeWeeklySummary -Records $records -Config $config -Range $range)
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
    $rows = @(Get-LeadTimeWeeklySummary -Records $records -Config $config -Range $range)
    Assert-Equal 3 $rows.Count
    Assert-Equal 'RepoA' $rows[0].Repository
    Assert-Equal 1 $rows[0].Total
    Assert-Equal 'RepoB' $rows[1].Repository
    Assert-Equal 1 $rows[1].From24To72h
    Assert-Equal '(ALL)' $rows[2].Repository
    Assert-Equal 2 $rows[2].Total
}

```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`
Expected: 追加した 3 件が `[FAIL]`（`Get-LeadTimeWeeklySummary` が認識されない）、`結果: 20 件成功 / 3 件失敗`

- [ ] **Step 3: 実装する**

`src/LeadTimeChart.ps1` の末尾に追加する。

```powershell

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
```

- [ ] **Step 4: テストが通ることを確認する（5.1 と 7）**

Run: テストの実行コマンド（2 つとも）
Expected: `結果: 23 件すべて成功`

- [ ] **Step 5: コミット**

```bash
git add src/LeadTimeChart.ps1 tests/Run-Tests.ps1
git commit -m "feat: クローズまでの時間区分別の週次集計を追加" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: 折れ線グラフ `New-LeadTimeChartSvg`

**Files:**
- Modify: `src/LeadTimeChart.ps1`
- Modify: `tests/Run-Tests.ps1`

**Interfaces:**
- Consumes: `$script:LeadTimeBuckets`（Task 1）、`Get-LeadTimeWeeklySummary` の行（Task 2。使う列は `WeekStart`, `IsPartial`, `Under24h`, `From24To72h`, `Over72h`）、`New-LeadTimeTestData`（Task 2 のテストヘルパー）
- Produces:
  - `New-LeadTimeChartSvg -Rows <object[]> [-Width <int>=900] [-Height <int>=360]` → `[string]`（`<svg ...>...</svg>`。行が 0 件なら空文字）
  - SVG 内のマークアップ規約（テストと HTML が依存する）:
    - 折れ線: `<polyline class="series series-{Id}" ...>` を区分ごとに 1 本
    - 点: `<g class="point">` または端の週は `<g class="point partial">`（白抜き）。中に `<title>{MM/dd} の週 {Label}: {N}件</title>`
    - 横軸ラベル: `<text class="x-label" ...>{MM/dd}</text>`。端の週は `{MM/dd}*`。最大 12 個になるよう間引く（`ceil(週数/12)` 個おき）

- [ ] **Step 1: 失敗するテストを書く**

`tests/Run-Tests.ps1` の Task 2 で追加したテスト（`'週次集計: 複数リポジトリでは (ALL)...'`）の**直後**に追加する。

```powershell
function Measure-Match {
    param([string]$Text, [string]$Pattern)
    return ([regex]::Matches($Text, $Pattern)).Count
}

It 'SVG: 折れ線 3 本・端の週の点は白抜き・ツールチップと * 付きラベル' {
    $d = New-LeadTimeTestData
    $rows = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range)
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

```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`
Expected: 追加した 2 件が `[FAIL]`、`結果: 23 件成功 / 2 件失敗`

- [ ] **Step 3: 実装する**

`src/LeadTimeChart.ps1` の末尾に追加する。

```powershell

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
```

- [ ] **Step 4: テストが通ることを確認する（5.1 と 7）**

Run: テストの実行コマンド（2 つとも）
Expected: `結果: 25 件すべて成功`

- [ ] **Step 5: コミット**

```bash
git add src/LeadTimeChart.ps1 tests/Run-Tests.ps1
git commit -m "feat: クローズまでの時間区分別の週次折れ線グラフ(SVG)を追加" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: HTML の組み立て `New-LeadTimeChartHtml` と `Export-PrMetricsHtml`

**Files:**
- Modify: `src/LeadTimeChart.ps1`
- Modify: `src/Output.ps1`
- Modify: `tests/Run-Tests.ps1`

**Interfaces:**
- Consumes: `$script:LeadTimeBuckets`（Task 1）、`Get-LeadTimeWeeklySummary` の行（Task 2）、`New-LeadTimeChartSvg`（Task 3）、`New-LeadTimeTestData`（Task 2 のテストヘルパー）
- Produces:
  - `New-LeadTimeChartHtml -Summary <object[]> -Config <hashtable> -Range <object> [-GeneratedAt <datetime>]` → `[string]`（完全な HTML 文書）
  - `Export-PrMetricsHtml -Html <string> -Path <string>`（UTF-8・BOM なしで保存）

- [ ] **Step 1: 失敗するテストを書く**

`tests/Run-Tests.ps1` の Task 3 で追加したテスト（`'SVG: 週が多いと横軸ラベルを間引く...'`）の**直後**に追加する。

```powershell
function Assert-Contains {
    param([string]$Text, [string]$Expected)
    if (-not $Text.Contains($Expected)) { throw "[$Expected] が含まれていない" }
}

It 'HTML: 見出し・凡例・グラフ・注記・表があり、記号はエスケープされる' {
    $d = New-LeadTimeTestData
    $d.Config.Project = 'P<&>'
    $rows = @(Get-LeadTimeWeeklySummary -Records $d.Records -Config $d.Config -Range $d.Range)
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
    $rows = @(Get-LeadTimeWeeklySummary -Records @() -Config $d.Config -Range $d.Range)
    $html = New-LeadTimeChartHtml -Summary $rows -Config $d.Config -Range $d.Range
    Assert-Contains $html '対象の PR がありません'
    Assert-Contains $html '<svg '
}

```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`
Expected: 追加した 2 件が `[FAIL]`、`結果: 25 件成功 / 2 件失敗`

- [ ] **Step 3: `Export-PrMetricsHtml` を実装する**

`src/Output.ps1` の `function Export-PrMetricsJson { ... }` の**直後**に追加する。

```powershell

function Export-PrMetricsHtml {
    <# HTML を UTF-8(BOM なし)で保存する。文字コードは HTML 内の <meta charset="utf-8"> で指定している。 #>
    param(
        [Parameter(Mandatory)][string]$Html,
        [Parameter(Mandatory)][string]$Path
    )
    [IO.File]::WriteAllText($Path, $Html, (New-Object Text.UTF8Encoding $false))
}
```

- [ ] **Step 4: `New-LeadTimeChartHtml` を実装する**

`src/LeadTimeChart.ps1` の末尾に追加する。CSS は波かっこを含むので、`-f` を使わず単一引用符のヒアストリングでそのまま追加する。

```powershell

function New-LeadTimeChartHtml {
    <#
    .SYNOPSIS
        週次集計の結果から、見出し・凡例・折れ線グラフ・注記・表をまとめた単一の HTML を作る。
    .DESCRIPTION
        外部リソースは読み込まない（社内ネットワークでも表示できるように）。
        埋め込む文字列はすべて HTML エスケープする。
        出力仕様: docs\06_出力仕様.md「leadtime_chart.html」
    #>
    [CmdletBinding()]
    param(
        [object[]]$Summary = @(),
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Range,
        [datetime]$GeneratedAt = (Get-Date)
    )

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $rows = @($Summary | Where-Object { $null -ne $_ })
    $repositories = @($rows | ForEach-Object { $_.Repository } | Select-Object -Unique)
    $weekStartName = (New-Object Globalization.CultureInfo 'ja-JP').DateTimeFormat.GetDayName([DayOfWeek]$Config.WeekStartDay)
    $fromText = $Range.FromLocal.ToString('yyyy-MM-dd', $culture)
    $toText = $Range.ToLocalExclusive.AddDays(-1).ToString('yyyy-MM-dd', $culture)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<!DOCTYPE html><html lang="ja"><head><meta charset="utf-8">')
    [void]$sb.Append('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.Append('<title>クローズまでの時間別 PR 件数（週次）</title><style>')
    [void]$sb.Append(@'
body { font-family: "Yu Gothic UI", "Meiryo", sans-serif; margin: 24px; color: #212121; background: #ffffff; }
h1 { font-size: 20px; margin-bottom: 8px; }
h2 { font-size: 16px; margin-top: 32px; }
.meta { color: #616161; font-size: 13px; margin: 2px 0; }
.legend { list-style: none; padding: 0; display: flex; gap: 16px; flex-wrap: wrap; font-size: 13px; }
.swatch { display: inline-block; width: 16px; height: 3px; vertical-align: middle; margin-right: 6px; }
.chart { max-width: 960px; }
.note { font-size: 12px; color: #616161; margin: 2px 0; }
.empty { color: #c62828; font-size: 13px; }
table { border-collapse: collapse; font-size: 13px; margin-top: 12px; }
th, td { border: 1px solid #e0e0e0; padding: 4px 10px; text-align: right; }
th { background: #f5f5f5; }
.left { text-align: left; }
'@)
    [void]$sb.Append('</style></head><body>')

    # 見出し
    [void]$sb.Append('<h1>クローズまでの時間別 PR 件数（週次）</h1>')
    [void]$sb.Append(('<p class="meta">組織 / プロジェクト: {0} / {1}</p>' -f [System.Net.WebUtility]::HtmlEncode([string]$Config.Organization), [System.Net.WebUtility]::HtmlEncode([string]$Config.Project)))
    [void]$sb.Append(('<p class="meta">集計範囲: {0} 〜 {1}（完了日、{2}）／ 週の始まり: {3}</p>' -f $fromText, $toText, [System.Net.WebUtility]::HtmlEncode([string]$Config.TimeZoneId), $weekStartName))
    [void]$sb.Append('<p class="meta">対象: マージ済み（completed）の PR ／ クローズまでの時間 = 完了日時 − 作成日時</p>')
    [void]$sb.Append(('<p class="meta">作成日時: {0}</p>' -f $GeneratedAt.ToString('yyyy-MM-dd HH:mm', $culture)))

    foreach ($repository in $repositories) {
        $groupRows = @($rows | Where-Object { $_.Repository -eq $repository })
        [void]$sb.Append(('<section><h2>{0}</h2>' -f [System.Net.WebUtility]::HtmlEncode([string]$repository)))

        # 凡例
        [void]$sb.Append('<ul class="legend">')
        foreach ($bucket in $script:LeadTimeBuckets) {
            [void]$sb.Append(('<li><span class="swatch" style="background:{0}"></span>{1}</li>' -f $bucket.Color, $bucket.Label))
        }
        [void]$sb.Append('</ul>')

        $total = 0
        foreach ($row in $groupRows) { $total += [int]$row.Total }
        if ($total -eq 0) { [void]$sb.Append('<p class="empty">対象の PR がありません</p>') }

        [void]$sb.Append('<div class="chart">')
        [void]$sb.Append((New-LeadTimeChartSvg -Rows $groupRows))
        [void]$sb.Append('</div>')

        # 端の週の注記
        foreach ($row in $groupRows) {
            if (-not [bool]$row.IsPartial) { continue }
            $label = [datetime]::ParseExact([string]$row.WeekStart, 'yyyy-MM-dd', $culture).ToString('MM/dd', $culture)
            [void]$sb.Append(('<p class="note">* {0} の週は {1} 日分（集計範囲の端のため）</p>' -f $label, $row.Days))
        }

        # 表
        [void]$sb.Append('<table><thead><tr><th class="left">週の開始日</th><th class="left">期間</th><th>日数</th>')
        foreach ($bucket in $script:LeadTimeBuckets) { [void]$sb.Append(('<th>{0}</th>' -f $bucket.Label)) }
        [void]$sb.Append('<th>合計</th></tr></thead><tbody>')
        foreach ($row in $groupRows) {
            $first = [datetime]::ParseExact([string]$row.WeekStart, 'yyyy-MM-dd', $culture)
            if ($Range.FromLocal -gt $first) { $first = $Range.FromLocal }
            $last = [datetime]::ParseExact([string]$row.WeekEnd, 'yyyy-MM-dd', $culture)
            [void]$sb.Append(('<tr><td class="left">{0}</td><td class="left">{1}〜{2}</td><td>{3}</td>' -f $row.WeekStart, $first.ToString('MM/dd', $culture), $last.ToString('MM/dd', $culture), $row.Days))
            foreach ($bucket in $script:LeadTimeBuckets) { [void]$sb.Append(('<td>{0}</td>' -f $row.($bucket.Id))) }
            [void]$sb.Append(('<td>{0}</td></tr>' -f $row.Total))
        }
        [void]$sb.Append('</tbody></table></section>')
    }

    [void]$sb.Append('</body></html>')
    return $sb.ToString()
}
```

- [ ] **Step 5: テストが通ることを確認する（5.1 と 7）**

Run: テストの実行コマンド（2 つとも）
Expected: `結果: 27 件すべて成功`

- [ ] **Step 6: コミット**

```bash
git add src/LeadTimeChart.ps1 src/Output.ps1 tests/Run-Tests.ps1
git commit -m "feat: クローズまでの時間区分別の週次グラフの HTML 出力を追加" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: 実行への組み込みと通し確認

**Files:**
- Modify: `src/LeadTimeChart.ps1`（`Test-LeadTimeChartEnabled` を追加）
- Modify: `Invoke-PrMetrics.ps1:54`（読み込みリスト）、`Invoke-PrMetrics.ps1:259` の直後（出力処理）
- Modify: `tests/Run-Tests.ps1`

**Interfaces:**
- Consumes: `Get-LeadTimeWeeklySummary`（Task 2）、`New-LeadTimeChartHtml`・`Export-PrMetricsHtml`（Task 4）、既存の `Export-PrMetricsCsv`、`$sortedRecords` / `$config` / `$range` / `$outputDir`（`Invoke-PrMetrics.ps1` の既存変数）
- Produces: `Test-LeadTimeChartEnabled -Config <hashtable>` → `[bool]`。出力ファイル `summary_leadtime_weekly.csv`、`leadtime_chart.html`

- [ ] **Step 1: 失敗するテストを書く**

`tests/Run-Tests.ps1` の Task 4 で追加したテスト（`'HTML: 対象の PR が 0 件でも...'`）の**直後**に追加する。

```powershell
It 'グラフは DateBasis=Closed のときだけ作る' {
    Assert-Equal $true (Test-LeadTimeChartEnabled -Config (New-TestConfig))
    Assert-Equal $false (Test-LeadTimeChartEnabled -Config (New-TestConfig @{ DateBasis = 'Created' }))
}

```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`
Expected: `結果: 27 件成功 / 1 件失敗`

- [ ] **Step 3: `Test-LeadTimeChartEnabled` を実装する**

`src/LeadTimeChart.ps1` の末尾に追加する。

```powershell

function Test-LeadTimeChartEnabled {
    <#
    .SYNOPSIS
        週次グラフを作るか判定する。DateBasis='Closed' のときだけ作る。
        'Created' だと「範囲内に作成された PR を完了週で数える」ことになり、意味がずれるため。
    #>
    param([Parameter(Mandatory)][hashtable]$Config)
    return ([string]$Config.DateBasis -eq 'Closed')
}
```

- [ ] **Step 4: テストが通ることを確認する（5.1 と 7）**

Run: テストの実行コマンド（2 つとも）
Expected: `結果: 28 件すべて成功`

- [ ] **Step 5: `Invoke-PrMetrics.ps1` に組み込む**

54 行目の読み込みリストを変更する。

```powershell
foreach ($file in @('Config.ps1', 'AzDoClient.ps1', 'SizeCalculator.ps1', 'Aggregator.ps1', 'Output.ps1', 'LeadTimeChart.ps1')) {
```

`Export-PrMetricsCsv -Data $authorSummary -Path (Join-Path $outputDir 'summary_by_author.csv')` の**直後**に追加する。

```powershell

    # ---- 6. クローズまでの時間区分別の週次グラフ ----
    # 失敗しても既存の CSV は出力済みなので、警告だけ出して続ける
    if (Test-LeadTimeChartEnabled -Config $config) {
        try {
            $leadTimeWeekly = Get-LeadTimeWeeklySummary -Records $sortedRecords -Config $config -Range $range
            Export-PrMetricsCsv -Data $leadTimeWeekly -Path (Join-Path $outputDir 'summary_leadtime_weekly.csv')
            $chartHtml = New-LeadTimeChartHtml -Summary $leadTimeWeekly -Config $config -Range $range
            Export-PrMetricsHtml -Html $chartHtml -Path (Join-Path $outputDir 'leadtime_chart.html')
        }
        catch {
            Write-Warning "クローズまでの時間の週次グラフを作成できませんでした（他の出力は完了しています）: $($_.Exception.Message)"
        }
    }
    else {
        Write-Warning "クローズまでの時間の週次グラフは DateBasis='Closed' のときだけ作成します（現在: $($config.DateBasis)）。"
    }
```

- [ ] **Step 6: テストを再実行する（読み込みの崩れがないか）**

Run: テストの実行コマンド（2 つとも）
Expected: `結果: 28 件すべて成功`

- [ ] **Step 7: 模擬データを作り、`-ReplayDir` で通し実行する（5.1 と 7）**

一時フォルダ（例: `$env:TEMP\prm_e2e`）に次の 2 ファイルを作る。

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

`$env:TEMP\prm_e2e\settings.e2e.psd1`（UTF-8 BOM 付き。`OutputDir` は実際のパスに置き換える）

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
- 最新の出力フォルダに `summary_leadtime_weekly.csv` と `leadtime_chart.html` がある
- `summary_leadtime_weekly.csv` が 5 行（8/31, 9/7, 9/14, 9/21, 9/28）で、次の値になる

| WeekStart | Days | Under24h | From24To72h | Over72h |
|---|---|---|---|---|
| 2026-08-31 | 4 | 1 | 1 | 0 |
| 2026-09-07 | 7 | 1 | 0 | 0 |
| 2026-09-14 | 7 | 0 | 0 | 1 |
| 2026-09-21 | 7 | 0 | 1 | 0 |
| 2026-09-28 | 3 | 1 | 0 | 0 |

- [ ] **Step 8: DateBasis=Created で警告になることを確認する**

`settings.e2e.psd1` に `DateBasis = 'Created'` を一時的に追加して実行する。
Expected: 「クローズまでの時間の週次グラフは DateBasis='Closed' のときだけ作成します（現在: Created）。」の警告が出て、最新の出力フォルダに `leadtime_chart.html` が無い。確認後に `DateBasis` の行を消す。

- [ ] **Step 9: 生成した HTML の見た目を確認する**

Step 7 の `leadtime_chart.html` をブラウザで開き、スクリーンショットで次を確認する。
- 見出しと集計範囲「2026-09-03 〜 2026-09-30」が表示される
- 緑・オレンジ・赤の 3 本の折れ線と凡例がある。点の形が丸・四角・三角
- 08/31 と 09/28 の点が白抜きで、横軸ラベルに `*` が付き、グラフの下に注記が 2 行ある
- 点にマウスを重ねると「09/14 の週 72時間以上: 1件」のように表示される
- 表が 5 行ある
- 日本語が文字化けしていない

- [ ] **Step 10: コミット**

```bash
git add src/LeadTimeChart.ps1 Invoke-PrMetrics.ps1 tests/Run-Tests.ps1
git commit -m "feat: 実行時にクローズまでの時間区分別の週次グラフを出力" -m "DateBasis='Closed' のときだけ summary_leadtime_weekly.csv と leadtime_chart.html を出力する。失敗しても既存の出力は残し、警告を出して続ける。" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: 資料の更新

**Files:**
- Modify: `docs/01_要件定義.md`, `docs/05_詳細設計.md`, `docs/06_出力仕様.md`, `docs/07_動作確認手順.md`, `README.md`, `AGENTS.md`

**Interfaces:**
- Consumes: Task 1〜5 で決まった関数名・ファイル名・列名
- Produces: なし

- [ ] **Step 1: `docs/01_要件定義.md` に指標を追加する**

`### 3.3 サイズ` の節の最後（サイズ区分の表の後、`## 4. 機能要件` の直前）に追加する。

```markdown

### 3.4 クローズまでの時間区分別の週次件数

| 項目 | 定義 |
|---|---|
| 対象 | 絞り込み後の PR のうち、マージ済み（`completed`）で完了日時があるもの |
| 週 | 完了日時（設定タイムゾーン）が属する週。週の始まりは `WeekStartDay`。横軸は常に週単位 |
| 区分 | 24時間未満（0 ≤ 時間 < 24）／ 24〜72時間未満（24 ≤ 時間 < 72）／ 72時間以上（72 ≤ 時間）。境界ちょうどは上側。区分は固定 |
| 端の週 | 集計範囲で切れた週はそのまま数え、日数を注記する |
| 出力 | `summary_leadtime_weekly.csv` と折れ線グラフ `leadtime_chart.html` |

- `DateBasis = 'Closed'` のときだけ出力する（`Created` では「範囲内に作成された PR を完了週で数える」ことになり意味がずれるため）。
```

`## 4. 機能要件` の表の最後の行（`| F-09 | ...`）の後に追加する。

```markdown
| F-10 | マージ済み PR を完了週ごとにクローズまでの時間の 3 区分で数え、週次 CSV と折れ線グラフ（HTML）を出力する |
```

- [ ] **Step 2: `docs/05_詳細設計.md` に章を追加する**

`## 7. テスト（tests/Run-Tests.ps1）` を `## 8. テスト（tests/Run-Tests.ps1）` に変え、その直前（`---` の後）に次の章を挿入する。

```markdown
## 7. LeadTimeChart.ps1

クローズまでの時間区分別の週次件数と、その折れ線グラフ（HTML）を作る。仕様: `docs/superpowers/specs/2026-10-09-leadtime-weekly-chart-design.md`

| 関数 | 内容 |
|---|---|
| `$script:LeadTimeBuckets` | 区分の定義（`Id`・`Label`・`Color`・`Marker`）。順序が CSV の列順・線の順 |
| `Get-LeadTimeBucket -Hours` | `< 24` → `Under24h`、`< 72` → `From24To72h`、それ以外 → `Over72h` |
| `Get-LeadTimeWeeklySummary -Records -Config -Range` | `Status='completed'` かつ `ClosedAt`・`LeadTimeHours` がある明細を、`ClosedAt` の週 × 区分で数える。週は `Get-PeriodStarts -Unit Week` で範囲内をすべて列挙し、0 件の週も出す。`Days` は範囲で切れた日数（1〜7）。グループは `Get-RecordGroups` |
| `New-LeadTimeChartSvg -Rows [-Width 900] [-Height 360]` | 1 グループ分の折れ線グラフを SVG 文字列で返す。縦軸は目盛り 5 本前後の整数刻み、横軸ラベルは最大 12 個（`ceil(週数/12)` 個おき）。端の週は点を白抜き・ラベルに `*`。各点に `<title>` |
| `New-LeadTimeChartHtml -Summary -Config -Range [-GeneratedAt]` | 見出し・凡例・SVG・端の週の注記・表をまとめた単一 HTML。文字列は `WebUtility.HtmlEncode` でエスケープ。全週 0 件なら「対象の PR がありません」 |
| `Test-LeadTimeChartEnabled -Config` | `DateBasis='Closed'` なら `$true` |

`Invoke-PrMetrics.ps1` は既存 CSV の出力後に、`Test-LeadTimeChartEnabled` が `$true` なら週次集計 → `summary_leadtime_weekly.csv` → `leadtime_chart.html`（`Export-PrMetricsHtml`）を出力する。例外は警告にして処理を続ける。`$false` なら警告だけ出す。

---

```

`## 6. Output.ps1` の表の `Export-PrMetricsJson` の行の後に追加する。

```markdown
| `Export-PrMetricsHtml` | UTF-8 BOM なし（HTML 内で `<meta charset="utf-8">` を指定） |
```

`## 8. テスト` の表の `| Git 方式 | ...` の行の前に追加する。

```markdown
| LeadTimeChart | 区分の境界、マージ済みのみ、0 件の週・端の週の日数、週の境目（日曜深夜/月曜未明）、`(ALL)` 行、SVG（線 3 本・白抜き・ラベル間引き）、HTML（エスケープ・注記・0 件表示）、DateBasis による作成可否 |
```

- [ ] **Step 3: `docs/06_出力仕様.md` に 2 ファイルを追加する**

冒頭のファイル一覧表の `| run_info.json | ...` の行の前に追加する。

```markdown
| `summary_leadtime_weekly.csv` | UTF-8 BOM 付き | `DateBasis='Closed'` のとき | クローズまでの時間区分別の週次件数 |
| `leadtime_chart.html` | UTF-8 | `DateBasis='Closed'` のとき | 上記の折れ線グラフ |
```

`## 4. run_info.json` を `## 6. run_info.json`、`## 5. Excel での活用例` を `## 7. Excel での活用例` に変え、`## 6. run_info.json` の直前に次を挿入する。

```markdown
## 4. summary_leadtime_weekly.csv

（リポジトリ × 週）= 1 行。範囲内のすべての週を出力する（0 件の週も含む）。リポジトリが複数のときは `(ALL)` の行も出す。
対象はマージ済み（`completed`）の PR だけ（`Statuses` に `abandoned` があっても数えない）。週は完了日時で決める。

| 列 | 例 | 説明 |
|---|---|---|
| `Repository` | `SampleRepo` | リポジトリ名 または `(ALL)` |
| `WeekStart` | `2026-09-28` | 週の開始日 |
| `WeekEnd` | `2026-09-30` | 週の最終日。範囲で切れる場合は範囲の最終日 |
| `Days` | `3` | 週のうち範囲に含まれる日数（1〜7） |
| `IsPartial` | `True` | `Days < 7` |
| `Under24h` | `5` | クローズまで 24 時間未満の件数 |
| `From24To72h` | `3` | 24 時間以上 72 時間未満の件数 |
| `Over72h` | `1` | 72 時間以上の件数 |
| `Total` | `9` | 3 区分の合計 |

## 5. leadtime_chart.html

ブラウザで開く単一の HTML。外部リソースを読み込まないので、社内ネットワークでも表示できる。

- 見出し: 組織 / プロジェクト、集計範囲、週の始まり、対象の条件、作成日時
- リポジトリごとに: 凡例、折れ線グラフ、端の週の注記、表
- グラフ: 横軸は週の開始日（`MM/dd`）、縦軸は件数。24時間未満（緑・丸）、24〜72時間未満（オレンジ・四角）、72時間以上（赤・三角）
- 端の週は点が白抜き、横軸ラベルに `*`、グラフの下に「* 09/28 の週は 3 日分（集計範囲の端のため）」
- 点にマウスを重ねると「09/28 の週 24時間未満: 5件」と表示される
- 対象の PR が 0 件のときは「対象の PR がありません」と表示する

```

- [ ] **Step 4: `docs/07_動作確認手順.md` に確認を追加する**

`## Step 5.` の「期待結果」の 2 行目を次に置き換える。

```markdown
- `output\yyyyMMdd_HHmmss\` に CSV 4 つ（`summary_leadtime_weekly.csv` を含む）、`leadtime_chart.html`、`run_info.json` ができる
```

`## Step 5.` の確認表の `| 5-5 | ...` の行の後に追加する。

```markdown
| 5-6 | 週次グラフが表示されるか | `leadtime_chart.html` をブラウザで開く。3 本の折れ線・凡例・表が表示され、日本語が化けていない |
| 5-7 | 週次グラフの件数が正しいか | 任意の 1 週について、`prs.csv` を `ClosedAt` でその週に絞り、`LeadTimeHours` を 24 / 72 で分けて数えた件数と、グラフの表の値を比べる |
```

`## チェックリスト（まとめ）` の `- [ ] Step 5: ...` の行を次に置き換える。

```markdown
- [ ] Step 5: 件数・日時・境界・文字化け・週次グラフを確認
```

- [ ] **Step 5: `README.md` を更新する**

出力ファイルの表の `| run_info.json | ...` の行の前に追加する。

```markdown
| `summary_leadtime_weekly.csv` | マージ済み PR の、クローズまでの時間（24時間未満 / 24〜72時間未満 / 72時間以上）別の週次件数 |
| `leadtime_chart.html` | 上記の折れ線グラフ（ブラウザで開く） |
```

フォルダ構成の `│   └─ Output.ps1 ...` の行を次の 2 行に置き換える。

```
│   ├─ Output.ps1              … CSV/JSON/HTML 出力・画面表示
│   └─ LeadTimeChart.ps1       … クローズまでの時間区分別の週次集計・グラフ
```

- [ ] **Step 6: `AGENTS.md` を更新する**

「構成」の表の `| src/Output.ps1 | ... |` の行を次の 2 行に置き換える。

```markdown
| `src/Output.ps1` | CSV/JSON/HTML の入出力・画面表示 | docs/05 6 章 |
| `src/LeadTimeChart.ps1` | クローズまでの時間区分別の週次集計・折れ線グラフ（SVG/HTML） | docs/05 7 章 |
```

同じ表の `| tests/Run-Tests.ps1 | 単体テスト（自作の簡易ランナー） | docs/05 7 章 |` の `7 章` を `8 章` に変える。

- [ ] **Step 7: 実名が入っていないこと・テストを最終確認する**

Run: `git diff` で、実在の組織名・人名などが含まれていないことを確認する。テストの実行コマンド（2 つとも）
Expected: `結果: 28 件すべて成功`

- [ ] **Step 8: コミット**

```bash
git add docs/01_要件定義.md docs/05_詳細設計.md docs/06_出力仕様.md docs/07_動作確認手順.md README.md AGENTS.md
git commit -m "docs: クローズまでの時間区分別の週次グラフを資料に反映" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
