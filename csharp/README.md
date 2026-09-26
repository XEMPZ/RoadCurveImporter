# RoadCurveImporter（C# / .NET 8 WPF 版）

根目录 PowerShell 7 + Python 版 v1.1 的完整复刻：同样的只读 CAD 读取、bulge 拆弧、端点拓扑排序、欧拉回旋线拟合与 DXF / 测量员八列 Excel 导出，全部以 C# 单进程实现。

**与原版的主要差异**

- **单文件自包含 exe**（win-x64）：内置 .NET 8 运行时，目标电脑无需安装 PowerShell 7、Python、Office 或任何依赖。
- **性能**：消除 PS↔Python 进程间通信，全部计算在进程内完成，体感速度约为原版十倍。
- **Excel 导出**：由 ClosedXML 直接写 `.xlsx`，不再依赖 openpyxl / Excel COM。
- **回旋线拟合**：手写 Levenberg-Marquardt 求解器（等价 scipy TRF 的 4 参数数值雅可比实现），配 Simpson 积分；16 条真实回旋线回归数据全部通过 **0.5 mm** 严格残差验收。

## 下载

前往 [Releases](https://github.com/XEMPZ/RoadCurveImporter/releases) 下载 `RoadCurveImporter.exe`（约 165 MB），双击即用。

## 运行环境

- Windows 10 / 11（x64）
- 导入时需正在运行 SouthMap/ZWCAD 或 AutoCAD（仅只读连接，不修改图纸）

## 从源码构建

需要 .NET 8 SDK：

```powershell
dotnet build RoadCurveImporter.sln -c Release
dotnet test RoadCurve.Tests\RoadCurve.Tests.csproj
dotnet publish RoadCurveImporter\RoadCurveImporter.csproj -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish
```

## 项目结构

| 路径 | 说明 |
|---|---|
| `RoadCurve.Core/` | 纯几何内核：角度/方位/DMS 换算、要素工厂（含 bulge 拆弧）、端点拓扑排序、回旋线拟合与加密、测量员表格、配置读写。不引用任何 CAD 程序集 |
| `RoadCurveImporter/` | WPF 界面、示意图绘制、CAD COM 只读层（ROT + GetActiveObject）、DXF / Excel 导出、内置自测 |
| `RoadCurve.Tests/` | xunit 单元测试 17 项（含 16 条真实回旋线严格回归） |

## 内置自测

8 个命令行开关（WinExe 会自动附加父控制台输出结果）：

```text
-SelfTest                       # 基础链路：要素生成、间隙填充、智能方向
-DxfCadRestoreSelfTest          # DXF 回读：AC1015、1 LINE + 1 ARC + 161 顶点 LWPOLYLINE
-LayoutSelfTest                 # 响应式布局三档（Narrow/Medium/Wide）
-SurveyorPreviewSelfTest        # 测量员预览列与 dd.mmss 编码
-CoordinateSwapSelfTest         # 坐标交换仅影响显示
-CurveDirectionSelfTest         # 路线反向的半径/扫角/预览几何
-PerformanceSelfTest            # 超大多段线防护（601 顶点）
-DefaultConfigurationSelfTest   # 默认配置校验
```

## 许可证

采用仓库根目录的 [MIT 许可证](../LICENSE)。
