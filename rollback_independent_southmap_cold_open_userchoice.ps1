[CmdletBinding()]
param(
 [string]$BackupDirectory='E:\Manus程序测试\RoadCurveImporter\SouthMap_独立UserChoice关联备份_20260825_085723'
)
$ErrorActionPreference='Stop'
$running=Get-Process -Name ZWCAD,ZwLauncher,StartCAD -ErrorAction SilentlyContinue
if($running){throw '请先关闭 SouthMap/ZWCAD 后再回滚文件关联，避免缓存导致结果不一致。'}
if(-not(Test-Path -LiteralPath $BackupDirectory)){throw "找不到首次安装前关联备份目录：$BackupDirectory"}
$entries=@(
 [pscustomobject]@{Extension='.dxf';ProgId='RoadCurveImporter.SouthMapColdOpen.DXF';Backup='dxf.reg'},
 [pscustomobject]@{Extension='.dwg';ProgId='RoadCurveImporter.SouthMapColdOpen.DWG';Backup='dwg.reg'}
)
foreach($entry in $entries){
 $userChoice="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$($entry.Extension)\UserChoice"
 if(Test-Path -LiteralPath $userChoice){Remove-Item -LiteralPath $userChoice -Recurse -Force}
 $customKey="HKCU:\Software\Classes\$($entry.ProgId)"
 if(Test-Path -LiteralPath $customKey){Remove-Item -LiteralPath $customKey -Recurse -Force}
 $openWith="HKCU:\Software\Classes\$($entry.Extension)\OpenWithProgids"
 if(Test-Path -LiteralPath $openWith){Remove-ItemProperty -LiteralPath $openWith -Name $entry.ProgId -ErrorAction SilentlyContinue}
 $regFile=Join-Path $BackupDirectory $entry.Backup
 if(Test-Path -LiteralPath $regFile){& reg.exe import $regFile|Out-Null;if($LASTEXITCODE -ne 0){throw "无法恢复：$regFile"}}
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RoadCurveAssociationRefresh { [DllImport("Shell32.dll")] public static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2); }
'@ -ErrorAction SilentlyContinue
[RoadCurveAssociationRefresh]::SHChangeNotify(0x08000000,0,[IntPtr]::Zero,[IntPtr]::Zero)
[pscustomobject]@{Timestamp=(Get-Date -Format o);RestoredFrom=$BackupDirectory;Action='Restored pre-independent-association FileExts registry backups and removed RoadCurveImporter custom ProgIDs.';CadDocumentsTouched=$false}|ConvertTo-Json
