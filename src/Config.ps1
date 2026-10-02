# =============================================================================
# Config.ps1
#   設定ファイル(settings.psd1)の読み込み・既定値の補完・検証、
#   および期間・日時・パスに関する共通ヘルパー。
#   詳細設計: docs\05_詳細設計.md「Config.ps1」
# =============================================================================

# 設定ファイルに書かれていない項目の既定値。
# 設定項目を追加するときは、ここ・config\settings.psd1・docs\04_設定ファイル仕様.md を一緒に更新する。
$script:PrMetricsDefaultConfig = @{
    BaseUrl                    = 'https://dev.azure.com'
    ApiVersion                 = '7.1'
    PatEnvVarName              = 'AZDO_PAT'
    Proxy                      = ''
    ProxyUseDefaultCredentials = $true
    FromDate                   = ''
    ToDate                     = ''
    LastNDays                  = 90
    DateBasis                  = 'Closed'
    TimeZoneId                 = 'Tokyo Standard Time'
    PeriodUnit                 = 'Week'
    WeekStartDay               = 'Monday'
    Statuses                   = @('completed')
    TargetBranches             = @()
    ExcludeDrafts              = $true
    ExcludeAuthors             = @()
    UseServerSideDateFilter    = $true
    SizeMethod                 = 'Git'
    LocalRepoRoot              = '.\repos'
    AutoClone                  = $true
    CloneExtraArgs             = @()
    FetchBeforeDiff            = $true
    FetchMissingCommits        = $true
    GitUsePatHeader            = $false
    ExcludePathPatterns        = @()
    SizeCategories             = @(
        @{ Name = 'XS'; MaxLines = 10;    MaxFiles = 1     }
        @{ Name = 'S';  MaxLines = 50;    MaxFiles = 3     }
        @{ Name = 'M';  MaxLines = 250;   MaxFiles = 10    }
        @{ Name = 'L';  MaxLines = 1000;  MaxFiles = 30    }
        @{ Name = 'XL'; MaxLines = $null; MaxFiles = $null }
    )
    OutputDir                  = '.\output'
    SaveRawJson                = $false
    PageSize                   = 100
    MaxRetry                   = 3
    RetryWaitSeconds           = 5
}

function Import-PrMetricsConfig {
    <#
    .SYNOPSIS
        設定ファイルを読み込み、コマンドライン上書き・既定値補完・検証を行って返す。
    .OUTPUTS
        [hashtable] 設定。キーは settings.psd1 と同じ。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        # コマンドライン引数による上書き。値が $null / 空文字 / 空配列のキーは無視する。
        [hashtable]$Overrides = @{}
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "設定ファイルが見つかりません: $Path"
    }
    $config = Import-PowerShellDataFile -LiteralPath $Path

    foreach ($key in @($Overrides.Keys)) {
        $value = $Overrides[$key]
        if ($null -eq $value) { continue }
        if ($value -is [array] -and $value.Count -eq 0) { continue }
        if ("$value" -eq '') { continue }
        $config[$key] = $value
    }

    foreach ($key in $script:PrMetricsDefaultConfig.Keys) {
        if (-not $config.ContainsKey($key)) {
            $config[$key] = $script:PrMetricsDefaultConfig[$key]
        }
    }

    # psd1 で要素1つの配列が文字列として読まれた場合でも配列として扱えるよう正規化
    foreach ($key in @('Repositories', 'Statuses', 'TargetBranches', 'ExcludeAuthors', 'ExcludePathPatterns', 'CloneExtraArgs', 'SizeCategories')) {
        $config[$key] = @($config[$key] | Where-Object { $null -ne $_ -and "$_" -ne '' })
    }

    Test-PrMetricsConfig -Config $config
    return $config
}

