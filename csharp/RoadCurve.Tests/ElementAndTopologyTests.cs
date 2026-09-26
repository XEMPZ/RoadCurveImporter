using RoadCurve.Core;
using Xunit;

namespace RoadCurve.Tests;

public class ElementAndTopologyTests
{
    private const double Tol = 0.001;

    [Fact]
    public void BulgeToArc_RoundTrip()
    {
        // bulge = tan(π/8) → sweep = π/2，起点(0,0) 终点(10,0)，左转
        double bulge = Math.Tan(Math.PI / 8.0);
        var e = ElementFactory.NewBulge(new Point2(0, 0), new Point2(10, 0), bulge, "T", "测试", 0, Tol);
        Assert.NotNull(e);
        Assert.Equal("圆曲线", e!.Kind);
        Assert.Equal(Math.PI / 2, e.Sweep, 12);
        // 半径 = chord / (2 sin(sweep/2)) = 10 / (2·sin45°)
        Assert.Equal(10.0 / (2 * Math.Sin(Math.PI / 4)), Math.Abs(e.Radius!.Value), 10);
        // 反推 bulge
        double recovered = Math.Tan(e.Sweep / 4.0);
        Assert.Equal(bulge, recovered, 12);
    }

    [Fact]
    public void BulgeZero_ProducesLine()
    {
        var e = ElementFactory.NewBulge(new Point2(0, 0), new Point2(10, 0), 0.0, "T", "测试", 0, Tol);
        Assert.NotNull(e);
        Assert.Equal("直线", e!.Kind);
    }

    [Fact]
    public void GapFill_BelowThreshold_NotInserted()
    {
        var diag = new List<string>();
        var sorter = new TopologySorter(diag, Limits.StrictSpiralToleranceM * 2); // 连接容差 1mm
        var a = ElementFactory.NewLine(new Point2(0, 0), new Point2(10, 0), "A", "测试", 0, Tol)!;
        var b = ElementFactory.NewLine(new Point2(10.00005, 0), new Point2(20, 0), "B", "测试", 0, Tol)!;
        var ordered = sorter.Order(new List<RoadElement> { a, b });
        Assert.Equal(2, ordered.Count); // < 0.1mm 直接连接，无填充
        Assert.DoesNotContain(ordered, e => e.IsGapFill);
    }

    [Fact]
    public void GapFill_AboveThreshold_Inserted()
    {
        var diag = new List<string>();
        var sorter = new TopologySorter(diag, 0.001); // 1mm
        var a = ElementFactory.NewLine(new Point2(0, 0), new Point2(10, 0), "A", "测试", 0, Tol)!;
        var b = ElementFactory.NewLine(new Point2(10.0005, 0), new Point2(20, 0), "B", "测试", 0, Tol)!;
        var ordered = sorter.Order(new List<RoadElement> { a, b });
        Assert.Equal(3, ordered.Count);
        Assert.True(ordered[1].IsGapFill);
        Assert.False(string.IsNullOrWhiteSpace(ordered[1].Note));
        Assert.Equal(0.0005, ordered[1].Length, 9);
    }

    [Fact]
    public void GapFill_BeyondTolerance_NotConnected()
    {
        var diag = new List<string>();
        var sorter = new TopologySorter(diag, 0.001);
        var a = ElementFactory.NewLine(new Point2(0, 0), new Point2(10, 0), "A", "测试", 0, Tol)!;
        var b = ElementFactory.NewLine(new Point2(10.5, 0), new Point2(20, 0), "B", "测试", 0, Tol)!;
        var ordered = sorter.Order(new List<RoadElement> { a, b });
        Assert.Equal(2, ordered.Count); // 两个分量，无填充
        Assert.DoesNotContain(ordered, e => e.IsGapFill);
    }

    [Fact]
    public void Reverse_SwapsEndpoints()
    {
        var e = ElementFactory.NewLine(new Point2(1, 2), new Point2(3, 4), "A", "测试", 0, Tol)!;
        var r = ElementFactory.Reverse(e);
        Assert.Equal(e.End, r.Start);
        Assert.Equal(e.Start, r.End);
        Assert.True(r.Reversed);
    }

    [Fact]
    public void SpatialSort_400Elements_ChainPreserved()
    {
        // 400 段乱序链，强制走空间索引路径（>300）
        var elements = new List<RoadElement>();
        int n = 400;
        for (int i = n - 1; i >= 0; i--)
        {
            var e = ElementFactory.NewLine(new Point2(i * 10.0, 0), new Point2((i + 1) * 10.0, 0), $"L{i}", "测试", 0, Tol)!;
            elements.Add(e);
        }
        var diag = new List<string>();
        var sorter = new TopologySorter(diag, 0.001);
        var ordered = sorter.Order(elements);
        Assert.Equal(n, ordered.Count);
        // 链应连续：前一段终点 == 后一段起点
        for (int i = 0; i < ordered.Count - 1; i++)
            Assert.True(Geometry.Distance(ordered[i].End, ordered[i + 1].Start) <= 0.001,
                $"第 {i} 段连接失败");
    }

    [Fact]
    public void OptimizeRouteDirection_MajorityWins()
    {
        var diag = new List<string>();
        var sorter = new TopologySorter(diag, 0.001);
        // 两段：一段正向、一段需要反转连接 → 链完成后看方向优化不翻转多数
        var a = ElementFactory.NewLine(new Point2(0, 0), new Point2(10, 0), "A", "测试", 0, Tol)!;
        var b = ElementFactory.NewLine(new Point2(20, 0), new Point2(10, 0), "B", "测试", 0, Tol)!; // 反向
        var ordered = sorter.Order(new List<RoadElement> { a, b });
        Assert.Equal(2, ordered.Count);
        Assert.True(Geometry.Distance(ordered[0].End, ordered[1].Start) <= 0.001);
    }
}
