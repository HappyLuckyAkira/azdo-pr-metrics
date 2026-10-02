# 09. GitHub Copilot 活用ガイド

会社 PC で、GitHub Copilot（VS Code の Copilot Chat）を使って確認・修正を進めるためのガイドです。

## 1. 準備

1. VS Code で `pr-metrics` フォルダを開く（**フォルダごと**開くと、Copilot が資料とコードを参照できる）。
2. リポジトリ直下の `AGENTS.md` が自動で読み込まれる（Copilot Chat の回答の参照元に表示される）。
   - このファイルに「5.1 互換」「PAT を出さない」「BOM を消さない」「公開リポジトリなので実名を書かない」などのルールが書いてあるので、毎回プロンプトで説明する必要はない。
   - 読み込まれない場合は、VS Code の設定で `chat.useAgentsMdFile` が有効か確認する。古い VS Code では対応していないことがあるので、そのときはプロンプトに `#file:AGENTS.md` を添付する。
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
Copilot に「状況・エラー全文・関係ファイル」を渡して相談（4 章 不具合調査のプロンプト集）
    ↓ 原因が分かったら、再現テストを書かせてから修正
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

接続確認でのエラーなど、手軽に聞く場合の例です。本格的な調査は [4 章](#4-不具合調査のプロンプト集) を使ってください。

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
AGENTS.md のルールに従い、設定項目・資料・テストも更新してください。
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

## 4. 不具合調査のプロンプト集

不具合の調査では、Copilot に**いきなり修正させない**のが基本です。次の順で進めます。

```
事実を渡す → 原因の候補を出させる → 自分で確認する → 再現テストを書かせる → 修正させる → 自分でテストする
```

### 4.1 前準備（材料をそろえる）

Copilot に渡す前に、次の 2 つを行っておくと調査が速くなります。

```powershell
# 1) 詳細ログ付きで再実行し、出力をファイルに保存（API の URL と git コマンドが記録される。PAT は出ない）
.\Invoke-PrMetrics.ps1 -ConfigPath .\config\settings.local.psd1 -Verbose *> .\debug.log

# 2) settings.local.psd1 で SaveRawJson = $true にして実行（API の生データを保存）
```

生データがあれば、`-ReplayDir` で **API を呼ばずに同じ状況を何度でも再現**できます。

> `debug.log` と `raw_pullrequests_*.json` には社内情報（組織名・PR タイトル・作成者名）が含まれます。どちらも `.gitignore` の対象（`*.log` と `output/`）なのでコミットされませんが、Copilot に貼るときは伏せ字にしてください。

### 4.2 基本テンプレート（どの不具合にも使える）

```
#file:AGENTS.md #file:docs/02_基本設計.md #file:docs/08_トラブルシューティング.md
不具合を調査したいです。まだコードは修正しないでください。

## 実行したこと
<実行したコマンド>

## 期待した結果
<例: 9月に完了した PR が 42 件出力される>

## 実際の結果
<例: 38 件しか出力されない / エラーになる>
<エラーや出力の全文を貼る。PAT・個人名・社内の組織名は伏せる>

## 環境
- PowerShell: <$PSVersionTable.PSVersion の結果>
- git: <git --version の結果>
- 設定の変更点: <既定値から変えた設定項目>

## お願い
1. 考えられる原因を、可能性の高い順に 3〜5 個挙げてください
2. それぞれについて「どのファイルのどの関数が関係するか」と
   「原因かどうかを確かめるために私が実行するコマンド」を示してください
3. 推測と、コードから確実に言えることを区別して書いてください
```

最後の「推測と確実なことを区別して」と「確かめるコマンドを示して」が重要です。これが無いと、Copilot がもっともらしい推測で修正を始めてしまいがちです。

### 4.3 症状別

#### A. エラーで止まる

```
#file:src/AzDoClient.ps1 #file:docs/03_AzureDevOps_API仕様.md #file:docs/08_トラブルシューティング.md
次のエラーで止まります。-Verbose の出力も貼ります。
エラーメッセージの「ヒント」の内容が当てはまるか、
08 のエラー一覧のどれに該当するかを判断し、確認手順を示してください。
コードの不具合なのか、環境・設定の問題なのかも判断してください。

<debug.log の該当部分>
```

#### B. 件数が Azure DevOps の画面と合わない

```
#file:src/Aggregator.ps1 #file:src/AzDoClient.ps1 #file:docs/01_要件定義.md
PR の件数が Azure DevOps の画面と合いません。
- 画面の件数: <N> 件（<Completed タブ / 期間の数え方>）
- ツールの件数: <M> 件
- run_info.json の Fetched / Included: <値>
- 画面にあってツールに無い PR の例: #<番号>（完了日時: <画面の表示>）

その PR が除外された理由を特定したいです。
Test-PullRequestIncluded の判定条件を 1 つずつ確認する PowerShell のコードを書いてください。
raw_pullrequests_*.json からその PR を読み込んで、どの条件で false になるか表示するものにしてください。
```

#### C. サイズが unavailable になる / 行数がおかしい

```
#file:src/SizeCalculator.ps1 #file:docs/05_詳細設計.md
PR #<番号> のサイズが <unavailable になる / 実際と違う> という問題があります。
- prs.csv の該当行: SizeSource=<値>, SizeNote=<値>, LinesAdded=<値>, LinesDeleted=<値>
- PR 画面での実際の変更: <例: 3 ファイル、+120 -30 くらい>
- MergeStrategy: <squash など>
- raw JSON の lastMergeTargetCommit / lastMergeSourceCommit / lastMergeCommit:
  <SHA の先頭 8 桁>

05 の 4.1 のアルゴリズムに沿って、どの段階で想定と違っているのかを確かめたいです。
repos\<リポジトリ名> で私が実行する git コマンドを、順番に、それぞれ何を確かめるのかの説明付きで示してください。
```

#### D. 文字化けする

```
#file:src/Output.ps1 #file:src/AzDoClient.ps1 #file:src/SizeCalculator.ps1
<どこで: 画面 / prs.csv / 設定ファイル読み込み> で日本語が文字化けします。
<化けた例を貼る>
PowerShell <5.1 / 7> で実行しています。
API の応答のデコード、git の出力エンコーディング、CSV 出力、ファイルの BOM の
どこが原因か切り分ける手順を示してください。
```

#### E. 遅い

```
#file:Invoke-PrMetrics.ps1 #file:src/AzDoClient.ps1 #file:src/SizeCalculator.ps1
PR <N> 件の処理に <M> 分かかります（SizeMethod=<値>）。
debug.log を貼ります。API 呼び出し回数と git コマンドの回数を数えて、
どこに時間がかかっているか推定してください。
改善案は、設定変更で済むものとコード修正が必要なものに分けてください。
```

### 4.4 原因が分かったら：再現テスト → 修正

```
#file:tests/Run-Tests.ps1 #file:src/<原因のファイル>.ps1
原因は <特定した原因> でした。
1. まず、この不具合を再現する（今は失敗する）テストを tests/Run-Tests.ps1 に追加してください。
   実データは使わず、架空の値で作ってください。
2. テストが失敗することを私が確認したら、修正してください。
3. 修正は AGENTS.md のルールに従い、関係する docs も更新してください。
```

修正後は、Copilot の「直りました」を鵜呑みにせず、**自分で両方のバージョンで**確認します。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
pwsh -NoProfile -File .\tests\Run-Tests.ps1
# 実データでも確認（API を呼ばずに再現）
.\Invoke-PrMetrics.ps1 -ConfigPath .\config\settings.local.psd1 -ReplayDir .\output\<前回の実行フォルダ>
```

### 4.5 調査時の注意

- 社内向けの Copilot（Business / Enterprise）であっても、**PAT は絶対に貼らない**。作成者名・メールアドレス・社内の組織名は `<伏せ字>` にする。
- `#file:` で添付するのは関係するファイルに絞る（全部添付すると回答がぼやける）。
- 1 回の会話で解決しないときは、分かった事実を箇条書きにまとめて**新しい会話**で続ける（長い会話は前提を取り違えやすい）。

## 5. Copilot の回答で注意すること

| よくある誤り | 見分け方 / 対処 |
|---|---|
| PowerShell 7 専用の構文を使う（`??`、三項演算子） | テストを 5.1（`powershell`）で実行する。`pwsh` だけで確認しない |
| `Invoke-RestMethod` に書き換える | 5.1 で日本語が化ける原因になるので、`Invoke-AzDoApi` を使うよう指示する |
| 存在しない API パラメーターを提案する | 03 の手動確認方法（ブラウザで URL を開く）で実際に確かめる |
| ファイルを BOM 無しで保存する | 保存後に `Format-Hex <file> \| Select-Object -First 1` で `EF BB BF` を確認 |
| 資料を更新しない | 「docs も更新して」と明示する |
| テストを実行せずに「直りました」と言う | 必ず自分で `tests/Run-Tests.ps1` を実行する |
