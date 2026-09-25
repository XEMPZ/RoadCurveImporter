# SouthMap/ZWCAD 2026 直接打开故障修复记录

**结论：已恢复。** Windows 默认文件关联（等同于双击）已成功将项目测试 DXF 交给 SouthMap/ZWCAD 2026 打开，未再出现 **“Failed to create empty document.”**。

| 阶段 | 结果 | 证据 |
|---|---|---|
| 初始故障 | 失败 | 用户截图显示 `SouthMap For ZWCADOEM` 对话框：`Failed to create empty document.` |
| 文件关联核对 | 正常 | `.dwg` / `.dxf` 均映射至 `ZWCAD.Drawing.2026` / `ZWCAD.DXF.2026`，open 命令为 `ZwLauncher.exe "%1"` |
| 主程序与模板 | 存在且可读 | `ZwLauncher.exe`、`ZWCAD.exe` 为 `26.10.0.20036`；默认 `zwcad.dwt` 存在且有有效 AC1032 文件头 |
| 会话状态 | 已清理 | 用户确认已关闭全部图纸后，回收无窗口的旧 ZWCAD PID 6244；未修改任何 CAD 文档 |
| 用户配置 | 已可回滚重建 | Roaming 与 Local 的 `SouthMapForZWCADOEM\2026` 均先压缩备份，再重命名以促成干净启动 |
| 残留临时文件 | 已归档 | `zw$8497.DWG`、`zw$8497.tmp`、`zwCopyClipTmp$0.wmf` 被移动至项目归档目录，未直接删除 |
| 干净启动 | 通过 | 官方 `StartCAD.exe` 成功创建 `SouthMap - [Drawing1.dwg]` |
| 双击路径复验 | 通过 | Windows Shell 默认关联在 **0.83 秒**内打开 `selftest_complex_spirals_ezdxf_candidate.dxf`；无 SouthMap 错误对话框 |

## 根因判断

故障并非 DXF 格式或文件关联映射缺失。初始会话在长时间运行后遗留了无窗口 ZWCAD 后台进程和 `zw$` 临时文件，且应用事件日志曾记录同版本 `ZwRx.dll`、`ZwAuto.dll` 与 `ZwDatabase.dll` 的访问冲突。启动器随后无法在该会话中建立空白文档。将旧用户会话状态安全退出、暂存用户配置并让官方 `StartCAD.exe` 建立干净会话后，默认关联立即恢复。

> 这是基于现场现象与修复后复验的工程归因，并非对厂商内部崩溃代码的反编译结论。

## 回滚位置

如未来需要回到修复前的用户设置，必须先关闭 SouthMap/ZWCAD。以下目录均完整保留，未删除。

| 内容 | 路径 |
|---|---|
| Roaming 用户配置压缩备份 | `E:\Manus程序测试\RoadCurveImporter\SouthMap_ZWCAD2026_用户配置备份_20260825_081919\Roaming_2026.zip` |
| Local 用户配置压缩备份 | `E:\Manus程序测试\RoadCurveImporter\SouthMap_ZWCAD2026_用户配置备份_20260825_081919\Local_2026.zip` |
| 原 Roaming 配置目录 | `%APPDATA%\ZWSOFT\SouthMapForZWCADOEM\2026.pre_empty_document_fix_20260825_081919` |
| 原 Local 配置目录 | `%LOCALAPPDATA%\ZWSOFT\SouthMapForZWCADOEM\2026.pre_empty_document_fix_20260825_081919` |
| 临时文件归档 | `E:\Manus程序测试\RoadCurveImporter\ZWCAD_残留临时文件归档_20260825_081953` |
| 验证结果 | 已通过 Windows Shell 默认关联（等效双击）验证；过程记录未随仓库发布 |

正常使用时不需要手动恢复上述内容。今后若再次出现创建空白文档错误，请先正常关闭全部 SouthMap/ZWCAD 窗口，确认任务管理器中没有 `ZWCAD.exe` / `ZwLauncher.exe`，再重新从开始菜单的 `StartCAD.exe` 或直接双击图纸启动。