function Test-PrMetricsConfig {
    <#
    .SYNOPSIS
        設定値を検証する。誤りがあれば例外、注意点があれば警告を出す。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($key in @('Organization', 'Project', 'BaseUrl', 'ApiVersion', 'PatEnvVarName')) {
        if ([string]::IsNullOrWhiteSpace([string]$Config[$key])) { $errors.Add("$key が空です。") }
    }
    if ($Config.Repositories.Count -eq 0) { $errors.Add('Repositories に 1 つ以上のリポジトリ名を指定してください。') }

    $enumChecks = @(
        @{ Key = 'DateBasis';    Allowed = @('Closed', 'Created') }
        @{ Key = 'PeriodUnit';   Allowed = @('Day', 'Week', 'Month') }
        @{ Key = 'SizeMethod';   Allowed = @('Git', 'Api', 'None') }
        @{ Key = 'WeekStartDay'; Allowed = [Enum]::GetNames([DayOfWeek]) }
    )
    foreach ($check in $enumChecks) {
        if ($check.Allowed -notcontains [string]$Config[$check.Key]) {
            $errors.Add("$($check.Key) の値 '$($Config[$check.Key])' は不正です。指定可能: $($check.Allowed -join ', ')")
        }
    }

    foreach ($status in $Config.Statuses) {
        if (@('completed', 'abandoned', 'active') -notcontains $status) {
            $errors.Add("Statuses の値 '$status' は不正です。指定可能: completed, abandoned, active")
        }
    }
    if ($Config.Statuses.Count -eq 0) { $errors.Add('Statuses に 1 つ以上指定してください。') }

    foreach ($key in @('FromDate', 'ToDate')) {
        $value = [string]$Config[$key]
        if ($value -ne '') {
            $parsed = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                $errors.Add("$key '$value' は yyyy-MM-dd 形式で指定してください。")
            }
        }
    }
    if ([string]$Config.FromDate -eq '' -and [int]$Config.LastNDays -le 0) {
        $errors.Add('FromDate が空の場合、LastNDays は 1 以上にしてください。')
    }

    try { [void][TimeZoneInfo]::FindSystemTimeZoneById([string]$Config.TimeZoneId) }
    catch { $errors.Add("TimeZoneId '$($Config.TimeZoneId)' が見つかりません。例: 'Tokyo Standard Time'") }

    if ([int]$Config.PageSize -lt 1 -or [int]$Config.PageSize -gt 1000) { $errors.Add('PageSize は 1～1000 で指定してください。') }
    if ([int]$Config.MaxRetry -lt 0) { $errors.Add('MaxRetry は 0 以上で指定してください。') }

    if ($Config.SizeCategories.Count -eq 0) {
        $errors.Add('SizeCategories が空です。')
    }
    else {
        foreach ($cat in $Config.SizeCategories) {
            if (-not ($cat -is [hashtable]) -or [string]::IsNullOrWhiteSpace([string]$cat.Name)) {
                $errors.Add('SizeCategories の各要素は @{ Name = ...; MaxLines = ...; MaxFiles = ... } 形式にしてください。')
                break
            }
        }
    }

    if ($errors.Count -gt 0) {
        throw ("設定ファイルに誤りがあります:`n - " + ($errors -join "`n - "))
    }

    if ($Config.DateBasis -eq 'Closed' -and $Config.Statuses -contains 'active') {
        Write-Warning "DateBasis='Closed' のため、Statuses の 'active'(未完了) は完了日が無く集計対象になりません。"
    }
}

function Resolve-ToolPath {
    <#
    .SYNOPSIS
        相対パスをツールのルートフォルダ基準の絶対パスに変換する。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ToolRoot
    )
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $ToolRoot $Path))
}

function Get-PrMetricsDateRange {
    <#
    .SYNOPSIS
        設定から集計期間を求める。
    .OUTPUTS
        FromLocal / ToLocalExclusive : 設定タイムゾーンでの期間（終端は含まない）
        FromUtc / ToUtcExclusive     : 同じ期間の UTC
        Days                         : 日数
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][TimeZoneInfo]$TimeZone,
        [datetime]$NowUtc = [datetime]::UtcNow
    )

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $todayLocal = [TimeZoneInfo]::ConvertTimeFromUtc($NowUtc, $TimeZone).Date

    if ([string]$Config.ToDate -ne '') {
        $toLocalExclusive = [datetime]::ParseExact($Config.ToDate, 'yyyy-MM-dd', $culture).AddDays(1)
    }
    else {
        $toLocalExclusive = $todayLocal.AddDays(1)
    }

    if ([string]$Config.FromDate -ne '') {
        $fromLocal = [datetime]::ParseExact($Config.FromDate, 'yyyy-MM-dd', $culture)
    }
    else {
        $fromLocal = $toLocalExclusive.AddDays(-[int]$Config.LastNDays)
    }

    if ($fromLocal -ge $toLocalExclusive) {
        throw "集計期間が不正です（開始 $($fromLocal.ToString('yyyy-MM-dd')) が終了以降）。FromDate/ToDate を確認してください。"
    }

    [pscustomobject]@{
        FromLocal        = $fromLocal
        ToLocalExclusive = $toLocalExclusive
        FromUtc          = ConvertTo-UtcFromZone -LocalDateTime $fromLocal -TimeZone $TimeZone
        ToUtcExclusive   = ConvertTo-UtcFromZone -LocalDateTime $toLocalExclusive -TimeZone $TimeZone
        Days             = ($toLocalExclusive - $fromLocal).TotalDays
    }
}

function ConvertTo-UtcFromZone {
    <# 指定タイムゾーンの日時(Kind 不問)を UTC に変換する。 #>
    param(
        [Parameter(Mandatory)][datetime]$LocalDateTime,
        [Parameter(Mandatory)][TimeZoneInfo]$TimeZone
    )
    $unspecified = [datetime]::SpecifyKind($LocalDateTime, [DateTimeKind]::Unspecified)
    return [TimeZoneInfo]::ConvertTimeToUtc($unspecified, $TimeZone)
}

function ConvertTo-UtcDateTime {
    <#
    .SYNOPSIS
        API の日時値を UTC の [datetime] に変換する。
        PowerShell 7 は JSON の日時を自動で [datetime] に変換し、5.1 は文字列のまま返すため、両方に対応する。
        値が無い・0001 年などの無効値の場合は $null を返す。
    #>
    param($Value)

    if ($null -eq $Value -or "$Value" -eq '') { return $null }

    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Local) { $utc = $Value.ToUniversalTime() }
        else { $utc = [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
    }
    else {
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        $utc = [datetime]::SpecifyKind(
            [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, $styles),
            [DateTimeKind]::Utc)
    }

    if ($utc.Year -lt 2000) { return $null }
    return $utc
}
