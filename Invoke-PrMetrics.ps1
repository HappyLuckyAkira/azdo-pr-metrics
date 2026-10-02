<#
.SYNOPSIS
    Azure DevOps リポジトリの PR メトリクス（頻度・リードタイム・サイズ）を収集して CSV に出力する。

.DESCRIPTION
    設定は config\settings.psd1 で行う。引数を指定すると設定ファイルの値を一時的に上書きできる。
    設計資料は docs\ フォルダを参照。

.PARAMETER ConfigPath
    設定ファイルのパス。既定は config\settings.psd1。

.PARAMETER Mode
    Collect        : 収集して CSV を出力する（既定）
    TestConnection : 接続・認証・権限・git の確認だけ行う（何も出力しない）

.PARAMETER FromDate / ToDate
    集計期間（yyyy-MM-dd）。設定ファイルの値を上書きする。

.PARAMETER Repositories
    対象リポジトリ。設定ファイルの値を上書きする。

.PARAMETER SizeMethod
    Git / Api / None。設定ファイルの値を上書きする。

.PARAMETER ReplayDir
    以前 SaveRawJson=$true で保存した出力フォルダ。指定すると PR 一覧を API から取らず、
    その JSON を使って再集計する（Git 方式のサイズ計算はローカル clone があれば動く）。

.EXAMPLE
    .\Invoke-PrMetrics.ps1 -Mode TestConnection

.EXAMPLE
    .\Invoke-PrMetrics.ps1

.EXAMPLE
    .\Invoke-PrMetrics.ps1 -FromDate 2026-04-01 -ToDate 2026-09-30 -SizeMethod None -Verbose
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateSet('Collect', 'TestConnection')][string]$Mode = 'Collect',
    [string]$FromDate,
    [string]$ToDate,
    [string[]]$Repositories,
    [ValidateSet('Git', 'Api', 'None')][string]$SizeMethod,
    [string]$ReplayDir
)

# 注意: Set-StrictMode は使わない。API の JSON は状態によってプロパティが欠けるため
#       （例: active の PR には closedDate が無い）、存在しないプロパティ参照を $null として扱う前提で書いている。
$ErrorActionPreference = 'Stop'

$toolRoot = $PSScriptRoot
foreach ($file in @('Config.ps1', 'AzDoClient.ps1', 'SizeCalculator.ps1', 'Aggregator.ps1', 'Output.ps1')) {
    . (Join-Path (Join-Path $toolRoot 'src') $file)
}

# PowerShell 5.1 で TLS1.2 を有効にする（Azure DevOps は TLS1.2 以上が必須）
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Get-WebBaseUrl {
    param([hashtable]$Config)
    '{0}/{1}/{2}' -f ([string]$Config.BaseUrl).TrimEnd('/'), [uri]::EscapeDataString([string]$Config.Organization), [uri]::EscapeDataString([string]$Config.Project)
}

