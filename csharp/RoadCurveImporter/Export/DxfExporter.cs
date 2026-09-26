using System.IO;
using netDxf;
using netDxf.Entities;
using netDxf.Header;
using netDxf.Tables;
using RoadCurve.Core;

namespace RoadCurveImporter.Export;

/// <summary>
/// 等价 Invoke-StandardDxfWriter + Get-SpiralDxfVertices。
/// 使用 netDxf 写 AC1015/R2000 完整容器，然后后处理加入 dxflib 兼容补丁。
/// </summary>
public static class DxfExporter
{
    public sealed class Result
    {
        public string TargetPath = "";
        public string DxfVersion = "";
        public int SpiralCount;
        public int DiscreteCount;
    }

    public static Result Write(string targetPath, IReadOnlyList<RoadElement> elements, List<string> diagnostics)
    {
        var doc = new DxfDocument(DxfVersion.AutoCad2000);
        doc.DrawingVariables.InsUnits = netDxf.Units.DrawingUnits.Meters;

        var layerColors = new Dictionary<string, short>
        {
            ["ROAD_CURVE"] = 7,
            ["ROAD_GAP_FILL"] = 30,
            ["ROAD_SPIRAL_POLYLINE"] = 5,
            ["ROAD_DISCRETE_POLYLINE"] = 6
        };
        foreach (var kv in layerColors)
        {
            if (doc.Layers.Contains(kv.Key)) continue;
            doc.Layers.Add(new Layer(kv.Key) { Color = new AciColor(kv.Value) });
        }

        int spiralCount = 0, discreteCount = 0;
        foreach (var e in elements)
        {
            if (e.Kind == "直线" || e.IsGapFill)
            {
                string layer = e.IsGapFill ? "ROAD_GAP_FILL" : "ROAD_CURVE";
                doc.Entities.Add(new Line(
                    new Vector2(e.Start.X, e.Start.Y),
                    new Vector2(e.End.X, e.End.Y)) { Layer = doc.Layers[layer] });
            }
            else if (e.Kind == "圆曲线")
            {
                if (!e.Center.HasValue || !e.Radius.HasValue) continue;
                double startAngle = Geometry.ToDegrees(Math.Atan2(e.Start.Y - e.Center.Value.Y, e.Start.X - e.Center.Value.X));
                double endAngle = startAngle + Geometry.ToDegrees(e.Sweep);
                if (e.Sweep < 0) (startAngle, endAngle) = (endAngle, startAngle);
                doc.Entities.Add(new Arc(
                    new Vector2(e.Center.Value.X, e.Center.Value.Y),
                    Math.Abs(e.Radius.Value),
                    startAngle, endAngle) { Layer = doc.Layers["ROAD_CURVE"] });
            }
            else
            {
                bool spiral = e.Kind == "缓和曲线";
                string layerName = spiral ? "ROAD_SPIRAL_POLYLINE" : "ROAD_DISCRETE_POLYLINE";
                List<Point2> vertices = spiral
                    ? SpiralDensifier.Densify(e, diagnostics)
                    : e.Vertices ?? new List<Point2> { e.Start, e.End };
                if (vertices.Count < 2) continue;
                var poly = new Polyline2D(vertices.Select(v => new Vector2(v.X, v.Y)), isClosed: false)
                {
                    Layer = doc.Layers[layerName],
                    // ACI 6（品红）；真彩色 420/16711935 由下方 dxflib 兼容补丁写入
                    Color = new AciColor(6),
                    LinetypeScale = 1.0
                };
                doc.Entities.Add(poly);
                if (spiral) spiralCount++; else discreteCount++;
            }
        }

        doc.Save(targetPath);
        ApplyDxflibPatch(targetPath);
        return new Result
        {
            TargetPath = targetPath,
            DxfVersion = "AC1015",
            SpiralCount = spiralCount,
            DiscreteCount = discreteCount
        };
    }

    /// <summary>
    /// 等价 apply_dxflib_polyline_compatibility：
    /// ROAD_SPIRAL_POLYLINE 的 LWPOLYLINE 中：62 后补 420/16711935；370 后补 48/1.0；每个 20 后补 30/0.0。
    /// 与原 Python 一致使用 cp1252。
    /// </summary>
    private static void ApplyDxflibPatch(string targetPath)
    {
        System.Text.Encoding.RegisterProvider(System.Text.CodePagesEncodingProvider.Instance);
        var cp1252 = System.Text.Encoding.GetEncoding(1252);
        var lines = new List<string>(File.ReadAllLines(targetPath, cp1252));
        var output = new List<string>(lines.Count + 4096);
        bool inLwpolyline = false;
        string layer = "";
        int index = 0;
        while (index + 1 < lines.Count)
        {
            string code = lines[index];
            string value = lines[index + 1];
            string strippedCode = code.Trim();
            string strippedValue = value.Trim();
            if (strippedCode == "0")
            {
                inLwpolyline = strippedValue == "LWPOLYLINE";
                layer = "";
            }
            if (inLwpolyline && strippedCode == "8") layer = strippedValue;
            output.Add(code);
            output.Add(value);
            if (inLwpolyline && layer == "ROAD_SPIRAL_POLYLINE")
            {
                if (strippedCode == "62") { output.Add("420"); output.Add("16711935"); }
                else if (strippedCode == "370") { output.Add(" 48"); output.Add("1.0"); }
                else if (strippedCode == "20") { output.Add(" 30"); output.Add("0.0"); }
            }
            index += 2;
        }
        if (index < lines.Count) output.Add(lines[index]);
        File.WriteAllText(targetPath, string.Join("\n", output) + "\n", cp1252);
    }
}
