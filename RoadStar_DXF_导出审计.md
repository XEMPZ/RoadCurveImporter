# 道路之星 DXF 导出审计记录

**审计日期：** 2026-08-25  
**范围：** 仅对用户已授权目录 `E:\Manus程序测试\道路之星` 中的 `RdStarPc.exe` 和桌面参考 DXF 执行静态/只读分析；未运行道路之星，未修改任何 CAD 图形。

## 1. 样本身份与静态识别

| 项目 | 结果 |
|---|---|
| 主程序 | `E:\Manus程序测试\道路之星\RdStarPc.exe` |
| SHA-256 | `ddcefdf8478130092b711c5029712bc17b71e4caaae96f1b28dc5b81c528368f` |
| 文件格式 | PE32、x86、Windows GUI |
| 编译环境 | Visual C++ 2010 / MFC 10.0 |
| 壳/保护 | 未检测到；总熵与节区扫描均标记为 `not packed` |
| 静态扫描记录 | `E:\Manus程序测试\道路之星_只读审计\RdStarPc.die.json` |

## 2. 已证实的导出实现

程序静态字符串中存在 `dxflib 3.17.0.0`、`DL_Dxf::writeLayer`、`DL_Dxf::writeLinetype`、`DL_Dxf::writeAppid`、`DL_WriterA`、`LINE`、`ARC`、`LWPOLYLINE`、`AcDbEntity`、`AcDbPolyline` 与 `SECTION/HEADER/ENDSEC/ENTITIES`。这些是**直接静态证据**：道路之星将曲线写为 dxflib 的标准 ASCII DXF 实体，而非 CAD 专有回旋线实体。

> 结论：道路之星的“缓和曲线正常显示”并不是向 DXF 写入欧拉/回旋曲线专有对象，而是将曲线离散为普通折线，并以完整 DXF 结构写出。

## 3. 实际道路之星参考输出

已审计桌面参考文件 `道路曲线要素1.dxf`。它含 `999 / dxflib 3.17.0` 标识，并具备以下结构：

| 项目 | 观察结果 |
|---|---|
| DXF 版本 | `AC1015`（R2000） |
| 必需区段 | `HEADER`、`TABLES`、`BLOCKS`、`ENTITIES`、`OBJECTS` |
| 曲线实体 | 开放 `LWPOLYLINE` |
| 实体子类 | `AcDbEntity`、`AcDbPolyline` |
| 关键组码 | `5` 句柄、`8` 图层、`62` 颜色、`420` 真彩色、`370` 线宽、`48` 线型比例、`6` 线型、`90` 顶点数、`70=0` |
| 顶点表示 | 每个顶点写出 `10=X`、`20=Y`、`30=0.0` |

参考文件的首条折线为 31 顶点 LWPOLYLINE。其完整写法说明：ZWCAD 兼容性关键不在“DXF 中存在一条名为缓和曲线的实体”，而在**完整 R2000 容器、合法 LWPOLYLINE 子类记录、明确顶点数和连续 X/Y/Z 顶点组**。

## 4. 对 RoadCurveImporter 的落实

当前候选 `RoadCurveImporter.ezdxf_candidate.ps1` 已将 `Export-Dxf` 改为调用 `dxf_writer.py`：

1. 由 `ezdxf` 生成完整的 AC1015 / R2000 文件，而不再由 PowerShell 手写不完整组码；
2. 已识别欧拉回旋线按 0.25 m 最大步长的拟合模型离散为开放 `LWPOLYLINE`；
3. 输出图层固定为 `ROAD_SPIRAL_POLYLINE`；
4. 折线附带道路之星参考文件相同类别的可见属性（颜色、真彩色、Continuous 线型、线宽、比例）；
5. 为缓和曲线每个顶点补写 `30=0.0`，与道路之星 dxflib 输出保持一致；
6. 坐标仍使用 CAD 原始 X/Y 和原方向，不受测量表 XY 显示交换和曲线方向显示选项影响。

## 5. 已通过的可复现验证

| 验证 | 结果 |
|---|---|
| 语法与内置 CAD 还原自测 | 通过；1 LINE、1 ARC、1 个 161 顶点拟合 LWPOLYLINE |
| ezdxf 独立解析 | 通过；AC1015、图层与实体均可解析 |
| 复杂图 DXF 回归 | 通过；16 条回旋曲线，单条 801–802 顶点，最大采样段长 `0.250000001 m`，端点保持 CAD 原始坐标 |
| 道路之星参考文件 ezdxf 解析 | 通过；AC1015、4 LINE、3 LWPOLYLINE、2 ARC 等实体可读 |

