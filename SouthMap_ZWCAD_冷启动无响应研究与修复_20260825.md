# SouthMap/ZWCAD 冷启动无响应：研究与修复记录

**状态：已修复并以真实冷启动验证。** 本次问题的表现为：若 SouthMap/ZWCAD 主程序已运行，双击 `.dwg` 或 `.dxf` 能够正常打开；若没有运行中的主程序，双击后没有图纸窗口，也没有可见错误提示。

## 结论

该现象是 **ZwLauncher 冷启动链路缺少主程序初始化**，而不是 DXF/DWG 文件损坏、道路曲线导出器、文件扩展名映射或系统级权限问题。系统默认关联原本直接执行：

```text
ZwLauncher.exe "%1"
```

对已有 SouthMap/ZWCAD 会话，`ZwLauncher.exe` 可以通过其命名管道将文件交给主程序，因此热启动正常。对没有主程序的状态，现场观察到 `ZwLauncher.exe` 仍常驻，却没有成功创建 `ZWCAD.exe` 进程或用户配置，表现为无窗口、无文档、无显式错误。

相反，厂商的开始菜单入口 `StartCAD.exe` 静态字符串明确表明其从 `ZWCAD.ini` 读取 OEM 配置，并以如下参数启动主程序：

```text
ZWCAD.exe /company <CompanyName> /product <ProductName> /language "<Locale>" /volkey "SouthMap"
```

其中安装目录根 `ZWCAD.ini` 的值为 `CompanyName=SouthGnss`、`ProductName=SouthMapForZWCADOEM`、`LocaleId=2052`。因此 `StartCAD.exe` 是该 OEM 产品正确建立**首个空白会话**的入口；`ZwLauncher.exe` 的职责更适合向已有会话传递待打开文件。

| 证据 | 观察 | 解释 |
|---|---|---|
| 默认文件关联 | 两类扩展都直接调用 `ZwLauncher.exe "%1"` | 冷启动没有通过 OEM 初始化入口 |
| ZwLauncher 静态审计 | PE64、MFC 14，含 `CreateMutexW`、`WaitNamedPipeW`、命名管道 `\\.\pipe\zwcad.2023...` 和 `ZWCAD.ini` 字符串 | 设计上包含单实例/进程间转发机制 |
| StartCAD 静态审计 | PE64、MFC 10，含 OEM 参数模板与 `GetPrivateProfileStringA` | 正确的 OEM 冷启动入口 |
| 冷启动实测（原关联） | `ZwLauncher.exe` 无窗口常驻，没有建立候选 DXF 文档 | 冷启动失败复现 |
| 热启动实测 | StartCAD 先创建 `Drawing1.dwg` 后，原 ZwLauncher 可在 0.83 秒打开 DXF | 原厂转发链路在主程序存在时正常 |
| 修复后冷启动实测 | Windows Shell 默认关联在 **16.82 秒**内打开项目测试 DXF；没有 `Failed to create empty document` 对话框 | 冷启动修复有效 |

> 该归因基于只读静态识别、安装配置、进程/窗口观察和受控测试副本，不包含对厂商代码的修改或动态调试。

## 实施的最小修复

修复仅覆盖**当前 Windows 用户**的两个 ProgID 的 `shell\open\command`：`ZWCAD.DXF.2026` 与 `ZWCAD.Drawing.2026`。系统级关联、厂商可执行文件、CAD 文档及其内容均未被更改。

新的每用户打开命令调用 `SouthMapColdOpen.ps1`。若检测到已有 `ZWCAD.exe`，它按原路径调用 `ZwLauncher.exe`；若不存在主程序，它先调用官方 `StartCAD.exe`，等待 `Drawing1.dwg` 会话可用后，再将文件交给原厂 `ZwLauncher.exe`。这样保留了厂商对 OEM 参数、授权、图纸解析和单实例转发的全部控制，只补足了原关联遗漏的冷启动初始化步骤。

| 项目 | 路径或值 |
|---|---|
| 冷启动包装器 | `E:\Manus程序测试\RoadCurveImporter\SouthMapColdOpen.ps1` |
| 安装脚本 | `E:\Manus程序测试\RoadCurveImporter\install_southmap_cold_open_association_fix.ps1` |
| 回滚脚本 | `E:\Manus程序测试\RoadCurveImporter\rollback_southmap_cold_open_association_fix.ps1` |
| 关联备份 | `E:\Manus程序测试\RoadCurveImporter\SouthMap_冷启动关联备份_20260825_083343` |
| 冷启动验证结果 | Windows Shell 默认关联双击验证通过；过程记录未随仓库发布 |

## 回滚

如需撤销包装器，双击运行或在 PowerShell 中执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "E:\Manus程序测试\RoadCurveImporter\rollback_southmap_cold_open_association_fix.ps1"
```

该操作仅删除当前用户的覆盖项，Windows 会回退到安装时系统级的 `ZwLauncher.exe "%1"` 命令。原有每用户类命令也已导出到关联备份目录，必要时可按其中 `.reg` 文件恢复。

## 使用建议

今后直接双击 `.dwg` 或 `.dxf` 时，若 SouthMap/ZWCAD 未运行，会先由 `StartCAD.exe` 建立正确 OEM 会话再打开图纸，因此首次启动比热启动略慢；若主程序已经运行，仍走原厂转发路径。当前冷启动测试图纸已正常打开，可直接开始使用。

## 参考资料

[1] [ZWCAD 官方：启动失败常见原因与处理](https://www.zwsoft.com/user-guide/fix-zwcad-crash-on-launch)

---

## 最终修正：关联默认值写入与冷启动稳定交接

首个包装器版本虽已验证“先 `StartCAD.exe`、后 `ZwLauncher.exe`”的逻辑有效，但其关联安装脚本采用了不正确的 PowerShell 注册表属性写法，未真正覆盖 ProgID 的**默认** `open\command` 值。因此，用户随后直接双击仍调用安装时的原始 `ZwLauncher.exe`，表现为 CAD 主程序可启动但图纸未即时加载。

已改为使用 `Set-Item -Value` 写入每用户 ProgID 的默认值，并用 `reg.exe query ... /ve` 复核实际值已指向：

```text
"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "E:\Manus程序测试\RoadCurveImporter\SouthMapColdOpen.ps1" "%1"
```

同时，包装器增加了空白 `Drawing1.dwg` 窗口出现后的 **5 秒稳定等待**，以及最多 5 次、每次 8 秒观察窗口的原厂 `ZwLauncher.exe` 文件转交重试。最终冷启动日志显示：`StartCAD.exe` 建立会话后，第一次原厂转交即在约 **1.03 秒**内出现测试 DXF 文档窗口；从 Shell 双击到图纸窗口建立的总时间为 **19.84 秒**。未出现 `Failed to create empty document`。

该最终版本仍只修改当前用户的两个 `open\command` 默认值，可随时运行 `rollback_southmap_cold_open_association_fix.ps1` 回退。系统级关联、厂商二进制、用户图纸和 DXF 内容均未修改。
