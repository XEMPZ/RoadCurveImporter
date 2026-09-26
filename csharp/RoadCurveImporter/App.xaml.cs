using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using RoadCurveImporter.SelfTests;

namespace RoadCurveImporter;

public partial class App : Application
{
    [DllImport("kernel32.dll")] private static extern bool AttachConsole(int dwProcessId);
    [DllImport("kernel32.dll")] private static extern bool FreeConsole();
    private const int AttachParentProcess = -1;

    public App()
    {
        var args = Environment.GetCommandLineArgs();
        string? flag = args.Skip(1).FirstOrDefault(a => a.StartsWith("-", StringComparison.Ordinal));
        if (flag == null) return;

        // 自测模式：附加到父控制台以输出结果（句柄被重定向时降级为默认编码）
        AttachConsole(AttachParentProcess);
        try { Console.OutputEncoding = Encoding.UTF8; } catch (IOException) { }
        try { Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), Encoding.UTF8) { AutoFlush = true }); } catch (IOException) { }
        try { Console.SetError(new StreamWriter(Console.OpenStandardError(), Encoding.UTF8) { AutoFlush = true }); } catch (IOException) { }

        Action? test = flag switch
        {
            "-SelfTest" => SelfTestRunner.RunSelfTest,
            "-DxfCadRestoreSelfTest" => SelfTestRunner.RunDxfCadRestoreSelfTest,
            "-LayoutSelfTest" => SelfTestRunner.RunLayoutSelfTest,
            "-SurveyorPreviewSelfTest" => SelfTestRunner.RunSurveyorPreviewSelfTest,
            "-CoordinateSwapSelfTest" => SelfTestRunner.RunCoordinateSwapSelfTest,
            "-CurveDirectionSelfTest" => SelfTestRunner.RunCurveDirectionSelfTest,
            "-PerformanceSelfTest" => SelfTestRunner.RunPerformanceSelfTest,
            "-DefaultConfigurationSelfTest" => SelfTestRunner.RunDefaultConfigurationSelfTest,
            _ => null
        };
        if (test != null)
        {
            test();
            Console.Out.WriteLine(); // 附加控制台不会自动换行提示符
            Console.Out.Flush();
            FreeConsole();
            Environment.Exit(0);
        }
    }
}
