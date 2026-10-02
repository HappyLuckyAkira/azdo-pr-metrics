# 03. Azure DevOps REST API 仕様（本ツールで使うもの）

公式リファレンス: <https://learn.microsoft.com/rest/api/azure/devops/git/>

> ⚠ 印は、実環境での確認が必要な項目です。確認方法は [07 動作確認手順](07_動作確認手順.md) にまとめています。

## 1. 共通事項

### 1.1 ベース URL

```
https://dev.azure.com/{organization}/{project}/_apis/{resource}?api-version=7.1
```

本ツールの値:

```
https://dev.azure.com/contoso/SampleProject/_apis/...
```

- `{repositoryId}` の部分には、リポジトリの **GUID でも名前（`SampleRepo`）でも** 指定できる。
- Azure DevOps Server（オンプレ）の場合は `https://{server}/tfs/{collection}/{project}/_apis/...`。設定の `BaseUrl` と `Organization` で切り替える。

### 1.2 認証

PAT を使った Basic 認証。ユーザー名は空、パスワードに PAT を入れる。

```
Authorization: Basic base64(":" + PAT)
```

PAT の作成: Azure DevOps 右上のユーザー設定 → **Personal access tokens** → New Token

| 項目 | 設定値 |
|---|---|
| Organization | `contoso` |
| Scopes | Custom defined → **Code: Read** |
| Expiration | 社内ルールに従う（期限切れに注意） |

### 1.3 ページング

| API | 方式 |
|---|---|
| PR 一覧 | `$top`（件数）と `$skip`（読み飛ばす件数）。返ってきた件数が `$top` 未満になったら最後のページ |
| イテレーションの変更一覧 | `$top`（最大 2000）・`$skip`。レスポンスの `nextSkip` が 0 または無ければ最後のページ |

### 1.4 主な HTTP ステータス

| ステータス | 意味 | 本ツールの扱い |
|---|---|---|
| 200 | 成功 | — |
| 203 | **PAT が無効なとき、サインイン画面の HTML が返る**ことがある | JSON でなければエラーにする |
| 400 | パラメーター不正（古いサーバーで未対応のパラメーターなど） | 停止（ヒント表示） |
| 401 | 認証失敗（PAT 期限切れ・スコープ不足） | 停止 |
| 403 | 権限不足 | 停止 |
| 404 | 組織・プロジェクト・リポジトリ名の誤り | 停止 |
| 429 | 呼び出し回数の制限（レート制限） | 再試行 |
| 5xx | サーバー側の一時障害 | 再試行 |

---

## 2. リポジトリ取得

```
GET {base}/_apis/git/repositories/{repositoryId}?api-version=7.1
```

用途: リポジトリの存在確認と、clone 用 URL（`remoteUrl`）の取得。

| レスポンス項目 | 型 | 説明 |
|---|---|---|
| `id` | GUID | リポジトリ ID |
| `name` | string | リポジトリ名 |
| `defaultBranch` | string | 既定ブランチ（例: `refs/heads/main`） |
| `remoteUrl` | string | clone 用 URL（例: `https://contoso@dev.azure.com/contoso/SampleProject/_git/SampleRepo`） |

---

## 3. PR 一覧取得（最重要）

```
GET {base}/_apis/git/repositories/{repositoryId}/pullrequests?api-version=7.1
    &searchCriteria.status=completed
    &searchCriteria.queryTimeRangeType=closed
    &searchCriteria.minTime=2026-07-03T15:00:00Z
    &searchCriteria.maxTime=2026-10-02T15:00:00Z
    &$top=100
    &$skip=0
```

リファレンス: Pull Requests - Get Pull Requests

### 3.1 パラメーター

| パラメーター | 本ツールでの値 | 説明 |
|---|---|---|
| `searchCriteria.status` | `completed` / `abandoned` / `active`（設定 `Statuses` ごとに呼ぶ） | 省略時は `active` のみになるので**必ず指定する** |
| `searchCriteria.queryTimeRangeType` | `closed` / `created`（設定 `DateBasis`） | `minTime`/`maxTime` をどの日時に適用するか ⚠ |
| `searchCriteria.minTime` | 期間開始（UTC） | この日時以降 ⚠ |
| `searchCriteria.maxTime` | 期間終了（UTC） | この日時以前 ⚠ |
| `searchCriteria.targetRefName` | （使わない） | マージ先ブランチで絞る。1 つしか指定できないため、本ツールではツール側で絞る |
| `$top` | `PageSize`（既定 100） | 1 ページの件数 |
| `$skip` | 0, 100, 200, ... | 読み飛ばす件数 |

⚠ `minTime` / `maxTime` / `queryTimeRangeType` は比較的新しいパラメーター。Azure DevOps Services（クラウド）の `api-version=7.1` では使える想定。
使えない環境では `UseServerSideDateFilter = $false` にすると、全件取得してツール側で絞り込む。
いずれの場合も、**最終的な期間判定はツール側で厳密に行う**（境界・タイムゾーンのずれを防ぐため）。

### 3.2 レスポンス（`value` 配列の各要素）

