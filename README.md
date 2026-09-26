# RoadCurveImporter 道路曲线要素导入器

一个 Windows 桌面工具：在**不修改 CAD 图纸**的前提下，从 SouthMap/ZWCAD（南方测绘中望 OEM）及 AutoCAD 中只读读取道路平面要素，自动识别直线、圆曲线与欧拉缓和曲线（回旋线），并导出道路要素表、测量员八列 Excel、可缩放示意图和标准 AC1015（R2000）DXF 还原文件。

**当前版本：v1.1**

> **C# / .NET 8 WPF 复刻版已发布**：单文件自包含 `RoadCurveImporter.exe`，无需安装 PowerShell 7、Python 或 Office，体感速度约为原版十倍。前往 [Releases](https://github.com/XEMPZ/RoadCurveImporter/releases) 下载，源码与构建说明见 [`csharp/`](./csharp/)。以下说明适用于原 PowerShell 版本。

## 功能特性

- **只读安全边界**：不调用任何保存、修改、删除、关闭图纸的接口；AutoCAD 仅读取预选集，SouthMap/ZWCAD 的临时选择集在 `finally` 中清理。
- 支持直线、圆弧、多段线（含 bulge 逐段拆解）。
- 欧拉缓和曲线自动识别：严格 **0.5 mm**、宽松 **2 mm** 两档拟合残差验收。
- 缓和曲线按拟合模型以最大 0.25 m 步长加密为开放 `LWPOLYLINE`（图层 `ROAD_SPIRAL_POLYLINE`）导出。
- 测量员八列 Excel：里程、坐标、方位角（`dd.mmss`）、半径（左负右正）。
- SouthMap/ZWCAD 冷启动文件关联修复，含一键回滚脚本。

## 运行环境

- Windows 10 / 11
- [PowerShell 7](https://github.com/PowerShell/PowerShell)（pwsh）
- Python 3.10+
- 待读取图纸的 CAD：SouthMap/ZWCAD 202x 或 AutoCAD

## 快速开始

1. 安装 Python 依赖：

   ```powershell
   pip install -r requirements.txt
   ```

2. 双击 `启动道路曲线要素导入器.cmd`；或在 PowerShell 7 中运行：

   ```powershell
   pwsh -NoProfile -Sta -File .\RoadCurveImporter.ps1
   ```

3. 在 CAD 中选中道路要素，按界面提示读取并导出 Excel / DXF。

## 项目结构

| 路径 | 说明 |
|---|---|
| `csharp/` | C# / .NET 8 WPF 复刻版（**当前推荐**，单文件自包含，见其 README） |
| `RoadCurveImporter.ps1` | PowerShell 7 + WPF 主程序 |
| `RoadCurveImporter.config.json` | 端点容差、宽松拟合阈值、Excel 小数位配置 |
| `启动道路曲线要素导入器.cmd` | 启动入口（STA 模式） |
| `dxf_writer.py` | 基于 `ezdxf` 的 AC1015 DXF 写出器 |
| `spiral_fitter.py` / `spiral_fitter_server.py` | SciPy 回旋线拟合器与持久服务端 |
| `validate_dxf_ezdxf.py` | 标准 DXF 独立验证器 |
| `SouthMapColdOpen.ps1` / `.vbs` | CAD 冷启动桥接器 |
| `install_independent_southmap_cold_open_userchoice.ps1` | 冷启动关联安装脚本 |
| `rollback_independent_southmap_cold_open_userchoice.ps1` | 冷启动关联回滚脚本 |
| `PS-SFTA_1.2.0_local_sid_patch.ps1` | UserChoice 哈希设置器（第三方，见下） |
| `tests/` | 开发期回归与结构对比脚本 |
| `RoadCurveImporter_技术手册.md` | 架构、参数、维护与回退手册 |

## 自测

```powershell
# 界面布局自测
pwsh -NoProfile -Sta -File .\RoadCurveImporter.ps1 -LayoutSelfTest

# CAD 还原 DXF 自测（1 LINE、1 ARC、1 条 161 顶点 LWPOLYLINE，AC1015）
pwsh -NoProfile -Sta -File .\RoadCurveImporter.ps1 -DxfCadRestoreSelfTest
```

更多回归命令见技术手册第 10 节。

## 安全与系统影响说明

- 程序对 CAD 仅做自动化读取，不保存、不修改图纸。
- 冷启动修复脚本会修改**当前用户**的 `.dwg` / `.dxf` UserChoice 文件关联，不触碰系统级关联和厂商程序；可随时运行 `rollback_independent_southmap_cold_open_userchoice.ps1` 完全回滚。
- `PS-SFTA_1.2.0_local_sid_patch.ps1` 基于第三方项目 [PS-SFTA](https://github.com/DanysysTeam/PS-SFTA)（MIT 许可证），仅替换了 SID 获取方式以避免本机目录服务查询阻塞；安装脚本内置该文件 SHA-256 校验。

## 许可证

本项目采用 [MIT 许可证](./LICENSE)。
