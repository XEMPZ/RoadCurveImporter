using RoadCurve.Core;
using Xunit;

namespace RoadCurve.Tests;

public class GeometryTests
{
    [Fact]
    public void SurveyorDms_ExampleVector()
    {
        Assert.Equal("46.544076", Geometry.FormatSurveyorDms(46.911323));
        Assert.Equal(46.544076, Geometry.GetSurveyorDmsNumber(46.911323), 10);
    }

    [Fact]
    public void SurveyorDms_CarryToZero()
    {
        Assert.Equal("0.000000", Geometry.FormatSurveyorDms(359.999999));
    }

    [Fact]
    public void SurveyorDms_RoundTrip()
    {
        double packed = Geometry.GetSurveyorDmsNumber(46.911323);
        double decoded = Geometry.ConvertSurveyorDmsToDegrees(packed);
        Assert.True(Math.Abs(decoded - 46.911323) <= 0.0000015);
    }

    [Fact]
    public void SurveyorDms_InvalidThrows()
    {
        Assert.Throws<FormatException>(() => Geometry.ConvertSurveyorDmsToDegrees(12.999999));
    }

    [Fact]
    public void SurveyAzimuth_NorthZeroClockwise()
    {
        // 数学航向 π/2（正北）→ 测绘方位角 0；数学航向 0（正东）→ 方位角 90
        Assert.Equal(0.0, Geometry.ToSurveyAzimuth(Math.PI / 2), 12);
        Assert.Equal(90.0, Geometry.ToSurveyAzimuth(0.0), 12);
    }

    [Fact]
    public void FormatStation_Vectors()
    {
        Assert.Equal("K1+234.567", Geometry.FormatStation(1234.567, "K", 3));
        Assert.Equal("K0+0.000", Geometry.FormatStation(0.0, "K", 3)); // 与 PS ToString('0.000') 行为一致
    }
}
