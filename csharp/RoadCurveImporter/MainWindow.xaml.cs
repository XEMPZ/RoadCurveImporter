using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using RoadCurve.Core;
using RoadCurveImporter.Cad;

namespace RoadCurveImporter;

public partial class MainWindow : Window
{
    // ------------------------------------------------ 状态（对应 PS 脚本级变量）
    private readonly List<ElementRow> _elements = new();
    private readonly List<SurveyorRow> _surveyorRows = new();
    private readonly List<string> _diagnostics = new();
    private ImportSettings _currentSettings = new();
    private ConfigStore _config = new();
    private int _spiralFitAttemptCount;
    private string _configPath = "";
    private string _runtimeLogPath = "";
    private string _previewRenderNotice = "";
    private double _previewZoom = 1.0, _previewPanX, _previewPanY;
    private const double PreviewMinZoom = 0.25, PreviewMaxZoom = 10.0;
    private bool _previewIsPanning;
    private Point _previewPanStart;
    private double _previewPanOriginX, _previewPanOriginY;
    private string _responsiveMode = "";

    private static readonly HashSet<string> AutoResultColumns =
        new(StringComparer.Ordinal) { "终点X坐标(m)", "终点Y坐标(m)", "终点方位角(dd.mmss)" };

    public MainWindow()
    {
        InitializeComponent();
        string baseDir = AppContext.BaseDirectory;
        _configPath = System.IO.Path.Combine(baseDir, ConfigStore.ConfigFileName);
        _runtimeLogPath = System.IO.Path.Combine(baseDir, "RoadCurveImporter.runtime.log");
        _config = ConfigStore.Load(_configPath);
        ConnectionToleranceBox.Text = (_config.ConnectionToleranceM * 1000.0).ToString("0.###", CultureInfo.InvariantCulture);
        StrictSpiralToleranceBox.Text = (_config.StrictSpiralToleranceM * 1000.0).ToString("0.###", CultureInfo.InvariantCulture);
        LooseSpiralToleranceBox.Text = (_config.LooseSpiralToleranceM * 1000.0).ToString("0.###", CultureInfo.InvariantCulture);
        InitializeResponsiveWindow();
    }

    private void Window_Loaded(object sender, RoutedEventArgs e)
    {
        UpdateHostStatus();
    }

    // ------------------------------------------------ 小工具
    private void WriteProgress(string message, bool clear = false)
    {
        if (clear) ProgressBox.Clear();
        ProgressBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {message}{Environment.NewLine}");
        if (ProgressBox.Text.Length > 18000)
            ProgressBox.Text = ProgressBox.Text[^13000..];
        ProgressBox.ScrollToEnd();
    }