## 6. 实际 ZWCAD 打开测试的当前边界

为避免改动用户原始图形，已尝试在当前运行的 ZWCAD 2026 会话中通过 `Documents.Open`、`ZcadDocument.Open`、`SendCommand OPEN` 和 Windows 文件关联临时加载 DXF。**同样的 COM 接口对道路之星已知参考 DXF 也返回 `0x80070057` 或 `0x80004005`，或不建立新文档**，因此这些失败不能归因于候选 DXF 损坏；它们表明当前会话的外部自动化“打开文档”入口不可用于 DXF 终验。

该边界不改变上述文件结构结论，但也意味着不能把 COM 打开失败表述为“候选已在当前 ZWCAD 中人工打开通过”。在发布前，应采用一个空闲/独立 ZWCAD 会话，或由用户在当前 GUI 中手动打开**测试副本**确认可见性；严禁保存或关闭原图。

## 7. 后续维护规则

- 不再回退至手写 PowerShell DXF 组码；所有正式导出统一经 `dxf_writer.py`。
- 变更 DXF 输出时必须同时执行：内置 DXF 自测、`validate_dxf_ezdxf.py`、复杂图 16 条拟合回归。
- 若将来获得独立 ZWCAD 核心控制台或空闲实例，应将“打开—统计 POLYLINE—无保存关闭”加入最终发布门禁。

### 2026-08-25 GUI 打开验证补充

已通过受控 GUI 操作尝试在当前 ZWCAD 会话打开候选自测文件 `selftest_cad_restore.dxf`。屏幕返回 **`Failed to create empty document.`**，而不是 DXF 解析错误。该窗口级证据与先前 COM `Documents.Open` / `ZcadDocument.Open` 对道路之星参考 DXF 同样失败的结果一致：当前 ZWCAD 会话的“新建/打开额外文档”能力处于异常状态，不能作为候选 DXF 损坏的判据。

在该状态恢复前，禁止将 GUI 打开失败记为候选文件格式损坏；候选仍必须以独立标准解析、道路之星样本结构对比和复杂图回归作为暂时门禁。为获得实际 ZWCAD 打开验收，需要在空闲、能正常创建新文档的 ZWCAD 会话中加载测试副本，且不保存原始图形。

### 2026-08-25 前台 GUI 终验进展

通过线程焦点关联后，已将当前 ZWCAD 实际置于前台并提交候选 `selftest_cad_restore.dxf` 的打开操作。打开后截图未出现“DXF 损坏”或解析错误提示，ZWCAD 已进入空白的模型/布局视图。该状态尚需执行**仅改变视图的 Zoom Extents**，以确认自测文件的直线、圆弧和拟合 LWPOLYLINE 是否实际存在且可见；该操作不保存、不编辑任何实体。

### 2026-08-25 GUI 终验阻塞更新

前台校验脚本可将 ZWCAD 置前并提交打开动作，但随后 `probe_current_zwcad_documents.ps1` 仍只列出原有 5 个文档，未出现 `selftest_cad_restore.dxf`。这表明候选文件**尚未实际进入**当前会话，不能将空白视图误认作成功打开。另一次未带前台校验的 Zoom Extents 输入因焦点自动回切至其他程序而没有作用于 CAD；后续不得再向未验证前台的窗口发送按键。

至此可证实：候选的文件结构已通过独立解析、复杂图 16 条回归与道路之星结构比对；当前运行中的 ZWCAD 会话却不能用于自动加载额外 DXF 文档。要完成真正的 ZWCAD 视觉打开验收，需先恢复该会话的文件打开能力或切换至独立空闲会话。

### 2026-08-25 安全恢复与发布门禁更新

本轮首先清理了此前仅用于道路之星参考文件验证的受控第二 ZWCAD 实例 **PID 25724**。该实例经过 PID、启动时间及窗口标题核验后，采用正常关闭与“**不保存**”方式退出；未强制终止进程，也没有触碰原始 ZWCAD 会话 **PID 6244**。清理后，PID 6244 仍保留原有 5 个文档，未执行激活、保存、关闭、打开、新建或键盘命令。

