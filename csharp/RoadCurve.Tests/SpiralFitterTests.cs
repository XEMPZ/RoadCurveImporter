using Newtonsoft.Json.Linq;
using RoadCurve.Core;
using Xunit;

namespace RoadCurve.Tests;

public class SpiralFitterTests
{
    /// <summary>合成回旋线 roundtrip：用已知参数生成采样点，再拟合回收参数。</summary>
    [Fact]
    public void SyntheticClothoid_RoundTrip()
    {
        double theta0 = 0.3, k0 = 0.001, k1 = 0.004, length = 120.0;
        int n = 161;
        var stations = new double[n];
        for (int i = 0; i < n; i++) stations[i] = length * i / (n - 1);
        var model = SpiralFitter.Integrate(theta0, k0, k1, length, stations, stepsPerM: 160);
        double ox = 1000.0, oy = 2000.0;
        var points = model.Select(p => new Point2(p.X + ox, p.Y + oy)).ToList();

        var fit = SpiralFitter.Fit(points, tolerance: 0.0005);
        Assert.True(fit.Success, $"LM 未收敛：{fit.Message}");
        Assert.True(fit.StrictPass, $"严格验收未通过：max={fit.MaxVertexErrorM * 1000:F4} mm");
        Assert.Equal(length, fit.LengthM, 3);
        Assert.Equal(theta0, fit.StartHeadingRad, 6);
        Assert.Equal(-1.0 / k0, fit.StartRadiusM, 1);
        Assert.Equal(-1.0 / k1, fit.EndRadiusM, 1);
    }

    /// <summary>直线（k0=k1≈0）不应误判：曲率全零 → one_direction 失败 → strict_pass=false。</summary>
    [Fact]
    public void StraightLine_NotAccepted()
    {
        var points = new List<Point2>();
        for (int i = 0; i <= 100; i++) points.Add(new Point2(i * 2.0, 0.0));
        var fit = SpiralFitter.Fit(points, tolerance: 0.0005);
        Assert.False(fit.StrictPass);
    }

    /// <summary>
    /// P1 关键验收：16 条真实高节点回旋线，严格 0.5 mm 全部通过。
    /// 原版最大顶点残差 0.017485 mm。
    /// </summary>
    [Fact]
    public void Regression_SixteenRealSpirals_AllStrictPass()
    {
        string path = Path.Combine(AppContext.BaseDirectory, "Data", "high_vertex_polyline_inspection.json");
        var array = JArray.Parse(File.ReadAllText(path));
        Assert.Equal(16, array.Count);

        double worstMm = 0;
        foreach (var item in array)
        {
            var points = item["Points"]!.Select(p => new Point2((double)p["X"]!, (double)p["Y"]!)).ToList();
            Assert.True(points.Count >= 20);
            Assert.Equal(0, (int)item["NonzeroBulges"]!);
            Assert.False((bool)item["Closed"]!);

            var fit = SpiralFitter.Fit(points, tolerance: 0.0005);
            double errMm = fit.MaxVertexErrorM * 1000.0;
            worstMm = Math.Max(worstMm, errMm);
            Assert.True(fit.StrictPass,
                $"句柄 {item["Handle"]} 未通过严格验收：max={errMm:F4} mm, success={fit.Success}, msg={fit.Message}");
        }
        // 与原版同等量级（< 0.1 mm，远低于 0.5 mm 限值）
        Assert.True(worstMm < 0.1, $"最大残差 {worstMm:F4} mm 超出原版量级");
    }
}
