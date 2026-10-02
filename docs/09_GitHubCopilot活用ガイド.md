# 09. GitHub Copilot 活用ガイド

会社 PC で、GitHub Copilot（VS Code の Copilot Chat）を使って確認・修正を進めるためのガイドです。

## 1. 準備

1. VS Code で `pr-metrics` フォルダを開く（**フォルダごと**開くと、Copilot が資料とコードを参照できる）。
2. `.github/copilot-instructions.md` が自動で読み込まれる（Copilot Chat の回答の参照元に表示される）。
   - このファイルに「5.1 互換」「PAT を出さない」「BOM を消さない」などのルールが書いてあるので、毎回プロンプトで説明する必要はない。
   - 読み込まれない場合は、VS Code の設定で `github.copilot.chat.codeGeneration.useInstructionFiles` が有効か確認する。
3. 質問するときは、`#file` で関係するファイルを添付すると精度が上がる。
   例: `#file:src/SizeCalculator.ps1 #file:docs/05_詳細設計.md`
4. 修正を頼むときは **Agent モード**（または Edits）を使うと、複数ファイルをまとめて変更してくれる。

> ⚠ Copilot Chat に、**PAT・実際の作成者名・メールアドレスを貼らない**でください。エラーメッセージや JSON を貼るときは伏せ字にします。

## 2. 進め方の基本

```
[07 動作確認手順] の Step を 1 つ実行
    ↓ 期待結果と違う
[08 トラブルシューティング] で該当するエラーを探す
    ↓ 解決しない
Copilot に「状況・エラー全文・関係ファイル」を渡して相談（下のプロンプト例）
    ↓ 修正
tests/Run-Tests.ps1 を実行してすべて成功を確認 → 同じ Step をやり直す
```

## 3. プロンプト例

### 3.1 全体を理解する

```
#file:README.md #file:docs/02_基本設計.md
このツールの処理の流れを、初めて見る人向けに 10 行程度で説明してください。
特に PR のサイズ（行数）をどうやって計算しているかを詳しく。
```

### 3.2 エラーの調査

```
#file:docs/08_トラブルシューティング.md #file:src/AzDoClient.ps1
次のコマンドを実行したらエラーになりました。原因の候補と、確認するコマンドを優先度順に教えてください。
コードはまだ修正しないでください。

実行コマンド:
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-PrMetrics.ps1 -Mode TestConnection -Verbose

出力（全文）:
<ここに貼る。PAT・個人名は伏せる>
```

### 3.3 API のレスポンスを確認する（要確認事項 Q-2）

```
#file:docs/03_AzureDevOps_API仕様.md
SaveRawJson=$true で取得した PR 1 件分の JSON を貼ります（個人名は伏せています）。
03 の 3.2 に書かれている項目と比べて、
(1) 存在しない項目、(2) 03 に書かれていない有用そうな項目
を表にしてください。

<JSON を貼る>
```

### 3.4 squash の PR の行数が取れない（要確認事項 Q-3）

```
#file:docs/07_動作確認手順.md #file:docs/05_詳細設計.md #file:src/SizeCalculator.ps1 #file:tests/Run-Tests.ps1
07 の「Q-3 で問題があった場合の改修方針」の 2 を実装してください。

事実確認の結果:
- PR #<番号> の lastMergeCommit は <sha先頭8桁> だが、main にある squash コミットは <sha先頭8桁> で別物だった
- そのコミットメッセージは "Merged PR <番号>: <タイトル>" だった

要件:
- Get-PrSizeFromGit の最初の戦略として 'git:merged-commit' を追加
  （マージ先ブランチの履歴から "Merged PR {id}:" で始まるコミットを探し、その親1との差分）
- 見つからなければ既存の戦略にフォールバック
- PowerShell 5.1 互換、Invoke-Git 経由で git を呼ぶ
- tests/Run-Tests.ps1 にテストを追加（一時リポジトリで squash コミットを作る既存のテストを参考に）
- docs/05_詳細設計.md の 4.1 と docs/06_出力仕様.md の SizeSource の表を更新
```

### 3.5 指標を追加する（例: 初回レビューまでの時間）

```
#file:docs/01_要件定義.md #file:docs/03_AzureDevOps_API仕様.md #file:src/AzDoClient.ps1 #file:src/Aggregator.ps1
01 の「将来拡張の候補」にある「初回レビューまでの時間」を追加したいです。
まず実装はせず、次を提案してください:
1. 使う API（pullRequests/{id}/threads）とレスポンスのどの項目を使うか
2. 「初回レビュー」の定義の案（作成者以外の最初のコメント？ 最初の投票？）とそれぞれの長所・短所
3. 変更が必要なファイルと関数
4. API 呼び出し回数が増えることへの対策（設定で ON/OFF できるようにする等）
```

提案に納得したら:

```
案 <番号> で実装してください。
.github/copilot-instructions.md のルールに従い、設定項目・資料・テストも更新してください。
```

### 3.6 設定を変える

```
#file:config/settings.psd1 #file:docs/04_設定ファイル仕様.md
次の条件で集計したいです。settings.psd1 の変更箇所だけを示してください。
- 2026 年 4 月〜9 月
- 月単位
- main と release/* ブランチへのマージだけ
- Generated フォルダ（どの階層でも）と *.a を除外
```

> `TargetBranches` はワイルドカードに対応していない（完全一致）。Copilot がそのことに気付くか確認し、必要なら「ワイルドカード対応にする改修」を別途依頼する。

### 3.7 結果の分析

```
#file:output/<実行フォルダ>/summary_by_period.csv
このデータから読み取れる傾向を 5 つ挙げてください。
特に、PR のサイズとリードタイムの関係、件数の推移について。
グラフにするなら、どの列をどのグラフにするのがよいかも提案してください。
```

（`prs.csv` は個人名を含むので、社外サービスに出してよいか社内ルールを確認すること）

### 3.8 コードレビューを頼む

```
#file:src/SizeCalculator.ps1
この変更を、次の観点でレビューしてください:
- PowerShell 5.1 で動かない構文が無いか
- PAT や認証ヘッダーがログに出る経路が無いか
- git の出力に日本語ファイル名があっても壊れないか
- エラー時に PR 1 件の失敗で全体が止まらないか
```

## 4. Copilot の回答で注意すること

| よくある誤り | 見分け方 / 対処 |
|---|---|
| PowerShell 7 専用の構文を使う（`??`、三項演算子） | テストを 5.1（`powershell`）で実行する。`pwsh` だけで確認しない |
| `Invoke-RestMethod` に書き換える | 5.1 で日本語が化ける原因になるので、`Invoke-AzDoApi` を使うよう指示する |
| 存在しない API パラメーターを提案する | 03 の手動確認方法（ブラウザで URL を開く）で実際に確かめる |
| ファイルを BOM 無しで保存する | 保存後に `Format-Hex <file> \| Select-Object -First 1` で `EF BB BF` を確認 |
| 資料を更新しない | 「docs も更新して」と明示する |
| テストを実行せずに「直りました」と言う | 必ず自分で `tests/Run-Tests.ps1` を実行する |