function Invoke-ConnectionTest {
    <# 接続確認。各項目の結果を表で表示する。 #>
    param([hashtable]$Config, $Context, $Range)

    $results = New-Object System.Collections.Generic.List[object]
    # Result: OK / NG / INFO（INFO は参考情報で合否に影響しない）
    function Add-Result([string]$Item, [bool]$Ok, [string]$Detail, [switch]$Info) {
        $label = 'NG'
        if ($Info) { $label = 'INFO' } elseif ($Ok) { $label = 'OK' }
        $results.Add([pscustomobject]@{ Result = $label; Item = $Item; Detail = $Detail })
    }

    foreach ($repo in $Config.Repositories) {
        $repoInfo = $null
        try {
            $repoInfo = Get-AzDoRepository -Context $Context -Repository $repo
            Add-Result "[$repo] リポジトリ取得" $true "id=$($repoInfo.id) defaultBranch=$($repoInfo.defaultBranch)"
        }
        catch { Add-Result "[$repo] リポジトリ取得" $false $_.Exception.Message; continue }

        $latest = $null
        try {
            $response = Invoke-AzDoApi -Context $Context -Path ('git/repositories/{0}/pullrequests' -f [uri]::EscapeDataString($repo)) `
                -Query ([ordered]@{ 'searchCriteria.status' = 'all'; '$top' = 1 })
            $latest = @($response.value) | Select-Object -First 1
            if ($latest) { Add-Result "[$repo] PR 一覧取得" $true "最新 PR #$($latest.pullRequestId) ($($latest.status)) $($latest.title)" }
            else { Add-Result "[$repo] PR 一覧取得" $true 'PR が 0 件です' }
        }
        catch { Add-Result "[$repo] PR 一覧取得" $false $_.Exception.Message }

        if ($Config.UseServerSideDateFilter) {
            try {
                $isoFormat = 'yyyy-MM-ddTHH:mm:ssZ'
                $culture = [Globalization.CultureInfo]::InvariantCulture
                $response = Invoke-AzDoApi -Context $Context -Path ('git/repositories/{0}/pullrequests' -f [uri]::EscapeDataString($repo)) `
                    -Query ([ordered]@{
                        'searchCriteria.status'             = 'completed'
                        'searchCriteria.queryTimeRangeType' = $Config.DateBasis.ToLowerInvariant()
                        'searchCriteria.minTime'            = $Range.FromUtc.ToString($isoFormat, $culture)
                        'searchCriteria.maxTime'            = $Range.ToUtcExclusive.ToString($isoFormat, $culture)
                        '$top'                              = 5
                    })
                Add-Result "[$repo] 期間指定(サーバー側)" $true "受け付けられました（期間内の completed 先頭 $(@($response.value).Count) 件）"
            }
            catch { Add-Result "[$repo] 期間指定(サーバー側)" $false ("UseServerSideDateFilter=`$false を検討: " + $_.Exception.Message) }
        }

        if ($latest) {
            $hasMergeInfo = ($latest.PSObject.Properties['lastMergeTargetCommit'] -and $null -ne $latest.lastMergeTargetCommit)
            Add-Result "[$repo] 一覧にマージコミット情報" $hasMergeInfo $(if ($hasMergeInfo) { "PR #$($latest.pullRequestId): lastMergeTargetCommit あり" } else { "PR #$($latest.pullRequestId): 無し → Git 方式では PR 個別取得で補完します" }) -Info
        }

        if ($Config.SizeMethod -eq 'Api' -and $latest) {
            try {
                $size = Get-PrSizeFromApi -Context $Context -Repository $repo -PullRequest $latest -ExcludePatterns $Config.ExcludePathPatterns
                Add-Result "[$repo] サイズ(Api)" $true "PR #$($latest.pullRequestId): ファイル数 $($size.FilesChanged)"
            }
            catch { Add-Result "[$repo] サイズ(Api)" $false $_.Exception.Message }
        }

        if ($Config.SizeMethod -eq 'Git') {
            $version = Invoke-Git -Arguments @('--version')
            Add-Result 'git コマンド' ($version.ExitCode -eq 0) (($version.Output -join ' ') + $version.Error)
            if ($version.ExitCode -eq 0) {
                $gitArgs = Get-GitAuthConfigArgs -Config $Config -Context $Context
                $remote = Invoke-Git -Arguments @('ls-remote', '--heads', $repoInfo.remoteUrl) -ConfigArgs $gitArgs
                Add-Result "[$repo] git 認証(ls-remote)" ($remote.ExitCode -eq 0) $(if ($remote.ExitCode -eq 0) { "ブランチ $(@($remote.Output).Count) 件" } else { $remote.Error })
                $localPath = Join-Path (Resolve-ToolPath -Path $Config.LocalRepoRoot -ToolRoot $toolRoot) $repo
                Add-Result "[$repo] ローカル clone" $true $(if (Test-Path $localPath) { "あり: $localPath" } else { "なし（実行時に clone します）: $localPath" })
            }
        }
    }

    $results | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    return (@($results | Where-Object { $_.Result -eq 'NG' }).Count -eq 0)
}

