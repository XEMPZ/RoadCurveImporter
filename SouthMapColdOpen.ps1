[CmdletBinding()]
param([Parameter(Mandatory=$true,Position=0)][string]$FilePath)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSCommandPath
$startCad='D:\Program Files\SouthMap\SouthMap For ZWCADOEM 2026\StartCAD.exe'
$launcher='D:\Program Files\SouthMap\SouthMap For ZWCADOEM 2026\ZwLauncher.exe'
$fullPath=[IO.Path]::GetFullPath($FilePath)
$extension=[IO.Path]::GetExtension($fullPath).ToLowerInvariant()
if($extension -notin @('.dwg','.dxf')){throw '仅允许通过 SouthMap 冷启动包装器打开 .dwg 或 .dxf 文件。'}
if(-not(Test-Path -LiteralPath $fullPath -PathType Leaf)){throw "图纸不存在：$fullPath"}
if(-not(Test-Path -LiteralPath $startCad)){throw "缺少官方 StartCAD.exe：$startCad"}
if(-not(Test-Path -LiteralPath $launcher)){throw "缺少官方 ZwLauncher.exe：$launcher"}
$log=Join-Path $root 'SouthMapColdOpen.log'
function Write-OpenLog([string]$message){("[{0}] {1}" -f (Get-Date -Format o),$message)|Add-Content -LiteralPath $log -Encoding utf8}
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class SouthMapColdOpenWindows {
 public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
 [DllImport("user32.dll")] static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);
 public static string[] Titles() {var values=new List<string>();EnumWindows((h,l)=>{if(!IsWindowVisible(h))return true;var s=new StringBuilder(2048);GetWindowText(h,s,s.Capacity);if(s.Length>0)values.Add(s.ToString());return true;},IntPtr.Zero);return values.ToArray();}
}
'@
$hadZwcad=@(Get-Process -Name ZWCAD -ErrorAction SilentlyContinue).Count -gt 0
if(-not $hadZwcad){
 Write-OpenLog "Cold start: invoking official StartCAD.exe before ZwLauncher for $fullPath"
 Start-Process -FilePath $startCad|Out-Null
 $deadline=(Get-Date).AddSeconds(45)
 do {Start-Sleep -Milliseconds 500;$ready=@([SouthMapColdOpenWindows]::Titles()|Where-Object {$_ -match '^SouthMap - \[Drawing\d+\.dwg\]$'}).Count -gt 0} while((Get-Date) -lt $deadline -and -not $ready)
 if(-not $ready){throw '官方 StartCAD 未在 45 秒内建立空白 SouthMap 文档；未调用 ZwLauncher。'}
}
# 空白文档的窗口出现并不意味着 OEM 模块和命名管道已经完成注册；额外留出稳定时间。
if(-not $hadZwcad){Start-Sleep -Seconds 5}
$escapedPath=[regex]::Escape($fullPath)
$opened=$false;$attempts=@()
for($attempt=1;$attempt -le 5 -and -not $opened;$attempt++){
 Write-OpenLog "ZwLauncher transfer attempt $attempt for $fullPath; existingZwcad=$hadZwcad"
 Start-Process -FilePath $launcher -ArgumentList ('"'+$fullPath+'"')|Out-Null
 $deadline=(Get-Date).AddSeconds(8)
 do {Start-Sleep -Milliseconds 500;$opened=@([SouthMapColdOpenWindows]::Titles()|Where-Object {$_ -match $escapedPath}).Count -gt 0} while((Get-Date) -lt $deadline -and -not $opened)
 $attempts += [pscustomobject]@{Attempt=$attempt;Opened=$opened;Timestamp=(Get-Date -Format o)}
 if(-not $opened -and $attempt -lt 5){Start-Sleep -Seconds 2}
}
if(-not $opened){Write-OpenLog "FAILED: ZwLauncher did not present document window after 5 attempts for $fullPath";throw 'SouthMap 已启动但原厂启动器在重试后仍未建立图纸窗口；详见 SouthMapColdOpen.log。'}
Write-OpenLog "SUCCESS: document window appeared after $($attempts.Count) transfer attempt(s) for $fullPath"
[pscustomobject]@{Timestamp=(Get-Date -Format o);FilePath=$fullPath;ColdStart=(-not $hadZwcad);StartCadUsed=(-not $hadZwcad);OriginalZwLauncherUsed=$true;Opened=$opened;Attempts=$attempts;Result='Official StartCAD initialized the OEM session and original ZwLauncher transferred the file successfully.'}|ConvertTo-Json -Depth 5
