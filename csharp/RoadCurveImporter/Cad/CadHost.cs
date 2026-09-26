using System.Runtime.InteropServices;
using RoadCurve.Core;

namespace RoadCurveImporter.Cad;

/// <summary>
/// CAD 只读适配层。安全边界：仅自动化读取，不调用任何保存/修改/关闭图形接口。
/// AutoCAD 只读 PickfirstSelectionSet（绝不 SelectOnScreen）；ZWCAD 临时选择集必须在 finally 删除。
/// </summary>
public static class CadHost
{
    // ---------------------------------------------------------------- ROT
    [DllImport("ole32.dll", CharSet = CharSet.Unicode)]
    private static extern int CLSIDFromProgID([MarshalAs(UnmanagedType.LPWStr)] string progId, out Guid clsid);

    [DllImport("oleaut32.dll")]
    private static extern int GetActiveObject(ref Guid clsid, IntPtr reserved, [MarshalAs(UnmanagedType.IUnknown)] out object? ppunk);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    private const uint WM_MDIGETACTIVE = 0x0629;

    public static object? GetActiveComApplication(string progId)
    {
        if (CLSIDFromProgID(progId, out var clsid) != 0) return null;
        try
        {
            GetActiveObject(ref clsid, IntPtr.Zero, out var obj);
            return obj;
        }
        catch { return null; }
    }

    public sealed class CadConnection
    {
        public string Name = "";
        public string ProgId = "";
        public string Version = "";
        public dynamic Application = null!;
    }

    /// <summary>mode：0=自动（优先 ZWCAD），1=ZWCAD，2=AutoCAD。等价 Get-RunningCadApplication。</summary>
    public static CadConnection GetRunningCadApplication(int mode)
    {
        var zw = (Name: "SouthMap/ZWCAD", ProgIds: new[] { "ZWCAD.Application.2026", "ZWCAD.Application" });
        var ac = (Name: "Autodesk AutoCAD", ProgIds: new[] { "AutoCAD.Application", "AutoCAD.Application.25", "AutoCAD.Application.24", "AutoCAD.Application.23", "AutoCAD.Application.22", "AutoCAD.Application.21", "AutoCAD.Application.20", "AutoCAD.Application.19", "AutoCAD.Application.18", "AutoCAD.Application.17" });
        var candidates = mode switch
        {
            1 => new[] { zw },
            2 => new[] { ac },
            _ => new[] { zw, ac }
        };
        foreach (var candidate in candidates)
        foreach (var progId in candidate.ProgIds)
        {
            var app = GetActiveComApplication(progId);
            if (app == null) continue;
            string version = "";
            try { version = Convert.ToString(((dynamic)app).Version) ?? ""; } catch { }
            return new CadConnection { Name = candidate.Name, ProgId = progId, Version = version, Application = (dynamic)app };
        }
        throw new InvalidOperationException("没有找到所选 CAD 的活动 COM 会话。请启动完整 Windows 版 AutoCAD 或 SouthMap/ZWCAD，并确认其与本程序处于相同权限级别。");
    }

    private static IntPtr ToHandle(object? value)
    {
        if (value == null) return IntPtr.Zero;
        try
        {
            long v = Convert.ToInt64(value);
            return new IntPtr(v);
        }
        catch { return IntPtr.Zero; }
    }

    /// <summary>MDI 活动子窗口探测，等价 Get-ActiveCadDocument。</summary>
    public static dynamic GetActiveCadDocument(dynamic app, List<string> diagnostics)
    {
        dynamic? active = null;
        try { active = app.ActiveDocument; } catch { }
        IntPtr activeChild = IntPtr.Zero;
        try
        {
            IntPtr main = ToHandle(app.HWND);
            if (main != IntPtr.Zero) activeChild = SendMessageW(main, WM_MDIGETACTIVE, IntPtr.Zero, IntPtr.Zero);
        }
        catch { }
        if (activeChild != IntPtr.Zero)
        {
            foreach (var docObj in app.Documents)
            {
                dynamic doc = docObj;
                var handles = new List<IntPtr>();
                try { handles.Add(ToHandle(doc.HWND)); } catch { }
                try { foreach (var win in doc.Windows) handles.Add(ToHandle(win.HWND)); } catch { }
                if (handles.Contains(activeChild))
                {
                    if (active != null)
                    {
                        try
                        {
                            string docName = Convert.ToString(doc.Name) ?? "";
                            string activeName = Convert.ToString(active.Name) ?? "";
                            if (docName != activeName)
                                diagnostics.Add($"COM ActiveDocument 报告“{activeName}”，但 CAD 当前标签窗口为“{docName}”；已按当前标签读取。");
                        }
                        catch { }
                    }
                    return doc;
                }
            }
        }
        if (active != null) return active;
        throw new InvalidOperationException("无法确定 CAD 当前活动标签页；请单击目标标签后重试。");
    }

    public static bool IsSupportedRoadEntity(dynamic entity)
    {
        try
        {
            string name = Convert.ToString(entity.ObjectName) ?? "";
            return System.Text.RegularExpressions.Regex.IsMatch(name, @"^(AcDbLine|Line)$|Arc$|Polyline$");
        }
        catch { return false; }
    }

