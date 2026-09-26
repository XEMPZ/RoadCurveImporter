namespace RoadCurve.Core;

public static class ElementFactory
{
    public static RoadElement? NewLine(Point2 start, Point2 end, string handle, string source, int segment, double toleranceM)
    {
        double length = Geometry.Distance(start, end);
        if (length < toleranceM) return null;
        double heading = Geometry.Heading(start, end);
        return new RoadElement
        {
            Kind = "直线",
            Classification = "直线",
            Start = start,
            End = end,
            StartRadius = 0,
            EndRadius = 0,
            Sweep = 0,
            Length = length,
            StartHeading = heading,
            EndHeading = heading,
            Handle = handle,
            Source = source,
            Segment = segment
        };
    }

    public static RoadElement? NewArc(Point2 start, Point2 end, Point2 center, double radius, double sweep,
        string handle, string source, int segment, double toleranceM)
    {
        double chord = Geometry.Distance(start, end);
        if (chord < toleranceM || radius <= 0 || Math.Abs(sweep) < 1e-12) return null;
        double chordHeading = Geometry.Heading(start, end);
        double signedRadius = Math.Sign(sweep) * radius;
        return new RoadElement
        {
            Kind = "圆曲线",
            Classification = "圆弧",
            Start = start,
            End = end,
            Center = center,
            Radius = signedRadius,
            StartRadius = -signedRadius,
            EndRadius = -signedRadius,
            Sweep = sweep,
            Length = Math.Abs(radius * sweep),
            StartHeading = Geometry.NormalizeAngle(chordHeading - sweep / 2.0),
            EndHeading = Geometry.NormalizeAngle(chordHeading + sweep / 2.0),
            Handle = handle,
            Source = source,
            Segment = segment
        };
    }

    public static RoadElement? NewBulge(Point2 start, Point2 end, double bulge,
        string handle, string source, int segment, double toleranceM)
    {
        double chord = Geometry.Distance(start, end);
        if (chord < toleranceM) return null;
        if (Math.Abs(bulge) < 1e-12)
            return NewLine(start, end, handle, source, segment, toleranceM);
        double sweep = 4.0 * Math.Atan(bulge);
        double sinHalf = Math.Sin(sweep / 2.0);
        if (Math.Abs(sinHalf) < 1e-12) return null;
        double radius = Math.Abs(chord / (2.0 * sinHalf));
        Point2 mid = new((start.X + end.X) / 2.0, (start.Y + end.Y) / 2.0);
        double dx = end.X - start.X, dy = end.Y - start.Y;
        Point2 leftNormal = new(-dy / chord, dx / chord);
        double offset = chord / (2.0 * Math.Tan(sweep / 2.0));
        Point2 center = new(mid.X + leftNormal.X * offset, mid.Y + leftNormal.Y * offset);
        return NewArc(start, end, center, radius, sweep, handle, source, segment, toleranceM);
    }

    public static RoadElement Reverse(RoadElement e)
    {
        List<Point2>? vertices = null;
        if (e.Vertices != null)
        {
            vertices = new List<Point2>(e.Vertices.Count);
            for (int i = e.Vertices.Count - 1; i >= 0; i--) vertices.Add(e.Vertices[i]);
        }
        return new RoadElement
        {
            Kind = e.Kind,
            Classification = e.Classification,
            Start = e.End,
            End = e.Start,
            Center = e.Center,
            Radius = e.Radius.HasValue ? -e.Radius.Value : null,
            StartRadius = -e.EndRadius,
            EndRadius = -e.StartRadius,
            Sweep = -e.Sweep,
            Length = e.Length,
            StartHeading = Geometry.NormalizeAngle(e.EndHeading + Math.PI),
            EndHeading = Geometry.NormalizeAngle(e.StartHeading + Math.PI),
            Handle = e.Handle,
            Source = e.Source,
            Segment = e.Segment,
            Vertices = vertices,
            Reversed = !e.Reversed,
            IsGapFill = e.IsGapFill,
            Note = e.Note
        };
    }

