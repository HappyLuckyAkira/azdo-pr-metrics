# AGENTS.md

AI コーディングエージェント（GitHub Copilot / Codex / Claude Code など）向けの作業ルールです。
人向けの説明は [README.md](README.md) と [docs/](docs/) にあります。

- 回答・コードコメント・コミットメッセージ・資料は**日本語**で書く。
- このファイルと `.github/copilot-instructions.md` が食い違う場合は、**このファイルが正**。

## プロジェクト概要

Azure DevOps のリポジトリから PR を取得し、**頻度・リードタイム・サイズ（変更行数/ファイル数）** を集計して CSV に出力する PowerShell ツール。

- 言語: PowerShell（**Windows PowerShell 5.1 と PowerShell 7 の両方**で動かす）
- 外部依存: なし（Pester も使わない）。行数の計算にだけ git を使う
- 利用者は会社 PC 上で実行する。開発環境から実際の Azure DevOps には接続できない前提で作業する

## コマンド

```powershell
# 単体テスト（接続不要）。変更したら必ず両方のバージョンで実行する
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
pwsh -NoProfile -File .\tests\Run-Tests.ps1

# 実行（実際の Azure DevOps と PAT が必要。エージェントは通常実行できない）
.\Invoke-PrMetrics.ps1 -ConfigPath .\config\settings.local.psd1
.\Invoke-PrMetrics.ps1 -Mode TestConnection          # 接続確認のみ
.\Invoke-PrMetrics.ps1 -SizeMethod None -Verbose     # サイズ計算なし・詳細ログ

# 保存済みの API データで再集計（API を呼ばない。SaveRawJson=$true で保存したフォルダを指定）
.\Invoke-PrMetrics.ps1 -ReplayDir .\output\<実行フォルダ>

# .ps1 / .psd1 に BOM があるか確認（先頭が EF BB BF なら OK）
Get-ChildItem -Recurse -Include *.ps1,*.psd1 | ForEach-Object { '{0} {1}' -f ((Get-Content $_ -Encoding Byte -TotalCount 3 | ForEach-Object { $_.ToString('X2') }) -join ' '), $_.Name }
```

> 最後のコマンドの `-Encoding Byte` は 5.1 用。PowerShell 7 では `-AsByteStream` に置き換える。

成功の基準: テストの最後に `結果: N 件すべて成功` が表示され、終了コードが 0。

## 構成

| パス | 役割 | 詳細設計 |
|---|---|---|
| `Invoke-PrMetrics.ps1` | エントリポイント（引数・全体の流れ・接続確認） | docs/05 1 章 |
| `config/settings.psd1` | 利用者が編集する設定（コメント付き） | docs/04 |
| `src/Config.ps1` | 設定の読み込み・既定値・検証、期間・日時の計算 | docs/05 2 章 |
| `src/AzDoClient.ps1` | REST API（認証・URL・再試行・ページング） | docs/05 3 章、docs/03 |
| `src/SizeCalculator.ps1` | PR サイズ（Git 方式 / Api 方式）、`Invoke-Git` | docs/05 4 章 |
| `src/Aggregator.ps1` | 対象判定・明細レコード化・期間別/作成者別集計 | docs/05 5 章 |
| `src/Output.ps1` | CSV/JSON の入出力・画面表示 | docs/05 6 章 |
| `tests/Run-Tests.ps1` | 単体テスト（自作の簡易ランナー） | docs/05 7 章 |
| `docs/01〜09` | 要件・設計・API・設定・出力・確認手順・トラブル・Copilot ガイド | — |

`src/*.ps1` はモジュールではなく、エントリポイントとテストから **dot-source** で読み込む。新しいファイルを追加したら、`Invoke-PrMetrics.ps1` と `tests/Run-Tests.ps1` の読み込みリストの両方に追加する。

## コーディング規約

### PowerShell 5.1 互換（最重要）