    public static HashSet<string> GetVisibleLayerNames(dynamic doc)
    {
        var visible = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var layerObj in doc.Layers)
        {
            try
            {
                dynamic layer = layerObj;
                bool layerOn = layer.LayerOn;
                bool frozen = layer.Freeze;
                bool vpFrozen = false;
                try { vpFrozen = layer.VPFreeze; } catch { }
                if (layerOn && !frozen && !vpFrozen)
                    visible.Add(Convert.ToString(layer.Name) ?? "");
            }
            catch { }
        }
        return visible;
    }

    // ------------------------------------------------------------ 实体转换

    private static Point2 ToPoint2(object? value)
    {
        var v = ToDoubleList(value);
        if (v.Count < 2) throw new InvalidOperationException("CAD 点坐标不完整。");
        return new Point2(v[0], v[1]);
    }

    private static List<double> ToDoubleList(object? value)
    {
        var result = new List<double>();
        if (value is Array arr)
            foreach (var item in arr) result.Add(Convert.ToDouble(item));
        else if (value is IEnumerable<double> ds)
            result.AddRange(ds);
        else if (value is System.Collections.IEnumerable en)
            foreach (var item in en) result.Add(Convert.ToDouble(item));
        return result;
    }

    /// <summary>等价 Convert-CadEntity。trySpiral 返回欧拉候选（未通过返回 null）。</summary>
    public static List<RoadElement> ConvertCadEntity(dynamic entity, ImportSettings settings, List<string> diagnostics, Func<List<Point2>, SpiralCandidate?> trySpiral)
    {
        string name = Convert.ToString(entity.ObjectName) ?? "";
        string handle = Convert.ToString(entity.Handle) ?? "";
        double tol = settings.ToleranceM;
        var output = new List<RoadElement>();

        if (name is "AcDbLine" or "Line")
        {
            var e = ElementFactory.NewLine(ToPoint2(entity.StartPoint), ToPoint2(entity.EndPoint), handle, name, 0, tol);
            if (e == null) diagnostics.Add($"忽略近零长度线段：{handle}");
            else output.Add(e);
            return output;
        }
        if (name.EndsWith("Arc"))
        {
            var start = ToPoint2(entity.StartPoint);
            var end = ToPoint2(entity.EndPoint);
            var center = ToPoint2(entity.Center);
            double sweep = Convert.ToDouble(entity.EndAngle) - Convert.ToDouble(entity.StartAngle);
            while (sweep <= 0) sweep += Geometry.Tau;
            var e = ElementFactory.NewArc(start, end, center, Convert.ToDouble(entity.Radius), sweep, handle, name, 0, tol);
            if (e == null) diagnostics.Add($"忽略无效圆弧：{handle}");
            else output.Add(e);
            return output;
        }
        if (name.EndsWith("Polyline"))
        {
            var raw = ToDoubleList(entity.Coordinates);
            if (raw.Count % 2 != 0) throw new InvalidOperationException("CAD 坐标数组不是二维坐标对。");
            var points = new List<Point2>(raw.Count / 2);
            for (int i = 0; i < raw.Count; i += 2) points.Add(new Point2(raw[i], raw[i + 1]));
            bool closed = entity.Closed;
            int count = closed ? points.Count : points.Count - 1;
            bool hasBulge = false;
            for (int b = 0; b < count; b++)
            {
                try { if (Math.Abs(Convert.ToDouble(entity.GetBulge(b))) > 1e-12) { hasBulge = true; break; } } catch { }
            }
            if (!closed && !hasBulge && points.Count >= 20)
            {
                var spiral = settings.Spiral != SpiralMode.Off ? trySpiral(points) : null;
                if (spiral != null)
                {
                    string modeText = spiral.FitMode == SpiralMode.Strict ? "严格 0.5 mm" : $"宽松 {spiral.FitToleranceM * 1000.0:F3} mm";
                    diagnostics.Add($"已识别欧拉回旋线：{handle}，{modeText} 验收通过，最大拟合偏差 {spiral.FitMaxResidualM * 1000.0:F3} mm；作为单一线元导入。");
                    output.Add(ElementFactory.NewSpiral(spiral, handle, name));
                    return output;
                }
                string reason = settings.Spiral == SpiralMode.Off ? "未启用缓和曲线识别" : "未通过所选欧拉回旋线验收";
                diagnostics.Add($"高节点折线 {handle} {reason}，按原始 {points.Count - 1} 条直线段保真输入。");
                for (int i = 0; i < points.Count - 1; i++)
                {
                    var line = ElementFactory.NewLine(points[i], points[i + 1], handle, name, i, tol);
                    if (line != null) output.Add(line);
                }
                return output;
            }
            for (int i = 0; i < count; i++)
            {
                double bulge = 0.0;
                try { bulge = Convert.ToDouble(entity.GetBulge(i)); } catch { }
                var part = ElementFactory.NewBulge(points[i], points[(i + 1) % points.Count], bulge, handle, name, i, tol);
                if (part != null) output.Add(part);
            }
            return output;
        }
        diagnostics.Add($"忽略不支持的实体 {name}（句柄 {handle}）");
        return output;
    }
}
