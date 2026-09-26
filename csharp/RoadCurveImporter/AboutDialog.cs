using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace RoadCurveImporter;

/// <summary>等价 Show-AboutDialog。</summary>
public class AboutDialog : Window
{
    private const string AppVersion = "1.1";
    private const string AppAuthor = "求道之心";
    private const string ProjectReleasesUrl = "https://github.com/XEMPZ/RoadCurveImporter/releases";
    private const string BugReportEmail = "jewettleah2@gmail.com";

    public AboutDialog()
    {
        Title = "关于本软件";
        Width = 520; Height = 480;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        FontFamily = new FontFamily("Microsoft YaHei UI");
        FontSize = 12;
        Background = Brushes.White;

        var dock = new DockPanel { Margin = new Thickness(16) };
        var bottom = new StackPanel
        {
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 14, 0, 0),
            Orientation = Orientation.Horizontal
        };
        DockPanel.SetDock(bottom, Dock.Bottom);
        var closeButton = MakeButton("关闭", 0);
        closeButton.Padding = new Thickness(18, 5, 18, 5);
        closeButton.Click += (_, _) => Close();
        bottom.Children.Add(closeButton);
        dock.Children.Add(bottom);

        var body = new StackPanel();
        body.Children.Add(MakeText("道路曲线要素导入器", 18, true, "#163B61", 0, 6));
        body.Children.Add(MakeText($"软件版本：{AppVersion}", 13, true, "#24567C", 2, 6));
        body.Children.Add(MakeText($"作者：{AppAuthor}", 12, false, "#22303C", 4, 4));
        body.Children.Add(MakeText("许可证：MIT License —— 开源免费，允许自由使用、复制、修改与再分发；完整条款见随附 LICENSE 文件。", 12, false, "#22303C", 0, 4));

        body.Children.Add(MakeText("最新版本地址（GitHub 发布页，可点击打开或复制）：", 12, true, "#22303C", 10, 4));
        body.Children.Add(MakeCopyRow(ProjectReleasesUrl, 300, "复制链接", "打开页面",
            () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(ProjectReleasesUrl) { UseShellExecute = true })));

        body.Children.Add(MakeText("报告 BUG（复制邮箱后写信反馈）：", 12, true, "#22303C", 12, 4));
        body.Children.Add(MakeCopyRow(BugReportEmail, 220, "复制邮箱", "写邮件",
            () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("mailto:" + BugReportEmail) { UseShellExecute = true })));

        dock.Children.Add(body);
        Content = dock;
    }

    private static SolidColorBrush Brush(string hex)
        => new((Color)ColorConverter.ConvertFromString(hex));

    private static TextBlock MakeText(string text, double fontSize, bool bold, string color, double top, double bottom)
        => new()
        {
            Text = text,
            FontSize = fontSize,
            Foreground = Brush(color),
            Margin = new Thickness(0, top, 0, bottom),
            TextWrapping = TextWrapping.Wrap,
            FontWeight = bold ? FontWeights.Bold : FontWeights.Normal
        };

    private static Button MakeButton(string text, double left)
        => new()
        {
            Content = text,
            Padding = new Thickness(10, 4, 10, 4),
            Margin = new Thickness(left, 0, 6, 0),
            VerticalAlignment = VerticalAlignment.Center
        };

    private UIElement MakeCopyRow(string value, double minWidth, string copyLabel, string actionLabel, Action action)
    {
        var row = new WrapPanel();
        var box = new TextBox
        {
            Text = value,
            IsReadOnly = true,
            IsReadOnlyCaretVisible = true,
            MinWidth = minWidth,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 6, 0)
        };
        row.Children.Add(box);
        var copy = MakeButton(copyLabel, 0);
        copy.Click += (_, _) =>
        {
            try { Clipboard.SetText(value); copy.Content = "已复制"; } catch { }
        };
        row.Children.Add(copy);
        var open = MakeButton(actionLabel, 0);
        open.Click += (_, _) =>
        {
            try { action(); }
            catch (Exception ex) { MessageBox.Show(ex.Message, "关于本软件", MessageBoxButton.OK, MessageBoxImage.Warning); }
        };
        row.Children.Add(open);
        return row;
    }
}
