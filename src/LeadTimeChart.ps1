# =============================================================================
# LeadTimeChart.ps1
#   クローズまでの時間（作成 → 完了）を 3 区分に分け、週ごとの件数を集計して
#   折れ線グラフ（SVG を埋め込んだ HTML）を作る。
#   仕様: docs\superpowers\specs\2026-10-09-leadtime-weekly-chart-design.md
#   詳細設計: docs\05_詳細設計.md「LeadTimeChart.ps1」
# =============================================================================

# 区分の定義（固定）。順序がそのまま CSV の列順・グラフの線の順になる。
#   Marker: グラフの点の形（白黒印刷でも区別できるように色と形の両方を変える）
$script:LeadTimeBuckets = @(
    [pscustomobject]@{ Id = 'Under24h';    Label = '24時間未満';     Color = '#2e7d32'; Marker = 'circle' }
    [pscustomobject]@{ Id = 'From24To72h'; Label = '24〜72時間未満'; Color = '#ef6c00'; Marker = 'square' }
    [pscustomobject]@{ Id = 'Over72h';     Label = '72時間以上';     Color = '#c62828'; Marker = 'triangle' }
)

function Get-LeadTimeBucket {
    <#
    .SYNOPSIS
        クローズまでの時間（時間）を区分 ID に変換する。境界ちょうど（24 / 72）は上側の区分に入る。
    #>
    param([Parameter(Mandatory)][double]$Hours)
    if ($Hours -lt 24) { return 'Under24h' }
    if ($Hours -lt 72) { return 'From24To72h' }
    return 'Over72h'
}
