using System.IO;
using ClosedXML.Excel;

namespace RoadCurveImporter.Export;

public static class ExcelExporter
{
    public static void Write(string targetPath, IReadOnlyList<double[]> rows, int digits)
    {
        if (File.Exists(targetPath)) File.Delete(targetPath);
        using var book = new XLWorkbook();
        var sheet = book.Worksheets.Add("测量员线元法");
        for (int r = 0; r < rows.Count; r++)
        {
            for (int c = 0; c < 8; c++)
            {
                var cell = sheet.Cell(r + 1, c + 1);
                cell.Value = rows[r][c];
            }
        }
        var range = sheet.Range($"A1:H{Math.Max(rows.Count, 1)}");
        string numberFormat = "0." + new string('0', digits);
        range.Style.NumberFormat.Format = numberFormat;
        sheet.Column(5).Style.NumberFormat.Format = "0.000000";
        sheet.Columns().AdjustToContents();
        book.SaveAs(targetPath);
    }
}
