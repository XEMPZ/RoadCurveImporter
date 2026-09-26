namespace RoadCurve.Core;

/// <summary>每次导入生效的运行设置，等价 PS 的 Get-CurrentSettings 输出。</summary>
public class ImportSettings
{
    public double ToleranceM { get; set; } = 0.001;
    public double PrecisionMm { get; set; } = 1.0;
    public int Digits { get; set; } = 3;
    public string Prefix { get; set; } = "K";
    public int StartPosition { get; set; } = 1;
    public double StartStation { get; set; } = 0.0;
    public SpiralMode Spiral { get; set; } = SpiralMode.Strict;
    public double SpiralFitToleranceM { get; set; } = 0.0005;
    public bool SwapCadXY { get; set; } = true;
    public bool ReverseCurveDirection { get; set; }

    public static int DigitsFromPrecisionMm(double precisionMm)
        => Math.Max(0, (int)Math.Ceiling(-Math.Log10(precisionMm / 1000.0)));
}

public enum SpiralMode { Off, Strict, Loose }

/// <summary>全局常量，等价 PS 脚本级变量。</summary>
public static class Limits
{
    public const int MaxCandidateSegments = 5000;
    public const double MinGapFillM = 0.0001;      // ≥0.1 mm 才写填充线
    public const int MaxSpiralFitCandidates = 24;
    public const int MaxSpiralFitVertices = 600;
    public const double MaxSpiralFitDurationSeconds = 5;
    public const int MaxPreviewElementShapes = 1600;
    public const int MaxPreviewVerticesPerCurve = 900;
    public const double StrictSpiralToleranceM = 0.0005;
    public const int SpatialSortThreshold = 300;
}
