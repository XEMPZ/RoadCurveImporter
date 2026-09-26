namespace RoadCurve.Core;

/// <summary>
/// 等价 Get-SpiralDxfVertices：DXF 无回旋线实体，按已验收的欧拉模型生成加密折线。
/// 最大段长 0.25 m、最多 2000 段；端点残差按弧长比例平滑分配，首末端点保持 CAD 原值。
/// </summary>
public static class SpiralDensifier
{
    public const double MaximumSegmentM = 0.25;
    public const int MaxSegments = 2000;

    public static List<Point2> Densify(RoadElement e, List<string>? diagnostics = null)
    {
        var existing = new List<Point2>();
        if (e.Vertices != null) existing.AddRange(e.Vertices);
        double length = Math.Max(0.0, e.Length);
        if (length < 1e-9) return existing;

        int segments = Math.Max(2, Math.Min(MaxSegments, (int)Math.Ceiling(length / MaximumSegmentM)));
        var generated = new List<Point2>(segments + 1);
        double x = e.Start.X, y = e.Start.Y;
        double heading = e.StartHeading;
        double k0 = Math.Abs(e.StartRadius) < 1e-12 ? 0.0 : -1.0 / e.StartRadius;
        double k1 = Math.Abs(e.EndRadius) < 1e-12 ? 0.0 : -1.0 / e.EndRadius;
        double ds = length / segments;
        generated.Add(new Point2(x, y));
        for (int i = 0; i < segments; i++)
        {
            double s = (i + 0.5) * ds;
            double a = heading + k0 * s + 0.5 * (k1 - k0) * s * s / length;
            x += ds * Math.Cos(a);
            y += ds * Math.Sin(a);
            generated.Add(new Point2(x, y));
        }
        // 将拟合端点与 CAD 源端点的小残差按弧长比例平滑分配。
        double endDeltaX = e.End.X - generated[^1].X;
        double endDeltaY = e.End.Y - generated[^1].Y;
        for (int i = 1; i < generated.Count; i++)
        {
            double ratio = (double)i / segments;
            generated[i] = new Point2(generated[i].X + ratio * endDeltaX, generated[i].Y + ratio * endDeltaY);
        }
        generated[^1] = e.End;
        diagnostics?.Add($"DXF：缓和曲线 {e.Handle} 已按欧拉拟合模型生成 {generated.Count} 个加密折线顶点（最大步长 {MaximumSegmentM:F2} m，CAD 端点闭合）。");
        return generated;
    }
}
