namespace RoadCurve.Core;

/// <summary>道路要素表行（Publish-Elements 输出）。</summary>
public class ElementRow
{
    public int Sequence { get; set; }
    public string Kind { get; set; } = "";
    public double LengthM { get; set; }
    public string StartStationText { get; set; } = "";
    public string EndStationText { get; set; } = "";
    public double StartX { get; set; }
    public double StartY { get; set; }
    public double EndX { get; set; }
    public double EndY { get; set; }
    public double StartAzimuthDms { get; set; }
    public double EndAzimuthDms { get; set; }
    public double StartRadiusM { get; set; }
    public double EndRadiusM { get; set; }
    public double? RadiusM { get; set; }
    public string DeflectionDms { get; set; } = "";
    public string Classification { get; set; } = "";
    public string Source { get; set; } = "";
    public string Note { get; set; } = "";
    public RoadElement Element { get; set; } = null!;
    public double StartStation { get; set; }
    public double EndStation { get; set; }
}

/// <summary>测量员格式预览行（含灰色终点核验列）。</summary>
public class SurveyorRow
{
    public string Kind { get; set; } = "";
    public double StartStation { get; set; }
    public double EndStation { get; set; }
    public double StartAzimuthDms { get; set; }
    public double StartX { get; set; }
    public double StartY { get; set; }
    public double StartRadiusM { get; set; }
    public double EndRadiusM { get; set; }
    public double EndX { get; set; }
    public double EndY { get; set; }
    public double EndAzimuthDms { get; set; }
}

public static class SurveyorTable
{
    /// <summary>等价 Get-SurveyorValues：固定八列（里程起/止、X、Y、方位角 dd.mmss、起半径、止半径、0）。</summary>
    public static double[] GetSurveyorValues(ElementRow row, ImportSettings settings, int digits)
    {
        var e = row.Element;
        var start = DisplaySemantics.GetOutputPoint(e.Start, settings.SwapCadXY);
        double heading = DisplaySemantics.GetDisplayHeading(e, true, settings.ReverseCurveDirection);
        return new[]
        {
            Math.Round(row.StartStation, digits),
            Math.Round(row.EndStation, digits),
            Math.Round(start.X, digits),
            Math.Round(start.Y, digits),
            Geometry.GetSurveyorDmsNumber(Geometry.ToSurveyAzimuth(heading)),
            Math.Round(DisplaySemantics.GetDisplayRadius(e, e.StartRadius, settings.ReverseCurveDirection), digits),
            Math.Round(DisplaySemantics.GetDisplayRadius(e, e.EndRadius, settings.ReverseCurveDirection), digits),
            0.0
        };
    }

    /// <summary>等价 Refresh-SurveyorRows。</summary>
    public static List<SurveyorRow> BuildSurveyorRows(IReadOnlyList<ElementRow> rows, ImportSettings settings, int digits)
    {
        var output = new List<SurveyorRow>(rows.Count);
        foreach (var row in rows)
        {
            var v = GetSurveyorValues(row, settings, digits);
            var e = row.Element;
            var endPoint = DisplaySemantics.GetOutputPoint(e.End, settings.SwapCadXY);
            output.Add(new SurveyorRow
            {
                Kind = e.Kind,
                StartStation = v[0],
                EndStation = v[1],
                StartAzimuthDms = v[4],
                StartX = v[2],
                StartY = v[3],
                StartRadiusM = v[5],
                EndRadiusM = v[6],
                EndX = Math.Round(endPoint.X, digits),
                EndY = Math.Round(endPoint.Y, digits),
                EndAzimuthDms = Geometry.GetSurveyorDmsNumber(Geometry.ToSurveyAzimuth(
                    DisplaySemantics.GetDisplayHeading(e, false, settings.ReverseCurveDirection)))
            });
        }
        return output;
    }

    /// <summary>等价 Publish-Elements：按排序结果生成主表（含桩号）。</summary>
    public static List<ElementRow> Publish(IReadOnlyList<RoadElement> ordered, ImportSettings settings, List<string> diagnostics)
    {
        var rows = new List<ElementRow>(ordered.Count);
        int digits = settings.Digits;
        int startIndex = settings.StartPosition;
        if (startIndex > ordered.Count)
        {
            diagnostics.Add($"起算点位置 {startIndex} 超过要素数 {ordered.Count}，已按第 1 个要素起算。");
            startIndex = 1;
        }
        double priorLength = 0.0;
        for (int i = 0; i < startIndex - 1; i++) priorLength += ordered[i].Length;
        double station = settings.StartStation - priorLength;
        int sequence = 0;
        foreach (var e in ordered)
        {
            sequence++;
            double startStation = station;
            station += e.Length;
            var displayStart = DisplaySemantics.GetOutputPoint(e.Start, settings.SwapCadXY);
            var displayEnd = DisplaySemantics.GetOutputPoint(e.End, settings.SwapCadXY);
            double displayStartHeading = DisplaySemantics.GetDisplayHeading(e, true, settings.ReverseCurveDirection);
            double displayEndHeading = DisplaySemantics.GetDisplayHeading(e, false, settings.ReverseCurveDirection);
            double displaySweep = DisplaySemantics.GetDisplaySweep(e, settings.ReverseCurveDirection);
            double displayStartRadius = DisplaySemantics.GetDisplayRadius(e, e.StartRadius, settings.ReverseCurveDirection);
            double displayEndRadius = DisplaySemantics.GetDisplayRadius(e, e.EndRadius, settings.ReverseCurveDirection);
            double? displayRadius = e.Radius.HasValue
                ? DisplaySemantics.GetDisplayRadius(e, e.Radius.Value, settings.ReverseCurveDirection) : null;
            rows.Add(new ElementRow
            {
                Sequence = sequence,
                Kind = e.Kind,
                LengthM = Math.Round(e.Length, digits),
                StartStationText = Geometry.FormatStation(startStation, settings.Prefix, digits),
                EndStationText = Geometry.FormatStation(station, settings.Prefix, digits),
                StartX = Math.Round(displayStart.X, digits),
                StartY = Math.Round(displayStart.Y, digits),
                EndX = Math.Round(displayEnd.X, digits),
                EndY = Math.Round(displayEnd.Y, digits),
                StartAzimuthDms = Geometry.GetSurveyorDmsNumber(Geometry.ToSurveyAzimuth(displayStartHeading)),
                EndAzimuthDms = Geometry.GetSurveyorDmsNumber(Geometry.ToSurveyAzimuth(displayEndHeading)),
                StartRadiusM = Math.Round(displayStartRadius, digits),
                EndRadiusM = Math.Round(displayEndRadius, digits),
                RadiusM = displayRadius.HasValue ? Math.Round(displayRadius.Value, digits) : null,
                DeflectionDms = Geometry.FormatDmsAngle(Geometry.ToDegrees(displaySweep)),
                Classification = e.Classification,
                Source = $"{e.Source}:{e.Handle}/{e.Segment}",
                Note = e.Note,
                Element = e,
                StartStation = startStation,
                EndStation = station
            });
        }
        return rows;
    }
}
