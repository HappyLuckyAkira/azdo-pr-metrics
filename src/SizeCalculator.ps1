# =============================================================================
# SizeCalculator.ps1
#   PR サイズ（変更ファイル数・追加/削除行数・サイズ区分）の計算。
#     ・Git 方式 : ローカル git の diff --numstat で行数まで計算
#     ・Api 方式 : PR イテレーションの変更一覧からファイル数のみ計算
#   詳細設計: docs\05_詳細設計.md「SizeCalculator.ps1」
# =============================================================================

function New-PrSizeResult {
    <# サイズ計算結果の共通オブジェクトを作る。取得できない値は $null。 #>
    param(
        $FilesChanged = $null,
        $LinesAdded = $null,
        $LinesDeleted = $null,
        $BinaryFiles = $null,
        $ExcludedFiles = $null,
        [string]$SizeSource = 'none',
        [string]$SizeNote = ''
    )
    $linesChanged = $null
    if ($null -ne $LinesAdded -and $null -ne $LinesDeleted) { $linesChanged = [int]$LinesAdded + [int]$LinesDeleted }

    [pscustomobject]@{
        FilesChanged  = $FilesChanged
        LinesAdded    = $LinesAdded
        LinesDeleted  = $LinesDeleted
        LinesChanged  = $linesChanged
        BinaryFiles   = $BinaryFiles
        ExcludedFiles = $ExcludedFiles
        SizeSource    = $SizeSource
        SizeNote      = $SizeNote
    }
}

# -----------------------------------------------------------------------------
# 共通: パス除外・サイズ区分
# -----------------------------------------------------------------------------

function ConvertTo-NormalizedRepoPath {
    <# パスを「先頭 / なし・区切り /」の形にそろえる。 #>
    param([string]$Path)
    if ($null -eq $Path) { return '' }
    return ($Path -replace '\\', '/').TrimStart('/')
}

function Test-PathExcluded {
    <#
    .SYNOPSIS
        パスが除外パターン(ワイルドカード)のいずれかに一致すれば $true。
        PowerShell の -like を使うため、* は '/' も含めて任意の文字列に一致する。
    #>
    param(
        [string]$Path,
        [string[]]$Patterns
    )
    if (-not $Patterns -or $Patterns.Count -eq 0) { return $false }
    $normalized = ConvertTo-NormalizedRepoPath $Path
    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($normalized -like (ConvertTo-NormalizedRepoPath $pattern)) { return $true }
    }
    return $false
}

function Get-PrSizeCategory {
    <#
    .SYNOPSIS
        サイズ区分名を返す。行数があれば MaxLines、無ければファイル数で MaxFiles を使って判定。
        どちらも無ければ空文字。上限 $null の区分は「上限なし」。
    #>
    param(
        $LinesChanged,
        $FilesChanged,
        [Parameter(Mandatory)][object[]]$Categories
    )

    if ($null -ne $LinesChanged) { $value = [int]$LinesChanged; $limitKey = 'MaxLines' }
    elseif ($null -ne $FilesChanged) { $value = [int]$FilesChanged; $limitKey = 'MaxFiles' }
    else { return '' }

    foreach ($category in $Categories) {
        $limit = $category[$limitKey]
        if ($null -eq $limit -or $value -le [int]$limit) { return [string]$category.Name }
    }
    return [string]$Categories[-1].Name
}

# -----------------------------------------------------------------------------
# Git 方式
# -----------------------------------------------------------------------------

function Invoke-Git {
    <#
    .SYNOPSIS
        git コマンドを実行し、終了コード・標準出力(行配列)・標準エラーを返す。
    .PARAMETER ConfigArgs
        '-c key=value' 形式の一時設定（認証ヘッダーなど）。ログには出さない。
    #>
    param(
        [string]$RepoPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string[]]$ConfigArgs = @()
    )

    $allArgs = @('-c', 'core.quotepath=false') + @($ConfigArgs)
    if ($RepoPath) { $allArgs += @('-C', $RepoPath) }
    $allArgs += $Arguments
    Write-Verbose ("git " + ($Arguments -join ' '))

    $previousEncoding = $null
    try { $previousEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # git が stderr に書いても例外にしない
    try {
        $raw = & git @allArgs 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
        if ($null -ne $previousEncoding) { try { [Console]::OutputEncoding = $previousEncoding } catch { } }
    }

    $stdout = New-Object System.Collections.Generic.List[string]
    $stderr = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($raw)) {
        if ($line -is [System.Management.Automation.ErrorRecord]) { $stderr.Add($line.ToString()) }
        elseif ($null -ne $line) { $stdout.Add([string]$line) }
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $stdout.ToArray()
        Error    = ($stderr -join "`n")
    }
}

function Get-GitAuthConfigArgs {
    <# GitUsePatHeader=$true のとき、PAT を一時的な HTTP ヘッダーとして渡す git 引数を返す。 #>
    param([Parameter(Mandatory)][hashtable]$Config, $Context)
    if (-not $Config.GitUsePatHeader -or $null -eq $Context) { return @() }
    return @('-c', "http.extraHeader=Authorization: Basic $($Context.BasicToken)")
}

