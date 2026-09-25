param(
    [Parameter(Mandatory=$true)][string]$DxfPath,
    [string]$ProgId = 'ZWCAD.Application.2026'
)
$ErrorActionPreference='Stop'
if(-not (Test-Path -LiteralPath $DxfPath)){throw "DXF 不存在：$DxfPath"}
$app=$null;$doc=$null;$stage='初始化'
try {
    $stage='创建独立 ZWCAD 自动化实例';$app=New-Object -ComObject $ProgId
    try {$stage='设置独立实例可见性';$app.Visible=$false} catch {}
    Start-Sleep -Seconds 2
    $stage='只读打开 DXF';try {$doc=$app.Documents.Open($DxfPath,$true)} catch {$stage='普通方式打开 DXF（只测试）';$doc=$app.Documents.Open($DxfPath)}
    if($null -eq $doc){throw 'ZWCAD 未返回已打开的测试文档。'}
    $counts=@{}
    foreach($entity in $doc.ModelSpace){
        $name=''
        try{$name=[string]$entity.ObjectName}catch{$name='Unknown'}
        if(-not $counts.ContainsKey($name)){$counts[$name]=0}
        $counts[$name]++
    }
    $layers=@()
    foreach($layer in $doc.Layers){$layers += [string]$layer.Name}
    [pscustomobject]@{
        Opened=$true
        ProgId=$ProgId
        Version=[string]$app.Version
        Document=[string]$doc.Name
        ReadOnly=$true
        ModelSpaceCount=[int]$doc.ModelSpace.Count
        EntityTypes=$counts
        HasSpiralLayer=($layers -contains 'ROAD_SPIRAL_POLYLINE')
        SpiralLayerEntityCount=if($counts.ContainsKey('AcDbPolyline')){$counts['AcDbPolyline']}else{0}
    } | ConvertTo-Json -Depth 5
} catch {
    $hr='';try{$hr=('0x{0:X8}' -f $_.Exception.HResult)}catch{}
    throw ('隔离 DXF 打开失败；阶段={0}；HRESULT={1}；错误={2}' -f $stage,$hr,$_.Exception.Message)
} finally {
    if($null -ne $doc){try{$doc.Close($false)}catch{}}
    if($null -ne $app){try{$app.Quit()}catch{};try{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($app)}catch{}}
}
