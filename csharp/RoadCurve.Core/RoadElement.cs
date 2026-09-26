namespace RoadCurve.Core;

public class RoadElement
{
    public string Kind { get; set; } = "";
    public string Classification { get; set; } = "";
    public Point2 Start { get; set; }
    public Point2 End { get; set; }
    public Point2? Center { get; set; }
    public double? Radius { get; set; }  // 带符号：左负右正
    public double StartRadius { get; set; } // 左负右正
    public double EndRadius { get; set; }   // 左负右正
    public double Sweep { get; set; }       // 圆弧张角（弧度）
    public double Length { get; set; }
    public double StartHeading { get; set; }  // 数学航向角，弧度
    public double EndHeading { get; set; }    // 数学航向角，弧度
    public string Handle { get; set; } = "";
    public string Source { get; set; } = "";
    public int Segment { get; set; }
    public List<Point2>? Vertices { get; set; }
    public bool Reversed { get; set; }
    public bool IsGapFill { get; set; }
    public string Note { get; set; } = "";
}
