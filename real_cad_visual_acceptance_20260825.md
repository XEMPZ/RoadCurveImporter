# SouthMap/ZWCAD 2026 真实加载与可视验收记录

**验收时刻：** 2026-08-25（GMT+8）  
**方式：** 用户在 SouthMap/ZWCAD 软件内部手动打开；随后仅进行了窗口标题与非激活式窗口渲染抓取。验收过程没有发送 `OPEN`、外壳双击、文件关联、新建文档、CAD 命令、键盘快捷键、保存或关闭操作。

| 验收项 | 观察结果 | 判定 |
|---|---|---|
| SouthMap/ZWCAD 实际打开目标 | 窗口标题为 `SouthMap - [E:\Manus程序测试\RoadCurveImporter\selftest_complex_spirals_ezdxf_candidate.dxf]` | 通过 |
| DXF 解析错误/损坏提示 | 窗口内未见“DXF 损坏”、代理对象或解析失败提示；文档标签已建立 | 通过 |
| 候选图层表 | 图层面板显示 `0`、`Defpoints`、`ROAD_CURVE`、`ROAD_DISCRETE_POLYLINE`、`ROAD_GAP_FILL`、`ROAD_SPIRAL_POLYLINE`，均处于可见状态 | 通过 |
| 缓和曲线绘制 | `ROAD_SPIRAL_POLYLINE` 已在实际 CAD 图层面板中加载；当前画布出现其拟合折线局部可见段。图纸未执行视图缩放或其他命令，故未改变用户视图。 | 通过（可视加载） |
| 完整 16 条实体计数 | 已由离线 `ezdxf` 独立解析与复杂回归确认 16 条；本次未使用 CAD 命令调整视图或选择实体，不作额外 CAD 内计数 | 结构回归已通过；CAD 画面未干预 |

> 结论：候选 AC1015 DXF 已被 SouthMap/ZWCAD 2026 实际接受并建立文档，图层与拟合缓和曲线可见，不存在此前“文件损坏、无法打开”的现象。结合同一候选已完成的 16 条回旋曲线结构回归，这满足正式发布标准 DXF 写出器替换的实物加载验收条件。

验收时通过 `PrintWindow` 非激活抓取留存了窗口截图证据（过程截图未随仓库发布），抓取不修改 CAD 图纸或用户视图。
