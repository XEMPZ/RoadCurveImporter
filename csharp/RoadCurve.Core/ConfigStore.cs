using System.Text.Json;
using System.Text.Json.Nodes;

namespace RoadCurve.Core;

/// <summary>同目录 RoadCurveImporter.config.json 的读写，等价 PS 的配置加载/恢复默认值。</summary>
public class ConfigStore
{
    public double EndpointConnectionToleranceMm { get; private set; } = 1.0;
    public double LooseSpiralFitToleranceMm { get; private set; } = 2.0;
    public int SurveyorExportDigits { get; private set; } = 6;

    public double ConnectionToleranceM => EndpointConnectionToleranceMm / 1000.0;
    public double LooseSpiralToleranceM => LooseSpiralFitToleranceMm / 1000.0;
    public double StrictSpiralToleranceM => Limits.StrictSpiralToleranceM;

    public const string ConfigFileName = "RoadCurveImporter.config.json";
    private const string Notes = "endpointConnectionToleranceMm 为端点自动连接平面距离阈值（mm）；其中距离小于 0.1 mm 的端点视为直接相连，不另写填充线；looseSpiralFitToleranceMm 为宽松欧拉回旋线验收最大拟合偏差（mm，默认 2）；严格欧拉回旋线验收固定为 0.5 mm，不能修改；surveyorExportDigits 为测量员八列 Excel 小数位，必须不低于 6。修改本文件后重启程序生效。";

    public static ConfigStore Load(string configPath)
    {
        var store = new ConfigStore();
        try
        {
            if (File.Exists(configPath))
            {
                var node = JsonNode.Parse(File.ReadAllText(configPath));
                if (node != null)
                {
                    double mm = node["endpointConnectionToleranceMm"]?.GetValue<double>() ?? 1.0;
                    if (mm > 0 && mm <= 1000) store.EndpointConnectionToleranceMm = mm;
                    double looseMm = node["looseSpiralFitToleranceMm"]?.GetValue<double>() ?? 2.0;
                    if (looseMm >= 0.1 && looseMm <= 10) store.LooseSpiralFitToleranceMm = looseMm;
                    int digits = node["surveyorExportDigits"]?.GetValue<int>() ?? 6;
                    if (digits >= 6 && digits <= 12) store.SurveyorExportDigits = digits;
                }
            }
        }
        catch { /* 配置损坏时按默认值运行 */ }
        return store;
    }

    /// <summary>原子重写默认配置，等价 Write-DefaultConfiguration。</summary>
    public static void WriteDefaults(string configPath)
    {
        var node = new JsonObject
        {
            ["endpointConnectionToleranceMm"] = 1.0,
            ["looseSpiralFitToleranceMm"] = 2.0,
            ["surveyorExportDigits"] = 6,
            ["notes"] = Notes
        };
        string tempPath = configPath + ".next";
        File.WriteAllText(tempPath, node.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        File.Move(tempPath, configPath, overwrite: true);
    }
}
