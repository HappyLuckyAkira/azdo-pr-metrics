# =============================================================================
# AzDoClient.ps1
#   Azure DevOps REST API の呼び出し（認証・URL組み立て・再試行・ページング）。
#   使用 API の仕様: docs\03_AzureDevOps_API仕様.md
#   詳細設計      : docs\05_詳細設計.md「AzDoClient.ps1」
# =============================================================================

function Get-AzDoPat {
    <#
    .SYNOPSIS
        PAT を環境変数(プロセス→ユーザー)から取得する。無ければ対話入力を求める。
        PAT はログ・ファイル・画面に一切出力しないこと。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $name = [string]$Config.PatEnvVarName
    $pat = [Environment]::GetEnvironmentVariable($name, 'Process')
    if (-not $pat) { $pat = [Environment]::GetEnvironmentVariable($name, 'User') }

    if (-not $pat) {
        Write-Host "環境変数 $name が未設定です。PAT を入力してください（入力内容は表示されません）。"
        $secure = Read-Host -AsSecureString -Prompt 'PAT'
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $pat = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    if ([string]::IsNullOrWhiteSpace($pat)) { throw 'PAT が取得できませんでした。' }
    return $pat.Trim()
}

function New-AzDoContext {
    <#
    .SYNOPSIS
        API 呼び出しに必要な情報（URL・認証ヘッダー・通信設定）をまとめたコンテキストを作る。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Pat
    )

    $token = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
    $projectUrl = '{0}/{1}/{2}' -f ([string]$Config.BaseUrl).TrimEnd('/'),
        [uri]::EscapeDataString([string]$Config.Organization),
        [uri]::EscapeDataString([string]$Config.Project)

    [pscustomobject]@{
        ProjectUrl                 = $projectUrl
        ApiVersion                 = [string]$Config.ApiVersion
        Headers                    = @{ Authorization = "Basic $token"; Accept = 'application/json' }
        BasicToken                 = $token
        Proxy                      = [string]$Config.Proxy
        ProxyUseDefaultCredentials = [bool]$Config.ProxyUseDefaultCredentials
        MaxRetry                   = [int]$Config.MaxRetry
        RetryWaitSeconds           = [int]$Config.RetryWaitSeconds
    }
}

function Invoke-AzDoApi {
    <#
    .SYNOPSIS
        Azure DevOps REST API を GET で呼び出し、JSON をオブジェクトにして返す。
    .DESCRIPTION
        ・URL は {ProjectUrl}/_apis/{Path}?api-version=...&{Query}
        ・429 / 5xx / 通信エラーは MaxRetry 回まで再試行（待ち時間は倍々）
        ・401/403/404 などは再試行せず、原因のヒント付きで例外にする
        ・PowerShell 5.1 の文字化け対策として、応答は UTF-8 として自前でデコードする
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Path,
        [System.Collections.IDictionary]$Query = @{}
    )

    $pairs = New-Object System.Collections.Generic.List[string]
    $pairs.Add('api-version=' + [uri]::EscapeDataString($Context.ApiVersion))
    foreach ($key in $Query.Keys) {
        $value = $Query[$key]
        if ($null -eq $value -or "$value" -eq '') { continue }
        $pairs.Add($key + '=' + [uri]::EscapeDataString([string]$value))
    }
    $url = '{0}/_apis/{1}?{2}' -f $Context.ProjectUrl, $Path.TrimStart('/'), ($pairs -join '&')

    $requestParams = @{
        Uri             = $url
        Method          = 'GET'
        Headers         = $Context.Headers
        UseBasicParsing = $true
        ErrorAction     = 'Stop'
    }
    if ($Context.Proxy) {
        $requestParams.Proxy = $Context.Proxy
        if ($Context.ProxyUseDefaultCredentials) { $requestParams.ProxyUseDefaultCredentials = $true }
    }

    $attempt = 0
    while ($true) {
        $attempt++
        $response = $null
        $statusCode = $null
        $errorMessage = $null

        Write-Verbose "GET $url (試行 $attempt)"
        try {
            $response = Invoke-WebRequest @requestParams
        }
        catch {
            $errorMessage = $_.Exception.Message
            if ($_.Exception.Response) {
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = $null }
            }
        }

        if ($null -ne $response) {
            $contentType = [string]($response.Headers['Content-Type'])
            $text = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
            if ($contentType -notmatch 'json') {
                # PAT が無効だと 203 + サインイン用 HTML が返ることがある
                throw ("API が JSON 以外を返しました(HTTP $([int]$response.StatusCode), $contentType)。" +
                    "PAT が無効・期限切れ、または組織名(Organization)/BaseUrl が誤っている可能性があります。`nURL: $url")
            }
            return ($text | ConvertFrom-Json)
        }

        $retryable = ($null -eq $statusCode) -or ($statusCode -eq 429) -or ($statusCode -ge 500)
        if (-not $retryable -or $attempt -gt $Context.MaxRetry) {
            throw (Get-AzDoErrorHint -StatusCode $statusCode -Message $errorMessage -Url $url)
        }

        $wait = [int]($Context.RetryWaitSeconds * [math]::Pow(2, $attempt - 1))
        Write-Warning "API 呼び出し失敗(HTTP $statusCode): $errorMessage → $wait 秒後に再試行します ($attempt/$($Context.MaxRetry))"
        Start-Sleep -Seconds $wait
    }
}

