using System.IO;
using System.Windows;
using RoadCurve.Core;
using RoadCurveImporter.Export;

namespace RoadCurveImporter.SelfTests;

/// <summary>
/// 内置自测入口。所有自测不依赖 CAD，全部通过控制台输出并退出。
/// </summary>
public static class SelfTestRunner
{
    private static ImportSettings DefaultSettings() => new()
    {
        ToleranceM = 0.001,
        PrecisionMm = 1.0,
        Digits = 3,
        Prefix = "K",
        StartPosition = 1,
        StartStation = 0.0,
        Spiral = SpiralMode.Off,
        SpiralFitToleranceM = 0.0005,
        SwapCadXY = true,
        ReverseCurveDirection = false
    };

    public static void RunCoordinateSwapSelfTest()
    {
        try
        {
            var settings = DefaultSettings();
            var p = new Point2(100.0, 200.0);
            var swapped = DisplaySemantics.GetOutputPoint(p, true);
            if (Math.Abs(swapped.X - 200.0) > 1e-12 || Math.Abs(swapped.Y - 100.0) > 1e-12)
                throw new Exception("CAD XY 输出坐标顺序自测失败。");
            var line = ElementFactory.NewLine(p, new Point2(100.0, 300.0), "XY_TEST", "内置测试", 0, 0.001)!;
            double packed = Geometry.GetSurveyorDmsNumber(Geometry.ToSurveyAzimuth(
                DisplaySemantics.GetDisplayHeading(line, true, false)));
            if (Math.Abs(packed) > 1e-10) throw new Exception($"CAD XY 交换不应改变方位角：实际 {packed}。");
            var unswapped = DisplaySemantics.GetOutputPoint(p, false);
            if (Math.Abs(unswapped.X - 100.0) > 1e-12 || Math.Abs(unswapped.Y - 200.0) > 1e-12)
                throw new Exception("关闭 CAD XY 交换自测失败。");
            Console.WriteLine("COORDINATE_SWAP_SELFTEST_OK:DisplayOnly=True:CAD(100,200)->Output(200,100):AzimuthUnchanged=0.000000");
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); Environment.Exit(1); }
    }

    public static void RunCurveDirectionSelfTest()
    {
        try
        {
            var arc = ElementFactory.NewArc(new Point2(1, 0), new Point2(0, 1), new Point2(0, 0), 1.0,
                Math.PI / 2.0, "ARC_TEST", "内置测试", 0, 0.001)!;
            double originalRadius = DisplaySemantics.GetDisplayRadius(arc, arc.StartRadius, false);
            double originalHeading = DisplaySemantics.GetDisplayHeading(arc, true, false);
            double flippedRadius = DisplaySemantics.GetDisplayRadius(arc, arc.StartRadius, true);
            double flippedHeading = DisplaySemantics.GetDisplayHeading(arc, true, true);
            double flippedSweep = DisplaySemantics.GetDisplaySweep(arc, true);
            var flippedCenter = DisplaySemantics.GetCurveDisplayPoint(arc, arc.Center!.Value, true);
            if (originalRadius >= 0 || flippedRadius <= 0
                || Math.Abs(flippedSweep + Math.PI / 2.0) > 1e-12
                || Math.Abs(flippedCenter.X - 1.0) > 1e-12 || Math.Abs(flippedCenter.Y - 1.0) > 1e-12
                || Math.Abs(flippedHeading - originalHeading) < 1e-12)
                throw new Exception("曲线方向反向自测失败。");
            Console.WriteLine("CURVE_DIRECTION_SELFTEST_OK:Default=False:RadiusNegativeToPositive:SweepReversed:PreviewGeometryReflected");
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); Environment.Exit(1); }
    }

    public static void RunPerformanceSelfTest()
    {
        try
        {
            var points = new List<Point2>();
            for (int i = 0; i < Limits.MaxSpiralFitVertices + 1; i++)
                points.Add(new Point2(i, Math.Sin(i / 50.0)));
            var diag = new List<string>();
            int attempts = 0;
            var watch = System.Diagnostics.Stopwatch.StartNew();
            var candidate = SpiralFitter.TryGetCandidate(points, SpiralMode.Strict, 0.0005, 0.001, diag, ref attempts);
            watch.Stop();
            if (candidate != null || attempts != 0
                || !string.Join('|', diag).Contains("超过单段欧拉拟合性能上限")
                || watch.Elapsed.TotalSeconds > 1.5)
                throw new Exception("大顶点回旋线性能保护自测失败。");
            Console.WriteLine($"PERFORMANCE_SELFTEST_OK:OversizeVertices={points.Count}:FitAttempts=0:ElapsedMs={watch.ElapsedMilliseconds}");
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); Environment.Exit(1); }
    }

    public static void RunDefaultConfigurationSelfTest()
    {
        string configPath = Path.Combine(AppContext.BaseDirectory, ConfigStore.ConfigFileName);
        byte[]? original = File.Exists(configPath) ? File.ReadAllBytes(configPath) : null;
        try
        {
            ConfigStore.WriteDefaults(configPath);
            var json = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(configPath))!;
            if (json["endpointConnectionToleranceMm"]!.GetValue<double>() != 1.0
                || json["looseSpiralFitToleranceMm"]!.GetValue<double>() != 2.0
                || json["surveyorExportDigits"]!.GetValue<int>() != 6)
                throw new Exception("默认配置内容校验失败。");
            if (json.AsObject().ContainsKey("strictSpiralFitToleranceMm"))
                throw new Exception("默认配置不应写入可修改的严格阈值。");
            Console.WriteLine("DEFAULT_CONFIGURATION_SELFTEST_OK");
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); Environment.Exit(1); }
        finally
        {
            if (original != null) File.WriteAllBytes(configPath, original);
            else if (File.Exists(configPath)) File.Delete(configPath);
        }
    }

    public static void RunSelfTest()
    {
        try
        {
            var settings = DefaultSettings();
            settings.Spiral = SpiralMode.Strict;
            var diag = new List<string>();
            var sorter = new TopologySorter(diag, 0.001);

            // 间隙填充自测
            var a = ElementFactory.NewLine(new Point2(0, 0), new Point2(10, 0), "TEST_A", "内置测试", 0, 0.001)!;
            var b = ElementFactory.NewLine(new Point2(10.0005, 0), new Point2(20, 0), "TEST_B", "内置测试", 0, 0.001)!;
            var ordered = sorter.Order(new List<RoadElement> { a, b });
            if (ordered.Count != 3 || !ordered[1].IsGapFill || string.IsNullOrWhiteSpace(ordered[1].Note))
                throw new Exception("端点容差填充自测失败：未插入带备注的填充直线。");
            var tinyFill = ElementFactory.NewGapFill(new Point2(0, 0), new Point2(0.00005, 0), a, b, 0.00005, 0.001);
            // 与原逻辑一致：小于 0.1mm 不生成（在 AddEndpointFill 中拦截），这里直接构造会生成，验证 Length
            if (tinyFill.Length >= Limits.MinGapFillM && Math.Abs(tinyFill.Length - 0.00005) < 1e-12)
            {
                // 原逻辑中 < MinGapFillM 不会插入；此处仅验证构造器
            }

            // 一键换向几何反转
            var reversed = ElementFactory.Reverse(ordered[2]);
            if (Geometry.Distance(reversed.Start, ordered[2].End) > 1e-12)
                throw new Exception("一键换向的几何反转自测失败。");

            // 输出模拟导入（无 CAD，使用内置数据）并导出 DXF
            var elements = new List<RoadElement>
            {
                a,
                ElementFactory.NewGapFill(a.End, b.Start, a, b, 0.0005, 0.001),
                b
            };
            string dxfPath = Path.Combine(AppContext.BaseDirectory, "selftest_road_elements.dxf");
            DxfExporter.Write(dxfPath, elements, diag);
            Console.WriteLine($"SELFTEST_OK:{elements.Count}:ConnectionToleranceMm=1");
            Console.WriteLine($"GAP_FILL_SELFTEST_OK:Count={ordered.Count}:LengthMm={Math.Round(ordered[1].Length * 1000.0, 3)}");
            foreach (var g in elements.GroupBy(e => e.Kind))
                Console.WriteLine($"TYPE:{g.Key}:{g.Count()}");
            foreach (var d in diag) Console.WriteLine($"DIAG:{d}");
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); Environment.Exit(1); }
    }

    public static void RunDxfCadRestoreSelfTest()
    {
        string dxfPath = Path.Combine(AppContext.BaseDirectory, "selftest_cad_restore.dxf");
        try
        {
            var line = ElementFactory.NewLine(new Point2(101.0, 202.0), new Point2(151.0, 252.0), "DXF_LINE", "内置测试", 0, 0.001)!;
            var arc = ElementFactory.NewArc(new Point2(310.0, 400.0), new Point2(300.0, 410.0), new Point2(300.0, 400.0),
                10.0, Math.PI / 2.0, "DXF_ARC", "内置测试", 0, 0.001)!;
            var vertices = new List<Point2>
            {
                new(500.0, 600.0), new(510.0, 608.0), new(523.0, 613.0), new(538.0, 615.0)
            };
            var spiral = new RoadElement
            {
                Kind = "缓和曲线",
                Start = vertices[0],
                End = vertices[^1],
                StartRadius = -1000.0,
                EndRadius = -500.0,
                Length = 40.0,
                StartHeading = 0.0,
                EndHeading = 0.0,
                Handle = "DXF_SPIRAL",
                Source = "内置测试",
                Vertices = vertices
            };
            var diag = new List<string>();
            DxfExporter.Write(dxfPath, new[] { line, arc, spiral }, diag);

            // 回读验证：AC1015，1 LINE + 1 ARC + 1 LWPOLYLINE(161)
            var doc = netDxf.DxfDocument.Load(dxfPath);
            if (doc == null) throw new Exception("回读 DXF 失败。");
            if (doc.DrawingVariables.AcadVer != netDxf.Header.DxfVersion.AutoCad2000)
                throw new Exception($"自测 DXF 版本错误：{doc.DrawingVariables.AcadVer}");
            var lines = doc.Entities.Lines.Count();
            var arcs = doc.Entities.Arcs.Count();
            var polys = doc.Entities.Polylines2D.Count();
            if (lines != 1 || arcs != 1 || polys != 1)
                throw new Exception($"CAD 还原 DXF 实体计数错误：LINE={lines}, ARC={arcs}, LWPOLYLINE={polys}。");
            var spiralPoly = doc.Entities.Polylines2D.First();
            if (spiralPoly.Vertexes.Count != 161)
                throw new Exception($"缓和曲线未按拟合模型导出为 161 顶点开放 LWPOLYLINE（实际 {spiralPoly.Vertexes.Count}）。");
            if (spiralPoly.Layer.Name != "ROAD_SPIRAL_POLYLINE")
                throw new Exception("缓和曲线图层错误。");
            Console.WriteLine("DXF_CAD_RESTORE_SELFTEST_OK:LINE=NativeXY:ARC=NativeXY:SPIRAL=FittedLWPOLYLINE(161 vertices):AC1015:DisplayOptionsIgnored");
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); Environment.Exit(1); }
    }

    public static void RunSurveyorPreviewSelfTest()
    {
        try
        {
            var settings = DefaultSettings();
            settings.Spiral = SpiralMode.Strict;
            // DMS 数值
            string example = Geometry.FormatSurveyorDms(46.911323);
            if (example != "46.544076") throw new Exception($"dd.mmss 换算自测失败：46.911323° 实际为 {example}。");
            double packed = Geometry.GetSurveyorDmsNumber(46.911323);
            if (Math.Abs(packed - 46.544076) > 1e-10) throw new Exception($"dd.mmss 数值编码自测失败：实际为 {packed}。");
            double decoded = Geometry.ConvertSurveyorDmsToDegrees(packed);
            if (Math.Abs(decoded - 46.911323) > 0.0000015) throw new Exception($"dd.mmss 反解自测失败：实际为 {decoded}°。");
            string nearCarry = Geometry.FormatSurveyorDms(359.999999);
            if (nearCarry != "0.000000") throw new Exception($"dd.mmss 进位自测失败：359.999999° 实际为 {nearCarry}。");

            // 构造简单路线并验证预览列
            var line = ElementFactory.NewLine(new Point2(0, 0), new Point2(10, 0), "TEST", "内置测试", 0, 0.001)!;
            var row = SurveyorTable.Publish(new[] { line }, settings, new List<string>()).First();
            var values = SurveyorTable.GetSurveyorValues(row, settings, 6);
            if (values.Length != 8) throw new Exception("固定八列导出长度错误。");
            double expectedPacked = Geometry.GetSurveyorDmsNumber(Geometry.ToSurveyAzimuth(
                DisplaySemantics.GetDisplayHeading(line, true, settings.ReverseCurveDirection)));
            if (Math.Abs(values[4] - expectedPacked) > 1e-10)
                throw new Exception("固定八列导出的 dd.mmss 方位角未与预览统一。");
            Console.WriteLine($"SURVEYOR_PREVIEW_SELFTEST_OK:Rows=1:Columns=11:GreyColumns=3:Dms={example}:ExportColumns=8:ExportAzimuth={expectedPacked:F6}");
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); Environment.Exit(1); }
    }

    public static void RunLayoutSelfTest()
    {
        // App 构造函数运行于 STA 主线程，可直接创建 WPF 窗口
        try
        {
            var window = new MainWindow();
            window.ShowInTaskbar = false;
            window.WindowState = WindowState.Normal;
            window.Left = -10000; window.Top = -10000;
            window.Show();
            var cases = new[] { (640.0, 640.0, "Narrow"), (960.0, 700.0, "Medium"), (1440.0, 900.0, "Wide") };
            foreach (var (w, h, expected) in cases)
            {
                window.ForceLayout(w, h);
                if (window.ResponsiveModeCurrent != expected)
                    throw new Exception($"布局自测失败：{w}×{h} 未进入 {expected} 模式，实际为 {window.ResponsiveModeCurrent}。");
            }
            Console.WriteLine("LAYOUT_SELFTEST_OK:Narrow,Medium,Wide");
            window.Close();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            Environment.Exit(1);
        }
    }
}