```jsonc
{
  "pullRequestId": 1234,
  "status": "completed",                       // active / completed / abandoned
  "title": "機能A追加",
  "isDraft": false,
  "createdBy": {
    "displayName": "山田 太郎",
    "uniqueName": "yamada@example.co.jp"       // 作成者の識別に使う
  },
  "creationDate": "2026-09-01T00:00:00.123Z",  // UTC
  "closedDate":   "2026-09-02T06:00:00Z",      // UTC。active の PR には無い
  "sourceRefName": "refs/heads/feature/xxx",
  "targetRefName": "refs/heads/main",
  "mergeStatus": "succeeded",
  "reviewers": [
    { "displayName": "鈴木", "vote": 10 },
    { "displayName": "[SampleProject]\\Team", "vote": 0, "isContainer": true }   // グループ
  ],
  "lastMergeSourceCommit": { "commitId": "aaaa..." },  // ソースブランチ側の最新コミット
  "lastMergeTargetCommit": { "commitId": "bbbb..." },  // マージ時点のマージ先のコミット
  "lastMergeCommit":       { "commitId": "cccc..." },  // マージ結果のコミット
  "completionOptions": { "mergeStrategy": "squash" }   // noFastForward / squash / rebase / rebaseMerge
}
```

| 項目 | 本ツールでの用途 |
|---|---|
| `pullRequestId` | 明細の ID・URL |
| `creationDate` / `closedDate` | 期間判定・リードタイム |
| `createdBy.uniqueName` / `displayName` | 作成者の集計・除外判定 |
| `isDraft` | Draft の除外 |
| `targetRefName` | マージ先ブランチの絞り込み |
| `reviewers[].vote` | 承認数（`vote` が 10=承認、5=提案付き承認、0=未投票、-5=待機、-10=却下） |
| `reviewers[].isContainer` | `true` はグループなので人数に数えない |
| `lastMerge*Commit.commitId` | Git 方式のサイズ計算 |

⚠ **要確認**: 一覧のレスポンスに `lastMergeCommit` などが含まれるか。含まれない場合、ツールは PR 個別取得（4 章）で補う（その分遅くなる）。
⚠ **要確認**: squash でマージされた PR の `lastMergeCommit` が、マージ先ブランチの履歴上の squash コミットと一致するか。

---

## 4. PR 個別取得

```
GET {base}/_apis/git/repositories/{repositoryId}/pullrequests/{pullRequestId}?api-version=7.1
```

用途: 一覧にマージコミット情報が無い場合の補完（Git 方式のみ）。レスポンスの形は 3.2 と同じ。

---

## 5. PR イテレーション一覧（Api 方式）

```
GET {base}/_apis/git/repositories/{repositoryId}/pullRequests/{pullRequestId}/iterations?api-version=7.1
```

イテレーション = PR に対する push の単位（1 回目の push が id=1、修正 push のたびに増える）。

| レスポンス項目 | 説明 |
|---|---|
| `value[].id` | イテレーション番号。**最大の id が最新**（PR の最終形） |
| `value[].sourceRefCommit.commitId` | その時点のソース側コミット |
| `value[].commonRefCommit.commitId` | ソースとターゲットの共通祖先 |

---

## 6. イテレーションの変更ファイル一覧（Api 方式）

```
GET {base}/_apis/git/repositories/{repositoryId}/pullRequests/{pullRequestId}/iterations/{iterationId}/changes?api-version=7.1
    &$top=2000&$skip=0
```

- `$compareTo` を省略（=0）すると、**共通祖先との比較 ＝ PR 全体の変更** になる。
- 行数は返らない（ファイル単位の変更種別のみ）。

| レスポンス項目 | 説明 |
|---|---|
| `changeEntries[].item.path` | ファイルパス（例: `/src/main.c`） |
| `changeEntries[].item.isFolder` | フォルダなら `true`（本ツールは数えない） |
| `changeEntries[].changeType` | `add` / `edit` / `delete` / `rename` / `edit, rename` など |
| `changeEntries[].originalPath` | リネーム元のパス |
| `nextSkip` / `nextTop` | 続きがある場合の次ページ指定 |

---

## 7. 手動で API を確かめる方法

Copilot に調査させる前に、まず人の手で 1 回叩いてみると問題の切り分けが速くなります。

### 7.1 PowerShell

```powershell
$pat = $env:AZDO_PAT
$headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat")) }
$base = 'https://dev.azure.com/contoso/SampleProject/_apis'

# リポジトリ
Invoke-RestMethod "$base/git/repositories/SampleRepo?api-version=7.1" -Headers $headers |
    Select-Object id, name, defaultBranch, remoteUrl

# 完了 PR を 3 件（中身をすべて確認）
$r = Invoke-RestMethod "$base/git/repositories/SampleRepo/pullrequests?searchCriteria.status=completed&`$top=3&api-version=7.1" -Headers $headers
$r.value | Select-Object pullRequestId, title, creationDate, closedDate, @{n='merge';e={$_.lastMergeCommit.commitId}}
$r.value[0] | ConvertTo-Json -Depth 5
```

> PowerShell の文字列中の `$top` は変数と解釈されるので、`` `$top `` のようにバッククォートでエスケープする。

### 7.2 curl（Git Bash など）

```bash
curl -s -u ":$AZDO_PAT" "https://dev.azure.com/contoso/SampleProject/_apis/git/repositories/SampleRepo/pullrequests?searchCriteria.status=completed&\$top=3&api-version=7.1"
```

### 7.3 ブラウザ

Azure DevOps にサインイン済みのブラウザで、上の URL（`api-version` 付き）を開くと JSON が表示される（PAT 不要）。
レスポンスの項目を目で確かめたいときに便利。

---

## 8. 使わなかった API（検討結果）

| API | 使わない理由 |
|---|---|
| Analytics (OData) | PR のデータが含まれない（作業項目・パイプライン・テストのみ） |
| `git/repositories/{repo}/diffs/commits` | ファイル単位の変更種別のみで、行数が無い |
| `git/repositories/{repo}/filediffs`（preview） | 行単位の差分は取れるが、ファイルごとに指定が必要で PR 数 × ファイル数の呼び出しになり遅い |
| `git/repositories/{repo}/commits`（`changeCounts`） | ファイル数（Add/Edit/Delete）のみで行数が無い |
