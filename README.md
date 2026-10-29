# PR メトリクス収集ツール（Azure DevOps）

Azure DevOps のリポジトリから Pull Request（PR）を取得し、**頻度（件数）・リードタイム・サイズ（変更行数/ファイル数）** を集計して CSV に出力する PowerShell ツールです。

- 対象: 組織 `contoso` / プロジェクト `SampleProject` / リポジトリ `SampleRepo`（設定ファイルで変更可）
- 動作環境: Windows PowerShell 5.1 または PowerShell 7 以上（追加モジュール不要）
- サイズ計算に行数まで使う場合は Git for Windows が必要

---

## クイックスタート（会社 PC）

```powershell
# 0) このフォルダへ移動
cd C:\path\to\pr-metrics

# 1) PAT（Code: Read 権限）を環境変数に設定（このウィンドウの間だけ有効）
$env:AZDO_PAT = '<ここに PAT>'

# 2) 接続確認（何もファイルは作られません）
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-PrMetrics.ps1 -Mode TestConnection

# 3) まずはサイズ計算なしで動作確認（速い）
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-PrMetrics.ps1 -SizeMethod None

# 4) 本番実行（設定ファイルどおり。既定は Git 方式で行数まで計算）
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-PrMetrics.ps1
```

結果は `output\yyyyMMdd_HHmmss\` に出力されます。

| ファイル | 内容 |
|---|---|
| `prs.csv` | PR 1 件 = 1 行の明細（作成者・日時・リードタイム・行数・サイズ区分 など） |
| `summary_by_period.csv` | 週/月ごとの PR 件数・リードタイム中央値・サイズ中央値・サイズ区分の内訳 |
| `summary_by_author.csv` | 作成者ごとの PR 件数・週あたり件数・中央値 |
| `summary_leadtime_weekly.csv` | マージ済み PR の、クローズまでの時間（24時間未満 / 24〜72時間未満 / 72時間以上）別の週次件数（全体・大・中・小） |
| `summary_leadtime_daily.csv` | 同じく日次件数（全体・大・中・小） |
| `leadtime_chart.html` | 上記の折れ線グラフ（ブラウザで開く。下の「グラフの見方」を参照） |
| `run_info.json` | 実行条件の記録（期間・設定・件数） |

CSV は UTF-8（BOM 付き）なので、Excel でそのまま開けます。

---

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

## よくある変更

設定はすべて [`config/settings.psd1`](config/settings.psd1) にあり、コメントで説明しています。

| やりたいこと | 変更する項目 |
|---|---|
| 対象リポジトリを増やす | `Repositories = @('SampleRepo', 'SampleTools')` |
| 期間を固定する | `FromDate = '2026-04-01'` と `ToDate = '2026-09-30'` |
| 直近 30 日にする | `LastNDays = 30`（FromDate/ToDate は空のまま） |
| 月単位で集計する | `PeriodUnit = 'Month'` |
| main へのマージだけを数える | `TargetBranches = @('refs/heads/main')` |
| 生成物をサイズから除外する | `ExcludePathPatterns` にパターンを追加 |
| サイズ区分の閾値を変える | `SizeCategories` |

一時的に変えたいだけなら、引数で上書きできます（設定ファイルは変更されません）。

```powershell
.\Invoke-PrMetrics.ps1 -FromDate 2026-04-01 -ToDate 2026-09-30 -Repositories SampleRepo -SizeMethod Api
```

---

## フォルダ構成

```
pr-metrics/
├─ Invoke-PrMetrics.ps1        … 実行するスクリプト（エントリポイント）
├─ config/settings.psd1        … 設定ファイル（ここを編集する）
├─ src/
│   ├─ Config.ps1              … 設定の読み込み・検証、期間・日時の計算
│   ├─ AzDoClient.ps1          … Azure DevOps REST API 呼び出し
│   ├─ SizeCalculator.ps1      … PR サイズ計算（Git / Api 方式）
│   ├─ Aggregator.ps1          … レコード化・期間別/作成者別の集計
│   ├─ Output.ps1              … CSV/JSON/HTML 出力・画面表示
│   └─ LeadTimeChart.ps1       … クローズまでの時間区分別の週次集計・グラフ
├─ tests/Run-Tests.ps1         … 単体テスト（接続不要）
├─ docs/                       … 設計資料（docs/adr/ は設計判断の記録）
└─ AGENTS.md                   … AI コーディングエージェント（Copilot など）向けの作業ルール
```

## 設計資料

| No | 資料 | 内容 |
|---|---|---|
| 01 | [要件定義](docs/01_要件定義.md) | 目的・スコープ・**指標の定義**・前提と制約 |
| 02 | [基本設計](docs/02_基本設計.md) | 全体構成・処理フロー・設計判断の理由 |
| 03 | [Azure DevOps API 仕様](docs/03_AzureDevOps_API仕様.md) | 使用する REST API・パラメーター・レスポンス項目・手動での確認方法 |
| 04 | [設定ファイル仕様](docs/04_設定ファイル仕様.md) | 全設定項目と変更例 |
| 05 | [詳細設計](docs/05_詳細設計.md) | 関数ごとの仕様・サイズ計算アルゴリズム・集計ロジック |
| 06 | [出力仕様](docs/06_出力仕様.md) | CSV の列定義・計算式 |
| 07 | [動作確認手順](docs/07_動作確認手順.md) | **会社 PC での段階的な確認手順と要確認事項** |
| 08 | [トラブルシューティング](docs/08_トラブルシューティング.md) | エラー別の原因と対処 |
| 09 | [GitHub Copilot 活用ガイド](docs/09_GitHubCopilot活用ガイド.md) | Copilot に渡すプロンプト例（**[不具合調査のプロンプト集](docs/09_GitHubCopilot活用ガイド.md#4-不具合調査のプロンプト集)** を含む） |

## 困ったときは

1. [08 トラブルシューティング](docs/08_トラブルシューティング.md) で、表示されたエラーに当てはまるものを探す
2. 解決しなければ、GitHub Copilot で調査する → [不具合調査のプロンプト集](docs/09_GitHubCopilot活用ガイド.md#4-不具合調査のプロンプト集)

## テスト

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```