    private static void PumpUiEvents()
    {
        var frame = new DispatcherFrame();
        Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background,
            new Action(() => frame.Continue = false));
        Dispatcher.PushFrame(frame);
    }

    private void WriteRuntimeFailureLog(string stage, Exception ex, int cadCount, int rawCount)
    {
        try
        {
            System.IO.File.AppendAllText(_runtimeLogPath,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] 阶段={stage}; CAD实体={cadCount}; 道路段={rawCount}; 错误={ex.Message}{Environment.NewLine}");
        }
        catch { }
    }

    private ImportSettings GetCurrentSettings()
    {
        if (!double.TryParse(PrecisionBox.Text, out double tolMm) || tolMm <= 0)
            throw new InvalidOperationException("计算精度必须是正数（单位：mm）。");
        if (!int.TryParse(StartPositionBox.Text, out int startPosition) || startPosition < 1)
            throw new InvalidOperationException("起算点位置必须是大于等于 1 的要素序号。");
        if (!double.TryParse(StartStationBox.Text, out double startStation))
            throw new InvalidOperationException("起算点桩号必须是数值（单位：m）。");
        int digits = ImportSettings.DigitsFromPrecisionMm(tolMm);
        var spiralMode = DetectSpiralsBox.IsChecked != true ? SpiralMode.Off
            : LooseSpiralRadio.IsChecked == true ? SpiralMode.Loose : SpiralMode.Strict;
        double spiralTolerance = spiralMode == SpiralMode.Loose ? _config.LooseSpiralToleranceM : _config.StrictSpiralToleranceM;
        return new ImportSettings
        {
            ToleranceM = tolMm / 1000.0,
            PrecisionMm = tolMm,
            Digits = digits,
            Prefix = PrefixBox.Text.Trim(),
            StartPosition = startPosition,
            StartStation = startStation,
            Spiral = spiralMode,
            SpiralFitToleranceM = spiralTolerance,
            SwapCadXY = CoordinateSwapBox.IsChecked == true,
            ReverseCurveDirection = CurveDirectionBox.IsChecked == true
        };
    }

    // ------------------------------------------------ CAD 连接
    private void UpdateHostStatus()
    {
        // XAML 初始化期间 HostSelector 会先触发 SelectionChanged，此时状态栏控件尚未赋值
        if (HostStatusText is null || StatusText is null) return;
        try
        {
            var cad = CadHost.GetRunningCadApplication(HostSelector.SelectedIndex);
            var doc = CadHost.GetActiveCadDocument(cad.Application, _diagnostics);
            string name = "";
            try { name = Convert.ToString(doc.Name) ?? ""; } catch { }
            HostStatusText.Text = $"{cad.Name} · {cad.Version} · {name}";
            HostStatusText.Foreground = Brushes.SeaGreen;
            StatusText.Text = $"已连接：{HostStatusText.Text}。仅读取，不写入图形。";
        }
        catch
        {
            HostStatusText.Text = "未检测到所选 CAD 会话";
            HostStatusText.Foreground = Brushes.IndianRed;
            StatusText.Text = "请启动完整 Windows 版 CAD，或在“CAD 主机”中切换后刷新。";
        }
    }

    // ------------------------------------------------ 导入（Run-Import 等价）
    private void RunImport(bool selectOnScreen)
    {
        ImportButton.IsEnabled = false;
        ReadButton.IsEnabled = false;
        int cadCount = 0;
        var raw = new List<RoadElement>();
        string stage = "初始化";
        try
        {
            _currentSettings = GetCurrentSettings();
            _spiralFitAttemptCount = 0;
            _previewRenderNotice = "";
            _diagnostics.Clear();
            string coordinateMode = _currentSettings.SwapCadXY
                ? "已启用 CAD XY 交换（测绘 X=北、Y=东）" : "未启用 CAD XY 交换（保留 CAD X/Y）";
            _diagnostics.Add(coordinateMode);
            WriteProgress($"开始导入。{coordinateMode}；端点自动连接容差：{_config.ConnectionToleranceM * 1000.0:0.###} mm（配置文件只读）。", true);
            stage = "连接 CAD";
            var cad = CadHost.GetRunningCadApplication(HostSelector.SelectedIndex);
            var app = cad.Application;
            var doc = CadHost.GetActiveCadDocument(app, _diagnostics);

            stage = "读取 CAD 实体";
            if (selectOnScreen)
            {
                int selected = 0;
                dynamic? pickSet = null;
                try { pickSet = doc.PickfirstSelectionSet; selected = pickSet.Count; } catch { }
                int pickfirstEnabled = 1;
                try { pickfirstEnabled = Convert.ToInt32(doc.GetVariable("PICKFIRST")); } catch { }
                if (selected > 0)
                {
                    WriteProgress($"{cad.Name} 当前标签预选读取：{selected} 个实体，开始只读转换。");
                    for (int i = 0; i < selected; i++)
                    {
                        dynamic entity = pickSet!.Item(i);
                        cadCount++;
                        ConvertAndAdd(entity, raw, cadCount, $"{cad.Name} 预选集");
                        if (cadCount % 50 == 0 || cadCount == selected)
                        {
                            WriteProgress($"已读取 {cadCount}/{selected} 个预选实体，当前生成 {raw.Count} 个道路段。");
                            PumpUiEvents();
                        }
                        if (raw.Count > Limits.MaxCandidateSegments)
                            throw new InvalidOperationException($"候选道路段超过安全上限 {Limits.MaxCandidateSegments}，请减少预选范围。");
                    }
                }
                else if (cad.Name == "Autodesk AutoCAD")
                {
                    if (pickfirstEnabled == 0)
                        throw new InvalidOperationException("AutoCAD 关闭了“先选择后执行”（系统变量 PICKFIRST=0），预选无法被读取。请在 AutoCAD 命令行输入 PICKFIRST 回车、再输入 1 回车（或在“选项 → 选择集”勾选“先选择后执行”），然后在当前标签重新点选或框选对象。程序不会向 AutoCAD 发送选择命令。");
                    throw new InvalidOperationException("AutoCAD 当前标签未检测到预选对象。请先在 AutoCAD 当前标签中点选或窗口/框选所需 LINE、ARC 或多段线，再切回本程序点击“读取 CAD 预选 / 选择”。程序不会向 AutoCAD 发送选择命令。");
                }
                else
                {
                    if (pickfirstEnabled == 0)
                        _diagnostics.Add($"{cad.Name} 的 PICKFIRST=0（未启用先选择后执行），无法读取预选；已转入屏幕点选模式。");
                    var choice = System.Windows.MessageBox.Show(
                        $"请确认已打开 {cad.Name} 图形。单击“确定”后程序会最小化，并在 CAD 当前标签中点选或框选多段线、直线和圆弧；完成后请按 Enter。{Environment.NewLine}{Environment.NewLine}导入过程只读取实体，不会修改或保存图形。",
                        $"CAD 导入 - {cad.Name}", MessageBoxButton.OKCancel, MessageBoxImage.Information);
                    if (choice != MessageBoxResult.OK) return;
                    string setName = "RDCURVE_" + Guid.NewGuid().ToString("N")[..8];
                    dynamic? set = null;
                    try
                    {
                        set = doc.SelectionSets.Add(setName);
                        WindowState = WindowState.Minimized;
                        Thread.Sleep(350);
                        set.SelectOnScreen();
                        selected = Convert.ToInt32(set.Count);
                        WriteProgress($"{cad.Name} 选择完成：{selected} 个实体，开始读取。");
                        for (int i = 0; i < selected; i++)
                        {
                            dynamic entity = set.Item(i);
                            cadCount++;
                            ConvertAndAdd(entity, raw, cadCount, $"{cad.Name} 选择集");
                            if (cadCount % 50 == 0 || cadCount == selected)
                            {
                                WriteProgress($"已读取 {cadCount}/{selected} 个选择实体，当前生成 {raw.Count} 个道路段。");
                                PumpUiEvents();
                            }
                            if (raw.Count > Limits.MaxCandidateSegments)
                                throw new InvalidOperationException($"候选道路段超过安全上限 {Limits.MaxCandidateSegments}，请减少框选范围。");
                        }
                    }
                    finally
                    {
                        if (set != null) { try { set.Delete(); } catch { } }
                        WindowState = WindowState.Normal;
                    }
                }
            }
            else
            {
                var visible = CadHost.GetVisibleLayerNames(doc);
                int hidden = 0, other = 0;
                StatusText.Text = $"正在读取当前显示图层（{visible.Count} 个可见图层）…";
                WriteProgress($"阶段 1/3：扫描当前显示图层，共 {visible.Count} 个可见图层。");
                foreach (var entityObj in doc.ModelSpace)
                {
                    dynamic entity = entityObj;
                    string layerName = "";
                    try { layerName = Convert.ToString(entity.Layer) ?? ""; } catch { }
                    if (!visible.Contains(layerName)) { hidden++; continue; }
                    if (!CadHost.IsSupportedRoadEntity(entity)) { other++; continue; }
                    cadCount++;
                    ConvertAndAdd(entity, raw, cadCount, "可见图层");
                    if (cadCount % 50 == 0)
                    {
                        StatusText.Text = $"正在读取当前显示图层：已检查 {cadCount} 个候选线元…";
                        WriteProgress($"阶段 1/3：已读取 {cadCount} 个候选线元，生成 {raw.Count} 个道路段。");
                        PumpUiEvents();
                    }
                    if (raw.Count > Limits.MaxCandidateSegments)
                        throw new InvalidOperationException($"当前显示图层中候选道路段超过安全上限 {Limits.MaxCandidateSegments}。为避免卡死已停止；请关闭不相关图层后重试，或改用“从 CAD 点选/框选”。");
                }
                _diagnostics.Add($"模型空间过滤：仅当前显示图层；已跳过 {hidden} 个隐藏/冻结图层实体及 {other} 个其他类型实体。");
            }
            if (cadCount == 0) throw new InvalidOperationException("未发现可导入的 LINE、ARC 或 LWPOLYLINE 实体。");
            if (raw.Count == 0) throw new InvalidOperationException("没有生成有效道路段。");

            stage = "连接排序";
            WriteProgress($"阶段 2/3：按 {_config.ConnectionToleranceM * 1000.0:0.###} mm 平面端点容差执行连接排序（{raw.Count} 个道路段）。");
            PumpUiEvents();
            var sorter = new TopologySorter(_diagnostics, _config.ConnectionToleranceM);
            var ordered = sorter.Order(raw);
            stage = "生成表格与示意图";
            WriteProgress($"阶段 3/3：生成表格与线路示意图（{ordered.Count} 个要素）。");
            PublishElements(ordered);
            ReverseRouteButton.IsEnabled = _elements.Count > 0;
            ResetPreviewZoom();

            DiagnosticText.Text = _diagnostics.Count > 0 || !string.IsNullOrWhiteSpace(_previewRenderNotice)
                ? string.Join(Environment.NewLine, _diagnostics.Concat(new[] { _previewRenderNotice }).Where(s => !string.IsNullOrWhiteSpace(s)))
                : "未发现几何诊断。";
            string docName = "";
            try { docName = Convert.ToString(doc.Name) ?? ""; } catch { }
            StatusText.Text = $"已从 {docName} 导入 {cadCount} 个可读取 CAD 实体，生成 {_elements.Count} 个道路要素。";
            WriteProgress($"完成：{cadCount} 个 CAD 实体，{_elements.Count} 个道路要素。");
        }
        catch (Exception ex)
        {
            StatusText.Text = "导入失败。";
            WriteRuntimeFailureLog(stage, ex, cadCount, raw.Count);
            WriteProgress($"失败（阶段：{stage}）：{ex.Message}。已写入运行诊断日志。");
            System.Windows.MessageBox.Show(ex.Message, "CAD 导入错误", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            ImportButton.IsEnabled = true;
            ReadButton.IsEnabled = true;
        }
    }

    private void ConvertAndAdd(dynamic entity, List<RoadElement> raw, int ordinal, string mode)
    {
        try
        {
            foreach (var part in CadHost.ConvertCadEntity((object)entity, _currentSettings, _diagnostics, TrySpiral))
                raw.Add(part);
        }
        catch (Exception ex)
        {
            _diagnostics.Add($"跳过{mode}实体 #{ordinal}：{ex.Message}");
        }
    }

    private SpiralCandidate? TrySpiral(List<Point2> points)
    {
        int before = _spiralFitAttemptCount;
        var candidate = SpiralFitter.TryGetCandidate(points, _currentSettings.Spiral,
            _currentSettings.SpiralFitToleranceM, _currentSettings.ToleranceM, _diagnostics, ref _spiralFitAttemptCount);
        if (_spiralFitAttemptCount > before)
        {
            string modeText = _currentSettings.Spiral == SpiralMode.Strict ? "严格 0.5 mm" : "宽松 2 mm";
            WriteProgress($"正在进行第 {_spiralFitAttemptCount}/{Limits.MaxSpiralFitCandidates} 段欧拉回旋线拟合（{points.Count} 个顶点，{modeText} 验收）…");
            PumpUiEvents();
        }
        return candidate;
    }

    // ------------------------------------------------ 发布与显示
    private void PublishElements(IReadOnlyList<RoadElement> ordered)
    {
        _elements.Clear();
        foreach (var row in SurveyorTable.Publish(ordered, _currentSettings, _diagnostics))
            _elements.Add(row);
        RefreshSurveyorRows();
    }

    private void RefreshSurveyorRows()
    {
        _surveyorRows.Clear();
        _surveyorRows.AddRange(SurveyorTable.BuildSurveyorRows(_elements, _currentSettings, _config.SurveyorExportDigits));
        UpdateGridView();
    }

    private void UpdateGridView()
    {
        ElementGrid.Columns.Clear();
        bool surveyor = SurveyorPreviewBox.IsChecked == true;
        if (surveyor)
        {
            AddTextColumn("线型", "Kind");
            AddTextColumn("起始里程(m)", "StartStation");
            AddTextColumn("结束里程(m)", "EndStation");
            AddTextColumn("起始方位角(dd.mmss)", "StartAzimuthDms");
            AddTextColumn("起始X坐标(m)", "StartX");
            AddTextColumn("起始Y坐标(m)", "StartY");
            AddTextColumn("开始半径(m；左负右正)", "StartRadiusM");
            AddTextColumn("结束半径(m；左负右正)", "EndRadiusM");
            AddTextColumn("终点X坐标(m)", "EndX", grey: true);
            AddTextColumn("终点Y坐标(m)", "EndY", grey: true);
            AddTextColumn("终点方位角(dd.mmss)", "EndAzimuthDms", grey: true);
            ElementGrid.ItemsSource = null;
            ElementGrid.ItemsSource = _surveyorRows;
        }
        else
        {
            AddTextColumn("序号", "Sequence");
            AddTextColumn("线型", "Kind");
            AddTextColumn("长度_m", "LengthM");
            AddTextColumn("起点桩号", "StartStationText");
            AddTextColumn("终点桩号", "EndStationText");
            AddTextColumn("起点X", "StartX");
            AddTextColumn("起点Y", "StartY");
            AddTextColumn("终点X", "EndX");
            AddTextColumn("终点Y", "EndY");
            AddTextColumn("起点方位角(dd.mmss)", "StartAzimuthDms");
            AddTextColumn("终点方位角(dd.mmss)", "EndAzimuthDms");
            AddTextColumn("开始半径_m", "StartRadiusM");
            AddTextColumn("结束半径_m", "EndRadiusM");
            AddTextColumn("半径_m", "RadiusM");
            AddTextColumn("偏角(dd.mmss)", "DeflectionDms");
            AddTextColumn("判别", "Classification");
            AddTextColumn("来源", "Source");
            AddTextColumn("备注", "Note");
            ElementGrid.ItemsSource = null;
            ElementGrid.ItemsSource = _elements;
        }
    }

    private void AddTextColumn(string header, string bindingPath, bool grey = false)
    {
        var column = new DataGridTextColumn
        {
            Header = header,
            Binding = new Binding(bindingPath)
        };
        if (grey)
        {
            var cellStyle = new Style(typeof(DataGridCell));
            cellStyle.Setters.Add(new Setter(Control.BackgroundProperty, Brushes.Gainsboro));
            cellStyle.Setters.Add(new Setter(Control.ForegroundProperty, Brushes.DimGray));
            column.CellStyle = cellStyle;
            var textStyle = new Style(typeof(TextBlock));
            textStyle.Setters.Add(new Setter(TextBlock.ForegroundProperty, Brushes.DimGray));
            column.ElementStyle = textStyle;
        }
        ElementGrid.Columns.Add(column);
    }

    // ------------------------------------------------ 示意图（Draw-Schematic 等价）
    private void DrawSchematic()
    {
        PreviewCanvas.Children.Clear();
        if (_elements.Count == 0) return;
        double minX = double.PositiveInfinity, minY = double.PositiveInfinity;
        double maxX = double.NegativeInfinity, maxY = double.NegativeInfinity;
        bool reverse = _currentSettings.ReverseCurveDirection;
        var bounds = new List<Point2>();
        foreach (var row in _elements)
        {
            var e = row.Element;
            bounds.Add(e.Start);
            bounds.Add(e.End);
            if (e.Center.HasValue) bounds.Add(DisplaySemantics.GetCurveDisplayPoint(e, e.Center.Value, reverse));
            if (e.Vertices != null)
                foreach (var v in e.Vertices)
                    bounds.Add(DisplaySemantics.GetCurveDisplayPoint(e, v, reverse));
        }
        foreach (var p in bounds)
        {
            if (p.X < minX) minX = p.X;
            if (p.X > maxX) maxX = p.X;
            if (p.Y < minY) minY = p.Y;
            if (p.Y > maxY) maxY = p.Y;
        }
        if (!double.IsFinite(minX)) return;
        double w = Math.Max(320.0, PreviewCanvas.ActualWidth);
        double h = Math.Max(220.0, PreviewCanvas.ActualHeight);
        double dx = Math.Max(1.0, maxX - minX), dy = Math.Max(1.0, maxY - minY);
        double baseScale = Math.Min((w - 58.0) / dx, (h - 58.0) / dy);
        double scale = baseScale * _previewZoom;
        double centerX = (minX + maxX) / 2.0, centerY = (minY + maxY) / 2.0;

        Point Map(Point2 p) => new(w / 2.0 + (p.X - centerX) * scale + _previewPanX,
                                   h / 2.0 - (p.Y - centerY) * scale + _previewPanY);

        int count = _elements.Count;
        int elementStep = Math.Max(1, (int)Math.Ceiling(count / (double)Limits.MaxPreviewElementShapes));
        if (elementStep > 1)
        {
            var overview = new Polyline { Stroke = Brushes.SteelBlue, StrokeThickness = 2.2 };
            for (int i = 0; i < count; i += elementStep)
            {
                var e = _elements[i].Element;
                overview.Points.Add(Map(e.Start));
                overview.Points.Add(Map(e.End));
            }
            overview.Points.Add(Map(_elements[count - 1].Element.End));
            PreviewCanvas.Children.Add(overview);
            _previewRenderNotice = $"示意图性能保护：共 {count} 个要素，已按每 {elementStep} 段抽样绘制总览；完整几何、表格与导出不受影响。";
        }
        else
        {
            _previewRenderNotice = "";
            foreach (var row in _elements)
            {
                var e = row.Element;
                var shape = new Polyline();
                shape.Stroke = e.IsGapFill ? Brushes.DarkOrange
                    : e.Kind == "直线" ? Brushes.MediumTurquoise
                    : e.Kind == "圆曲线" ? Brushes.IndianRed
                    : Brushes.MediumSlateBlue;
                shape.StrokeThickness = e.IsGapFill ? 3.2 : 2.6;
                if (e.IsGapFill) shape.StrokeDashArray = new DoubleCollection { 4, 2 };
                if (e.Kind == "直线" || e.IsGapFill)
                {
                    shape.Points.Add(Map(e.Start));
                    shape.Points.Add(Map(e.End));
                }
                else if (e.Kind == "圆曲线")
                {
                    var center = DisplaySemantics.GetCurveDisplayPoint(e, e.Center!.Value, reverse);
                    var start = e.Start;
                    double displaySweep = DisplaySemantics.GetDisplaySweep(e, reverse);
                    double startAngle = Math.Atan2(start.Y - center.Y, start.X - center.X);
                    int n = Math.Max(12, (int)(Math.Abs(displaySweep) * 24));
                    for (int i = 0; i <= n; i++)
                    {
                        double a = startAngle + displaySweep * i / n;
                        shape.Points.Add(Map(new Point2(center.X + Math.Abs(e.Radius!.Value) * Math.Cos(a),
                                                        center.Y + Math.Abs(e.Radius!.Value) * Math.Sin(a))));
                    }
                }
                else if (e.Vertices != null)
                {
                    int vertexCount = e.Vertices.Count;
                    int vertexStep = Math.Max(1, (int)Math.Ceiling(vertexCount / (double)Limits.MaxPreviewVerticesPerCurve));
                    for (int i = 0; i < vertexCount; i += vertexStep)
                        shape.Points.Add(Map(DisplaySemantics.GetCurveDisplayPoint(e, e.Vertices[i], reverse)));
                    if ((vertexCount - 1) % vertexStep != 0)
                        shape.Points.Add(Map(DisplaySemantics.GetCurveDisplayPoint(e, e.Vertices[vertexCount - 1], reverse)));
                }
                PreviewCanvas.Children.Add(shape);
            }
        }
        AddRouteMarker(Map(_elements[0].Element.Start), "起点", Brushes.SeaGreen, -27.0);
        AddRouteMarker(Map(_elements[count - 1].Element.End), "终点", Brushes.Crimson, 9.0);
    }

    private void AddRouteMarker(Point mapped, string caption, Brush brush, double labelOffset)
    {
        var dot = new Ellipse { Width = 12, Height = 12, Fill = brush, Stroke = Brushes.White, StrokeThickness = 1.7 };
        PreviewCanvas.Children.Add(dot);
        Canvas.SetLeft(dot, mapped.X - 6);
        Canvas.SetTop(dot, mapped.Y - 6);
        var labelText = new TextBlock { Text = caption, FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = brush };
        var label = new Border
        {
            Background = Brushes.White,
            BorderBrush = brush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(3),
            Padding = new Thickness(4, 1, 4, 1),
            Child = labelText
        };
        PreviewCanvas.Children.Add(label);
        Canvas.SetLeft(label, mapped.X + 8);
        Canvas.SetTop(label, mapped.Y + labelOffset);
    }

    // ------------------------------------------------ 事件
    private void ImportButton_Click(object sender, RoutedEventArgs e) => RunImport(true);
    private void ReadButton_Click(object sender, RoutedEventArgs e) => RunImport(false);
    private void RefreshHostButton_Click(object sender, RoutedEventArgs e) => UpdateHostStatus();

    private void ReverseRouteButton_Click(object sender, RoutedEventArgs e)
    {
        if (_elements.Count == 0) return;
        var reversed = new List<RoadElement>(_elements.Count);
        for (int i = _elements.Count - 1; i >= 0; i--)
            reversed.Add(ElementFactory.Reverse(_elements[i].Element));
        StartPositionBox.Text = "1";
        PublishElements(reversed);
        _diagnostics.Add("已执行一键换向：起点、终点、线元顺序、测绘方位角及曲线左右方向均已同步反转；起算要素已设为 1。");
        DiagnosticText.Text = string.Join(Environment.NewLine, _diagnostics);
        ResetPreviewZoom();
        StatusText.Text = "已一键换向；当前绿色标记为新起点、红色标记为新终点。";
        WriteProgress("已一键换向并重新计算桩号与测量员线元法数据。");
    }

    private void ClearButton_Click(object sender, RoutedEventArgs e) => ClearImportedData(true);

    private void ClearImportedData(bool confirm)
    {
        if (confirm && _elements.Count > 0)
        {
            var choice = System.Windows.MessageBox.Show("将清除当前表格、示意图和工作进度中的导入结果。CAD 图形不会被修改。是否继续？",
                "清除数据", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (choice != MessageBoxResult.Yes) return;
        }
        _elements.Clear();
        _surveyorRows.Clear();
        ReverseRouteButton.IsEnabled = false;
        UpdateGridView();
        _diagnostics.Clear();
        DrawSchematic();
        DiagnosticText.Text = "已清除读取数据。";
        WriteProgress("已清除读取数据；CAD 图形未被修改。", true);
        StatusText.Text = "已清除当前道路要素；可重新导入。";
    }

    private void RestoreDefaultsButton_Click(object sender, RoutedEventArgs e)
    {
        var choice = System.Windows.MessageBox.Show(
            "将恢复界面起算参数、缓和曲线判定设置、缩放状态和同目录配置文件中的默认值；当前读取结果会被清除。不会修改、保存或关闭 CAD 图形。是否继续？",
            "恢复默认值", MessageBoxButton.YesNo, MessageBoxImage.Warning);
        if (choice != MessageBoxResult.Yes) return;
        try
        {
            ConfigStore.WriteDefaults(_configPath);
            _config = new ConfigStore();
            PrecisionBox.Text = "1"; PrefixBox.Text = "K"; StartPositionBox.Text = "1"; StartStationBox.Text = "0.000";
            CoordinateSwapBox.IsChecked = true; CurveDirectionBox.IsChecked = false;
            HostSelector.SelectedIndex = 0; DetectSpiralsBox.IsChecked = true; StrictSpiralRadio.IsChecked = true;
            ConnectionToleranceBox.Text = "1"; StrictSpiralToleranceBox.Text = "0.5"; LooseSpiralToleranceBox.Text = "2";
            SurveyorPreviewBox.IsChecked = false;
            ClearImportedData(false);
            ResetPreviewZoom();
            DiagnosticText.Text = "已恢复默认界面与配置：严格欧拉回旋线验收固定 0.5 mm；宽松验收默认 2 mm。";
            StatusText.Text = "已恢复默认值；CAD 图形未被修改。";
            WriteProgress("已恢复默认值并重写 RoadCurveImporter.config.json。", true);
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show($"恢复默认值失败：{ex.Message}", "恢复默认值", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void RefreshDisplayOptions()
    {
        if (_elements.Count == 0) return;
        _currentSettings = GetCurrentSettings();
        var ordered = _elements.Select(r => r.Element).ToList();
        PublishElements(ordered);
        DrawSchematic();
        StatusText.Text = "已按当前坐标显示/曲线方向选项刷新道路要素表、预览与导出数据。";
    }

    // ------------------------------------------------ 画布交互
    private void ResetPreviewZoom()
    {
        _previewZoom = 1.0; _previewPanX = 0; _previewPanY = 0; _previewIsPanning = false;
        DrawSchematic();
    }

    private void ResetZoomButton_Click(object sender, RoutedEventArgs e) => ResetPreviewZoom();
    private void PreviewCanvas_SizeChanged(object sender, SizeChangedEventArgs e) => DrawSchematic();

    private void PreviewCanvas_MouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (_elements.Count == 0) return;
        double oldZoom = _previewZoom;
        double factor = e.Delta > 0 ? 1.2 : 1.0 / 1.2;
        double newZoom = Math.Max(PreviewMinZoom, Math.Min(PreviewMaxZoom, oldZoom * factor));
        if (Math.Abs(newZoom - oldZoom) < 1e-12) return;
        var mouse = e.GetPosition(PreviewCanvas);
        double w = Math.Max(320.0, PreviewCanvas.ActualWidth);
        double h = Math.Max(220.0, PreviewCanvas.ActualHeight);
        double ratio = newZoom / oldZoom;
        _previewPanX += (mouse.X - w / 2.0 - _previewPanX) * (1.0 - ratio);
        _previewPanY += (mouse.Y - h / 2.0 - _previewPanY) * (1.0 - ratio);
        _previewZoom = newZoom;
        DrawSchematic();
        e.Handled = true;
    }

    private void PreviewCanvas_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (_elements.Count == 0) return;
        _previewIsPanning = true;
        _previewPanStart = e.GetPosition(PreviewCanvas);
        _previewPanOriginX = _previewPanX;
        _previewPanOriginY = _previewPanY;
        PreviewCanvas.CaptureMouse();
        PreviewCanvas.Cursor = System.Windows.Input.Cursors.SizeAll;
        e.Handled = true;
    }

    private void PreviewCanvas_MouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (!_previewIsPanning) return;
        var position = e.GetPosition(PreviewCanvas);
        _previewPanX = _previewPanOriginX + (position.X - _previewPanStart.X);
        _previewPanY = _previewPanOriginY + (position.Y - _previewPanStart.Y);
        DrawSchematic();
        e.Handled = true;
    }

    private void EndPreviewPan(MouseEventArgs e)
    {
        if (!_previewIsPanning) return;
        _previewIsPanning = false;
        if (PreviewCanvas.IsMouseCaptured) PreviewCanvas.ReleaseMouseCapture();
        PreviewCanvas.Cursor = System.Windows.Input.Cursors.Hand;
        e.Handled = true;
    }

    private void PreviewCanvas_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => EndPreviewPan(e);
    private void PreviewCanvas_MouseLeave(object sender, System.Windows.Input.MouseEventArgs e) => EndPreviewPan(e);

    private void SurveyorPreviewBox_CheckedChanged(object sender, RoutedEventArgs e) => UpdateGridView();

    private void Window_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateResponsiveLayout();

    private void DetectSpirals_Changed(object sender, RoutedEventArgs e)
    {
        // XAML 初始化期间可能先触发 Checked 事件，此时对端控件尚未赋值
        if (SpiralModePanel is null || DetectSpiralsBox is null) return;
        SpiralModePanel.IsEnabled = DetectSpiralsBox.IsChecked == true;
    }

    private void DisplayOption_Changed(object sender, RoutedEventArgs e) => RefreshDisplayOptions();

    private void HostSelector_SelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateHostStatus();

    // ------------------------------------------------ 响应式布局
    private void InitializeResponsiveWindow()
    {
        var work = SystemParameters.WorkArea;
        Width = Math.Min(1280.0, Math.Max(520.0, work.Width - 20.0));
        Height = Math.Min(760.0, Math.Max(650.0, work.Height - 20.0));
        _responsiveMode = "";
    }

    private void UpdateResponsiveLayout()
    {
        double width = ActualWidth;
        if (width < 1) return;
        string mode = width < 820 ? "Narrow" : width < 1130 ? "Medium" : "Wide";
        if (_responsiveMode == mode) return;
        _responsiveMode = mode;
        ControlGrid.RowDefinitions.Clear();
        ControlGrid.ColumnDefinitions.Clear();
        ContentGrid.RowDefinitions.Clear();
        ContentGrid.ColumnDefinitions.Clear();

        void SetPos(UIElement el, int row, int col)
        {
            Grid.SetRow(el, row);
            Grid.SetColumn(el, col);
        }

        if (mode == "Wide")
        {
            ControlGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.45, GridUnitType.Star) });
            ControlGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.20, GridUnitType.Star) });
            ControlGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.05, GridUnitType.Star) });
            ControlGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            SetPos(StartSettingsGroup, 0, 0); SetPos(SpecialLinesGroup, 0, 1); SetPos(HostGroup, 0, 2); SetPos(OperationPanel, 0, 3);
            ContentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2.2, GridUnitType.Star) });
            ContentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
            ContentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            SetPos(TablePanel, 0, 0); SetPos(PreviewPanel, 0, 2);
            StartSettingsGroup.Margin = new Thickness(0, 0, 9, 0);
            SpecialLinesGroup.Margin = new Thickness(0, 0, 9, 0);
            HostGroup.Margin = new Thickness(0, 0, 9, 0);
            OperationPanel.Margin = new Thickness(0);
        }
        else if (mode == "Medium")
        {
            ControlGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            ControlGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            ControlGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.25, GridUnitType.Star) });
            ControlGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            ControlGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            SetPos(StartSettingsGroup, 0, 0); SetPos(SpecialLinesGroup, 0, 1); SetPos(HostGroup, 1, 0); SetPos(OperationPanel, 1, 1);
            Grid.SetColumnSpan(OperationPanel, 2);
            ContentGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            ContentGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            ContentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            SetPos(TablePanel, 0, 0); SetPos(PreviewPanel, 1, 0);
            StartSettingsGroup.Margin = new Thickness(0, 0, 9, 7);
            SpecialLinesGroup.Margin = new Thickness(0, 0, 0, 7);
            HostGroup.Margin = new Thickness(0, 0, 9, 0);
            OperationPanel.Margin = new Thickness(0);
        }
        else
        {
            for (int i = 0; i < 4; i++) ControlGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            ControlGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            SetPos(StartSettingsGroup, 0, 0); SetPos(SpecialLinesGroup, 1, 0); SetPos(HostGroup, 2, 0); SetPos(OperationPanel, 3, 0);
            ContentGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            ContentGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            ContentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            SetPos(TablePanel, 0, 0); SetPos(PreviewPanel, 1, 0);
            StartSettingsGroup.Margin = new Thickness(0, 0, 0, 7);
            SpecialLinesGroup.Margin = new Thickness(0, 0, 0, 7);
            HostGroup.Margin = new Thickness(0, 0, 0, 7);
            OperationPanel.Margin = new Thickness(0);
        }
        Grid.SetRowSpan(TablePanel, 1); Grid.SetColumnSpan(TablePanel, 1);
        Grid.SetRowSpan(PreviewPanel, 1); Grid.SetColumnSpan(PreviewPanel, 1);
        ControlGrid.UpdateLayout();
        ContentGrid.UpdateLayout();
        DrawSchematic();
    }

    // ------------------------------------------------ 导出与关于
    private void DxfButton_Click(object sender, RoutedEventArgs e)
    {
        try { ExportDxf(null); } catch (Exception ex) { System.Windows.MessageBox.Show(ex.Message, "导出 DXF"); }
    }

    private void ExcelButton_Click(object sender, RoutedEventArgs e)
    {
        try { ExportExcel(null); } catch (Exception ex) { System.Windows.MessageBox.Show(ex.Message, "导出 Excel"); }
    }

    private void ExportDxf(string? targetPath)
    {
        if (_elements.Count == 0) throw new InvalidOperationException("没有可导出的曲线要素。");
        if (string.IsNullOrWhiteSpace(targetPath))
        {
            var dialog = new Microsoft.Win32.SaveFileDialog
            {
                Filter = "CAD 还原 DXF 图形 (*.dxf)|*.dxf",
                FileName = "道路曲线要素_CAD还原.dxf"
            };
            if (dialog.ShowDialog() != true) return;
            targetPath = dialog.FileName;
        }
        var elements = _elements.Select(r => r.Element).ToList();
        var result = Export.DxfExporter.Write(targetPath, elements, _diagnostics);
        StatusText.Text = $"已导出标准 CAD 还原 DXF：{targetPath}（缓和曲线拟合折线 {result.SpiralCount} 条；离散曲线折线 {result.DiscreteCount} 条）。";
        WriteProgress($"DXF 导出完成：R2000 标准格式；缓和曲线已转换为 {result.SpiralCount} 条拟合 LWPOLYLINE。");
    }

    private void ExportExcel(string? targetPath)
    {
        if (_elements.Count == 0) throw new InvalidOperationException("没有可导出的曲线要素。");
        if (string.IsNullOrWhiteSpace(targetPath))
        {
            var dialog = new Microsoft.Win32.SaveFileDialog
            {
                Filter = "测量员线元法 Excel (*.xlsx)|*.xlsx",
                FileName = "测量员线元法.xlsx"
            };
            if (dialog.ShowDialog() != true) return;
            targetPath = dialog.FileName;
        }
        WriteProgress("正在生成测量员软件线元法 Excel（8 列、无表头）。");
        int digits = _config.SurveyorExportDigits;
        var rows = _elements.Select(r => SurveyorTable.GetSurveyorValues(r, _currentSettings, digits)).ToList();
        Export.ExcelExporter.Write(targetPath, rows, digits);
        StatusText.Text = $"已导出测量员线元法 Excel：{targetPath}";
        WriteProgress($"已导出测量员线元法 Excel：{rows.Count} 行。");
    }

    private void AboutButton_Click(object sender, RoutedEventArgs e)
    {
        try { new AboutDialog { Owner = this }.ShowDialog(); }
        catch (Exception ex) { System.Windows.MessageBox.Show($"无法打开关于窗口：{ex.Message}", "关于本软件", MessageBoxButton.OK, MessageBoxImage.Warning); }
    }

    // ------------------------------------------------ 自测支撑（CLI 调用，见 SelfTests.cs）
    internal List<ElementRow> ElementsInternal => _elements;
    internal List<SurveyorRow> SurveyorRowsInternal => _surveyorRows;
    internal List<string> DiagnosticsInternal => _diagnostics;
    internal string ResponsiveModeCurrent => _responsiveMode;
    internal void ForceLayout(double width, double height)
    {
        Width = width; Height = height;
        UpdateLayout();
        Thread.Sleep(120);
        _responsiveMode = "";
        UpdateResponsiveLayout();
    }
    internal void RunVisibleLayerImportForTest() => RunImport(false);
    internal void SetSettingsForTest(ImportSettings settings) => _currentSettings = settings;
    internal ImportSettings GetSettingsForTest() => _currentSettings;
    internal void SetGridSurveyorMode(bool surveyor)
    {
        SurveyorPreviewBox.IsChecked = surveyor;
        UpdateGridView();
    }
    internal void PublishForTest(IReadOnlyList<RoadElement> ordered) => PublishElements(ordered);
}
