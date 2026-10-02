# =============================================================================
# PR メトリクス収集ツール 設定ファイル
# -----------------------------------------------------------------------------
# ・このファイルだけ編集すれば、対象や期間を変更できます。
# ・書式は PowerShell のデータファイル(.psd1)です。# 以降はコメントです。
# ・文字列は '...' で囲みます。配列は @('a','b')、空配列は @() です。
# ・全項目の詳細は docs\04_設定ファイル仕様.md を参照してください。
# ・PAT(アクセストークン)はこのファイルに書かないでください（環境変数で渡します）。
# =============================================================================
@{
    # =========================================================================
    # 1. 接続先
    # =========================================================================
    # Azure DevOps の組織名（URL の https://dev.azure.com/{ここ}）
    Organization  = 'contoso'

    # プロジェクト名
    Project       = 'SampleProject'

    # 対象リポジトリ名（複数指定可）。例: @('SampleRepo', 'SampleTools')
    Repositories  = @('SampleRepo')

    # Azure DevOps Services(クラウド)なら変更不要。
    # オンプレ(Azure DevOps Server)の場合は 'https://サーバー名/tfs' などにし、
    # Organization にコレクション名(例: 'DefaultCollection')を指定する。
    BaseUrl       = 'https://dev.azure.com'

    # REST API のバージョン。Azure DevOps Server の古い版では '6.0' 等に下げる。
    ApiVersion    = '7.1'

    # PAT を格納した環境変数の名前。未設定なら実行時に入力を求められる。
    PatEnvVarName = 'AZDO_PAT'

    # プロキシ。空ならOS(Windows)の設定に従う。例: 'http://proxy.example.co.jp:8080'
    Proxy                      = ''
    ProxyUseDefaultCredentials = $true

    # =========================================================================
    # 2. 集計期間
    # =========================================================================
    # FromDate / ToDate を 'yyyy-MM-dd' で指定すると優先される（ToDate はその日を含む）。
    # 両方空なら「今日を含む直近 LastNDays 日間」が対象。
    FromDate      = ''
    ToDate        = ''
    LastNDays     = 90

    # どの日付で期間判定・集計するか
    #   'Closed'  : 完了(マージ)日   ← マージ頻度を見たい場合（推奨）
    #   'Created' : 作成日           ← PR の作成頻度を見たい場合
    DateBasis     = 'Closed'

    # 日付を表示・集計するタイムゾーン（Windows のタイムゾーンID）
    TimeZoneId    = 'Tokyo Standard Time'

    # 頻度の集計単位: 'Day' | 'Week' | 'Month'
    PeriodUnit    = 'Week'

    # 週の開始曜日（PeriodUnit='Week' のとき）: 'Monday' | 'Sunday' など
    WeekStartDay  = 'Monday'

    # =========================================================================
    # 3. 対象 PR の絞り込み
    # =========================================================================
    # 対象ステータス: 'completed'(マージ済) / 'abandoned'(破棄) / 'active'(未完了)
    # ※ DateBasis='Closed' のとき 'active' は完了日が無いため集計されない。
    Statuses       = @('completed')

    # マージ先ブランチで絞り込む。空 @() なら全ブランチ。
    # 例: @('refs/heads/main', 'refs/heads/develop')   ※ 'refs/heads/' から書く
    TargetBranches = @()

    # 下書き(Draft)PR を除外するか
    ExcludeDrafts  = $true

    # 除外する作成者（表示名 または メールアドレス/UPN）。Bot などを除外する用途。
    # 例: @('Project Collection Build Service (contoso)')
    ExcludeAuthors = @()

    # 期間指定をサーバー側(API)で行うか。
    # Azure DevOps Server の古い版でエラー(400)になる場合は $false にする。
    # $false の場合は全 PR を取得してからツール側で絞り込む（遅いが確実）。
    UseServerSideDateFilter = $true

    # =========================================================================
    # 4. PR サイズの計算方法
    # =========================================================================
    # 'Git'  : ローカルの git で差分行数(追加/削除)まで計算（推奨・行数が取れる）
    # 'Api'  : REST API のみで変更ファイル数を計算（行数は取れない・git 不要）
    # 'None' : サイズを計算しない（頻度・リードタイムだけ欲しい場合。最速）
    SizeMethod     = 'Git'

    # [Git のみ] ローカルの clone 置き場。{LocalRepoRoot}\{リポジトリ名} を使う。
    # 相対パスはツールのフォルダ(Invoke-PrMetrics.ps1 のある場所)基準。
    # 既に作業用 clone がある場合は、その親フォルダを指定すれば再利用される。
    LocalRepoRoot  = '.\repos'

    # [Git のみ] ローカルに無ければ自動で clone(--mirror) するか
    AutoClone      = $true

    # [Git のみ] clone 時の追加引数。巨大リポジトリで容量を抑えたい場合は
    # @('--filter=blob:none') を指定（差分計算時に必要な分だけ取得される）
    CloneExtraArgs = @()

    # [Git のみ] 実行前に git fetch して最新化するか
    FetchBeforeDiff     = $true

    # [Git のみ] ローカルに無いコミットを個別に fetch して取りに行くか
    FetchMissingCommits = $true

    # [Git のみ] git の認証に PAT を使うか。
    #   $false : Git Credential Manager 等、PC の既存の git 認証を使う（推奨）
    #   $true  : 環境変数の PAT を一時的なヘッダーとして渡す（設定には保存されない）
    GitUsePatHeader     = $false

    # サイズ計算から除外するファイル（ワイルドカード。大文字小文字は区別しない）。
    # パスはリポジトリ直下からの相対で、区切りは '/'。
    #   '*.hex'          : どの階層の .hex も除外
    #   'Generated/*'    : 直下の Generated フォルダ配下を除外
    #   '*/Generated/*'  : 2階層目以降の Generated フォルダ配下を除外
    ExcludePathPatterns = @(
        '*.hex'
        '*.bin'
        '*.mot'
        '*.srec'
        '*.map'
    )

    # PR サイズ区分。上から順に判定し、最初に「以下」に収まった区分になる。
    # 行数(追加+削除)が取れる場合は MaxLines、取れない場合(Api)は MaxFiles で判定。
    # 最後の区分は $null（上限なし）にする。
    SizeCategories = @(
        @{ Name = 'XS'; MaxLines = 10;    MaxFiles = 1     }
        @{ Name = 'S';  MaxLines = 50;    MaxFiles = 3     }
        @{ Name = 'M';  MaxLines = 250;   MaxFiles = 10    }
        @{ Name = 'L';  MaxLines = 1000;  MaxFiles = 30    }
        @{ Name = 'XL'; MaxLines = $null; MaxFiles = $null }
    )

    # =========================================================================
    # 5. 出力
    # =========================================================================
    # 出力先。実行ごとに {OutputDir}\yyyyMMdd_HHmmss フォルダが作られる。
    OutputDir   = '.\output'

    # API の生レスポンス(JSON)も保存するか。調査・デバッグ時に $true。
    # 保存した JSON は -ReplayDir で再利用できる（API を呼ばずに再集計）。
    SaveRawJson = $false

    # =========================================================================
    # 6. 通信
    # =========================================================================
    # 1 回の API 呼び出しで取得する PR 件数（1～1000）
    PageSize         = 100
    # 429(制限)/5xx/通信エラー時の再試行回数と、初回待ち秒数（以降は倍々）
    MaxRetry         = 3
    RetryWaitSeconds = 5
}