次は 5.1 で構文エラー・動作差になるので**使わない**:

| 使わない | 代わりに |
|---|---|
| `$a ?? $b`, `$a?.b` | `if ($null -eq $a) { ... }` |
| 三項演算子 `$c ? $x : $y` | `if ($c) { $x } else { $y }` |
| `cmd1 && cmd2`, `\|\|` | `if ($LASTEXITCODE -eq 0) { ... }` |
| `ConvertFrom-Json -AsHashtable` | PSCustomObject のまま扱う |
| `Join-Path a b c`（3 引数以上） | `Join-Path (Join-Path a b) c` |
| `ForEach-Object -Parallel` | 通常のループ |
| `Invoke-RestMethod` | `Invoke-AzDoApi`（5.1 で日本語が化けるため、応答を UTF-8 で自前デコードしている） |
| `Export-Csv -Encoding utf8BOM` を直接 | `Export-PrMetricsCsv`（バージョンで切り替え済み） |

PowerShell 7 だけでテストして済ませない。**必ず `powershell`（5.1）でもテストする。**

### その他のルール

1. `.ps1` / `.psd1` は **UTF-8（BOM 付き）** で保存する。新規ファイルも BOM を付ける。BOM が無いと 5.1 が日本語を Shift-JIS として読み、壊れる。
2. `Set-StrictMode` を使わない。API の JSON は状態によって項目が欠ける（例: active の PR に `closedDate` が無い）。欠けた項目を区別する必要があるときは `$obj.PSObject.Properties['name']` で確認する。
3. 関数から配列を返すときに `return , $array` を使わない（呼び出し側の `@(...)` で配列の配列になる）。普通に出力し、呼び出し側で `@(...)` で受ける。
4. `ConvertFrom-Json` に JSON 配列を渡すと、5.1 では配列が 1 個のオブジェクトとして出てくる。`foreach` で展開してから返す（`Import-PrMetricsRawJson` を参照）。
5. git は必ず `Invoke-Git` 経由で呼ぶ（UTF-8 出力・`core.quotepath=false`・stderr の扱い・終了コードを統一している）。
6. API 呼び出しは必ず `Invoke-AzDoApi` 経由で行う（認証・再試行・エラーヒントを統一している）。
7. 関数名は承認された動詞の `動詞-名詞` 形式。関数の先頭に `<# .SYNOPSIS #>` のコメントを書く。
8. 既存のコメント量・書き方に合わせる（日本語コメント、「なぜそうしているか」を書く）。

## セキュリティ（必ず守る）

1. **PAT（環境変数 `AZDO_PAT`）と Authorization ヘッダーを、画面・ログ・`Write-Verbose`・ファイル・URL・例外メッセージに出さない。** 設定ファイルに PAT の項目を作らない。
2. Azure DevOps に対しては **GET（読み取り）だけ** を行う。POST/PATCH/DELETE を追加しない。
3. git の認証情報を git の設定ファイルに保存しない（`-c http.extraHeader` で、その実行の間だけ渡す）。
4. **このリポジトリは GitHub で公開されている。** 実際の組織名・プロジェクト名・リポジトリ名・PR タイトル・人名・メールアドレス・社内 URL をコミットしない。
   - 設定・資料・テストの例には、ダミー名（`contoso` / `SampleProject` / `SampleRepo` / `example.com`）を使う。
   - 実環境の値は `config/*.local.psd1`（`.gitignore` 済み）に書く。
   - `output/`・`repos/`・`*.log` は `.gitignore` 済み。これらの中身を他の場所にコピーしてコミットしない。

## 変更するときのチェックリスト

### 共通
- [ ] 関係する `docs/` を更新した（下表）
- [ ] `tests/Run-Tests.ps1` にテストを追加・更新した
- [ ] 5.1 と 7 の両方でテストが全件成功した
- [ ] 変更した `.ps1` / `.psd1` に BOM がある