function Initialize-GitRepository {
    <#
    .SYNOPSIS
        サイズ計算に使うローカルリポジトリを用意し、そのパスを返す。
        無ければ clone --mirror（AutoClone=$true の場合）、あれば fetch（FetchBeforeDiff=$true の場合）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$RepositoryName,
        [string]$RemoteUrl,
        [Parameter(Mandatory)][string]$ToolRoot,
        [string[]]$GitConfigArgs = @()
    )

    $version = Invoke-Git -Arguments @('--version')
    if ($version.ExitCode -ne 0) { throw 'git が見つかりません。Git for Windows をインストールするか、SizeMethod を Api / None にしてください。' }

    $root = Resolve-ToolPath -Path ([string]$Config.LocalRepoRoot) -ToolRoot $ToolRoot
    $path = Join-Path $root $RepositoryName

    if (-not (Test-Path -LiteralPath $path)) {
        if (-not $Config.AutoClone) {
            throw "ローカルリポジトリがありません: $path （AutoClone=`$true にするか、手動で clone してください）"
        }
        if (-not $RemoteUrl) { throw "clone 元 URL が不明です（リポジトリ: $RepositoryName）。" }

        New-Item -ItemType Directory -Force -Path $root | Out-Null
        Write-Host "  git clone --mirror を実行します（初回は時間がかかります）: $path"
        $cloneArgs = @('clone', '--mirror') + @($Config.CloneExtraArgs) + @($RemoteUrl, $path)
        $result = Invoke-Git -Arguments $cloneArgs -ConfigArgs $GitConfigArgs
        if ($result.ExitCode -ne 0) {
            throw "git clone に失敗しました: $($result.Error)`n  ヒント: git の認証(Git Credential Manager)・プロキシ(git config http.proxy)を確認するか、GitUsePatHeader=`$true を試してください。"
        }
    }
    else {
        $check = Invoke-Git -RepoPath $path -Arguments @('rev-parse', '--git-dir')
        if ($check.ExitCode -ne 0) { throw "git リポジトリではありません: $path" }

        if ($Config.FetchBeforeDiff) {
            Write-Host "  git fetch を実行します: $path"
            $result = Invoke-Git -RepoPath $path -Arguments @('fetch', 'origin', '--prune') -ConfigArgs $GitConfigArgs
            if ($result.ExitCode -ne 0) {
                Write-Warning "git fetch に失敗しました（ローカルの内容で続行します）: $($result.Error)"
            }
        }
    }
    return $path
}

function Test-GitCommitAvailable {
    <# コミットがローカルにあるか確認し、無ければ(許可されていれば)個別に fetch を試みる。 #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$CommitId,
        [bool]$FetchMissing = $true,
        [string[]]$GitConfigArgs = @()
    )
    $exists = (Invoke-Git -RepoPath $RepoPath -Arguments @('cat-file', '-e', "$CommitId^{commit}")).ExitCode -eq 0
    if ($exists -or -not $FetchMissing) { return $exists }

    [void](Invoke-Git -RepoPath $RepoPath -Arguments @('fetch', '--quiet', 'origin', $CommitId) -ConfigArgs $GitConfigArgs)
    return (Invoke-Git -RepoPath $RepoPath -Arguments @('cat-file', '-e', "$CommitId^{commit}")).ExitCode -eq 0
}

function Resolve-GitRenamePath {
    <#
    .SYNOPSIS
        numstat のリネーム表記を変更後のパスに変換する。
          'src/{old => new}/a.c' → 'src/new/a.c'
          'old.c => new.c'       → 'new.c'
    #>
    param([string]$Path)
    if ($Path -match '\{[^{}]* => [^{}]*\}') {
        $resolved = [regex]::Replace($Path, '\{[^{}]* => ([^{}]*)\}', '$1')
        return ($resolved -replace '/{2,}', '/')
    }
    if ($Path -match ' => ') { return ($Path -split ' => ', 2)[1] }
    return $Path
}

