# 复杂缓和曲线拟合 DXF 回归脚本（开发期验收用）。
# 注意：本脚本依赖高节点折线数据文件 high_vertex_polyline_inspection.json，
# 该文件含真实图纸数据，未随仓库发布；运行前需自行准备并置于项目根目录。
param(
    [string]$CandidatePath = (Join-Path $PSScriptRoot '..\RoadCurveImporter.ps1'),
    [string]$OutputPath = (Join-Path $env:TEMP 'selftest_complex_spirals_fitted.dxf')
)

$ErrorActionPreference = 'Stop'
. $CandidatePath -LayoutSelfTest
try {
    $script:CurrentSettings = [pscustomobject]@{
        ToleranceM = 0.001; PrecisionMm = 1.0; Digits = 3; Prefix = 'K'; StartPosition = 1; StartStation = 0.0
        SpiralMode = 'Strict'; SpiralFitToleranceM = 0.0005; SwapCadXY = $true; ReverseCurveDirection = $true
    }
    $script:SpiralFitAttemptCount = 0
    $script:Diagnostics.Clear()
    $raw = [System.Collections.Generic.List[object]]::new()
    foreach($item in (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\high_vertex_polyline_inspection.json') -Raw | ConvertFrom-Json)) {
        $points = [System.Collections.Generic.List[object]]::new()
        foreach($point in $item.Points) { $points.Add((New-Point2 ([double]$point.X) ([double]$point.Y))) }
        $spiral = Get-SpiralCandidate $points
        if($null -eq $spiral) { throw ('高节点多段线 {0} 未通过 0.5 mm 严格验收。' -f $item.Handle) }
        $raw.Add((New-SpiralElement $spiral ([string]$item.Handle) 'ComplexFittedDxfRegression'))
    }
    Publish-Elements $raw
    Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
    Export-Dxf $OutputPath

    $lines = Get-Content -LiteralPath $OutputPath
    $entities = [System.Collections.Generic.List[object]]::new()
    for($i=0;$i -lt $lines.Count;$i++) {
        if($lines[$i].Trim() -eq '0' -and ($i+1 -lt $lines.Count) -and $lines[$i+1].Trim() -eq 'LWPOLYLINE') {
            $body = [System.Collections.Generic.List[string]]::new();$j=$i+2
            while(($j+1) -lt $lines.Count -and $lines[$j].Trim() -ne '0') {$body.Add($lines[$j].Trim());$body.Add($lines[$j+1].Trim());$j+=2}
            $layer='';$declared=-1;$vertices=[System.Collections.Generic.List[object]]::new()
            for($k=0;$k -lt $body.Count;$k+=2) {
                if($k+1 -ge $body.Count){break};$code=$body[$k];$value=$body[$k+1]
                if($code -eq '8'){$layer=$value}elseif($code -eq '90'){$declared=[int]$value}elseif($code -eq '10'){
                    $x=[double]::Parse($value,[cultureinfo]::InvariantCulture);$y=[double]::Parse($body[$k+3],[cultureinfo]::InvariantCulture);$vertices.Add((New-Point2 $x $y))
                }
            }
            if($layer -eq 'ROAD_SPIRAL_POLYLINE'){$entities.Add([pscustomobject]@{Declared=$declared;Vertices=$vertices})}
            $i=$j-1
        }
    }
    if($entities.Count -ne 16) { throw ('拟合 DXF 回旋线数量错误：{0}。' -f $entities.Count) }
    $minVertices=999999;$maxVertices=0;$maxSegment=0.0
    for($index=0;$index -lt $entities.Count;$index++) {
        $entity=$entities[$index];$count=$entity.Vertices.Count
        if($count -ne $entity.Declared -or $count -lt 801 -or $count -gt 802) { throw ('第 {0} 条拟合 DXF 折线顶点数错误：声明={1}，实际={2}。' -f ($index+1),$entity.Declared,$count) }
        $minVertices=[Math]::Min($minVertices,$count);$maxVertices=[Math]::Max($maxVertices,$count)
        for($p=1;$p -lt $count;$p++) {$maxSegment=[Math]::Max($maxSegment,(Get-Distance $entity.Vertices[$p-1] $entity.Vertices[$p]))}
        $source=$raw[$index]
        if((Get-Distance $entity.Vertices[0] $source.Start) -gt 1e-9 -or (Get-Distance $entity.Vertices[$count-1] $source.End) -gt 1e-9) { throw ('第 {0} 条拟合 DXF 折线端点未保持 CAD 原始坐标。' -f ($index+1)) }
    }
    if($maxSegment -gt 0.250001) { throw ('拟合 DXF 折线最大线段超过 0.25 m：{0:F9} m。' -f $maxSegment) }
    [pscustomobject]@{FittedSpiralPolylines=$entities.Count;MinimumVertices=$minVertices;MaximumVertices=$maxVertices;MaximumSegmentM=[Math]::Round($maxSegment,9);CadOriginalEndpoints=$true;DisplayOptionsIgnored=$true} | ConvertTo-Json
} finally { Stop-SpiralFitServer }