### 変更内容ごとに更新するもの

| 変更内容 | 更新するもの |
|---|---|
| 設定項目の追加・変更 | `src/Config.ps1` の `$script:PrMetricsDefaultConfig`（配列なら正規化リストも）、`Test-PrMetricsConfig`（検証が必要なら）、`config/settings.psd1`（コメント付き）、`docs/04_設定ファイル仕様.md` |
| 指標の定義・計算方法の変更 | **先に** `docs/01_要件定義.md` 3 章を更新し、次にコード、`docs/05_詳細設計.md`、`docs/06_出力仕様.md` |
| CSV の列の追加・変更 | `docs/06_出力仕様.md` |
| 使う API の追加・変更 | `docs/03_AzureDevOps_API仕様.md`（パラメーター・レスポンス項目） |
| サイズ計算の方式（`SizeSource`）の追加 | `docs/05_詳細設計.md` 4.1、`docs/06_出力仕様.md` の SizeSource 表 |
| 新しいエラー・その対処 | `docs/08_トラブルシューティング.md` |
| 引数の追加 | `Invoke-PrMetrics.ps1` のコメントヘルプ、`docs/04` 3 章、`docs/05` 1 章 |
| ファイル構成の変更 | `README.md`、このファイルの「構成」、`.github/copilot-instructions.md` |

## テストの書き方

`tests/Run-Tests.ps1` は Pester を使わない自作ランナー（Windows 標準の Pester 3.4 と 5.x で書き方が違うため）。

```powershell
It 'テストの名前（日本語で、何を確かめるか）' {
    Assert-Equal <期待値> <実際の値> '失敗時の補足（任意）'
    Assert-Throws { <例外になる処理> } -Like '*メッセージの一部*'
}
```

- 実データは使わず、架空の値（`New-FakePr`、`New-TestConfig` を使う）。
- 日時に依存するテストは `Get-PrMetricsDateRange -NowUtc` で「今日」を固定する。
- git が関係するテストは、既存の「Git 方式（実リポジトリ）」の節のように一時フォルダに実際のリポジトリを作る。最後に必ず削除する。
- 不具合を直すときは、**先に再現するテストを書いて失敗を確認してから**直す。

## 実環境で未確認の事項

開発環境からは実際の Azure DevOps に接続できないため、次は未確認（詳細と確認方法は `docs/07_動作確認手順.md` の「要確認事項」）。
これらに関わる変更をするときは、推測で断定せず、利用者に確認方法（実行するコマンド）を示す。

| No | 内容 |
|---|---|
| Q-1 | PR 一覧 API の `searchCriteria.minTime/maxTime/queryTimeRangeType` が使えるか |
| Q-2 | PR 一覧のレスポンスに `lastMergeCommit` などが含まれるか |
| Q-3 | squash・ソースブランチ削除済みの PR の `lastMergeCommit` が clone から取得できるか |
| Q-4 | squash の PR の行数が正しいか |
| Q-5 | 社内のプロキシ・認証環境で git の clone/fetch ができるか |
| Q-6 | `isDraft` / `completionOptions` が返るか |

## コミット

- メッセージは日本語。1 行目に種類を付ける: `feat:`（機能）/ `fix:`（不具合修正）/ `docs:`（資料のみ）/ `test:`（テストのみ）/ `refactor:`
- 1 行目は変更内容の要約、空行のあとに理由や補足を書く。
- コミット前に、上の「セキュリティ」4 の情報が含まれていないか `git diff --cached` で確認する。

## やってはいけないこと

- テストを実行せずに「修正しました」と報告する。
- テストを通すためにテストの期待値を書き換える（期待値が間違っている根拠を示せる場合を除く）。
- 依存モジュール（Pester・PSScriptAnalyzer・外部パッケージ）を必須にする。
- `docs/` を更新せずに、仕様（指標の定義・設定項目・出力列）を変える。