try {
    if (-not $ConfigPath) { $ConfigPath = Join-Path (Join-Path $toolRoot 'config') 'settings.psd1' }

    Write-Log "設定ファイル: $ConfigPath" -Level Step
    $config = Import-PrMetricsConfig -Path $ConfigPath -Overrides @{
        FromDate     = $FromDate
        ToDate       = $ToDate
        Repositories = $Repositories
        SizeMethod   = $SizeMethod
    }
    $timeZone = [TimeZoneInfo]::FindSystemTimeZoneById($config.TimeZoneId)
    $range = Get-PrMetricsDateRange -Config $config -TimeZone $timeZone
    Write-Log ("対象: {0}/{1} リポジトリ: {2}" -f $config.Organization, $config.Project, ($config.Repositories -join ', '))
    Write-Log ("期間: {0} ～ {1} ({2}日, 基準日={3}, 集計単位={4}, サイズ={5})" -f `
            $range.FromLocal.ToString('yyyy-MM-dd'), $range.ToLocalExclusive.AddDays(-1).ToString('yyyy-MM-dd'),
        $range.Days, $config.DateBasis, $config.PeriodUnit, $config.SizeMethod)

    $context = $null
    if (-not $ReplayDir -or $config.SizeMethod -eq 'Api') {
        $context = New-AzDoContext -Config $config -Pat (Get-AzDoPat -Config $config)
    }

    if ($Mode -eq 'TestConnection') {
        Write-Log '接続確認を実行します' -Level Step
        $ok = Invoke-ConnectionTest -Config $config -Context $context -Range $range
        if ($ok) { Write-Log '接続確認: すべて OK' -Level Ok; exit 0 }
        Write-Warning '接続確認: NG の項目があります。docs\08_トラブルシューティング.md を参照してください。'
        exit 1
    }

    $outputDir = New-RunOutputDirectory -OutputRoot (Resolve-ToolPath -Path $config.OutputDir -ToolRoot $toolRoot)
    $webBaseUrl = Get-WebBaseUrl -Config $config
    $records = New-Object System.Collections.Generic.List[object]
    $repoStats = New-Object System.Collections.Generic.List[object]

    foreach ($repo in $config.Repositories) {
        Write-Log "[$repo] PR 一覧を取得します" -Level Step

        # ---- 1. PR 一覧の取得 ----
        $repoInfo = $null
        if ($ReplayDir) {
            $rawPrs = Import-PrMetricsRawJson -Path (Join-Path $ReplayDir "raw_pullrequests_$repo.json")
        }
        else {
            $repoInfo = Get-AzDoRepository -Context $context -Repository $repo
            $rawList = New-Object System.Collections.Generic.List[object]
            foreach ($status in $config.Statuses) {
                foreach ($pr in (Get-AzDoPullRequests -Context $context -Repository $repo -Status $status -FromUtc $range.FromUtc `
                            -ToUtcExclusive $range.ToUtcExclusive -DateBasis $config.DateBasis -PageSize $config.PageSize `
                            -ServerSideDateFilter $config.UseServerSideDateFilter)) {
                    $rawList.Add($pr)
                }
            }
            $rawPrs = $rawList.ToArray()
            if ($config.SaveRawJson) { Export-PrMetricsJson -Data $rawPrs -Path (Join-Path $outputDir "raw_pullrequests_$repo.json") }
        }

        # ---- 2. 対象の絞り込み ----
        $targetPrs = @($rawPrs | Where-Object { Test-PullRequestIncluded -PullRequest $_ -Config $config -Range $range })
        Write-Log "[$repo] 取得 $(@($rawPrs).Count) 件 → 対象 $($targetPrs.Count) 件"

        # ---- 3. サイズ計算の準備 ----
        $repoPath = $null
        $gitArgs = @()
        if ($config.SizeMethod -eq 'Git' -and $targetPrs.Count -gt 0) {
            $gitArgs = Get-GitAuthConfigArgs -Config $config -Context $context
            $remoteUrl = $null
            if ($repoInfo) { $remoteUrl = [string]$repoInfo.remoteUrl }
            $repoPath = Initialize-GitRepository -Config $config -RepositoryName $repo -RemoteUrl $remoteUrl -ToolRoot $toolRoot -GitConfigArgs $gitArgs
        }

        # ---- 4. PR ごとのサイズ計算とレコード化 ----
        $index = 0
        foreach ($pr in $targetPrs) {
            $index++
            Write-Progress -Activity "[$repo] PR サイズ計算 ($($config.SizeMethod))" -Status "$index / $($targetPrs.Count) : #$($pr.pullRequestId)" `
                -PercentComplete ([int](100 * $index / $targetPrs.Count))

            $size = New-PrSizeResult -SizeSource 'none'
            try {
                switch ($config.SizeMethod) {
                    'Git' {
                        $prForGit = $pr
                        $hasTarget = $pr.PSObject.Properties['lastMergeTargetCommit'] -and $null -ne $pr.lastMergeTargetCommit
                        if (-not $hasTarget -and $context) {
                            $prForGit = Get-AzDoPullRequest -Context $context -Repository $repo -PullRequestId ([int]$pr.pullRequestId)
                        }
                        $size = Get-PrSizeFromGit -RepoPath $repoPath -PullRequest $prForGit -ExcludePatterns $config.ExcludePathPatterns `
                            -FetchMissing $config.FetchMissingCommits -GitConfigArgs $gitArgs
                    }
                    'Api' {
                        $size = Get-PrSizeFromApi -Context $context -Repository $repo -PullRequest $pr -ExcludePatterns $config.ExcludePathPatterns
                    }
                }
            }
            catch {
                Write-Warning "[$repo] PR #$($pr.pullRequestId) のサイズ計算に失敗: $($_.Exception.Message)"
                $size = New-PrSizeResult -SizeSource 'unavailable' -SizeNote $_.Exception.Message
            }

            $records.Add((ConvertTo-PrRecord -PullRequest $pr -Repository $repo -Size $size -Config $config -TimeZone $timeZone -WebBaseUrl $webBaseUrl))
        }
        Write-Progress -Activity "[$repo] PR サイズ計算" -Completed
        $repoStats.Add([pscustomobject]@{ Repository = $repo; Fetched = @($rawPrs).Count; Included = $targetPrs.Count })
    }

    # ---- 5. 集計と出力 ----
    Write-Log '集計して出力します' -Level Step
    $sortedRecords = @($records | Sort-Object Repository, PullRequestId)
    $periodSummary = Get-PeriodSummary -Records $sortedRecords -Config $config -Range $range
    $authorSummary = Get-AuthorSummary -Records $sortedRecords -Config $config -Range $range

    Export-PrMetricsCsv -Data $sortedRecords -Path (Join-Path $outputDir 'prs.csv')
    Export-PrMetricsCsv -Data $periodSummary -Path (Join-Path $outputDir 'summary_by_period.csv')
    Export-PrMetricsCsv -Data $authorSummary -Path (Join-Path $outputDir 'summary_by_author.csv')

    $configForLog = @{}
    foreach ($key in $config.Keys) { $configForLog[$key] = $config[$key] }
    Export-PrMetricsJson -Path (Join-Path $outputDir 'run_info.json') -Data ([ordered]@{
            ExecutedAt        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            ConfigPath        = $ConfigPath
            ReplayDir         = $ReplayDir
            FromLocal         = $range.FromLocal.ToString('yyyy-MM-dd')
            ToLocalInclusive  = $range.ToLocalExclusive.AddDays(-1).ToString('yyyy-MM-dd')
            Repositories      = $repoStats.ToArray()
            TotalPrs          = $sortedRecords.Count
            Config            = $configForLog
        })

    Write-PrMetricsConsoleSummary -PeriodSummary $periodSummary -Records $sortedRecords -Config $config
    Write-Log "完了: $($sortedRecords.Count) 件 → $outputDir" -Level Ok
    exit 0
}
catch {
    Write-Host ''
    Write-Host "エラー: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  場所: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    Write-Host '  詳細な原因は -Verbose を付けて再実行するか、docs\08_トラブルシューティング.md を参照してください。' -ForegroundColor DarkGray
    exit 1
}
