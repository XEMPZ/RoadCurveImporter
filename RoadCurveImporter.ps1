[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$LayoutSelfTest,
    [switch]$SpiralModeSelfTest,
    [switch]$DefaultConfigurationSelfTest,
    [switch]$SurveyorPreviewSelfTest,
    [switch]$CoordinateSwapSelfTest,
    [switch]$CurveDirectionSelfTest,
    [switch]$DxfCadRestoreSelfTest,
    [switch]$PerformanceSelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing
if (-not ('ReadOnlyRot' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ReadOnlyRot {
  [DllImport("oleaut32.dll", PreserveSig=false)]
  public static extern void GetActiveObject(ref Guid rclsid, IntPtr reserved, [MarshalAs(UnmanagedType.IUnknown)] out object ppunk);
}
'@
}

$script:Tau = 2.0 * [Math]::PI
$script:DefaultTolerance = 0.001
$script:Elements = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
$script:SurveyorRows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
$script:Diagnostics = [System.Collections.ObjectModel.ObservableCollection[string]]::new()
$script:CurrentSettings = $null
$script:MaxCandidateSegments = 5000
$script:MinGapFillM = 0.0001  # ≥0.1 mm 才写入端点填充线
# Expensive SciPy Euler fitting is bounded per import.  Segments beyond the budget
# remain as exact source polylines; no curve is silently discarded.
$script:MaxSpiralFitCandidates = 24
$script:MaxSpiralFitVertices = 600
$script:MaxSpiralFitDurationSeconds = 5
$script:SpiralFitAttemptCount = 0
$script:SpiralFitServer = $null
$script:MaxPreviewElementShapes = 1600
$script:MaxPreviewVerticesPerCurve = 900
$script:MaxProgressTextCharacters = 18000
$script:RuntimeLogPath = Join-Path $PSScriptRoot 'RoadCurveImporter.runtime.log'
$script:PreviewRenderNotice = ''
$script:PreviewZoom = 1.0
$script:PreviewPanX = 0.0
$script:PreviewPanY = 0.0
$script:PreviewMinZoom = 0.25
$script:PreviewMaxZoom = 10.0
$script:PreviewIsPanning = $false
$script:PreviewPanStart = $null
$script:PreviewPanOriginX = 0.0
$script:PreviewPanOriginY = 0.0

function New-Point2([double]$x, [double]$y) { [pscustomobject]@{ X=$x; Y=$y } }
function Copy-Point2($p) { New-Point2 ([double]$p.X) ([double]$p.Y) }
function Get-Distance($a, $b) { [Math]::Sqrt(([double]$a.X-[double]$b.X)*([double]$a.X-[double]$b.X) + ([double]$a.Y-[double]$b.Y)*([double]$a.Y-[double]$b.Y)) }
function Get-Heading($a, $b) { Normalize-Angle ([Math]::Atan2(([double]$b.Y-[double]$a.Y), ([double]$b.X-[double]$a.X))) }
function Normalize-Angle([double]$angle) { $v=$angle % $script:Tau; if($v -lt 0){$v += $script:Tau}; return [double]$v }
function To-Degrees([double]$rad) { $rad * 180.0 / [Math]::PI }
function To-Radians([double]$degrees) { $degrees * [Math]::PI / 180.0 }
function To-SurveyAzimuth([double]$mathHeading) { To-Degrees (Normalize-Angle ([Math]::PI/2.0-$mathHeading)) }
function Format-DmsAngle([double]$decimalDegrees) {
    $sign='';if($decimalDegrees -lt 0){$sign='-'};$totalCentiseconds=[int64][Math]::Round([Math]::Abs($decimalDegrees)*360000.0,[MidpointRounding]::AwayFromZero)
    $degrees=[int][Math]::Floor($totalCentiseconds/360000);$remainder=$totalCentiseconds%360000
    $minutes=[int][Math]::Floor($remainder/6000);$remainder=$remainder%6000
    $seconds=[int][Math]::Floor($remainder/100);$centiseconds=[int]($remainder%100)
    return ('{0}{1}.{2:00}{3:00}{4:00}' -f $sign,$degrees,$minutes,$seconds,$centiseconds)
}
function Format-SurveyorDms([double]$decimalDegrees) {
    $azimuth=$decimalDegrees % 360.0;if($azimuth -lt 0){$azimuth+=360.0}
    $packed=Format-DmsAngle $azimuth
    if($packed -eq '360.000000'){return '0.000000'}
    return $packed
}
function Get-SurveyorDmsNumber([double]$decimalDegrees) {
    return [double]::Parse((Format-SurveyorDms $decimalDegrees),[cultureinfo]::InvariantCulture)
}
function Convert-SurveyorDmsToDegrees([double]$packedValue) {
    $sign=if($packedValue -lt 0){-1.0}else{1.0};$absolute=[Math]::Abs($packedValue);$degrees=[Math]::Floor($absolute);$packed=[int64][Math]::Round(($absolute-$degrees)*1000000.0,[MidpointRounding]::AwayFromZero)
    if($packed -ge 1000000){$degrees++;$packed=0};$minutes=[Math]::Floor($packed/10000);$remainder=$packed%10000;$seconds=[Math]::Floor($remainder/100);$centiseconds=$remainder%100
    if($minutes -gt 59 -or $seconds -gt 59){throw ('无效的 dd.mmss 方位角：{0}' -f $packedValue)}
    return $sign*($degrees+$minutes/60.0+$seconds/3600.0+$centiseconds/360000.0)
}

function Get-ActiveComApplication([string]$progId) {
    $clsidText=$null
    try {$clsidText=(Get-ItemProperty -LiteralPath ("Registry::HKEY_CLASSES_ROOT\{0}\CLSID" -f $progId) -ErrorAction Stop).'(default)'} catch {}
    if([string]::IsNullOrWhiteSpace($clsidText)){return $null}
    try {$obj=$null;$guid=[Guid]$clsidText;[ReadOnlyRot]::GetActiveObject([ref]$guid,[IntPtr]::Zero,[ref]$obj);return $obj} catch {return $null}
}
function Get-RunningCadApplication {
    $mode=0;try{$mode=[int]$HostSelector.SelectedIndex}catch{}
    $candidates=switch($mode) {
        1 {@([pscustomobject]@{Name='SouthMap/ZWCAD';ProgIds=@('ZWCAD.Application.2026','ZWCAD.Application')})}
        2 {@([pscustomobject]@{Name='Autodesk AutoCAD';ProgIds=@('AutoCAD.Application','AutoCAD.Application.25','AutoCAD.Application.24','AutoCAD.Application.23','AutoCAD.Application.22','AutoCAD.Application.21','AutoCAD.Application.20','AutoCAD.Application.19','AutoCAD.Application.18','AutoCAD.Application.17')})}
        default {@([pscustomobject]@{Name='SouthMap/ZWCAD';ProgIds=@('ZWCAD.Application.2026','ZWCAD.Application')},[pscustomobject]@{Name='Autodesk AutoCAD';ProgIds=@('AutoCAD.Application','AutoCAD.Application.25','AutoCAD.Application.24','AutoCAD.Application.23','AutoCAD.Application.22','AutoCAD.Application.21','AutoCAD.Application.20','AutoCAD.Application.19','AutoCAD.Application.18','AutoCAD.Application.17')})}
    }
    foreach($candidate in $candidates){foreach($progId in $candidate.ProgIds){$app=Get-ActiveComApplication $progId;if($null -ne $app){$version='';try{$version=[string]$app.Version}catch{};return [pscustomobject]@{Name=$candidate.Name;ProgId=$progId;Version=$version;Application=$app}}}
    }
    throw '没有找到所选 CAD 的活动 COM 会话。请启动完整 Windows 版 AutoCAD 或 SouthMap/ZWCAD，并确认其与本程序处于相同权限级别。'
}
function Update-HostStatus {
    try {$cadHost=Get-RunningCadApplication;$doc=$cadHost.Application.ActiveDocument;$HostStatusText.Text=('{0} · {1} · {2}' -f $cadHost.Name,$cadHost.Version,$doc.Name);$HostStatusText.Foreground=[System.Windows.Media.Brushes]::SeaGreen;$StatusText.Text=('已连接：{0}。仅读取，不写入图形。' -f $HostStatusText.Text)} catch {$HostStatusText.Text='未检测到所选 CAD 会话';$HostStatusText.Foreground=[System.Windows.Media.Brushes]::IndianRed;$StatusText.Text='请启动完整 Windows 版 CAD，或在“CAD 主机”中切换后刷新。'}
}
function Test-CadCoordinateSwap {
    try {return [bool]$script:CurrentSettings.SwapCadXY} catch {return $true}
}
function Convert-CadPoint([double]$cadX,[double]$cadY) {
    return New-Point2 $cadX $cadY
}
function Get-OutputPoint($point) {
    if(Test-CadCoordinateSwap){return New-Point2 ([double]$point.Y) ([double]$point.X)}
    return Copy-Point2 $point
}
function Test-CurveDirectionReverse {
    try {return [bool]$script:CurrentSettings.ReverseCurveDirection} catch {return $false}
}
function Test-IsCurveElement($e) {
    return (-not [bool]$e.IsGapFill -and $e.Kind -ne '直线')
}
function Get-CurveChordHeading($e) { return Get-Heading $e.Start $e.End }
function Get-DisplayHeading($e,[bool]$isStart) {
    $heading=if($isStart){[double]$e.StartHeading}else{[double]$e.EndHeading}
    if((Test-CurveDirectionReverse) -and (Test-IsCurveElement $e)){
        $chord=Get-CurveChordHeading $e
        return Normalize-Angle (2.0*$chord-$heading)
    }
    return Normalize-Angle $heading
}
function Get-DisplaySweep($e) {
    if((Test-CurveDirectionReverse) -and (Test-IsCurveElement $e)){return -[double]$e.Sweep}
    return [double]$e.Sweep
}
function Get-DisplayRadius($e,[double]$radius) {
    if((Test-CurveDirectionReverse) -and (Test-IsCurveElement $e)){return -$radius}
    return $radius
}
function Get-CurveDisplayPoint($e,$point) {
    if(-not ((Test-CurveDirectionReverse) -and (Test-IsCurveElement $e))){return Copy-Point2 $point}
    $origin=$e.Start;$chord=Get-CurveChordHeading $e;$ux=[Math]::Cos($chord);$uy=[Math]::Sin($chord);$dx=[double]$point.X-[double]$origin.X;$dy=[double]$point.Y-[double]$origin.Y;$projection=$dx*$ux+$dy*$uy
    return New-Point2 ([double]$origin.X+(2.0*$projection*$ux-$dx)) ([double]$origin.Y+(2.0*$projection*$uy-$dy))
}
function Convert-PointArray($value) {
    $values = @($value | ForEach-Object { [double]$_ })
    if (($values.Count % 2) -ne 0) { throw 'CAD 坐标数组不是二维坐标对。' }
    $points = [System.Collections.Generic.List[object]]::new()
    for($i=0; $i -lt $values.Count; $i+=2) { $points.Add((Convert-CadPoint $values[$i] $values[$i+1])) }
    return $points
}

function Convert-ThreePoint($value) {
    $v=@($value | ForEach-Object {[double]$_})
    if($v.Count -lt 2){ throw 'CAD 点坐标不完整。' }
    return Convert-CadPoint $v[0] $v[1]
}

function New-LineElement($start, $end, [string]$handle, [string]$source, [int]$segment) {
    $length = Get-Distance $start $end
    if ($length -lt $script:CurrentSettings.ToleranceM) { $script:Diagnostics.Add("忽略近零长度线段：$handle") ; return $null }
    $heading=Get-Heading $start $end
    return [pscustomobject]@{ Kind='直线'; Classification='直线'; Start=(Copy-Point2 $start); End=(Copy-Point2 $end); Center=$null; Radius=$null; StartRadius=0.0; EndRadius=0.0; Sweep=0.0; Length=$length; StartHeading=$heading; EndHeading=$heading; Handle=$handle; Source=$source; Segment=$segment; Vertices=$null; Reversed=$false; IsGapFill=$false; Note='' }
}

function New-ArcElement($start, $end, $center, [double]$radius, [double]$sweep, [string]$handle, [string]$source, [int]$segment) {
    $chord=Get-Distance $start $end
    if($chord -lt $script:CurrentSettings.ToleranceM -or $radius -le 0 -or [Math]::Abs($sweep) -lt 1e-12) { $script:Diagnostics.Add("忽略无效圆弧：$handle") ; return $null }
    $chordHeading=Get-Heading $start $end
    $signedRadius=([Math]::Sign($sweep)*$radius)
    return [pscustomobject]@{ Kind='圆曲线'; Classification='圆弧'; Start=(Copy-Point2 $start); End=(Copy-Point2 $end); Center=(Copy-Point2 $center); Radius=$signedRadius; StartRadius=(-$signedRadius); EndRadius=(-$signedRadius); Sweep=$sweep; Length=([Math]::Abs($radius*$sweep)); StartHeading=(Normalize-Angle ($chordHeading-$sweep/2.0)); EndHeading=(Normalize-Angle ($chordHeading+$sweep/2.0)); Handle=$handle; Source=$source; Segment=$segment; Vertices=$null; Reversed=$false; IsGapFill=$false; Note='' }
}

function Get-SpiralCandidate($points) {
    if($points.Count -lt 20){return $null}
    $mode=[string]$script:CurrentSettings.SpiralMode
    if($mode -eq 'Off'){return $null}
    if($points.Count -gt $script:MaxSpiralFitVertices){
        $script:Diagnostics.Add(('高节点折线含 {0} 个顶点，超过单段欧拉拟合性能上限 {1}；为防止卡顿已按原始折线保真输入。' -f $points.Count,$script:MaxSpiralFitVertices))
        return $null
    }
    if($script:SpiralFitAttemptCount -ge $script:MaxSpiralFitCandidates){
        $script:Diagnostics.Add(('本次导入已达到欧拉拟合安全上限 {0} 段；其余高节点折线按原始顶点保真输入。' -f $script:MaxSpiralFitCandidates))
        return $null
    }
    $toleranceM=[double]$script:CurrentSettings.SpiralFitToleranceM
    $lengths=[System.Collections.Generic.List[double]]::new();$headings=[System.Collections.Generic.List[double]]::new();$stations=[System.Collections.Generic.List[double]]::new();[void]$stations.Add(0.0);$total=0.0
    for($i=0;$i -lt $points.Count-1;$i++){$d=Get-Distance $points[$i] $points[$i+1];if($d -lt $script:CurrentSettings.ToleranceM){continue};$total+=$d;[void]$lengths.Add([double]$d);[void]$headings.Add([double](Get-Heading $points[$i] $points[$i+1]));[void]$stations.Add([double]$total)}
    if($headings.Count -lt 12 -or $total -le 0){return $null}
    $x=@();$y=@();for($i=1;$i -lt $headings.Count;$i++){$delta=Normalize-Angle($headings[$i]-$headings[$i-1]);if($delta -gt [Math]::PI){$delta-=$script:Tau};$ds=([double]$lengths[$i-1]+[double]$lengths[$i])/2.0;$x += [double]$stations[$i];$y += ($delta/$ds)}
    if($x.Count -lt 10){return $null};$n=[double]$x.Count;$sumX=($x|Measure-Object -Sum).Sum;$sumY=($y|Measure-Object -Sum).Sum;$sumXX=0.0;$sumXY=0.0;for($i=0;$i -lt $x.Count;$i++){$sumXX+=$x[$i]*$x[$i];$sumXY+=$x[$i]*$y[$i]};$den=$n*$sumXX-$sumX*$sumX;if([Math]::Abs($den) -lt 1e-14){return $null};$slope=($n*$sumXY-$sumX*$sumY)/$den;$intercept=($sumY-$slope*$sumX)/$n
    $meanY=$sumY/$n;$ssRes=0.0;$ssTot=0.0;for($i=0;$i -lt $x.Count;$i++){$res=$y[$i]-($intercept+$slope*$x[$i]);$ssRes+=$res*$res;$dev=$y[$i]-$meanY;$ssTot+=$dev*$dev};if($ssTot -lt 1e-18){return $null};$r2=1.0-$ssRes/$ssTot;$startK=$intercept;$endK=$intercept+$slope*$total;$signs=@($y|Where-Object {[Math]::Abs($_) -gt 1e-8}|ForEach-Object {[Math]::Sign($_)}|Select-Object -Unique)
    $span=[Math]::Abs($endK-$startK);$scale=[Math]::Max([Math]::Max([Math]::Abs($startK),[Math]::Abs($endK)),1e-6);$preliminaryPass=($r2 -ge 0.999 -and $span -ge 0.05*$scale -and $signs.Count -eq 1)
    if(-not $preliminaryPass -and $mode -eq 'Strict'){return $null}
    if(-not $preliminaryPass -and $mode -eq 'Loose'){$script:Diagnostics.Add(('宽松欧拉判定：曲率预筛选未完全通过（R²={0:F6}），继续执行 2 mm 拟合验收。' -f $r2))}
    $script:SpiralFitAttemptCount++
    $fitLabel=if($mode -eq 'Strict'){'严格 0.5 mm'}else{'宽松 2 mm'}
    Write-Progress ('正在进行第 {0}/{1} 段欧拉回旋线拟合（{2} 个顶点，{3} 验收）…' -f $script:SpiralFitAttemptCount,$script:MaxSpiralFitCandidates,$points.Count,$fitLabel) $false;Pump-UiEvents
    $fit=Invoke-EulerFit $points $toleranceM $mode;if($null -eq $fit){return $null}
    [pscustomobject]@{Length=[double]$fit.length_m;StartHeading=(Normalize-Angle ([double]$fit.start_heading_rad));EndHeading=(Normalize-Angle ([double]$fit.end_heading_rad));StartCurvature=if([double]$fit.start_radius_m -eq 0){0.0}else{-1.0/[double]$fit.start_radius_m};EndCurvature=if([double]$fit.end_radius_m -eq 0){0.0}else{-1.0/[double]$fit.end_radius_m};Slope=$slope;R2=$r2;FitMaxResidualM=[double]$fit.max_vertex_error_m;FitToleranceM=$toleranceM;FitMode=$mode;Vertices=$points}
}
function Stop-SpiralFitServer {
    if($null -eq $script:SpiralFitServer){return}
    try {if(-not $script:SpiralFitServer.HasExited){$script:SpiralFitServer.Kill($true)}} catch {}
    try {$script:SpiralFitServer.Dispose()} catch {}
    $script:SpiralFitServer=$null
}
function Start-SpiralFitServer {
    if($null -ne $script:SpiralFitServer -and -not $script:SpiralFitServer.HasExited){return $true}
    Stop-SpiralFitServer
    if($null -eq $script:SpiralFitterPath -or -not (Test-Path -LiteralPath $script:SpiralFitterPath)){return $false}
    $serverPath=Join-Path $PSScriptRoot 'spiral_fitter_server.py'
    if(-not (Test-Path -LiteralPath $serverPath)){return $false}
    $python=Get-Command python -ErrorAction SilentlyContinue|Select-Object -First 1
    if($null -eq $python){$script:Diagnostics.Add('未检测到 Python；高节点折线不会被合并为欧拉回旋线。');return $false}
    try {
        $psi=[System.Diagnostics.ProcessStartInfo]::new();$psi.FileName=[string]$python.Source;$psi.WorkingDirectory=$PSScriptRoot;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        [void]$psi.ArgumentList.Add('-u');[void]$psi.ArgumentList.Add($serverPath);[void]$psi.ArgumentList.Add([string]$script:SpiralFitterPath)
        $process=[System.Diagnostics.Process]::new();$process.StartInfo=$psi
        if(-not $process.Start()){throw '无法启动持久欧拉回旋线拟合进程。'}
        $script:SpiralFitServer=$process
        return $true
    } catch {$script:Diagnostics.Add(('无法启动持久欧拉回旋线拟合进程：{0}' -f $_.Exception.Message));Stop-SpiralFitServer;return $false}
}
function Invoke-EulerFit($points,[double]$toleranceM,[string]$mode) {
    $modeText=if($mode -eq 'Strict'){'严格 0.5 mm'}else{'宽松 2 mm'}
    try {
        if(-not (Start-SpiralFitServer)){return $null}
        $payload=[pscustomobject]@{points=@(foreach($p in $points){[pscustomobject]@{x=[double]$p.X;y=[double]$p.Y}});tolerance_m=$toleranceM}|ConvertTo-Json -Compress
        $script:SpiralFitServer.StandardInput.WriteLine($payload);$script:SpiralFitServer.StandardInput.Flush()
        $responseTask=$script:SpiralFitServer.StandardOutput.ReadLineAsync()
        if(-not $responseTask.Wait([int]($script:MaxSpiralFitDurationSeconds*1000))){$script:Diagnostics.Add(('欧拉回旋线{0}拟合超过 {1} 秒，已安全终止并按原始折线保留。' -f $modeText,$script:MaxSpiralFitDurationSeconds));Stop-SpiralFitServer;return $null}
        $line=$responseTask.Result
        if([string]::IsNullOrWhiteSpace($line)){throw '持久拟合进程未返回结果。'}
        $response=$line|ConvertFrom-Json
        if(-not [bool]$response.ok){$detail=if($response.error){[string]$response.error}else{'未生成拟合结果'};$script:Diagnostics.Add(('欧拉回旋线{0}拟合失败：{1}；将按原始折线保留。' -f $modeText,$detail));return $null}
        $fit=$response.result
        if(-not [bool]$fit.strict_pass){$script:Diagnostics.Add(('高节点折线未通过欧拉回旋线{0}验收：最大拟合偏差 {1:F3} mm（限值 ≤ {2:F3} mm），将按原始折线段保留。' -f $modeText,(1000.0*[double]$fit.max_vertex_error_m),(1000.0*$toleranceM)));return $null}
        return $fit
    } catch {$script:Diagnostics.Add(('欧拉回旋线{0}拟合失败：{1}，将按原始折线段保留。' -f $modeText,$_.Exception.Message));Stop-SpiralFitServer;return $null}
}

function Get-SurveySignedRadius([double]$curvature) {if([Math]::Abs($curvature) -lt 1e-4){return 0.0};return -1.0/$curvature}
function New-SpiralElement($candidate,[string]$handle,[string]$source) {$copies=[System.Collections.Generic.List[object]]::new();foreach($p in $candidate.Vertices){$copies.Add((Copy-Point2 $p))};$modeText=if($candidate.FitMode -eq 'Strict'){'严格 0.5 mm'}else{('宽松 {0:F3} mm' -f (1000.0*[double]$candidate.FitToleranceM))};return [pscustomobject]@{Kind='缓和曲线';Classification=('欧拉回旋线：{0} 验收；曲率—弧长回归 R²={1:F6}；最大拟合偏差 {2:F3} mm' -f $modeText,$candidate.R2,(1000.0*[double]$candidate.FitMaxResidualM));Start=(Copy-Point2 $candidate.Vertices[0]);End=(Copy-Point2 $candidate.Vertices[$candidate.Vertices.Count-1]);Center=$null;Radius=$null;StartRadius=(Get-SurveySignedRadius $candidate.StartCurvature);EndRadius=(Get-SurveySignedRadius $candidate.EndCurvature);Sweep=0.0;Length=$candidate.Length;StartHeading=$candidate.StartHeading;EndHeading=$candidate.EndHeading;Handle=$handle;Source=$source;Segment=0;Vertices=$copies;Reversed=$false;IsGapFill=$false;Note=''}}

function New-DiscreteCurveElement($points, [string]$handle, [string]$source) {
    if($points.Count -lt 2){return $null}
    $length=0.0; $headings=[System.Collections.Generic.List[double]]::new()
    for($i=0;$i -lt $points.Count-1;$i++){$segmentLength=Get-Distance $points[$i] $points[$i+1];if($segmentLength -ge $script:CurrentSettings.ToleranceM){$length+=$segmentLength;[void]$headings.Add([double](Get-Heading $points[$i] $points[$i+1]))}}
    if($length -lt $script:CurrentSettings.ToleranceM -or $headings.Count -lt 1){return $null}
    $classification='原始离散曲线（未可靠判别：可能为椭圆弧、样条或自由曲线）'
    if($headings.Count -ge 8){
        $turns=[System.Collections.Generic.List[double]]::new(); for($i=1;$i -lt $headings.Count;$i++){$d=Normalize-Angle($headings[$i]-$headings[$i-1]);if($d -gt [Math]::PI){$d-=$script:Tau};[void]$turns.Add([double]$d)}
        $positive=@($turns|Where-Object {$_ -gt 1e-10}).Count; $negative=@($turns|Where-Object {$_ -lt -1e-10}).Count
        if(($positive -eq 0 -or $negative -eq 0) -and ($positive+$negative -ge 6)){$classification='原始离散曲线（曲率单向渐变候选；仍保留原始点，未转换为缓和曲线）'}
    }
    $copies=[System.Collections.Generic.List[object]]::new(); foreach($p in $points){$copies.Add((Copy-Point2 $p))}
    return [pscustomobject]@{Kind='原始离散曲线';Classification=$classification;Start=(Copy-Point2 $points[0]);End=(Copy-Point2 $points[$points.Count-1]);Center=$null;Radius=$null;StartRadius=0.0;EndRadius=0.0;Sweep=0.0;Length=$length;StartHeading=$headings[0];EndHeading=$headings[$headings.Count-1];Handle=$handle;Source=$source;Segment=0;Vertices=$copies;Reversed=$false;IsGapFill=$false;Note=''}
}

function New-BulgeElement($start, $end, [double]$bulge, [string]$handle, [string]$source, [int]$segment) {
    $chord=Get-Distance $start $end
    if($chord -lt $script:CurrentSettings.ToleranceM) { $script:Diagnostics.Add("忽略近零长度多段线段：$handle/$segment") ; return $null }
    if([Math]::Abs($bulge) -lt 1e-12) { return New-LineElement $start $end $handle $source $segment }
    $sweep=4.0*[Math]::Atan($bulge)
    $sinHalf=[Math]::Sin($sweep/2.0)
    if([Math]::Abs($sinHalf) -lt 1e-12) { $script:Diagnostics.Add("bulge 数值退化：$handle/$segment") ; return $null }
    $radius=[Math]::Abs($chord/(2.0*$sinHalf))
    $mid=New-Point2 (([double]$start.X+[double]$end.X)/2.0) (([double]$start.Y+[double]$end.Y)/2.0)
    $dx=[double]$end.X-[double]$start.X; $dy=[double]$end.Y-[double]$start.Y
    $leftNormal=New-Point2 (-$dy/$chord) ($dx/$chord)
    $offset=$chord/(2.0*[Math]::Tan($sweep/2.0))
    $center=New-Point2 ($mid.X+$leftNormal.X*$offset) ($mid.Y+$leftNormal.Y*$offset)
    return New-ArcElement $start $end $center $radius $sweep $handle $source $segment
}

function Convert-CadEntity($entity) {
    $name=[string]$entity.ObjectName; $handle=[string]$entity.Handle
    switch -Regex ($name) {
        '^(AcDbLine|Line)$' {
            return ,(New-LineElement (Convert-ThreePoint $entity.StartPoint) (Convert-ThreePoint $entity.EndPoint) $handle $name 0)
        }
        'Arc$' {
            $start=Convert-ThreePoint $entity.StartPoint; $end=Convert-ThreePoint $entity.EndPoint; $center=Convert-ThreePoint $entity.Center
            $sweep=[double]$entity.EndAngle-[double]$entity.StartAngle
            while($sweep -le 0){$sweep += $script:Tau}
            return ,(New-ArcElement $start $end $center ([double]$entity.Radius) $sweep $handle $name 0)
        }
        'Polyline$' {
            $points=Convert-PointArray $entity.Coordinates
            $closed=[bool]$entity.Closed; $count=if($closed){$points.Count}else{$points.Count-1}
            $hasBulge=$false; for($b=0;$b -lt $count;$b++){try{if([Math]::Abs([double]$entity.GetBulge($b)) -gt 1e-12){$hasBulge=$true;break}}catch{}}
            if(-not $closed -and -not $hasBulge -and $points.Count -ge 20){
                $spiral=$null; if([string]$script:CurrentSettings.SpiralMode -ne 'Off'){$spiral=Get-SpiralCandidate $points}
                if($null -ne $spiral){$modeText=if($spiral.FitMode -eq 'Strict'){'严格 0.5 mm'}else{('宽松 {0:F3} mm' -f (1000.0*$spiral.FitToleranceM))};$script:Diagnostics.Add(('已识别欧拉回旋线：{0}，{1} 验收通过，最大拟合偏差 {2:F3} mm；作为单一线元导入。' -f $handle,$modeText,(1000.0*$spiral.FitMaxResidualM)));return ,(New-SpiralElement $spiral $handle $name)}
                $reason=if([string]$script:CurrentSettings.SpiralMode -eq 'Off'){'未启用缓和曲线识别'}else{'未通过所选欧拉回旋线验收'}
                $script:Diagnostics.Add(('高节点折线 {0} {1}，按原始 {2} 条直线段保真输入。' -f $handle,$reason,($points.Count-1)));$segments=[System.Collections.Generic.List[object]]::new();for($i=0;$i -lt $points.Count-1;$i++){$line=New-LineElement $points[$i] $points[$i+1] $handle $name $i;if($null -ne $line){$segments.Add($line)}};return @($segments)
            }
            $result=[System.Collections.Generic.List[object]]::new()
            for($i=0;$i -lt $count;$i++){
                $bulge=0.0; try { $bulge=[double]$entity.GetBulge($i) } catch {}
                $part=New-BulgeElement $points[$i] $points[(($i+1)%$points.Count)] $bulge $handle $name $i
                if($null -ne $part){$result.Add($part)}
            }
            return @($result)
        }
        default { $script:Diagnostics.Add("忽略不支持的实体 $name（句柄 $handle）") ; return @() }
    }
}

function Reverse-Element($e) {
    $vertices=$null; if($null -ne $e.Vertices){$vertices=[System.Collections.Generic.List[object]]::new();for($i=$e.Vertices.Count-1;$i -ge 0;$i--){$vertices.Add((Copy-Point2 $e.Vertices[$i]))}}
    [pscustomobject]@{ Kind=$e.Kind; Classification=$e.Classification; Start=(Copy-Point2 $e.End); End=(Copy-Point2 $e.Start); Center=$e.Center; Radius=if($null -eq $e.Radius){$null}else{-[double]$e.Radius}; StartRadius=(-[double]$e.EndRadius); EndRadius=(-[double]$e.StartRadius); Sweep=-[double]$e.Sweep; Length=[double]$e.Length; StartHeading=(Normalize-Angle ([double]$e.EndHeading+[Math]::PI)); EndHeading=(Normalize-Angle ([double]$e.StartHeading+[Math]::PI)); Handle=$e.Handle; Source=$e.Source; Segment=$e.Segment; Vertices=$vertices; Reversed=(-not [bool]$e.Reversed); IsGapFill=[bool]$e.IsGapFill; Note=[string]$e.Note }
}

function New-GapFillElement($start,$end,$from,$to,[double]$distance) {
    if($distance -lt $script:MinGapFillM){return $null}
    $heading=Get-Heading $start $end
    $note=('端点容差填充：{0}:{1}/{2} → {3}:{4}/{5}，间隙 {6:F3} mm（配置容差 ≤ {7:F3} mm）。' -f $from.Source,$from.Handle,$from.Segment,$to.Source,$to.Handle,$to.Segment,(1000.0*$distance),(1000.0*$script:ConnectionToleranceM))
    return [pscustomobject]@{ Kind='填充直线'; Classification='端点容差填充线'; Start=(Copy-Point2 $start); End=(Copy-Point2 $end); Center=$null; Radius=$null; StartRadius=0.0; EndRadius=0.0; Sweep=0.0; Length=$distance; StartHeading=$heading; EndHeading=$heading; Handle=('FILL_{0}_{1}_{2}' -f $from.Handle,$from.Segment,$to.Handle); Source='端点容差填充'; Segment=0; Vertices=$null; Reversed=$false; IsGapFill=$true; Note=$note }
}

function Add-EndpointFill($ordered,$from,$to,[double]$distance) {
    if($distance -lt $script:MinGapFillM){return}
    $fill=New-GapFillElement $from.End $to.Start $from $to $distance
    if($null -ne $fill){$ordered.Add($fill);$script:Diagnostics.Add($fill.Note)}
}

function Get-EndpointDegree($items, $point, [double]$tol) {
    $count=0
    foreach($e in $items){ if((Get-Distance $e.Start $point) -le $tol){$count++}; if((Get-Distance $e.End $point) -le $tol){$count++} }
    return $count
}

function Optimize-RouteDirection($items) {
    if($items.Count -lt 2){return @($items)}
    $keep=0;$flip=0
    foreach($e in $items){if([bool]$e.IsGapFill){continue};if([bool]$e.Reversed){$flip++}else{$keep++}}
    if($flip -gt $keep){
        $result=[System.Collections.Generic.List[object]]::new();for($i=$items.Count-1;$i -ge 0;$i--){$result.Add((Reverse-Element $items[$i]))}
        $script:Diagnostics.Add(('智能方向判定：已采用与 CAD 原始实体方向一致性更高的线路正向（保留 {0} 段，反向匹配 {1} 段）。' -f $flip,$keep))
        return @($result)
    }
    $script:Diagnostics.Add(('智能方向判定：已采用与 CAD 原始实体方向一致性更高的线路正向（保留 {0} 段，反向匹配 {1} 段）。' -f $keep,$flip))
    return @($items)
}

function Append-Sequentially($target,$candidate,[double]$tol) {
    if($target.Count -eq 0){$target.Add($candidate);return}
    $previous=$target[$target.Count-1]
    $startDistance=Get-Distance $candidate.Start $previous.End; $endDistance=Get-Distance $candidate.End $previous.End
    if($endDistance -lt $startDistance -and $endDistance -le $tol){$candidate=Reverse-Element $candidate;$startDistance=$endDistance}
    if($startDistance -le $tol){Add-EndpointFill $target $previous $candidate $startDistance}
    $target.Add($candidate)
}function Get-OrderSpatialKey($point,[double]$cellSize) {
    $gx=[int64][Math]::Floor([double]$point.X/$cellSize)
    $gy=[int64][Math]::Floor([double]$point.Y/$cellSize)
    return ('{0}|{1}' -f $gx,$gy)
}
function Get-OrderSpatialNeighbors($buckets,$point,[double]$cellSize,[double]$tol,$visited,[int]$excludeIndex) {
    $result=[System.Collections.Generic.List[object]]::new()
    $gx=[int64][Math]::Floor([double]$point.X/$cellSize)
    $gy=[int64][Math]::Floor([double]$point.Y/$cellSize)
    for($dx=-1;$dx -le 1;$dx++){
        for($dy=-1;$dy -le 1;$dy++){
            $key=('{0}|{1}' -f ($gx+$dx),($gy+$dy))
            if(-not $buckets.ContainsKey($key)){continue}
            foreach($record in $buckets[$key]){
                if($record.Index -eq $excludeIndex -or $visited.Contains([int]$record.Index)){continue}
                if((Get-Distance $record.Point $point) -le $tol){$result.Add($record)}
            }
        }
    }
    return @($result)
}
function Get-OrderSpatialSeed($items,$buckets,[double]$cellSize,[double]$tol,$visited) {
    $best=$null;$bestDegree=[int]::MaxValue
    for($index=0;$index -lt $items.Count;$index++){
        if($visited.Contains($index)){continue}
        $item=$items[$index]
        $startDegree=@(Get-OrderSpatialNeighbors $buckets $item.Start $cellSize $tol $visited $index).Count
        $endDegree=@(Get-OrderSpatialNeighbors $buckets $item.End $cellSize $tol $visited $index).Count
        $side=if($endDegree -lt $startDegree){'End'}else{'Start'}
        $degree=[Math]::Min($startDegree,$endDegree)
        if($null -eq $best -or $degree -lt $bestDegree){$best=[pscustomobject]@{Index=$index;Side=$side;Degree=$degree};$bestDegree=$degree;if($degree -eq 0){break}}
    }
    return $best
}
function Order-LargeElementsSpatial($items,[double]$tol) {
    if($items.Count -eq 0){return @()}
    $cellSize=[Math]::Max($tol,1e-9)
    $buckets=[System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[object]]]::new([System.StringComparer]::Ordinal)
    for($index=0;$index -lt $items.Count;$index++){
        $item=$items[$index]
        foreach($endpoint in @([pscustomobject]@{Side='Start';Point=$item.Start},[pscustomobject]@{Side='End';Point=$item.End})){
            $key=Get-OrderSpatialKey $endpoint.Point $cellSize
            if(-not $buckets.ContainsKey($key)){$buckets[$key]=[System.Collections.Generic.List[object]]::new()}
            $buckets[$key].Add([pscustomobject]@{Index=$index;Side=$endpoint.Side;Point=$endpoint.Point})
        }
    }
    $visited=[System.Collections.Generic.HashSet[int]]::new()
    $ordered=[System.Collections.Generic.List[object]]::new();$components=0;$branches=0
    while($visited.Count -lt $items.Count){
        $seed=Get-OrderSpatialSeed $items $buckets $cellSize $tol $visited
        if($null -eq $seed){break}
        $element=$items[$seed.Index];if($seed.Side -eq 'End'){$element=Reverse-Element $element}
        $visited.Add([int]$seed.Index)|Out-Null;$ordered.Add($element);$current=$element.End;$previous=$element;$components++
        while($true){
            $neighbors=@(Get-OrderSpatialNeighbors $buckets $current $cellSize $tol $visited -1)
            if($neighbors.Count -eq 0){break}
            if($neighbors.Count -gt 1){$branches++}
            $nextRecord=$neighbors|Sort-Object @{Expression={Get-Distance $_.Point $current};Ascending=$true},Index,Side|Select-Object -First 1
            $next=$items[[int]$nextRecord.Index]
            if($nextRecord.Side -eq 'End'){$next=Reverse-Element $next}
            $distance=Get-Distance $next.Start $current
            Add-EndpointFill $ordered $previous $next $distance
            $ordered.Add($next);$visited.Add([int]$nextRecord.Index)|Out-Null;$current=$next.End;$previous=$next
        }
    }
    if($components -gt 1){$script:Diagnostics.Add(('空间拓扑排序：发现 {0} 个不连通分量，已分别保持线内连续顺序。' -f $components))}
    if($branches -gt 0){$script:Diagnostics.Add(('空间拓扑排序：发现 {0} 次分叉候选，已按最近端点和稳定输入序号选择主线。' -f $branches))}
    return @(Optimize-RouteDirection $ordered)
}

function Order-Elements($items, [double]$tol) {
    if($items.Count -gt 300){
        $script:Diagnostics.Add(('大量离散线元：{0} 个道路段使用空间索引端点拓扑排序；不再依赖 CAD 枚举或框选顺序。' -f $items.Count))
        return @(Order-LargeElementsSpatial $items $tol)
    }
    $remaining=[System.Collections.Generic.List[object]]::new(); foreach($e in $items){$remaining.Add($e)}
    $ordered=[System.Collections.Generic.List[object]]::new()
    while($remaining.Count -gt 0){
        $seed=$remaining[0]; $startSide='Start'
        if((Get-EndpointDegree $remaining $seed.End $tol) -eq 1 -and (Get-EndpointDegree $remaining $seed.Start $tol) -ne 1){$startSide='End'}
        if($startSide -eq 'End'){$seed=Reverse-Element $seed}
        $ordered.Add($seed); $remaining.RemoveAt(0); $current=$seed.End; $previous=$seed
        $connected=$true
        while($connected -and $remaining.Count -gt 0){
            $connected=$false
            for($i=0;$i -lt $remaining.Count;$i++){
                $candidate=$remaining[$i]; $startDistance=Get-Distance $candidate.Start $current; $endDistance=Get-Distance $candidate.End $current
                if($startDistance -le $tol){ Add-EndpointFill $ordered $previous $candidate $startDistance; $ordered.Add($candidate); $current=$candidate.End; $previous=$candidate; $remaining.RemoveAt($i); $connected=$true; break }
                if($endDistance -le $tol){ $reversed=Reverse-Element $candidate; Add-EndpointFill $ordered $previous $reversed $endDistance; $ordered.Add($reversed); $current=$reversed.End; $previous=$reversed; $remaining.RemoveAt($i); $connected=$true; break }
            }
        }
        if($remaining.Count -gt 0){$script:Diagnostics.Add('检测到不连续或分叉实体：已从下一连通分量重新开始排序。')}
    }
    return @(Optimize-RouteDirection $ordered)
}

function Format-Station([double]$station, [string]$prefix) {
    $digits=3;try{$digits=[int]$script:CurrentSettings.Digits}catch{};$sign='';if($station -lt 0){$sign='-'};$abs=[Math]::Abs($station);$km=[Math]::Floor($abs/1000.0);$m=$abs-$km*1000.0;$decimal='';if($digits -gt 0){$decimal='.'+('0'*$digits)};$pattern='0'+$decimal;$m=[Math]::Round($m,$digits);if($m -ge 1000){$km++;$m=0};return ('{0}{1}{2}+{3}' -f $sign,$prefix,$km,$m.ToString($pattern,[cultureinfo]::InvariantCulture))
}

function Get-SurveyorValues($row) {$e=$row._Element;$digits=[int]$script:SurveyorExportDigits;$start=Get-OutputPoint $e.Start;$heading=Get-DisplayHeading $e $true;return @([Math]::Round([double]$row._StartStation,$digits),[Math]::Round([double]$row._EndStation,$digits),[Math]::Round([double]$start.X,$digits),[Math]::Round([double]$start.Y,$digits),(Get-SurveyorDmsNumber (To-SurveyAzimuth $heading)),[Math]::Round((Get-DisplayRadius $e $e.StartRadius),$digits),[Math]::Round((Get-DisplayRadius $e $e.EndRadius),$digits),0)}
function Refresh-SurveyorRows {
    $script:SurveyorRows.Clear()
    foreach($row in $script:Elements){
        $v=Get-SurveyorValues $row;$e=$row._Element
        $script:SurveyorRows.Add([pscustomobject]@{
            '线型'=$e.Kind
            '起始里程(m)'=$v[0]
            '结束里程(m)'=$v[1]
            '起始方位角(dd.mmss)'=$v[4]
            '起始X坐标(m)'=$v[2]
            '起始Y坐标(m)'=$v[3]
            '开始半径(m；左负右正)'=$v[5]
            '结束半径(m；左负右正)'=$v[6]
            '终点X坐标(m)'=[Math]::Round([double](Get-OutputPoint $e.End).X,[int]$script:SurveyorExportDigits)
            '终点Y坐标(m)'=[Math]::Round([double](Get-OutputPoint $e.End).Y,[int]$script:SurveyorExportDigits)
            '终点方位角(dd.mmss)'=(Get-SurveyorDmsNumber (To-SurveyAzimuth (Get-DisplayHeading $e $false)))
        })
    }
    Update-GridView
}
function Update-GridView {if($null -eq $ElementGrid){return};if([bool]$SurveyorPreviewBox.IsChecked){$ElementGrid.ItemsSource=$script:SurveyorRows}else{$ElementGrid.ItemsSource=$script:Elements}}

function Publish-Elements($ordered) {
    # Detach the grid during bulk population. Thousands of collection notifications otherwise redraw once per row.
    if($null -ne $ElementGrid){$ElementGrid.ItemsSource=$null}
    $script:Elements.Clear(); $sequence=0; $digits=[int]$script:CurrentSettings.Digits
    $startIndex=[int]$script:CurrentSettings.StartPosition
    if($startIndex -gt $ordered.Count){$script:Diagnostics.Add("起算点位置 $startIndex 超过要素数 $($ordered.Count)，已按第 1 个要素起算。") ; $startIndex=1}
    $priorLength=0.0; for($i=0;$i -lt ($startIndex-1);$i++){$priorLength += [double]$ordered[$i].Length}
    $station=[double]$script:CurrentSettings.StartStation-$priorLength
    foreach($e in $ordered){
        $sequence++; $startStation=$station; $station += [double]$e.Length;$displayStart=Get-OutputPoint $e.Start;$displayEnd=Get-OutputPoint $e.End;$displayStartHeading=Get-DisplayHeading $e $true;$displayEndHeading=Get-DisplayHeading $e $false;$displaySweep=Get-DisplaySweep $e;$displayStartRadius=Get-DisplayRadius $e $e.StartRadius;$displayEndRadius=Get-DisplayRadius $e $e.EndRadius;$displayRadius=if($null -eq $e.Radius){$null}else{Get-DisplayRadius $e $e.Radius}
        $row=[pscustomobject]@{
            序号=$sequence; 线型=$e.Kind; 长度_m=[Math]::Round($e.Length,$digits); 起点桩号=(Format-Station $startStation $script:CurrentSettings.Prefix); 终点桩号=(Format-Station $station $script:CurrentSettings.Prefix)
            起点X=[Math]::Round($displayStart.X,$digits); 起点Y=[Math]::Round($displayStart.Y,$digits); 终点X=[Math]::Round($displayEnd.X,$digits); 终点Y=[Math]::Round($displayEnd.Y,$digits)
            '起点方位角(dd.mmss)'=(Get-SurveyorDmsNumber (To-SurveyAzimuth $displayStartHeading)); '终点方位角(dd.mmss)'=(Get-SurveyorDmsNumber (To-SurveyAzimuth $displayEndHeading)); 开始半径_m=[Math]::Round($displayStartRadius,$digits); 结束半径_m=[Math]::Round($displayEndRadius,$digits); 半径_m=if($null -eq $displayRadius){''}else{[Math]::Round($displayRadius,$digits)}; '偏角(dd.mmss)'=(Format-DmsAngle (To-Degrees $displaySweep)); 判别=$e.Classification; 来源=('{0}:{1}/{2}' -f $e.Source,$e.Handle,$e.Segment); 备注=[string]$e.Note
            _Element=$e; _StartStation=$startStation; _EndStation=$station
        }
        $script:Elements.Add($row)
    }
    Refresh-SurveyorRows
}

function Get-CurrentSettings {
    $tolMm=0.0; $startStation=0.0; $startPosition=1
    if(-not [double]::TryParse($PrecisionBox.Text,[ref]$tolMm) -or $tolMm -le 0){throw '计算精度必须是正数（单位：mm）。'}
    if(-not [int]::TryParse($StartPositionBox.Text,[ref]$startPosition) -or $startPosition -lt 1){throw '起算点位置必须是大于等于 1 的要素序号。'}
    if(-not [double]::TryParse($StartStationBox.Text,[ref]$startStation)){throw '起算点桩号必须是数值（单位：m）。'}
    $digits=[Math]::Max(0,[int][Math]::Ceiling(-[Math]::Log10($tolMm/1000.0)))
    $spiralMode=if(-not [bool]$DetectSpiralsBox.IsChecked){'Off'}elseif([bool]$LooseSpiralRadio.IsChecked){'Loose'}else{'Strict'};$spiralTolerance=if($spiralMode -eq 'Loose'){$script:LooseSpiralToleranceM}else{$script:StrictSpiralToleranceM};return [pscustomobject]@{ ToleranceM=($tolMm/1000.0); PrecisionMm=$tolMm; Digits=$digits; Prefix=$PrefixBox.Text.Trim(); StartPosition=$startPosition; StartStation=$startStation; SpiralMode=$spiralMode; SpiralFitToleranceM=$spiralTolerance; SwapCadXY=[bool]$CoordinateSwapBox.IsChecked; ReverseCurveDirection=[bool]$CurveDirectionBox.IsChecked }
}

function Draw-Schematic {
    $PreviewCanvas.Children.Clear(); if($script:Elements.Count -eq 0){return}
    $minX=[double]::PositiveInfinity;$minY=[double]::PositiveInfinity;$maxX=[double]::NegativeInfinity;$maxY=[double]::NegativeInfinity
    # Assigning min/max inside a nested PowerShell function writes child-scope locals.
    # Keep bounds collection and reduction in this function's own scope.
    $previewBounds=[System.Collections.Generic.List[object]]::new()
    foreach($row in $script:Elements){
        $e=$row._Element
        if($null -ne $e.Start){$previewBounds.Add($e.Start)}
        if($null -ne $e.End){$previewBounds.Add($e.End)}
        if($null -ne $e.Center){$previewBounds.Add((Get-CurveDisplayPoint $e $e.Center))}
        if($null -ne $e.Vertices){foreach($vertex in $e.Vertices){if($null -ne $vertex){$previewBounds.Add((Get-CurveDisplayPoint $e $vertex))}}}
    }
    foreach($point in $previewBounds){
        $x=[double]$point.X;$y=[double]$point.Y
        if($x -lt $minX){$minX=$x};if($x -gt $maxX){$maxX=$x}
        if($y -lt $minY){$minY=$y};if($y -gt $maxY){$maxY=$y}
    }
    if(-not [double]::IsFinite($minX)){return}
    $w=[Math]::Max(320.0,$PreviewCanvas.ActualWidth);$h=[Math]::Max(220.0,$PreviewCanvas.ActualHeight);$dx=[Math]::Max(1.0,$maxX-$minX);$dy=[Math]::Max(1.0,$maxY-$minY);$baseScale=[Math]::Min(($w-58.0)/$dx,($h-58.0)/$dy);$scale=$baseScale*$script:PreviewZoom;$centerX=($minX+$maxX)/2.0;$centerY=($minY+$maxY)/2.0
    $script:PreviewBaseScale=$baseScale;$script:PreviewCenterX=$centerX;$script:PreviewCenterY=$centerY
    function Map-Point($p){[System.Windows.Point]::new($w/2.0+($p.X-$centerX)*$scale+$script:PreviewPanX,$h/2.0-($p.Y-$centerY)*$scale+$script:PreviewPanY)}
    function Add-RouteMarker($point,[string]$caption,$brush,[double]$labelOffset){$mapped=Map-Point $point;$dot=[System.Windows.Shapes.Ellipse]::new();$dot.Width=12;$dot.Height=12;$dot.Fill=$brush;$dot.Stroke=[System.Windows.Media.Brushes]::White;$dot.StrokeThickness=1.7;$PreviewCanvas.Children.Add($dot)|Out-Null;[System.Windows.Controls.Canvas]::SetLeft($dot,$mapped.X-6);[System.Windows.Controls.Canvas]::SetTop($dot,$mapped.Y-6);$label=[System.Windows.Controls.Border]::new();$label.Background=[System.Windows.Media.Brushes]::White;$label.BorderBrush=$brush;$label.BorderThickness=[System.Windows.Thickness]::new(1);$label.CornerRadius=[System.Windows.CornerRadius]::new(3);$label.Padding=[System.Windows.Thickness]::new(4,1,4,1);$labelText=[System.Windows.Controls.TextBlock]::new();$labelText.Text=$caption;$labelText.FontSize=11;$labelText.FontWeight='SemiBold';$labelText.Foreground=$brush;$label.Child=$labelText;$PreviewCanvas.Children.Add($label)|Out-Null;[System.Windows.Controls.Canvas]::SetLeft($label,$mapped.X+8);[System.Windows.Controls.Canvas]::SetTop($label,$mapped.Y+$labelOffset)}
    $count=$script:Elements.Count;$elementStep=[Math]::Max(1,[int][Math]::Ceiling($count/[double]$script:MaxPreviewElementShapes))
    if($elementStep -gt 1){
        $overview=[System.Windows.Shapes.Polyline]::new();$overview.Stroke=[System.Windows.Media.Brushes]::SteelBlue;$overview.StrokeThickness=2.2
        for($i=0;$i -lt $count;$i+=$elementStep){$e=$script:Elements[$i]._Element;$overview.Points.Add((Map-Point $e.Start));$overview.Points.Add((Map-Point $e.End))}
        $last=$script:Elements[$count-1]._Element;$overview.Points.Add((Map-Point $last.End));$PreviewCanvas.Children.Add($overview)|Out-Null
        $script:PreviewRenderNotice=('示意图性能保护：共 {0} 个要素，已按每 {1} 段抽样绘制总览；完整几何、表格与导出不受影响。' -f $count,$elementStep)
    } else {
        $script:PreviewRenderNotice=''
        foreach($row in $script:Elements){
            $e=$row._Element;$shape=[System.Windows.Shapes.Polyline]::new();$shape.Stroke=if([bool]$e.IsGapFill){[System.Windows.Media.Brushes]::DarkOrange}elseif($e.Kind -eq '直线'){[System.Windows.Media.Brushes]::MediumTurquoise}elseif($e.Kind -eq '圆曲线'){[System.Windows.Media.Brushes]::IndianRed}else{[System.Windows.Media.Brushes]::MediumSlateBlue};$shape.StrokeThickness=if([bool]$e.IsGapFill){3.2}else{2.6};if([bool]$e.IsGapFill){$shape.StrokeDashArray=[System.Windows.Media.DoubleCollection]@(4,2)}
            if($e.Kind -eq '直线' -or [bool]$e.IsGapFill){$shape.Points.Add((Map-Point $e.Start));$shape.Points.Add((Map-Point $e.End))}
            elseif($e.Kind -eq '圆曲线'){$center=Get-CurveDisplayPoint $e $e.Center;$start=$e.Start;$displaySweep=Get-DisplaySweep $e;$startAngle=[Math]::Atan2(($start.Y-$center.Y),($start.X-$center.X));$n=[Math]::Max(12,[int]([Math]::Abs($displaySweep)*24));for($i=0;$i -le $n;$i++){$a=$startAngle+$displaySweep*$i/$n;$p=New-Point2 ($center.X+[Math]::Abs($e.Radius)*[Math]::Cos($a)) ($center.Y+[Math]::Abs($e.Radius)*[Math]::Sin($a));$shape.Points.Add((Map-Point $p))}}
            else {$vertexCount=$e.Vertices.Count;$vertexStep=[Math]::Max(1,[int][Math]::Ceiling($vertexCount/[double]$script:MaxPreviewVerticesPerCurve));for($i=0;$i -lt $vertexCount;$i+=$vertexStep){$shape.Points.Add((Map-Point (Get-CurveDisplayPoint $e $e.Vertices[$i])))};if(($vertexCount-1)%$vertexStep -ne 0){$shape.Points.Add((Map-Point (Get-CurveDisplayPoint $e $e.Vertices[$vertexCount-1])))}}
            $PreviewCanvas.Children.Add($shape)|Out-Null
        }
    }
    Add-RouteMarker $script:Elements[0]._Element.Start '起点' ([System.Windows.Media.Brushes]::SeaGreen) -27.0;Add-RouteMarker $script:Elements[$script:Elements.Count-1]._Element.End '终点' ([System.Windows.Media.Brushes]::Crimson) 9.0
}

function Reset-PreviewZoom {
    $script:PreviewZoom=1.0;$script:PreviewPanX=0.0;$script:PreviewPanY=0.0;$script:PreviewIsPanning=$false;$script:PreviewPanStart=$null;Draw-Schematic
}
function Start-PreviewPan($eventArgs) {
    if($script:Elements.Count -eq 0){return};$script:PreviewIsPanning=$true;$script:PreviewPanStart=$eventArgs.GetPosition($PreviewCanvas);$script:PreviewPanOriginX=$script:PreviewPanX;$script:PreviewPanOriginY=$script:PreviewPanY;$PreviewCanvas.CaptureMouse()|Out-Null;$PreviewCanvas.Cursor=[System.Windows.Input.Cursors]::SizeAll;$eventArgs.Handled=$true
}
function Move-PreviewPan($eventArgs) {
    if(-not $script:PreviewIsPanning -or $null -eq $script:PreviewPanStart){return};$position=$eventArgs.GetPosition($PreviewCanvas);$script:PreviewPanX=$script:PreviewPanOriginX+($position.X-$script:PreviewPanStart.X);$script:PreviewPanY=$script:PreviewPanOriginY+($position.Y-$script:PreviewPanStart.Y);Draw-Schematic;$eventArgs.Handled=$true
}
function End-PreviewPan($eventArgs) {
    if(-not $script:PreviewIsPanning){return};$script:PreviewIsPanning=$false;$script:PreviewPanStart=$null;if($PreviewCanvas.IsMouseCaptured){$PreviewCanvas.ReleaseMouseCapture()|Out-Null};$PreviewCanvas.Cursor=[System.Windows.Input.Cursors]::Hand;$eventArgs.Handled=$true
}
function Refresh-DisplayOptions {
    if($script:Elements.Count -eq 0){return};$script:CurrentSettings=Get-CurrentSettings;$ordered=@($script:Elements|ForEach-Object {$_._Element})
    Publish-Elements $ordered;Draw-Schematic;$StatusText.Text='已按当前坐标显示/曲线方向选项刷新道路要素表、预览与导出数据。'
}

function Zoom-Preview($eventArgs) {
    if($script:Elements.Count -eq 0){return}
    $oldZoom=[double]$script:PreviewZoom;$factor=if($eventArgs.Delta -gt 0){1.2}else{1.0/1.2};$newZoom=[Math]::Max($script:PreviewMinZoom,[Math]::Min($script:PreviewMaxZoom,$oldZoom*$factor))
    if([Math]::Abs($newZoom-$oldZoom) -lt 1e-12){return}
    $mouse=$eventArgs.GetPosition($PreviewCanvas);$w=[Math]::Max(320.0,$PreviewCanvas.ActualWidth);$h=[Math]::Max(220.0,$PreviewCanvas.ActualHeight);$ratio=$newZoom/$oldZoom
    $script:PreviewPanX=$script:PreviewPanX+($mouse.X-$w/2.0-$script:PreviewPanX)*(1.0-$ratio)
    $script:PreviewPanY=$script:PreviewPanY+($mouse.Y-$h/2.0-$script:PreviewPanY)*(1.0-$ratio)
    $script:PreviewZoom=$newZoom;Draw-Schematic;$eventArgs.Handled=$true
}

function Get-SpiralDxfVertices($e) {
    # DXF has no Euler-spiral entity. Always export a dense polyline from the accepted model.
    $existing=[System.Collections.Generic.List[object]]::new()
    if($null -ne $e.Vertices){foreach($v in $e.Vertices){if($null -ne $v){$existing.Add($v)}}}
    $length=[Math]::Max(0.0,[double]$e.Length)
    if($length -lt 1e-9){return @($existing)}
    $maximumSegmentM=0.25
    $segments=[Math]::Max(2,[int][Math]::Min(2000,[int][Math]::Ceiling($length/$maximumSegmentM)))
    $generated=[System.Collections.Generic.List[object]]::new()
    $x=[double]$e.Start.X;$y=[double]$e.Start.Y;$heading=[double]$e.StartHeading
    $k0=if([Math]::Abs([double]$e.StartRadius) -lt 1e-12){0.0}else{-1.0/[double]$e.StartRadius}
    $k1=if([Math]::Abs([double]$e.EndRadius) -lt 1e-12){0.0}else{-1.0/[double]$e.EndRadius}
    $ds=$length/$segments;$generated.Add((New-Point2 $x $y))
    for($i=0;$i -lt $segments;$i++){
        $s=($i+0.5)*$ds;$a=$heading+$k0*$s+0.5*($k1-$k0)*$s*$s/$length
        $x+=$ds*[Math]::Cos($a);$y+=$ds*[Math]::Sin($a);$generated.Add((New-Point2 $x $y))
    }
    # Smoothly distribute the small endpoint residual so each segment remains at or below 0.25 m.
    $endDeltaX=[double]$e.End.X-[double]$generated[$generated.Count-1].X
    $endDeltaY=[double]$e.End.Y-[double]$generated[$generated.Count-1].Y
    for($i=1;$i -lt $generated.Count;$i++){
        $ratio=[double]$i/[double]$segments;$point=$generated[$i]
        $point.X=[double]$point.X+$ratio*$endDeltaX;$point.Y=[double]$point.Y+$ratio*$endDeltaY
    }
    $generated[$generated.Count-1]=Copy-Point2 $e.End
    $script:Diagnostics.Add(('DXF：缓和曲线 {0} 已按欧拉拟合模型生成 {1} 个加密折线顶点（最大步长 {2:F2} m，CAD 端点闭合）。' -f $e.Handle,$generated.Count,$maximumSegmentM))
    return @($generated)
}
function Add-DxfLwPolyline($lines,[string]$layer,$vertices) {
    $points=[System.Collections.Generic.List[object]]::new()
    if($null -ne $vertices){foreach($point in $vertices){if($null -ne $point){$points.Add($point)}}}
    if($points.Count -lt 2){return $false}
    [void]$lines.AddRange(@('0','LWPOLYLINE','100','AcDbEntity','8',$layer,'100','AcDbPolyline','90',([string]$points.Count),'70','0','43','0'))
    foreach($point in $points){
        [void]$lines.AddRange(@('10',(([double]$point.X).ToString('R',[cultureinfo]::InvariantCulture)),'20',(([double]$point.Y).ToString('R',[cultureinfo]::InvariantCulture))))
    }
    return $true
}
function Convert-DxfPoint($point) {
    return [pscustomobject]@{X=[double]$point.X;Y=[double]$point.Y}
}
function Invoke-StandardDxfWriter([string]$targetPath) {
    $writerPath=Join-Path $PSScriptRoot 'dxf_writer.py'
    if(-not (Test-Path -LiteralPath $writerPath)){throw ('缺少标准 DXF 写出器：{0}' -f $writerPath)}
    $outbound=[System.Collections.Generic.List[object]]::new()
    foreach($row in $script:Elements){
        $e=$row._Element
        $vertices=[System.Collections.Generic.List[object]]::new()
        if($e.Kind -eq '缓和曲线'){foreach($vertex in (Get-SpiralDxfVertices $e)){if($null -ne $vertex){$vertices.Add($vertex)}}}
        elseif($e.Kind -ne '直线' -and -not [bool]$e.IsGapFill){foreach($vertex in $e.Vertices){if($null -ne $vertex){$vertices.Add($vertex)}}}
        $outbound.Add([pscustomobject]@{
            Kind=[string]$e.Kind;Handle=[string]$e.Handle;IsGapFill=[bool]$e.IsGapFill
            Start=(Convert-DxfPoint $e.Start);End=(Convert-DxfPoint $e.End)
            Center=if($null -ne $e.Center){Convert-DxfPoint $e.Center}else{$null}
            Radius=[double]$e.Radius;Sweep=[double]$e.Sweep
            Vertices=@($vertices|ForEach-Object{Convert-DxfPoint $_})
        })
    }
    $payload=[pscustomobject]@{target_path=$targetPath;elements=@($outbound)}
    $json=$payload|ConvertTo-Json -Depth 12 -Compress
    $psi=[System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName='python';$psi.Arguments=('"{0}"' -f $writerPath);$psi.UseShellExecute=$false
    $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
    $process=[System.Diagnostics.Process]::new();$process.StartInfo=$psi
    if(-not $process.Start()){throw '无法启动标准 DXF 写出器。'}
    $process.StandardInput.Write($json);$process.StandardInput.Close()
    if(-not $process.WaitForExit(120000)){try{$process.Kill($true)}catch{};throw '标准 DXF 写出器超时（120 秒）。'}
    $stdout=$process.StandardOutput.ReadToEnd();$stderr=$process.StandardError.ReadToEnd()
    if($process.ExitCode -ne 0){throw ('标准 DXF 写出器失败：{0}' -f (($stderr+' '+$stdout).Trim()))}
    try{return ($stdout|ConvertFrom-Json)}catch{throw ('标准 DXF 写出器未返回有效结果：{0}' -f $stdout)}
}
function Export-Dxf([string]$targetPath) {
    if($script:Elements.Count -eq 0){throw '没有可导出的曲线要素。'}
    if([string]::IsNullOrWhiteSpace($targetPath)){
        $dialog=[Microsoft.Win32.SaveFileDialog]::new();$dialog.Filter='CAD 还原 DXF 图形 (*.dxf)|*.dxf';$dialog.FileName='道路曲线要素_CAD还原.dxf'
        if($dialog.ShowDialog() -ne $true){return};$targetPath=$dialog.FileName
    }
    $result=Invoke-StandardDxfWriter $targetPath
    $spiralCount=[int]$result.counts.spiral;$discreteCount=[int]$result.counts.discrete
    $StatusText.Text=('已导出标准 CAD 还原 DXF：{0}（缓和曲线拟合折线 {1} 条；离散曲线折线 {2} 条）。' -f $targetPath,$spiralCount,$discreteCount)
    Write-Progress ('DXF 导出完成：R2000 标准格式；缓和曲线已转换为 {0} 条拟合 LWPOLYLINE。' -f $spiralCount) $false
}

function Export-Excel([string]$targetPath) {
    if($script:Elements.Count -eq 0){throw '没有可导出的曲线要素。'}
    if([string]::IsNullOrWhiteSpace($targetPath)){
        $dialog=[Microsoft.Win32.SaveFileDialog]::new(); $dialog.Filter='测量员线元法 Excel (*.xlsx)|*.xlsx'; $dialog.FileName='测量员线元法.xlsx'
        if($dialog.ShowDialog() -ne $true){return}; $targetPath=$dialog.FileName
    }
    $excel=$null;$book=$null;$sheet=$null
    try {
        Write-Progress '正在生成测量员软件线元法 Excel（8 列、无表头）。' $false
        if(Test-Path -LiteralPath $targetPath){Remove-Item -LiteralPath $targetPath -Force}
        $excel=New-Object -ComObject Excel.Application;$excel.Visible=$false;$excel.DisplayAlerts=$false;$book=$excel.Workbooks.Add();$sheet=$book.Worksheets.Item(1);$sheet.Name='测量员线元法'
        $digits=[int]$script:SurveyorExportDigits;$r=1
        foreach($row in $script:Elements){$values=Get-SurveyorValues $row;for($c=0;$c -lt 8;$c++){$sheet.Cells.Item($r,$c+1)=$values[$c]};$r++}
        $sheet.Range('A:H').NumberFormat=('0.'+('0'*[int]$script:SurveyorExportDigits));$sheet.Columns.Item(5).NumberFormat='0.000000';$sheet.UsedRange.EntireColumn.AutoFit()|Out-Null;$book.SaveAs($targetPath,51);$StatusText.Text="已导出测量员线元法 Excel：$targetPath";Write-Progress ('已导出测量员线元法 Excel：{0} 行。' -f ($r-1)) $false
    } finally {if($sheet){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($sheet)};if($book){$book.Close($false);[void][Runtime.InteropServices.Marshal]::ReleaseComObject($book)};if($excel){$excel.Quit();[void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)};[GC]::Collect();[GC]::WaitForPendingFinalizers()}
}

[xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="道路曲线要素导入器" Height="760" Width="1280" MinHeight="650" MinWidth="700" FontFamily="Microsoft YaHei UI" FontSize="12" Background="#F3F6F9" WindowStartupLocation="CenterScreen" UseLayoutRounding="True" SnapsToDevicePixels="True">
<Grid x:Name="AppRoot" Margin="8" MinWidth="492"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*" MinHeight="245"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<Border Background="White" BorderBrush="#DCE5ED" BorderThickness="1" CornerRadius="9" Padding="9"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="250"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="道路曲线要素导入" FontSize="20" FontWeight="SemiBold" Foreground="#163B61"/><TextBlock Text="按 CAD 选择或读取当前显示图层；全过程仅读取几何，不修改、保存或关闭图形。" Foreground="#60717F" Margin="0,5,0,0" TextWrapping="Wrap"/></StackPanel><Border Grid.Column="1" Background="#F6FAFF" BorderBrush="#D4E6F7" BorderThickness="1" CornerRadius="6" Padding="9"><StackPanel><TextBlock Text="当前 CAD 连接" FontWeight="SemiBold" Foreground="#24567C"/><TextBlock x:Name="HostStatusText" Text="正在检测…" TextWrapping="Wrap" Margin="0,3,0,0" FontSize="12"/></StackPanel></Border></Grid></Border>
<Border Grid.Row="1" Margin="0,6,0,6" Background="White" BorderBrush="#DCE5ED" BorderThickness="1" CornerRadius="9" Padding="7"><Grid x:Name="ControlGrid"><Grid.ColumnDefinitions><ColumnDefinition Width="1.45*"/><ColumnDefinition Width="1.20*"/><ColumnDefinition Width="1.05*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
<GroupBox x:Name="StartSettingsGroup" Header="路线起算设置" Padding="9" Margin="0,0,9,0"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*" MinWidth="70"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*" MinWidth="70"/></Grid.ColumnDefinitions><TextBlock Text="计算精度 (mm)" VerticalAlignment="Center"/><TextBox x:Name="PrecisionBox" Grid.Column="1" Margin="7,0,12,0" MinWidth="58" Text="1"/><TextBlock Grid.Column="2" Text="线路前缀" VerticalAlignment="Center"/><TextBox x:Name="PrefixBox" Grid.Column="3" Margin="7,0,0,0" MinWidth="58" Text="K"/><TextBlock Grid.Row="1" Text="起算要素序号" VerticalAlignment="Center" Margin="0,9,0,0"/><TextBox x:Name="StartPositionBox" Grid.Row="1" Grid.Column="1" Margin="7,9,12,0" MinWidth="58" Text="1" ToolTip="按导入排序后的要素序号。"/><TextBlock Grid.Row="1" Grid.Column="2" Text="起算里程 (m)" VerticalAlignment="Center" Margin="0,9,0,0"/><TextBox x:Name="StartStationBox" Grid.Row="1" Grid.Column="3" Margin="7,9,0,0" MinWidth="58" Text="0.000"/><CheckBox x:Name="CoordinateSwapBox" Grid.Row="2" Grid.ColumnSpan="4" Content="CAD 坐标 XY 交换（仅表格/导出）" IsChecked="True" Margin="0,7,0,0" ToolTip="默认勾选：仅将道路要素表与测量员八列中的 CAD X/Y 显示顺序交换；示意图和 CAD 还原 DXF 保持原始方向。"/><CheckBox x:Name="CurveDirectionBox" Grid.Row="2" Grid.ColumnSpan="4" Content="曲线方向反向（左右符号取反）" IsChecked="False" Margin="250,7,0,0" ToolTip="默认不勾选。仅反向圆曲线、缓和曲线和离散曲线的左右方向；道路要素表、示意图和导出数据同步刷新。"/></Grid></GroupBox>
<GroupBox x:Name="SpecialLinesGroup" Grid.Column="1" Header="特殊线预处理" Padding="9" Margin="0,0,9,0"><StackPanel><CheckBox x:Name="DetectSpiralsBox" Content="识别并合并欧拉缓和曲线" IsChecked="True" ToolTip="仅高节点无 bulge 折线参与欧拉回旋线判定；不勾选时按原始折线逐段输入。"/><StackPanel x:Name="SpiralModePanel" Margin="18,6,0,0"><RadioButton x:Name="StrictSpiralRadio" Content="严格判定（固定 ≤ 0.5 mm）" IsChecked="True" ToolTip="固定的 0.5 mm 最大拟合残差验收，不可在界面或配置文件中修改。"/><RadioButton x:Name="LooseSpiralRadio" Content="宽松判定（默认 ≤ 2 mm）" Margin="0,4,0,0" ToolTip="阈值在界面中只读；默认 2 mm，修改同目录配置文件后重启生效。"/><StackPanel Orientation="Horizontal" Margin="0,5,0,0"><TextBlock Text="严格阈值" VerticalAlignment="Center"/><TextBox x:Name="StrictSpiralToleranceBox" Width="58" Margin="7,0,5,0" IsReadOnly="True" IsEnabled="False" Background="#E9EDF1" Foreground="#55636E"/><TextBlock Text="mm（固定）" VerticalAlignment="Center"/></StackPanel><StackPanel Orientation="Horizontal" Margin="0,4,0,0"><TextBlock Text="宽松阈值" VerticalAlignment="Center"/><TextBox x:Name="LooseSpiralToleranceBox" Width="58" Margin="7,0,5,0" IsReadOnly="True" IsEnabled="False" Background="#E9EDF1" Foreground="#55636E" ToolTip="修改 RoadCurveImporter.config.json 的 looseSpiralFitToleranceMm 后重启。"/><TextBlock Text="mm（配置）" VerticalAlignment="Center"/></StackPanel></StackPanel><TextBlock Text="未通过或未启用识别的高节点折线，均按原始顶点逐段保真输入；含直线与圆弧的复合多段线始终分离处理。" FontSize="10" Foreground="#6E7F8C" TextWrapping="Wrap" Margin="0,7,0,0"/><StackPanel Orientation="Horizontal" Margin="0,8,0,0"><TextBlock Text="端点连接容差 (mm)" VerticalAlignment="Center"/><TextBox x:Name="ConnectionToleranceBox" Width="60" Margin="7,0,0,0" IsReadOnly="True" IsEnabled="False" Background="#E9EDF1" Foreground="#55636E" ToolTip="只读；修改同目录 RoadCurveImporter.config.json 后重启。"/></StackPanel></StackPanel></GroupBox>
<GroupBox x:Name="HostGroup" Grid.Column="2" Header="CAD 主机" Padding="9" Margin="0,0,9,0"><StackPanel><ComboBox x:Name="HostSelector" SelectedIndex="0" MinWidth="150"><ComboBoxItem Content="自动检测（优先 ZWCAD）"/><ComboBoxItem Content="SouthMap / ZWCAD"/><ComboBoxItem Content="Autodesk AutoCAD"/></ComboBox><Button x:Name="RefreshHostButton" Content="刷新连接状态" Margin="0,8,0,0" HorizontalAlignment="Left" Padding="10,4"/></StackPanel></GroupBox>
<StackPanel x:Name="OperationPanel" Grid.Column="3" VerticalAlignment="Center" MinWidth="210"><Button x:Name="ImportButton" Content="读取 CAD 预选 / 选择" Padding="13,6" Background="#146ABD" Foreground="White" FontWeight="SemiBold"/><WrapPanel Margin="0,7,0,0"><Button x:Name="ReadButton" Content="读取显示图层" Padding="9,4" Margin="0,0,6,0"/><Button x:Name="ReverseRouteButton" Content="一键换向" Padding="9,4" Margin="0,0,6,0" IsEnabled="False" ToolTip="反转线路起终点、要素顺序、方位角和曲线左右方向；起算要素自动设为 1。"/><Button x:Name="ClearButton" Content="清除数据" Padding="9,4"/></WrapPanel><WrapPanel Margin="0,6,0,0"><Button x:Name="DxfButton" Content="导出 CAD 还原 DXF" Padding="9,4" Margin="0,0,6,0" ToolTip="始终输出 CAD 原始笛卡尔坐标和原始曲线方向；缓和曲线以折线导出。"/><Button x:Name="ExcelButton" Content="导出测量员 Excel" Padding="9,4" Margin="0,0,6,0"/><Button x:Name="RestoreDefaultsButton" Content="恢复默认值" Padding="9,4" ToolTip="恢复界面参数与同目录配置文件的默认值；不会修改 CAD 图形。"/></WrapPanel></StackPanel>
</Grid></Border>
<Grid x:Name="ContentGrid" Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="2.2*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition Height="*"/></Grid.RowDefinitions><Border x:Name="TablePanel" Background="White" BorderBrush="#DCE5ED" BorderThickness="1" CornerRadius="9" Padding="8"><DockPanel><Grid DockPanel.Dock="Top" Margin="2,0,2,7"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="道路要素表" FontWeight="SemiBold" FontSize="15" Foreground="#163B61"/><TextBlock Text="核验预览：末尾灰色列为自动识别/计算结果；固定八列 Excel 仍为 8 列无表头。表中全部方位角采用 dd.mmss（度分秒编码）。" FontSize="11" Foreground="#6E7F8C" Margin="0,2,0,0" TextWrapping="Wrap"/></StackPanel><CheckBox x:Name="SurveyorPreviewBox" Grid.Column="1" Content="查看测量员格式预览" VerticalAlignment="Center" ToolTip="勾选后显示含线型、dd.mmss 方位角和灰色终点核验列的扩展预览；Excel 导出仍为固定无表头八列，且第 5 列方位角同样采用 dd.mmss。"/></Grid><DataGrid x:Name="ElementGrid" AutoGenerateColumns="True" IsReadOnly="True" CanUserAddRows="False" GridLinesVisibility="Horizontal" AlternatingRowBackground="#F6FAFD" HeadersVisibility="Column" MinHeight="180" ScrollViewer.VerticalScrollBarVisibility="Auto" ScrollViewer.HorizontalScrollBarVisibility="Auto" EnableRowVirtualization="True" EnableColumnVirtualization="True" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling"/></DockPanel></Border>
<Border x:Name="PreviewPanel" Grid.Column="2" Background="White" BorderBrush="#DCE5ED" BorderThickness="1" CornerRadius="9" Padding="8"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*" MinHeight="150"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid Grid.Row="0" Margin="3"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="线路示意图" FontWeight="SemiBold" FontSize="15" Foreground="#163B61"/><TextBlock Text="绿色为起点，红色为终点，橙色虚线为端点容差填充；左键拖拽平移。" FontSize="10" Foreground="#6E7F8C" Margin="0,2,0,0" TextWrapping="Wrap"/></StackPanel><StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center"><TextBlock Text="滚轮缩放 25%–1000%" FontSize="10" Foreground="#6E7F8C" VerticalAlignment="Center" Margin="0,0,6,0"/><Button x:Name="ResetZoomButton" Content="复位视图" ToolTip="同时复位缩放比例和拖拽位置" Padding="7,3"/></StackPanel></Grid><Border Grid.Row="1" BorderBrush="#E3EAF0" BorderThickness="1" Margin="0,5,0,8"><Canvas x:Name="PreviewCanvas" Background="#FCFDFE" MinHeight="150" ClipToBounds="True" Cursor="Hand"/></Border><Border Grid.Row="2" Background="#FFF8DE" BorderBrush="#F1DF95" BorderThickness="1" Padding="8" MinHeight="142"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><TextBlock Text="运行诊断与工作进度" FontWeight="SemiBold" Foreground="#735A00" Margin="1,0,1,5"/><TextBox x:Name="DiagnosticText" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Height="48" Background="Transparent" BorderThickness="0" Foreground="#735A00" Padding="1"/><TextBox x:Name="ProgressBox" Grid.Row="2" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Height="62" Background="Transparent" BorderBrush="#E7D795" BorderThickness="1" Foreground="#36454F" Padding="6" Margin="0,6,0,0"/></Grid></Border></Grid></Border></Grid>
<TextBlock Grid.Row="3" x:Name="StatusText" VerticalAlignment="Center" Foreground="#51606C" Text="正在准备只读 CAD 连接。" Margin="3,6,3,0" TextWrapping="Wrap"/>
</Grid></Window>
'@
$reader=[System.Xml.XmlNodeReader]::new($xaml); $Window=[Windows.Markup.XamlReader]::Load($reader)
$AppRoot=$Window.FindName('AppRoot');$ControlGrid=$Window.FindName('ControlGrid');$ContentGrid=$Window.FindName('ContentGrid');$StartSettingsGroup=$Window.FindName('StartSettingsGroup');$CoordinateSwapBox=$Window.FindName('CoordinateSwapBox');$CurveDirectionBox=$Window.FindName('CurveDirectionBox');$SpecialLinesGroup=$Window.FindName('SpecialLinesGroup');$HostGroup=$Window.FindName('HostGroup');$OperationPanel=$Window.FindName('OperationPanel');$TablePanel=$Window.FindName('TablePanel');$PreviewPanel=$Window.FindName('PreviewPanel');$PrecisionBox=$Window.FindName('PrecisionBox');$PrefixBox=$Window.FindName('PrefixBox');$StartPositionBox=$Window.FindName('StartPositionBox');$StartStationBox=$Window.FindName('StartStationBox');$ConnectionToleranceBox=$Window.FindName('ConnectionToleranceBox');$DetectSpiralsBox=$Window.FindName('DetectSpiralsBox');$SpiralModePanel=$Window.FindName('SpiralModePanel');$StrictSpiralRadio=$Window.FindName('StrictSpiralRadio');$LooseSpiralRadio=$Window.FindName('LooseSpiralRadio');$StrictSpiralToleranceBox=$Window.FindName('StrictSpiralToleranceBox');$LooseSpiralToleranceBox=$Window.FindName('LooseSpiralToleranceBox');$HostSelector=$Window.FindName('HostSelector');$RefreshHostButton=$Window.FindName('RefreshHostButton');$HostStatusText=$Window.FindName('HostStatusText');$ImportButton=$Window.FindName('ImportButton');$ReadButton=$Window.FindName('ReadButton');$ClearButton=$Window.FindName('ClearButton');$DxfButton=$Window.FindName('DxfButton');$ExcelButton=$Window.FindName('ExcelButton');$RestoreDefaultsButton=$Window.FindName('RestoreDefaultsButton');$ReverseRouteButton=$Window.FindName('ReverseRouteButton');$ResetZoomButton=$Window.FindName('ResetZoomButton');$ElementGrid=$Window.FindName('ElementGrid');$SurveyorPreviewBox=$Window.FindName('SurveyorPreviewBox');$PreviewCanvas=$Window.FindName('PreviewCanvas');$DiagnosticText=$Window.FindName('DiagnosticText');$ProgressBox=$Window.FindName('ProgressBox');$StatusText=$Window.FindName('StatusText');
$script:AutoResultColumns=@('终点X坐标(m)','终点Y坐标(m)','终点方位角(dd.mmss)')
$ElementGrid.Add_AutoGeneratingColumn({
    param($sender,$eventArgs)
    if($eventArgs.PropertyName -like '_*'){$eventArgs.Cancel=$true;return}
    if($script:AutoResultColumns -contains [string]$eventArgs.PropertyName){
        $cellStyle=[System.Windows.Style]::new([System.Windows.Controls.DataGridCell]);$cellStyle.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::BackgroundProperty,[System.Windows.Media.Brushes]::Gainsboro));$cellStyle.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::ForegroundProperty,[System.Windows.Media.Brushes]::DimGray));$eventArgs.Column.CellStyle=$cellStyle
        $textStyle=[System.Windows.Style]::new([System.Windows.Controls.TextBlock]);$textStyle.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.TextBlock]::ForegroundProperty,[System.Windows.Media.Brushes]::DimGray));$eventArgs.Column.ElementStyle=$textStyle
    }
});$ElementGrid.ItemsSource=$script:Elements;$SurveyorPreviewBox.Add_Checked({Update-GridView});$SurveyorPreviewBox.Add_Unchecked({Update-GridView})
$script:ConnectionConfigPath=Join-Path $PSScriptRoot 'RoadCurveImporter.config.json'
$script:DefaultConfiguration=[ordered]@{endpointConnectionToleranceMm=1.0;looseSpiralFitToleranceMm=2.0;surveyorExportDigits=6;notes='endpointConnectionToleranceMm 为端点自动连接平面距离阈值（mm）；其中距离小于 0.1 mm 的端点视为直接相连，不另写填充线；looseSpiralFitToleranceMm 为宽松欧拉回旋线验收最大拟合偏差（mm，默认 2）；严格欧拉回旋线验收固定为 0.5 mm，不能修改；surveyorExportDigits 为测量员八列 Excel 小数位，必须不低于 6。修改本文件后重启程序生效。'}
$script:ConnectionToleranceM=0.001;$script:StrictSpiralToleranceM=0.0005;$script:LooseSpiralToleranceM=0.002;$script:SurveyorExportDigits=6;$script:SpiralFitterPath=Join-Path $PSScriptRoot 'spiral_fitter.py'
try {if(Test-Path $script:ConnectionConfigPath){$config=Get-Content -LiteralPath $script:ConnectionConfigPath -Raw|ConvertFrom-Json;$mm=[double]$config.endpointConnectionToleranceMm;if($mm -gt 0 -and $mm -le 1000){$script:ConnectionToleranceM=$mm/1000.0};$looseMm=[double]$config.looseSpiralFitToleranceMm;if($looseMm -ge 0.1 -and $looseMm -le 10){$script:LooseSpiralToleranceM=$looseMm/1000.0};$digits=[int]$config.surveyorExportDigits;if($digits -ge 6 -and $digits -le 12){$script:SurveyorExportDigits=$digits}}}catch{}
$ConnectionToleranceBox.Text=($script:ConnectionToleranceM*1000.0).ToString('0.###',[cultureinfo]::InvariantCulture)
$StrictSpiralToleranceBox.Text=($script:StrictSpiralToleranceM*1000.0).ToString('0.###',[cultureinfo]::InvariantCulture)
$LooseSpiralToleranceBox.Text=($script:LooseSpiralToleranceM*1000.0).ToString('0.###',[cultureinfo]::InvariantCulture)
function Set-ResponsiveGridPosition($control,[int]$row,[int]$column) {
    [System.Windows.Controls.Grid]::SetRow($control,$row);[System.Windows.Controls.Grid]::SetColumn($control,$column)
}