function ConvertFrom-GitNumstat {
    <#
    .SYNOPSIS
        'git diff --numstat' の出力（"追加<TAB>削除<TAB>パス" の行）を集計する。
        バイナリは "-<TAB>-<TAB>パス" になるため、ファイル数には数え、行数には数えない。
    #>
    param(
        [string[]]$Lines,
        [string[]]$ExcludePatterns = @()
    )
    $added = 0; $deleted = 0; $files = 0; $binary = 0; $excluded = 0

    foreach ($line in @($Lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 3
        if ($parts.Count -lt 3) { continue }

        $path = Resolve-GitRenamePath $parts[2]
        if (Test-PathExcluded -Path $path -Patterns $ExcludePatterns) { $excluded++; continue }

        $files++
        if ($parts[0] -eq '-' -or $parts[1] -eq '-') { $binary++; continue }
        $added += [int]$parts[0]
        $deleted += [int]$parts[1]
    }

    [pscustomobject]@{
        FilesChanged  = $files
        LinesAdded    = $added
        LinesDeleted  = $deleted
        BinaryFiles   = $binary
        ExcludedFiles = $excluded
    }
}

function Get-CommitIdOrEmpty {
    param($CommitRef)
    if ($null -eq $CommitRef) { return '' }
    return [string]$CommitRef.commitId
}

function Get-PrSizeFromGit {
    <#
    .SYNOPSIS
        ローカル git で PR の差分行数を計算する。
    .DESCRIPTION
        次の順で試し、最初に成功したものを採用する（採用方式は SizeSource に記録）。
          1. git:target..merge   lastMergeTargetCommit と lastMergeCommit の差分
                                 （マージ結果 − マージ先 ＝ PR が持ち込んだ変更。squash でも同じ）
          2. git:base...source   lastMergeTargetCommit と lastMergeSourceCommit の共通祖先からの差分
        どちらもコミットが手に入らなければ SizeSource='unavailable'。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)]$PullRequest,
        [string[]]$ExcludePatterns = @(),
        [bool]$FetchMissing = $true,
        [string[]]$GitConfigArgs = @()
    )

    $target = Get-CommitIdOrEmpty $PullRequest.lastMergeTargetCommit
    $merge = Get-CommitIdOrEmpty $PullRequest.lastMergeCommit
    $source = Get-CommitIdOrEmpty $PullRequest.lastMergeSourceCommit

    $strategies = @()
    if ($target -and $merge) {
        $strategies += [pscustomobject]@{ Name = 'target..merge'; Commits = @($target, $merge); DiffArgs = @($target, $merge) }
    }
    if ($target -and $source) {
        $strategies += [pscustomobject]@{ Name = 'base...source'; Commits = @($target, $source); DiffArgs = @("$target...$source") }
    }
    if ($strategies.Count -eq 0) {
        return New-PrSizeResult -SizeSource 'unavailable' -SizeNote 'PR にマージ関連のコミットIDがありません'
    }

    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($strategy in $strategies) {
        $missing = @($strategy.Commits | Where-Object {
                -not (Test-GitCommitAvailable -RepoPath $RepoPath -CommitId $_ -FetchMissing $FetchMissing -GitConfigArgs $GitConfigArgs)
            })
        if ($missing.Count -gt 0) {
            $notes.Add("$($strategy.Name): コミット未取得 $(($missing | ForEach-Object { $_.Substring(0, [math]::Min(8, $_.Length)) }) -join ',')")
            continue
        }

        $diff = Invoke-Git -RepoPath $RepoPath -Arguments (@('diff', '--numstat', '-M') + $strategy.DiffArgs) -ConfigArgs $GitConfigArgs
        if ($diff.ExitCode -ne 0) {
            $notes.Add("$($strategy.Name): git diff 失敗 $($diff.Error)")
            continue
        }

        $stat = ConvertFrom-GitNumstat -Lines $diff.Output -ExcludePatterns $ExcludePatterns
        return New-PrSizeResult -FilesChanged $stat.FilesChanged -LinesAdded $stat.LinesAdded -LinesDeleted $stat.LinesDeleted `
            -BinaryFiles $stat.BinaryFiles -ExcludedFiles $stat.ExcludedFiles -SizeSource "git:$($strategy.Name)" -SizeNote ($notes -join ' / ')
    }

    return New-PrSizeResult -SizeSource 'unavailable' -SizeNote ($notes -join ' / ')
}

# -----------------------------------------------------------------------------
# Api 方式
# -----------------------------------------------------------------------------

function Get-PrSizeFromApi {
    <#
    .SYNOPSIS
        REST API（最終イテレーションの変更一覧）から変更ファイル数を計算する。行数は取れない。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)]$PullRequest,
        [string[]]$ExcludePatterns = @()
    )

    $prId = [int]$PullRequest.pullRequestId
    $iterations = @(Get-AzDoPullRequestIterations -Context $Context -Repository $Repository -PullRequestId $prId)
    if ($iterations.Count -eq 0) {
        return New-PrSizeResult -SizeSource 'unavailable' -SizeNote 'イテレーションがありません'
    }
    $lastIterationId = ($iterations | Measure-Object -Property id -Maximum).Maximum

    $changes = @(Get-AzDoPullRequestIterationChanges -Context $Context -Repository $Repository -PullRequestId $prId -IterationId $lastIterationId)
    $files = 0; $excluded = 0
    foreach ($change in $changes) {
        $item = $change.item
        if ($null -ne $item -and $item.PSObject.Properties['isFolder'] -and $item.isFolder) { continue }
        $path = ''
        if ($null -ne $item -and $item.path) { $path = [string]$item.path }
        elseif ($change.PSObject.Properties['originalPath']) { $path = [string]$change.originalPath }

        if (Test-PathExcluded -Path $path -Patterns $ExcludePatterns) { $excluded++; continue }
        $files++
    }

    return New-PrSizeResult -FilesChanged $files -ExcludedFiles $excluded -SizeSource 'api' -SizeNote "iteration=$lastIterationId"
}