function Get-AzDoErrorHint {
    <# HTTP ステータスに応じて、原因のヒントを付けたエラーメッセージを作る。 #>
    param($StatusCode, [string]$Message, [string]$Url)

    switch ($StatusCode) {
        400 { $hint = 'パラメーターが不正です。Azure DevOps Server の場合、ApiVersion を下げるか UseServerSideDateFilter=$false を試してください。' }
        401 { $hint = 'PAT が無効・期限切れ、またはスコープ不足です。PAT に Code (Read) スコープがあるか確認してください。' }
        403 { $hint = 'アクセス権がありません。PAT の作成者がプロジェクト/リポジトリを閲覧できるか確認してください。' }
        404 { $hint = '見つかりません。Organization / Project / Repositories の綴り（大文字小文字・ハイフン・アンダースコア）を確認してください。' }
        $null { $hint = '通信できませんでした。ネットワーク・プロキシ設定(Proxy)・BaseUrl を確認してください。' }
        default { $hint = '' }
    }
    return "Azure DevOps API エラー (HTTP $StatusCode): $Message`n  ヒント: $hint`n  URL: $Url"
}

function Get-AzDoRepository {
    <# リポジトリ情報（id, name, remoteUrl, defaultBranch など）を取得する。 #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Repository
    )
    Invoke-AzDoApi -Context $Context -Path ('git/repositories/{0}' -f [uri]::EscapeDataString($Repository))
}

function Get-AzDoPullRequests {
    <#
    .SYNOPSIS
        指定ステータスの PR を全ページ取得する。
    .DESCRIPTION
        ServerSideDateFilter=$true の場合、searchCriteria.minTime/maxTime/queryTimeRangeType で
        サーバー側でも期間を絞る（最終的な期間判定は呼び出し側で必ず行う）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][datetime]$FromUtc,
        [Parameter(Mandatory)][datetime]$ToUtcExclusive,
        [Parameter(Mandatory)][ValidateSet('Closed', 'Created')][string]$DateBasis,
        [int]$PageSize = 100,
        [bool]$ServerSideDateFilter = $true
    )

    $path = 'git/repositories/{0}/pullrequests' -f [uri]::EscapeDataString($Repository)
    $result = New-Object System.Collections.Generic.List[object]
    $skip = 0
    $isoFormat = 'yyyy-MM-ddTHH:mm:ssZ'
    $culture = [Globalization.CultureInfo]::InvariantCulture

    do {
        $query = [ordered]@{
            'searchCriteria.status' = $Status
            '$top'                  = $PageSize
            '$skip'                 = $skip
        }
        if ($ServerSideDateFilter) {
            $query['searchCriteria.queryTimeRangeType'] = $DateBasis.ToLowerInvariant()
            $query['searchCriteria.minTime'] = $FromUtc.ToString($isoFormat, $culture)
            $query['searchCriteria.maxTime'] = $ToUtcExclusive.ToString($isoFormat, $culture)
        }

        $response = Invoke-AzDoApi -Context $Context -Path $path -Query $query
        $items = @($response.value)
        foreach ($item in $items) { $result.Add($item) }
        $skip += $items.Count
        Write-Verbose "PR 取得: status=$Status 累計 $($result.Count) 件"
    } while ($items.Count -ge $PageSize)

    return $result.ToArray()
}

function Get-AzDoPullRequest {
    <# PR 1 件の詳細を取得する（一覧にマージコミット情報が無い場合の補完用）。 #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][int]$PullRequestId
    )
    Invoke-AzDoApi -Context $Context -Path ('git/repositories/{0}/pullrequests/{1}' -f [uri]::EscapeDataString($Repository), $PullRequestId)
}

function Get-AzDoPullRequestIterations {
    <# PR のイテレーション(push の単位)一覧を取得する。 #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][int]$PullRequestId
    )
    $response = Invoke-AzDoApi -Context $Context -Path ('git/repositories/{0}/pullRequests/{1}/iterations' -f [uri]::EscapeDataString($Repository), $PullRequestId)
    return @($response.value)
}

function Get-AzDoPullRequestIterationChanges {
    <#
    .SYNOPSIS
        指定イテレーションの変更ファイル一覧を全ページ取得する。
        $compareTo を省略(=0)すると、ソースとターゲットの共通祖先との比較＝PR 全体の変更になる。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)][int]$IterationId
    )

    $path = 'git/repositories/{0}/pullRequests/{1}/iterations/{2}/changes' -f [uri]::EscapeDataString($Repository), $PullRequestId, $IterationId
    $result = New-Object System.Collections.Generic.List[object]
    $skip = 0
    $top = 2000   # API の上限

    while ($true) {
        $response = Invoke-AzDoApi -Context $Context -Path $path -Query ([ordered]@{ '$top' = $top; '$skip' = $skip })
        foreach ($entry in @($response.changeEntries)) { if ($null -ne $entry) { $result.Add($entry) } }

        $nextSkip = 0
        if ($response.PSObject.Properties['nextSkip']) { $nextSkip = [int]$response.nextSkip }
        if ($nextSkip -le 0 -or $nextSkip -le $skip) { break }
        $skip = $nextSkip
    }
    return $result.ToArray()
}