候选的本轮一致性离线回归于 2026-08-25 04:17（GMT+8）完成，候选 SHA-256 为 `4FA051A122FFCF911F058C64F99C525C24E70C3189C18FA88AF8E9CA60702932`。结果如下。

| 门禁项 | 本轮结果 | 证据 |
|---|---:|---|
| Python 写出器语法检查 | 通过 | `dxf_writer.py`、独立解析器、结构对比器均成功编译 |
| 内置 CAD 还原自测 | 通过 | 1 LINE、1 ARC、1 条 161 顶点拟合开放 LWPOLYLINE，AC1015 |
| 独立 `ezdxf` 解析 | 通过 | 版本 AC1015；`ROAD_SPIRAL_POLYLINE` 上 1 条开放 LWPOLYLINE，端点 `(500,600)` 至 `(538,615)` |
| 与道路之星参考的结构对比 | 通过 | 完整必需区段、`AcDbEntity`/`AcDbPolyline`、组码、开放标志、XYZ 顶点计数与显示属性均满足 |
| 复杂 16 条回旋曲线回归 | 通过 | 16 条拟合折线；每条 801–802 顶点；最大段长 `0.250000001 m`；保持原始 CAD 端点和 XY/方向独立性 |

然而，原始 ZWCAD 会话中预先打开的 5 个文档均**不包含**图层 `ROAD_SPIRAL_POLYLINE`，因此其中不存在可由本轮只读观察确认的候选 DXF。用户已明确禁止外壳双击、文件关联、`OPEN`、新建文档、文件打开与 GUI 快捷键测试；为了遵守该限制，本轮没有再打开或切换任何图纸。由此，当前只能证明候选在标准解析器、道路之星格式基线和复杂几何回归下通过，**尚不能证明候选已经在真实 ZWCAD 画布中实际加载并可视显示**。

正式程序 `RoadCurveImporter.ps1` 仍保持 SHA-256 `B55A8DD5FC094F61705F9B5E3FDAAE10BEC8645B0730FE8EDB99D6AB225E7BE7`，未被候选覆盖。当时发布门禁状态为 `Published=false`、`VisualCadAcceptance=false`（门禁过程记录未随仓库发布）。在不违反当前 CAD 安全边界的前提下，不能将该候选发布为“已完成真实 CAD 验收”的最终修复。

### 2026-08-25 真实 SouthMap/ZWCAD 验收与正式发布

用户已在 SouthMap/ZWCAD 软件内部手动打开 `E:\Manus程序测试\RoadCurveImporter\selftest_complex_spirals_ezdxf_candidate.dxf`。随后以**不激活窗口、不发送 CAD 命令**的窗口渲染抓取进行观察：SouthMap 实际窗口标题包含该完整路径；文档标签已经建立，未出现 DXF 损坏或解析错误提示；图层面板中 `ROAD_SPIRAL_POLYLINE` 与标准图层完整存在且可见，画布中出现拟合缓和折线局部。结合此前对同一文件的独立解析和复杂 16 条曲线回归，可确认候选 AC1015 DXF 已被 SouthMap/ZWCAD 2026 实际加载并显示。

因此，候选已于 2026-08-25 08:03（GMT+8）原子发布为正式 `RoadCurveImporter.ps1`。发布后 SHA-256 为 `4FA051A122FFCF911F058C64F99C525C24E70C3189C18FA88AF8E9CA60702932`，与验收候选完全一致。发布采用 `File.Replace`，并保留以下回滚副本：

| 回滚文件 | SHA-256 | 用途 |
|---|---|---|
| `RoadCurveImporter.ps1.before_ezdxf_20260825_080232.bak` | `B55A8DD5FC094F61705F9B5E3FDAAE10BEC8645B0730FE8EDB99D6AB225E7BE7` | 发布前手写 DXF 正式版的显式备份 |
| `RoadCurveImporter.ps1.atomic_replace_20260825_080305.bak` | `B55A8DD5FC094F61705F9B5E3FDAAE10BEC8645B0730FE8EDB99D6AB225E7BE7` | NTFS 原子替换自动备份 |

发布后，正式版的 `-DxfCadRestoreSelfTest` 与 `validate_dxf_ezdxf.py` 再次通过，确认输出为 AC1015、1 条 LINE、1 条 ARC 与 1 条 161 顶点拟合开放 LWPOLYLINE。全程没有关闭、保存、编辑、重启或切换用户 CAD 图纸。