function Update-ResponsiveLayout {
    $width=[double]$Window.ActualWidth;if($width -lt 1){return}
    $mode=if($width -lt 820){'Narrow'}elseif($width -lt 1130){'Medium'}else{'Wide'}
    if($script:ResponsiveMode -eq $mode){return}
    $script:ResponsiveMode=$mode
    $ControlGrid.RowDefinitions.Clear();$ControlGrid.ColumnDefinitions.Clear();$ContentGrid.RowDefinitions.Clear();$ContentGrid.ColumnDefinitions.Clear()
    if($mode -eq 'Wide'){
        [void]$ControlGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]@{Width='1.45*'});[void]$ControlGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]@{Width='1.20*'});[void]$ControlGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]@{Width='1.05*'});[void]$ControlGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]@{Width='Auto'})
        Set-ResponsiveGridPosition $StartSettingsGroup 0 0;Set-ResponsiveGridPosition $SpecialLinesGroup 0 1;Set-ResponsiveGridPosition $HostGroup 0 2;Set-ResponsiveGridPosition $OperationPanel 0 3
        [void]$ContentGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]@{Width='2.2*'});[void]$ContentGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]@{Width='12'});[void]$ContentGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]@{Width='1*'})
        Set-ResponsiveGridPosition $TablePanel 0 0;Set-ResponsiveGridPosition $PreviewPanel 0 2
        $StartSettingsGroup.Margin=[System.Windows.Thickness]::new(0,0,9,0);$SpecialLinesGroup.Margin=[System.Windows.Thickness]::new(0,0,9,0);$HostGroup.Margin=[System.Windows.Thickness]::new(0,0,9,0);$OperationPanel.Margin=[System.Windows.Thickness]::new(0)
    } elseif($mode -eq 'Medium') {
        [void]$ControlGrid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]@{Height='Auto'});[void]$ControlGrid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]@{Height='Auto'})
        [void]$ControlGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]@{Width='1.25*'});[void]$ControlGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]@{Width='1*'});[void]$ControlGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]@{Width='Auto'})
        Set-ResponsiveGridPosition $StartSettingsGroup 0 0;Set-ResponsiveGridPosition $SpecialLinesGroup 0 1;Set-ResponsiveGridPosition $HostGroup 1 0;Set-ResponsiveGridPosition $OperationPanel 1 1
        [System.Windows.Controls.Grid]::SetColumnSpan($OperationPanel,2);[System.Windows.Controls.Grid]::SetColumnSpan($HostGroup,1)
        [void]$ContentGrid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]@{Height='*'});[void]$ContentGrid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]@{Height='Auto'})
        [void]$ContentGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]@{Width='*'})
        Set-ResponsiveGridPosition $TablePanel 0 0;Set-ResponsiveGridPosition $PreviewPanel 1 0
        $StartSettingsGroup.Margin=[System.Windows.Thickness]::new(0,0,9,7);$SpecialLinesGroup.Margin=[System.Windows.Thickness]::new(0,0,0,7);$HostGroup.Margin=[System.Windows.Thickness]::new(0,0,9,0);$OperationPanel.Margin=[System.Windows.Thickness]::new(0)
    } else {
        [void]$ControlGrid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]@{Height='Auto'});[void]$ControlGrid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]@{Height='Auto'});[void]$ControlGrid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]@{Height='Auto'});[void]$ControlGrid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]@{Height='Auto'})
        [void]$ControlGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]@{Width='*'})
        Set-ResponsiveGridPosition $StartSettingsGroup 0 0;Set-ResponsiveGridPosition $SpecialLinesGroup 1 0;Set-ResponsiveGridPosition $HostGroup 2 0;Set-ResponsiveGridPosition $OperationPanel 3 0
        [void]$ContentGrid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]@{Height='*'});[void]$ContentGrid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]@{Height='Auto'})
        [void]$ContentGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]@{Width='*'})
        Set-ResponsiveGridPosition $TablePanel 0 0;Set-ResponsiveGridPosition $PreviewPanel 1 0
        $StartSettingsGroup.Margin=[System.Windows.Thickness]::new(0,0,0,7);$SpecialLinesGroup.Margin=[System.Windows.Thickness]::new(0,0,0,7);$HostGroup.Margin=[System.Windows.Thickness]::new(0,0,0,7);$OperationPanel.Margin=[System.Windows.Thickness]::new(0)
    }
    [System.Windows.Controls.Grid]::SetRowSpan($TablePanel,1);[System.Windows.Controls.Grid]::SetColumnSpan($TablePanel,1);[System.Windows.Controls.Grid]::SetRowSpan($PreviewPanel,1);[System.Windows.Controls.Grid]::SetColumnSpan($PreviewPanel,1)
    $ControlGrid.UpdateLayout();$ContentGrid.UpdateLayout();Draw-Schematic
}

