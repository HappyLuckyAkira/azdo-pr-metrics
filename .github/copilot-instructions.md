# Copilot への指示（このリポジトリ共通）

このリポジトリは、Azure DevOps の PR メトリクス（頻度・リードタイム・サイズ）を収集する PowerShell ツールです。
回答・コメント・コミットメッセージは**日本語**で書いてください。

## 必ず守ること

1. **PowerShell 5.1 と 7 の両方で動くコードにする。** 次は使わない:
   `??`, `?.`, 三項演算子, `&&` / `||`, `ConvertFrom-Json -AsHashtable`, `Join-Path` に 3 つ以上の引数, `ForEach-Object -Parallel`, クラス構文の多用
2. `.ps1` / `.psd1` は **UTF-8 (BOM 付き)** で保存する。BOM を消さない。
3. **PAT（環境変数 `AZDO_PAT`）や Authorization ヘッダーを、画面・ログ・ファイル・URL に出さない。** 設定ファイルに PAT の項目を作らない。
4. Azure DevOps に対しては **GET（読み取り）だけ** を行う。
5. `Set-StrictMode` は使わない（API の JSON は項目が欠けることがあるため）。
6. 関数から配列を返すときに `return , $array` を使わない。呼び出し側で `@(...)` で受ける。
7. git は `Invoke-Git`（`src/SizeCalculator.ps1`）経由で呼ぶ。
8. 設定項目を追加したら、`src/Config.ps1` の既定値・`config/settings.psd1`・`docs/04_設定ファイル仕様.md` をそろえて更新する。
9. 出力列を追加・変更したら `docs/06_出力仕様.md` を更新する。
10. 変更したら `tests/Run-Tests.ps1` にテストを追加し、次で全件成功を確認する:
    `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`

## 構成

| パス | 役割 |
|---|---|
| `Invoke-PrMetrics.ps1` | エントリポイント（引数・全体の流れ・接続確認） |
| `config/settings.psd1` | 利用者が編集する設定 |
| `src/Config.ps1` | 設定の読み込み・検証、期間・日時 |
| `src/AzDoClient.ps1` | REST API（認証・再試行・ページング） |
| `src/SizeCalculator.ps1` | PR サイズ（Git 方式 / Api 方式） |
| `src/Aggregator.ps1` | 対象判定・明細化・集計 |
| `src/Output.ps1` | CSV/JSON 出力・表示 |
| `tests/Run-Tests.ps1` | 単体テスト（Pester 不使用の簡易ランナー） |
| `docs/` | 設計資料（01 要件 〜 09 Copilot ガイド） |

## 用語と定義

- 指標の定義は `docs/01_要件定義.md` の 3 章が正。計算を変えるときは先にそこを更新する。
- 「PR の変更」= `lastMergeTargetCommit` → `lastMergeCommit` の差分（`docs/05_詳細設計.md` 4.1）。
- 日時は API では UTC。表示・期間判定は設定の `TimeZoneId`（既定: Tokyo Standard Time）。

## 実データの扱い

- PR のタイトル・作成者名・メールアドレスは社内情報。テストデータには架空の値を使う。
