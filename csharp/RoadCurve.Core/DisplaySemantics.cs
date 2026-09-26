namespace RoadCurve.Core;

/// <summary>
/// 显示/导出语义：XY 交换与曲线反向只影响表格、预览和 Excel，不污染内部 CAD 原始几何与 DXF。
/// </summary>
public static class DisplaySemantics
{
    public static bool IsCurveElement(RoadElement e) => !e.IsGapFill && e.Kind != "直线";

    public static Point2 GetOutputPoint(Point2 p, bool swapCadXY)
        => swapCadXY ? new Point2(p.Y, p.X) : p;

    public static double GetCurveChordHeading(RoadElement e) => Geometry.Heading(e.Start, e.End);

    public static double GetDisplayHeading(RoadElement e, bool isStart, bool reverseCurveDirection)
    {
        double heading = isStart ? e.StartHeading : e.EndHeading;
        if (reverseCurveDirection && IsCurveElement(e))
        {
            double chord = GetCurveChordHeading(e);
            return Geometry.NormalizeAngle(2.0 * chord - heading);
        }
        return Geometry.NormalizeAngle(heading);
    }

    public static double GetDisplaySweep(RoadElement e, bool reverseCurveDirection)
        => reverseCurveDirection && IsCurveElement(e) ? -e.Sweep : e.Sweep;

    public static double GetDisplayRadius(RoadElement e, double radius, bool reverseCurveDirection)
        => reverseCurveDirection && IsCurveElement(e) ? -radius : radius;

    /// <summary>把曲线上的点按弦方向做镜像（仅反向显示用）。</summary>
    public static Point2 GetCurveDisplayPoint(RoadElement e, Point2 point, bool reverseCurveDirection)
    {
        if (!(reverseCurveDirection && IsCurveElement(e))) return point;
        Point2 origin = e.Start;
        double chord = GetCurveChordHeading(e);
        double ux = Math.Cos(chord), uy = Math.Sin(chord);
        double dx = point.X - origin.X, dy = point.Y - origin.Y;
        double projection = dx * ux + dy * uy;
        return new Point2(origin.X + (2.0 * projection * ux - dx), origin.Y + (2.0 * projection * uy - dy));
    }
}
