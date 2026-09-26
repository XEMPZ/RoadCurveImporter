using System.Globalization;

namespace RoadCurve.Core;

/// <summary>二维点。内部几何一律为 CAD 笛卡尔坐标：X 东、Y 北。</summary>
public readonly struct Point2
{
    public readonly double X;
    public readonly double Y;
    public Point2(double x, double y) { X = x; Y = y; }
    public override string ToString() => string.Create(CultureInfo.InvariantCulture, $"({X:R}, {Y:R})");
}

public static class Geometry
{
    public const double Tau = Math.PI * 2.0;

    public static double Distance(Point2 a, Point2 b)
    {
        double dx = a.X - b.X, dy = a.Y - b.Y;
        return Math.Sqrt(dx * dx + dy * dy);
    }

    /// <summary>数学航向角：东为 0、逆时针为正，弧度。</summary>
    public static double Heading(Point2 a, Point2 b) => NormalizeAngle(Math.Atan2(b.Y - a.Y, b.X - a.X));

    public static double NormalizeAngle(double angle)
    {
        double v = angle % Tau;
        if (v < 0) v += Tau;
        return v;
    }

    public static double ToDegrees(double rad) => rad * 180.0 / Math.PI;
    public static double ToRadians(double deg) => deg * Math.PI / 180.0;

    /// <summary>测绘方位角：北为 0、顺时针为正，单位度。</summary>
    public static double ToSurveyAzimuth(double mathHeading) => ToDegrees(NormalizeAngle(Math.PI / 2.0 - mathHeading));

    /// <summary>度 → dd.mmss（含厘秒）字符串，等价 Format-DmsAngle。</summary>
    public static string FormatDmsAngle(double decimalDegrees)
    {
        string sign = decimalDegrees < 0 ? "-" : "";
        long totalCentiseconds = (long)Math.Round(Math.Abs(decimalDegrees) * 360000.0, MidpointRounding.AwayFromZero);
        long degrees = totalCentiseconds / 360000;
        long remainder = totalCentiseconds % 360000;
        long minutes = remainder / 6000;
        remainder %= 6000;
        long seconds = remainder / 100;
        long centiseconds = remainder % 100;
        return string.Create(CultureInfo.InvariantCulture, $"{sign}{degrees}.{minutes:00}{seconds:00}{centiseconds:00}");
    }

    /// <summary>测绘 dd.mmss：对 360 取模，360.000000 归一为 0.000000。</summary>
    public static string FormatSurveyorDms(double decimalDegrees)
    {
        double azimuth = decimalDegrees % 360.0;
        if (azimuth < 0) azimuth += 360.0;
        string packed = FormatDmsAngle(azimuth);
        return packed == "360.000000" ? "0.000000" : packed;
    }

    public static double GetSurveyorDmsNumber(double decimalDegrees)
        => double.Parse(FormatSurveyorDms(decimalDegrees), CultureInfo.InvariantCulture);

    /// <summary>dd.mmss → 度，等价 Convert-SurveyorDmsToDegrees。</summary>
    public static double ConvertSurveyorDmsToDegrees(double packedValue)
    {
        double sign = packedValue < 0 ? -1.0 : 1.0;
        double absolute = Math.Abs(packedValue);
        double degrees = Math.Floor(absolute);
        long packed = (long)Math.Round((absolute - degrees) * 1000000.0, MidpointRounding.AwayFromZero);
        if (packed >= 1000000) { degrees++; packed = 0; }
        long minutes = packed / 10000;
        long remainder = packed % 10000;
        long seconds = remainder / 100;
        long centiseconds = remainder % 100;
        if (minutes > 59 || seconds > 59)
            throw new FormatException(string.Create(CultureInfo.InvariantCulture, $"无效的 dd.mmss 方位角：{packedValue}"));
        return sign * (degrees + minutes / 60.0 + seconds / 3600.0 + centiseconds / 360000.0);
    }

    /// <summary>桩号格式化，等价 Format-Station。</summary>
    public static string FormatStation(double station, string prefix, int digits)
    {
        string sign = station < 0 ? "-" : "";
        double abs = Math.Abs(station);
        double km = Math.Floor(abs / 1000.0);
        double m = abs - km * 1000.0;
        string pattern = digits > 0 ? "0." + new string('0', digits) : "0";
        m = Math.Round(m, digits);
        if (m >= 1000) { km++; m = 0; }
        return string.Create(CultureInfo.InvariantCulture, $"{sign}{prefix}{km}+{m.ToString(pattern, CultureInfo.InvariantCulture)}");
    }
}