    public static RoadElement NewGapFill(Point2 start, Point2 end, RoadElement from, RoadElement to,
        double distance, double connectionToleranceM)
    {
        double heading = Geometry.Heading(start, end);
        string note = $"端点容差填充：{from.Source}:{from.Handle}/{from.Segment} → {to.Source}:{to.Handle}/{to.Segment}，间隙 {distance * 1000.0:F3} mm（配置容差 ≤ {connectionToleranceM * 1000.0:F3} mm）。";
        return new RoadElement
        {
            Kind = "填充直线",
            Classification = "端点容差填充线",
            Start = start,
            End = end,
            StartRadius = 0,
            EndRadius = 0,
            Sweep = 0,
            Length = distance,
            StartHeading = heading,
            EndHeading = heading,
            Handle = $"FILL_{from.Handle}_{from.Segment}_{to.Handle}",
            Source = "端点容差填充",
            Segment = 0,
            IsGapFill = true,
            Note = note
        };
    }

    public static RoadElement NewSpiral(SpiralCandidate candidate, string handle, string source)
    {
        var copies = new List<Point2>(candidate.Vertices.Count);
        foreach (var p in candidate.Vertices) copies.Add(p);
        string modeText = candidate.FitMode == SpiralMode.Strict ? "严格 0.5 mm" : $"宽松 {candidate.FitToleranceM * 1000.0:F3} mm";
        return new RoadElement
        {
            Kind = "缓和曲线",
            Classification = $"欧拉回旋线：{modeText} 验收；曲率—弧长回归 R²={candidate.R2:F6}；最大拟合偏差 {candidate.FitMaxResidualM * 1000.0:F3} mm",
            Start = candidate.Vertices[0],
            End = candidate.Vertices[^1],
            StartRadius = GetSurveySignedRadius(candidate.StartCurvature),
            EndRadius = GetSurveySignedRadius(candidate.EndCurvature),
            Length = candidate.Length,
            StartHeading = Geometry.NormalizeAngle(candidate.StartHeading),
            EndHeading = Geometry.NormalizeAngle(candidate.EndHeading),
            Handle = handle,
            Source = source,
            Segment = 0,
            Vertices = copies
        };
    }

    public static RoadElement? NewDiscreteCurve(List<Point2> points, string handle, string source, double toleranceM)
    {
        if (points.Count < 2) return null;
        double length = 0.0;
        var headings = new List<double>(points.Count - 1);
        for (int i = 0; i < points.Count - 1; i++)
        {
            double seg = Geometry.Distance(points[i], points[i + 1]);
            if (seg >= toleranceM) { length += seg; headings.Add(Geometry.Heading(points[i], points[i + 1])); }
        }
        if (length < toleranceM || headings.Count < 1) return null;
        string classification = "原始离散曲线（未可靠判别：可能为椭圆弧、样条或自由曲线）";
        if (headings.Count >= 8)
        {
            var turns = new List<double>(headings.Count - 1);
            for (int i = 1; i < headings.Count; i++)
            {
                double d = Geometry.NormalizeAngle(headings[i] - headings[i - 1]);
                if (d > Math.PI) d -= Geometry.Tau;
                turns.Add(d);
            }
            int positive = turns.Count(t => t > 1e-10);
            int negative = turns.Count(t => t < -1e-10);
            if ((positive == 0 || negative == 0) && (positive + negative >= 6))
                classification = "原始离散曲线（曲率单向渐变候选；仍保留原始点，未转换为缓和曲线）";
        }
        var copies = new List<Point2>(points.Count);
        foreach (var p in points) copies.Add(p);
        return new RoadElement
        {
            Kind = "原始离散曲线",
            Classification = classification,
            Start = points[0],
            End = points[^1],
            StartRadius = 0,
            EndRadius = 0,
            Sweep = 0,
            Length = length,
            StartHeading = headings[0],
            EndHeading = headings[^1],
            Handle = handle,
            Source = source,
            Segment = 0,
            Vertices = copies
        };
    }

    public static double GetSurveySignedRadius(double curvature)
        => Math.Abs(curvature) < 1e-4 ? 0.0 : -1.0 / curvature;
}

public class SpiralCandidate
{
    public double Length { get; set; }
    public double StartHeading { get; set; }
    public double EndHeading { get; set; }
    public double StartCurvature { get; set; }
    public double EndCurvature { get; set; }
    public double Slope { get; set; }
    public double R2 { get; set; }
    public double FitMaxResidualM { get; set; }
    public double FitToleranceM { get; set; }
    public SpiralMode FitMode { get; set; }
    public List<Point2> Vertices { get; set; } = new();
}
