# =============================================================================
# Output.ps1
#   CSV / JSON の出力と、コンソールへの要約表示。
#   出力仕様: docs\06_出力仕様.md
# =============================================================================

function Write-Log {
    <# 時刻付きでコンソールに表示する。 #>
    param([string]$Message, [ValidateSet('Info', 'Step', 'Ok')][string]$Level = 'Info')
    $time = (Get-Date).ToString('HH:mm:ss')
    switch ($Level) {
        'Step' { Write-Host "[$time] == $Message" -ForegroundColor Cyan }
        'Ok' { Write-Host "[$time] $Message" -ForegroundColor Green }
        default { Write-Host "[$time] $Message" }
    }
}

function New-RunOutputDirectory {
    <# {OutputDir}\yyyyMMdd_HHmmss フォルダを作ってパスを返す。 #>
    param([Parameter(Mandatory)][string]$OutputRoot)
    $path = Join-Path $OutputRoot ((Get-Date).ToString('yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
}

function Export-PrMetricsCsv {
    <#
    .SYNOPSIS
        CSV を UTF-8(BOM付き) で出力する。Excel で開いても日本語が化けない。
        データが 0 件でも空ファイルを作る。
    #>
    param(
        [object[]]$Data = @(),
        [Parameter(Mandatory)][string]$Path
    )
    $rows = @($Data | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) {
        [IO.File]::WriteAllText($Path, '', (New-Object Text.UTF8Encoding $true))
        return
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8BOM
    }
    else {
        $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8   # 5.1 の UTF8 は BOM 付き
    }
}

function Export-PrMetricsJson {
    <# オブジェクトを UTF-8(BOM なし)の JSON で保存する。 #>
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)][string]$Path
    )
    $json = ConvertTo-Json -InputObject $Data -Depth 20
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

function Import-PrMetricsRawJson {
    <# SaveRawJson で保存した PR 一覧 JSON を読み込む（-ReplayDir 用）。 #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Replay 用ファイルがありません: $Path" }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    # PowerShell 5.1 の ConvertFrom-Json は JSON 配列を「配列 1 個」として出力するため、foreach で展開して返す
    $parsed = $text | ConvertFrom-Json
    foreach ($item in $parsed) { $item }
}

function Write-PrMetricsConsoleSummary {
    <# 実行結果の要約をコンソールに表示する。 #>
    param(
        [object[]]$PeriodSummary = @(),
        [object[]]$Records = @(),
        [Parameter(Mandatory)][hashtable]$Config
    )

    $target = $Config.Repositories[0]
    if ($Config.Repositories.Count -gt 1) { $target = $script:AllRepositoriesLabel }

    Write-Host ''
    Write-Host "---- 期間別サマリー ($target / 単位: $($Config.PeriodUnit) / 基準日: $($Config.DateBasis)) ----"
    $PeriodSummary | Where-Object { $_.Repository -eq $target } |
        Select-Object Period, PrCount, AuthorCount, LeadTimeMedianH, LinesChangedMedian, FilesChangedMedian |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    $sizeUnknown = @($Records | Where-Object { $_.SizeSource -eq 'unavailable' }).Count
    if ($sizeUnknown -gt 0) {
        Write-Warning "サイズを計算できなかった PR が $sizeUnknown 件あります（prs.csv の SizeNote 列を参照）。"
    }
}