function Initialize-ResponsiveWindow {
    $work=[System.Windows.SystemParameters]::WorkArea
    $targetWidth=[Math]::Min(1280.0,[Math]::Max(520.0,$work.Width-20.0));$targetHeight=[Math]::Min(760.0,[Math]::Max(650.0,$work.Height-20.0))
    $Window.Width=$targetWidth;$Window.Height=$targetHeight;$script:ResponsiveMode=''
}

Update-HostStatus
function Write-Progress([string]$message,[bool]$clear){
    if($clear){$ProgressBox.Clear()}
    $ProgressBox.AppendText(('[{0:HH:mm:ss}] {1}{2}' -f (Get-Date),$message,[Environment]::NewLine))
    if($ProgressBox.Text.Length -gt $script:MaxProgressTextCharacters){$ProgressBox.Text=$ProgressBox.Text.Substring($ProgressBox.Text.Length-[int]($script:MaxProgressTextCharacters*0.72))}
    $ProgressBox.ScrollToEnd();$ProgressBox.UpdateLayout()
}

function Pump-UiEvents {
    try {
        $frame=[System.Windows.Threading.DispatcherFrame]::new()
        [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background,[System.Windows.Threading.DispatcherOperationCallback]{param($state)$state.Continue=$false;return $null},$frame)
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    } catch {}
}
function Clear-ImportedData([bool]$confirm) {
    if($confirm -and $script:Elements.Count -gt 0){$choice=[System.Windows.MessageBox]::Show('将清除当前表格、示意图和工作进度中的导入结果。CAD 图形不会被修改。是否继续？','清除数据',[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Question);if($choice -ne [System.Windows.MessageBoxResult]::Yes){return}}
    $script:Elements.Clear();$script:SurveyorRows.Clear();$ReverseRouteButton.IsEnabled=$false;Update-GridView;$script:Diagnostics.Clear();Draw-Schematic;$DiagnosticText.Text='已清除读取数据。';Write-Progress '已清除读取数据；CAD 图形未被修改。' $true;$StatusText.Text='已清除当前道路要素；可重新导入。'
}

function Get-VisibleLayerNames($doc) {
    $visible=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach($layer in $doc.Layers){
        try {
            $layerOn=[bool]$layer.LayerOn; $frozen=[bool]$layer.Freeze; $vpFrozen=$false
            try {$vpFrozen=[bool]$layer.VPFreeze}catch{}
            if($layerOn -and -not $frozen -and -not $vpFrozen){[void]$visible.Add([string]$layer.Name)}
        } catch {}
    }
    return ,$visible
}
function Test-SupportedRoadEntity($entity) { try { return ([string]$entity.ObjectName -match '^(AcDbLine|Line)$|Arc$|Polyline$') } catch { return $false } }
function Convert-AndAddEntity($entity,$raw,[int]$ordinal,[string]$mode) {
    try {
        $name=[string]$entity.ObjectName; $handle=[string]$entity.Handle; $parts=@(Convert-CadEntity $entity)
        foreach($part in $parts){if($null -ne $part){$raw.Add($part)}}
    } catch { $script:Diagnostics.Add(("跳过{0}实体 #{1}：{2}" -f $mode,$ordinal,$_.Exception.Message)) }
}
function Write-RuntimeFailureLog([string]$stage,$errorRecord,[int]$cadCount,[int]$rawCount) {
    try {$entry=('[{0:yyyy-MM-dd HH:mm:ss}] 阶段={1}; CAD实体={2}; 道路段={3}; 错误={4}{5}' -f (Get-Date),$stage,$cadCount,$rawCount,$errorRecord.Exception.Message,[Environment]::NewLine);[System.IO.File]::AppendAllText($script:RuntimeLogPath,$entry,[System.Text.UTF8Encoding]::new($false))}catch{}
}
function Run-Import([bool]$selectOnScreen) {
    $ImportButton.IsEnabled=$false;$ReadButton.IsEnabled=$false
    # Keep catch/finally paths safe even if CAD connection or settings validation fails early.
    $cadCount=0;$raw=[System.Collections.Generic.List[object]]::new();$stage='初始化'
    try {
        $script:CurrentSettings=Get-CurrentSettings; $script:SpiralFitAttemptCount=0; $script:PreviewRenderNotice=''; $script:Diagnostics.Clear();$coordinateMode=if([bool]$script:CurrentSettings.SwapCadXY){'已启用 CAD XY 交换（测绘 X=北、Y=东）'}else{'未启用 CAD XY 交换（保留 CAD X/Y）'};$script:Diagnostics.Add($coordinateMode); Write-Progress ('开始导入。{0}；端点自动连接容差：{1:0.###} mm（配置文件只读）。' -f $coordinateMode,($script:ConnectionToleranceM*1000.0)) $true; $stage='连接 CAD';$cad=Get-RunningCadApplication; $app=$cad.Application; $doc=$app.ActiveDocument
        $stage='读取 CAD 实体'
        if($selectOnScreen){
            if($cad.Name -eq 'Autodesk AutoCAD'){
                $set=$doc.PickfirstSelectionSet; $selected=[int]$set.Count
                if($selected -le 0){throw 'AutoCAD 未检测到预选对象。请先在 AutoCAD 中窗口/框选所需 LINE、ARC 或多段线，再切回本程序点击“读取 CAD 预选”。程序不会向 AutoCAD 发送选择命令。'}
                Write-Progress ("AutoCAD 预选读取：$selected 个实体，开始只读转换。") $false
                for($i=0;$i -lt $selected;$i++){$entity=$set.Item($i);$cadCount++;Convert-AndAddEntity $entity $raw $cadCount 'AutoCAD 预选集';if(($cadCount % 50) -eq 0 -or $cadCount -eq $selected){Write-Progress ("已读取 $cadCount/$selected 个 AutoCAD 预选实体，当前生成 $($raw.Count) 个道路段。") $false;Pump-UiEvents};if($raw.Count -gt $script:MaxCandidateSegments){throw "候选道路段超过安全上限 $($script:MaxCandidateSegments)，请减少预选范围。"}}
            } else {
                $choice=[System.Windows.MessageBox]::Show(('请确认已打开 {0} 图形。单击“确定”后程序会最小化，并在 CAD 中点选或框选多段线、直线和圆弧；完成后请按 Enter。\n\n导入过程只读取实体，不会修改或保存图形。' -f $cad.Name),('CAD 导入 - {0}' -f $cad.Name),[System.Windows.MessageBoxButton]::OKCancel,[System.Windows.MessageBoxImage]::Information)
                if($choice -ne [System.Windows.MessageBoxResult]::OK){return}
                $sets=$doc.SelectionSets; $setName='RDCURVE_'+([Guid]::NewGuid().ToString('N').Substring(0,8)); $set=$null
                try {$set=$sets.Add($setName);$Window.WindowState='Minimized';Start-Sleep -Milliseconds 350;$set.SelectOnScreen();$selected=[int]$set.Count;Write-Progress ("ZWCAD 选择完成：$selected 个实体，开始读取。") $false;for($i=0;$i -lt $selected;$i++){$entity=$set.Item($i);$cadCount++;Convert-AndAddEntity $entity $raw $cadCount 'ZWCAD 选择集';if(($cadCount % 50) -eq 0 -or $cadCount -eq $selected){Write-Progress ("已读取 $cadCount/$selected 个选择实体，当前生成 $($raw.Count) 个道路段。") $false;Pump-UiEvents};if($raw.Count -gt $script:MaxCandidateSegments){throw "候选道路段超过安全上限 $($script:MaxCandidateSegments)，请减少框选范围。"}}} finally {if($set){try{$set.Delete()}catch{}};$Window.WindowState='Normal'}
            }
        } else {
            $visible=Get-VisibleLayerNames $doc; $hidden=0; $other=0; $StatusText.Text=('正在读取当前显示图层（{0} 个可见图层）…' -f $visible.Count); $StatusText.UpdateLayout(); Write-Progress ('阶段 1/3：扫描当前显示图层，共 {0} 个可见图层。' -f $visible.Count) $false
            foreach($entity in $doc.ModelSpace){
                $layerName='';try{$layerName=[string]$entity.Layer}catch{}
                if(-not $visible.Contains($layerName)){$hidden++;continue}
                if(-not (Test-SupportedRoadEntity $entity)){$other++;continue}
                $cadCount++;Convert-AndAddEntity $entity $raw $cadCount '可见图层'
                if(($cadCount % 50) -eq 0){$StatusText.Text="正在读取当前显示图层：已检查 $cadCount 个候选线元…";$StatusText.UpdateLayout();Write-Progress ("阶段 1/3：已读取 $cadCount 个候选线元，生成 $($raw.Count) 个道路段。") $false;Pump-UiEvents}
                if($raw.Count -gt $script:MaxCandidateSegments){throw ('当前显示图层中候选道路段超过安全上限 {0}。为避免卡死已停止；请关闭不相关图层后重试，或改用“从 CAD 点选/框选”。' -f $script:MaxCandidateSegments)}
            }
            $script:Diagnostics.Add(("模型空间过滤：仅当前显示图层；已跳过 $hidden 个隐藏/冻结图层实体及 $other 个其他类型实体。"))
        }
        if($cadCount -eq 0){throw '未发现可导入的 LINE、ARC 或 LWPOLYLINE 实体。'}
        if($raw.Count -eq 0){throw '没有生成有效道路段。'}
        $stage='连接排序';Write-Progress ("阶段 2/3：按 1 mm 平面端点容差执行连接排序（$($raw.Count) 个道路段）。") $false; $ordered=Order-Elements @($raw) $script:ConnectionToleranceM; $stage='生成表格与示意图';Write-Progress ("阶段 3/3：生成表格与线路示意图（$($ordered.Count) 个要素）。") $false; Publish-Elements $ordered; $ReverseRouteButton.IsEnabled=($script:Elements.Count -gt 0); Reset-PreviewZoom
        $DiagnosticText.Text=if($script:Diagnostics.Count -or -not [string]::IsNullOrWhiteSpace($script:PreviewRenderNotice)){(@($script:Diagnostics)+@($script:PreviewRenderNotice)|Where-Object{$_}) -join [Environment]::NewLine}else{'未发现几何诊断。'}
        $StatusText.Text=('已从 {0} 导入 {1} 个可读取 CAD 实体，生成 {2} 个道路要素。' -f $doc.Name,$cadCount,$script:Elements.Count); Write-Progress ('完成：{0} 个 CAD 实体，{1} 个道路要素。' -f $cadCount,$script:Elements.Count) $false
    } catch {
        $StatusText.Text='导入失败。'; Write-RuntimeFailureLog $stage $_ $cadCount $raw.Count; Write-Progress ('失败（阶段：{0}）：{1}。已写入运行诊断日志。' -f $stage,$_.Exception.Message) $false; if($SelfTest -or $SpiralModeSelfTest -or $SurveyorPreviewSelfTest){throw}; [System.Windows.MessageBox]::Show($_.Exception.Message,'CAD 导入错误',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Warning)|Out-Null
    } finally {Stop-SpiralFitServer;$ImportButton.IsEnabled=$true;$ReadButton.IsEnabled=$true}
}
function Reverse-PublishedRoute {
    if($script:Elements.Count -eq 0){return}
    $reversed=[System.Collections.Generic.List[object]]::new();for($i=$script:Elements.Count-1;$i -ge 0;$i--){$reversed.Add((Reverse-Element $script:Elements[$i]._Element))}
    $StartPositionBox.Text='1';Publish-Elements @($reversed);$script:Diagnostics.Add('已执行一键换向：起点、终点、线元顺序、测绘方位角及曲线左右方向均已同步反转；起算要素已设为 1。');$DiagnosticText.Text=$script:Diagnostics -join [Environment]::NewLine;Reset-PreviewZoom;$StatusText.Text='已一键换向；当前绿色标记为新起点、红色标记为新终点。';Write-Progress '已一键换向并重新计算桩号与测量员线元法数据。' $false
}

function Update-SpiralModeUi {
    $enabled=[bool]$DetectSpiralsBox.IsChecked;$SpiralModePanel.IsEnabled=$enabled
}
function Write-DefaultConfiguration {
    $json=($script:DefaultConfiguration|ConvertTo-Json -Depth 3);$encoding=[System.Text.UTF8Encoding]::new($false);$tempPath=$script:ConnectionConfigPath+'.next';[System.IO.File]::WriteAllText($tempPath,$json,$encoding);Move-Item -LiteralPath $tempPath -Destination $script:ConnectionConfigPath -Force
}
function Restore-DefaultValues {
    $choice=[System.Windows.MessageBox]::Show('将恢复界面起算参数、缓和曲线判定设置、缩放状态和同目录配置文件中的默认值；当前读取结果会被清除。不会修改、保存或关闭 CAD 图形。是否继续？','恢复默认值',[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Warning);if($choice -ne [System.Windows.MessageBoxResult]::Yes){return}
    try {
        Write-DefaultConfiguration;$script:ConnectionToleranceM=0.001;$script:StrictSpiralToleranceM=0.0005;$script:LooseSpiralToleranceM=0.002;$script:SurveyorExportDigits=6
        $PrecisionBox.Text='1';$PrefixBox.Text='K';$StartPositionBox.Text='1';$StartStationBox.Text='0.000';$CoordinateSwapBox.IsChecked=$true;$CurveDirectionBox.IsChecked=$false;$HostSelector.SelectedIndex=0;$DetectSpiralsBox.IsChecked=$true;$StrictSpiralRadio.IsChecked=$true;$ConnectionToleranceBox.Text='1';$StrictSpiralToleranceBox.Text='0.5';$LooseSpiralToleranceBox.Text='2';$SurveyorPreviewBox.IsChecked=$false;Update-SpiralModeUi;Clear-ImportedData $false;Reset-PreviewZoom;$DiagnosticText.Text='已恢复默认界面与配置：严格欧拉回旋线验收固定 0.5 mm；宽松验收默认 2 mm。';$StatusText.Text='已恢复默认值；CAD 图形未被修改。';Write-Progress '已恢复默认值并重写 RoadCurveImporter.config.json。' $true
    } catch {[System.Windows.MessageBox]::Show(('恢复默认值失败：{0}' -f $_.Exception.Message),'恢复默认值',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Warning)|Out-Null}
}

Initialize-ResponsiveWindow;Update-SpiralModeUi;$Window.Add_SizeChanged({Update-ResponsiveLayout});$DetectSpiralsBox.Add_Checked({Update-SpiralModeUi});$DetectSpiralsBox.Add_Unchecked({Update-SpiralModeUi});$RefreshHostButton.Add_Click({Update-HostStatus});$HostSelector.Add_SelectionChanged({Update-HostStatus});$ImportButton.Add_Click({Run-Import $true}); $ReadButton.Add_Click({Run-Import $false}); $ReverseRouteButton.Add_Click({Reverse-PublishedRoute}); $ClearButton.Add_Click({Clear-ImportedData $true}); $DxfButton.Add_Click({try{Export-Dxf}catch{[System.Windows.MessageBox]::Show($_.Exception.Message,'导出 DXF')|Out-Null}}); $ExcelButton.Add_Click({try{Export-Excel}catch{[System.Windows.MessageBox]::Show($_.Exception.Message,'导出 Excel')|Out-Null}}); $ResetZoomButton.Add_Click({Reset-PreviewZoom}); $RestoreDefaultsButton.Add_Click({Restore-DefaultValues}); $PreviewCanvas.Add_SizeChanged({Draw-Schematic});$PreviewCanvas.Add_MouseWheel({param($sender,$eventArgs) Zoom-Preview $eventArgs});$PreviewCanvas.Add_MouseLeftButtonDown({param($sender,$eventArgs) Start-PreviewPan $eventArgs});$PreviewCanvas.Add_MouseMove({param($sender,$eventArgs) Move-PreviewPan $eventArgs});$PreviewCanvas.Add_MouseLeftButtonUp({param($sender,$eventArgs) End-PreviewPan $eventArgs});$PreviewCanvas.Add_MouseLeave({param($sender,$eventArgs) End-PreviewPan $eventArgs});$CoordinateSwapBox.Add_Checked({Refresh-DisplayOptions});$CoordinateSwapBox.Add_Unchecked({Refresh-DisplayOptions});$CurveDirectionBox.Add_Checked({Refresh-DisplayOptions});$CurveDirectionBox.Add_Unchecked({Refresh-DisplayOptions})

if($CoordinateSwapSelfTest){
    try {
        $script:CurrentSettings=[pscustomobject]@{ToleranceM=0.001;PrecisionMm=1.0;Digits=3;Prefix='K';StartPosition=1;StartStation=0.0;SpiralMode='Off';SpiralFitToleranceM=0.0005;SwapCadXY=$true;ReverseCurveDirection=$false}
        $raw=Convert-PointArray @(100.0,200.0,100.0,300.0);$out=Get-OutputPoint $raw[0];if($out.X -ne 200.0 -or $out.Y -ne 100.0){throw 'CAD XY 输出坐标顺序自测失败。'}
        $line=New-LineElement $raw[0] $raw[1] 'XY_TEST' '内置测试' 0;$packed=Get-SurveyorDmsNumber (To-SurveyAzimuth (Get-DisplayHeading $line $true));if([Math]::Abs($packed-0.0) -gt 1e-10){throw ('CAD XY 交换不应改变方位角：实际 {0}。' -f $packed)}
        $script:CurrentSettings.SwapCadXY=$false;$unSwapped=Get-OutputPoint $raw[0];if($unSwapped.X -ne 100.0 -or $unSwapped.Y -ne 200.0){throw '关闭 CAD XY 交换自测失败。'}
        $script:CurrentSettings.SwapCadXY=$true;Write-Output 'COORDINATE_SWAP_SELFTEST_OK:DisplayOnly=True:CAD(100,200)->Output(200,100):AzimuthUnchanged=0.000000'
    } catch {Write-Error $_;exit 1}
} elseif($CurveDirectionSelfTest){
    try {
        $script:CurrentSettings=[pscustomobject]@{ToleranceM=0.001;PrecisionMm=1.0;Digits=3;Prefix='K';StartPosition=1;StartStation=0.0;SpiralMode='Off';SpiralFitToleranceM=0.0005;SwapCadXY=$false;ReverseCurveDirection=$false}
        $arc=New-ArcElement (New-Point2 1 0) (New-Point2 0 1) (New-Point2 0 0) 1.0 ([Math]::PI/2.0) 'ARC_TEST' '内置测试' 0;$originalRadius=Get-DisplayRadius $arc $arc.StartRadius;$originalHeading=Get-DisplayHeading $arc $true
        $script:CurrentSettings.ReverseCurveDirection=$true;$flippedRadius=Get-DisplayRadius $arc $arc.StartRadius;$flippedHeading=Get-DisplayHeading $arc $true;$flippedSweep=Get-DisplaySweep $arc;$flippedCenter=Get-CurveDisplayPoint $arc $arc.Center
        if($originalRadius -ge 0 -or $flippedRadius -le 0 -or [Math]::Abs($flippedSweep+[Math]::PI/2.0) -gt 1e-12 -or [Math]::Abs($flippedCenter.X-1.0) -gt 1e-12 -or [Math]::Abs($flippedCenter.Y-1.0) -gt 1e-12 -or [Math]::Abs($flippedHeading-$originalHeading) -lt 1e-12){throw '曲线方向反向自测失败。'}
        Write-Output 'CURVE_DIRECTION_SELFTEST_OK:Default=False:RadiusNegativeToPositive:SweepReversed:PreviewGeometryReflected'
    } catch {Write-Error $_;exit 1}
  } elseif($PerformanceSelfTest){
    try {
        $script:CurrentSettings=[pscustomobject]@{ToleranceM=0.001;PrecisionMm=1.0;Digits=3;Prefix='K';StartPosition=1;StartStation=0.0;SpiralMode='Strict';SpiralFitToleranceM=0.0005;SwapCadXY=$true;ReverseCurveDirection=$false};$script:Diagnostics.Clear();$script:SpiralFitAttemptCount=0
        $points=[System.Collections.Generic.List[object]]::new();for($i=0;$i -lt ($script:MaxSpiralFitVertices+1);$i++){$points.Add((New-Point2 ([double]$i) ([Math]::Sin($i/50.0))))}
        $watch=[System.Diagnostics.Stopwatch]::StartNew();$candidate=Get-SpiralCandidate $points;$watch.Stop()
        if($null -ne $candidate -or $script:SpiralFitAttemptCount -ne 0 -or -not (($script:Diagnostics -join '|') -match '超过单段欧拉拟合性能上限') -or $watch.Elapsed.TotalSeconds -gt 1.5){throw '大顶点回旋线性能保护自测失败。'}
        Write-Output ('PERFORMANCE_SELFTEST_OK:OversizeVertices={0}:FitAttempts=0:ElapsedMs={1}' -f $points.Count,$watch.ElapsedMilliseconds)
    } catch {Write-Error $_;exit 1}
} elseif($DxfCadRestoreSelfTest){
    $dxfPath=Join-Path $PSScriptRoot 'selftest_cad_restore.dxf'
    try {
        $script:CurrentSettings=[pscustomobject]@{ToleranceM=0.001;PrecisionMm=1.0;Digits=3;Prefix='K';StartPosition=1;StartStation=0.0;SpiralMode='Off';SpiralFitToleranceM=0.0005;SwapCadXY=$true;ReverseCurveDirection=$true}
        $line=New-LineElement (New-Point2 101.0 202.0) (New-Point2 151.0 252.0) 'DXF_LINE' '内置测试' 0
        $arc=New-ArcElement (New-Point2 310.0 400.0) (New-Point2 300.0 410.0) (New-Point2 300.0 400.0) 10.0 ([Math]::PI/2.0) 'DXF_ARC' '内置测试' 0
        $vertices=[System.Collections.Generic.List[object]]::new();[void]$vertices.Add((New-Point2 500.0 600.0));[void]$vertices.Add((New-Point2 510.0 608.0));[void]$vertices.Add((New-Point2 523.0 613.0));[void]$vertices.Add((New-Point2 538.0 615.0))
        $spiral=[pscustomobject]@{Kind='缓和曲线';Start=$vertices[0];End=$vertices[$vertices.Count-1];Center=$null;Radius=$null;StartRadius=-1000.0;EndRadius=-500.0;Sweep=0.0;Length=40.0;StartHeading=0.0;EndHeading=0.0;Handle='DXF_SPIRAL';Source='内置测试';Segment=0;Vertices=$vertices;IsGapFill=$false}
        $script:Elements.Clear();$script:Elements.Add([pscustomobject]@{_Element=$line})|Out-Null;$script:Elements.Add([pscustomobject]@{_Element=$arc})|Out-Null;$script:Elements.Add([pscustomobject]@{_Element=$spiral})|Out-Null
        Export-Dxf $dxfPath
        $validatorPath=Join-Path $PSScriptRoot 'validate_dxf_ezdxf.py'
        $validationLines=& python $validatorPath $dxfPath
        if($LASTEXITCODE -ne 0){throw ('标准 DXF 解析器拒绝自测文件：{0}' -f ($validationLines -join ' '))}
        $validation=(($validationLines -join [Environment]::NewLine)|ConvertFrom-Json)
        if(-not [bool]$validation.valid){throw '标准 DXF 解析器报告自测文件无效。'}
        if([string]$validation.dxfversion -ne 'AC1015'){throw ('自测 DXF 版本错误：{0}' -f $validation.dxfversion)}
        if([int]$validation.entity_counts.LINE -ne 1 -or [int]$validation.entity_counts.ARC -ne 1 -or [int]$validation.entity_counts.LWPOLYLINE -ne 1){throw 'CAD 还原 DXF 实体计数错误。'}
        if([int]$validation.spiral_polyline_count -ne 1 -or [string]$validation.spiral_polylines[0].entity_type -ne 'LWPOLYLINE' -or [int]$validation.spiral_polylines[0].vertices -ne 161){throw '缓和曲线未按拟合模型导出为 161 顶点开放 LWPOLYLINE。'}
        Write-Output 'DXF_CAD_RESTORE_SELFTEST_OK:LINE=NativeXY:ARC=NativeXY:SPIRAL=FittedLWPOLYLINE(161 vertices):AC1015:DisplayOptionsIgnored'
    } catch {Write-Error $_;exit 1}
} elseif($SurveyorPreviewSelfTest){
    try {
        $example=(Format-SurveyorDms 46.911323);if($example -ne '46.544076'){throw ('dd.mmss 换算自测失败：46.911323° 实际为 {0}。' -f $example)}
        $exampleValue=Get-SurveyorDmsNumber 46.911323;if([Math]::Abs($exampleValue-46.544076) -gt 1e-10){throw ('dd.mmss 数值编码自测失败：实际为 {0}。' -f $exampleValue)}
        $decoded=Convert-SurveyorDmsToDegrees $exampleValue;if([Math]::Abs($decoded-46.911323) -gt 0.0000015){throw ('dd.mmss 反解自测失败：实际为 {0}°。' -f $decoded)}
        $nearCarry=(Format-SurveyorDms 359.999999);if($nearCarry -ne '0.000000'){throw ('dd.mmss 进位自测失败：359.999999° 实际为 {0}。' -f $nearCarry)}
        $script:CurrentSettings=[pscustomobject]@{ToleranceM=0.001;PrecisionMm=1.0;Digits=3;Prefix='K';StartPosition=1;StartStation=0.0;SpiralMode='Strict';SpiralFitToleranceM=0.0005;SwapCadXY=$true;ReverseCurveDirection=$false};Run-Import $false
        if($script:SurveyorRows.Count -ne $script:Elements.Count){throw '核验预览行数与道路要素行数不一致。'}
        $preview=$script:SurveyorRows[0];$properties=@($preview.PSObject.Properties.Name);$expected=@('线型','起始里程(m)','结束里程(m)','起始方位角(dd.mmss)','起始X坐标(m)','起始Y坐标(m)','开始半径(m；左负右正)','结束半径(m；左负右正)','终点X坐标(m)','终点Y坐标(m)','终点方位角(dd.mmss)');if(($properties -join '|') -ne ($expected -join '|')){throw '核验预览列顺序不符合要求。'}
        $Window.ShowInTaskbar=$false;$Window.Left=-10000;$Window.Top=-10000;$Window.Show()|Out-Null;$SurveyorPreviewBox.IsChecked=$true;Update-GridView;$ElementGrid.UpdateLayout();Start-Sleep -Milliseconds 120;$greyColumns=@($ElementGrid.Columns|Where-Object{$script:AutoResultColumns -contains [string]$_.Header});if($greyColumns.Count -ne 3 -or @($greyColumns|Where-Object{$null -eq $_.CellStyle -or $null -eq $_.ElementStyle}).Count -ne 0){$headers=@($ElementGrid.Columns|ForEach-Object{[string]$_.Header}) -join '|';throw ('终点自动核验列未完整应用灰显样式。当前列：{0}' -f $headers)};$Window.Close()
        $survey=$null;$row=$script:Elements[0];$survey=Get-SurveyorValues $row;$expectedPacked=Get-SurveyorDmsNumber (To-SurveyAzimuth (Get-DisplayHeading $row._Element $true));if($survey.Count -ne 8 -or [Math]::Abs([double]$survey[4]-$expectedPacked) -gt 1e-10){throw '固定八列导出的 dd.mmss 方位角未与预览统一。'};$main=$script:Elements[0];if([Math]::Abs([double]$main.'起点方位角(dd.mmss)'-$expectedPacked) -gt 1e-10){throw '道路要素表起点方位角未使用 dd.mmss。'}
        Write-Output ('SURVEYOR_PREVIEW_SELFTEST_OK:Rows={0}:Columns={1}:GreyColumns={2}:Dms={3}:ExportColumns={4}:ExportAzimuth={5:F6}' -f $script:SurveyorRows.Count,$properties.Count,$greyColumns.Count,$example,$survey.Count,$expectedPacked)
    } catch {Write-Error $_;exit 1}
} elseif($DefaultConfigurationSelfTest){
    $originalConfig=$null;if(Test-Path -LiteralPath $script:ConnectionConfigPath){$originalConfig=[System.IO.File]::ReadAllBytes($script:ConnectionConfigPath)}
    try {Write-DefaultConfiguration;$check=Get-Content -LiteralPath $script:ConnectionConfigPath -Raw|ConvertFrom-Json;if([double]$check.endpointConnectionToleranceMm -ne 1.0 -or [double]$check.looseSpiralFitToleranceMm -ne 2.0 -or [int]$check.surveyorExportDigits -ne 6){throw '默认配置内容校验失败。'};if($check.PSObject.Properties.Name -contains 'strictSpiralFitToleranceMm'){throw '默认配置不应写入可修改的严格阈值。'};Write-Output 'DEFAULT_CONFIGURATION_SELFTEST_OK'} catch {Write-Error $_;exit 1} finally {if($null -ne $originalConfig){[System.IO.File]::WriteAllBytes($script:ConnectionConfigPath,$originalConfig)}else{Remove-Item -LiteralPath $script:ConnectionConfigPath -Force -ErrorAction SilentlyContinue}}
} elseif($LayoutSelfTest){
    try {
        $Window.ShowInTaskbar=$false;$Window.WindowState='Normal';$Window.Left=-10000;$Window.Top=-10000;$Window.Show()|Out-Null
        $layoutCases=@(@(640,640,'Narrow'),@(960,700,'Medium'),@(1440,900,'Wide'))
        foreach($case in $layoutCases){$Window.Width=[double]$case[0];$Window.Height=[double]$case[1];$Window.UpdateLayout();Start-Sleep -Milliseconds 120;Update-ResponsiveLayout;if($script:ResponsiveMode -ne [string]$case[2]){throw ('布局自测失败：{0}×{1} 未进入 {2} 模式，实际为 {3}。' -f $case[0],$case[1],$case[2],$script:ResponsiveMode)}}
        Write-Output 'LAYOUT_SELFTEST_OK:Narrow,Medium,Wide';$Window.Close()
    } catch {Write-Error $_;try{$Window.Close()}catch{};exit 1}
} elseif($SpiralModeSelfTest){
    try {
        $DetectSpiralsBox.IsChecked=$true;$StrictSpiralRadio.IsChecked=$true;$LooseSpiralRadio.IsChecked=$false;Run-Import $false;$strictCount=$script:Elements.Count
        $LooseSpiralRadio.IsChecked=$true;Run-Import $false;$looseCount=$script:Elements.Count;if($looseCount -gt $strictCount){throw ('宽松判定自测失败：宽松结果 {0} 不应多于严格结果 {1}。' -f $looseCount,$strictCount)}
        $DetectSpiralsBox.IsChecked=$false;Run-Import $false;$offCount=$script:Elements.Count;if($offCount -lt $strictCount){throw ('关闭识别自测失败：关闭结果 {0} 不应少于严格结果 {1}。' -f $offCount,$strictCount)}
        $mock=[pscustomobject]@{ObjectName='AcDbPolyline';Handle='COMPOSITE_TEST';Coordinates=@(0.0,0.0,10.0,0.0,20.0,0.0);Closed=$false};$mock|Add-Member -MemberType ScriptMethod -Name GetBulge -Value {param($index) if($index -eq 1){return [Math]::Tan([Math]::PI/8.0)};return 0.0};$composite=@(Convert-CadEntity $mock);if($composite.Count -ne 2 -or $composite[0].Kind -ne '直线' -or $composite[1].Kind -ne '圆曲线'){throw '复合多段线分离自测失败：未得到一条直线和一条圆曲线。'}
        Write-Output ('SPIRAL_MODE_SELFTEST_OK:Strict={0}:Loose={1}:Off={2}:Composite=Line+Arc' -f $strictCount,$looseCount,$offCount)
    } catch {Write-Error $_;exit 1}
} elseif($SelfTest){
    $selfTestLog=Join-Path $PSScriptRoot 'selftest_result.json'
    try {
        $script:CurrentSettings=[pscustomobject]@{ToleranceM=0.001;PrecisionMm=1.0;Digits=3;Prefix='K';StartPosition=1;StartStation=0.0;SpiralMode='Strict';SpiralFitToleranceM=0.0005;SwapCadXY=$true;ReverseCurveDirection=$false}
        Run-Import $false
        $gapA=New-LineElement (New-Point2 0.0 0.0) (New-Point2 10.0 0.0) 'TEST_A' '内置测试' 0
        $gapB=New-LineElement (New-Point2 10.0005 0.0) (New-Point2 20.0 0.0) 'TEST_B' '内置测试' 0
        $gapRoute=@(Order-Elements @($gapA,$gapB) $script:ConnectionToleranceM)
        if($gapRoute.Count -ne 3 -or -not [bool]$gapRoute[1].IsGapFill -or [string]::IsNullOrWhiteSpace([string]$gapRoute[1].Note)){throw '端点容差填充自测失败：未插入带备注的填充直线。'};$tinyGap=New-GapFillElement (New-Point2 0 0) (New-Point2 0.00005 0) $gapA $gapB 0.00005;if($null -ne $tinyGap){throw '小于 0.1 mm 的端点间隙不应生成填充线。'}
        $gapReverse=Reverse-Element $gapRoute[2]; if((Get-Distance $gapReverse.Start $gapRoute[2].End) -gt 1e-12){throw '一键换向的几何反转自测失败。'}
        [System.IO.File]::WriteAllText($selfTestLog, ($script:Elements | Select-Object 序号,线型,长度_m,起点桩号,终点桩号,半径_m,偏角_度,来源,备注 | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
        Export-Dxf (Join-Path $PSScriptRoot 'selftest_road_elements.dxf')
        Write-Output "SELFTEST_OK:$($script:Elements.Count):ConnectionToleranceMm=$($script:ConnectionToleranceM*1000.0)"; Write-Output "GAP_FILL_SELFTEST_OK:Count=$($gapRoute.Count):LengthMm=$([Math]::Round($gapRoute[1].Length*1000.0,3))"; $script:Elements | Group-Object 线型 | ForEach-Object {Write-Output ("TYPE:{0}:{1}" -f $_.Name,$_.Count)}; $script:Diagnostics | ForEach-Object {Write-Output ("DIAG:{0}" -f $_)}
    } catch {
        [System.IO.File]::WriteAllText($selfTestLog, (([pscustomobject]@{error=$_.Exception.Message; stack=$_.ScriptStackTrace}) | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
        Write-Error $_
        exit 1
    }
} else {$Window.ShowDialog() | Out-Null}

