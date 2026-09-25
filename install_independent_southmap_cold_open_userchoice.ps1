$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSCommandPath
$cmd=Join-Path $root 'SouthMapColdOpen.vbs'
$wscript=Join-Path $env:WINDIR 'System32\wscript.exe'
$sfta=Join-Path $root 'PS-SFTA_1.2.0_local_sid_patch.ps1'
$icon='D:\Program Files\SouthMap\SouthMap For ZWCADOEM 2026\ZWCAD.exe,2'
if(-not(Test-Path -LiteralPath $cmd)){throw '冷启动 WScript 桥接器不存在。'}
if(-not(Test-Path -LiteralPath $wscript)){throw 'Windows wscript.exe 不存在。'}
if(-not(Test-Path -LiteralPath $sfta)){throw '已审阅 PS-SFTA 源码不存在。'}
$expected='F036C249F602D7FC44C6EFCCC2C9E6C5F393E70BE1FC4D0719F4C09AF274B3F6'
if((Get-FileHash -LiteralPath $sfta -Algorithm SHA256).Hash -ne $expected){throw 'PS-SFTA 哈希不匹配，拒绝执行。'}
$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$backupDir=Join-Path $root ('SouthMap_独立UserChoice关联备份_'+$stamp)
New-Item -ItemType Directory -Path $backupDir -Force|Out-Null
$entries=@(
 [pscustomobject]@{Extension='.dxf';ProgId='RoadCurveImporter.SouthMapColdOpen.DXF'},
 [pscustomobject]@{Extension='.dwg';ProgId='RoadCurveImporter.SouthMapColdOpen.DWG'}
)
foreach($entry in $entries){
 $subkey='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\'+$entry.Extension
 & reg.exe query $subkey *> $null
 if($LASTEXITCODE -eq 0){& reg.exe export $subkey (Join-Path $backupDir (($entry.Extension.TrimStart('.'))+'.reg')) /y|Out-Null}
}
. $sfta
foreach($entry in $entries){
 $openWith='HKEY_CURRENT_USER\SOFTWARE\Classes\'+$entry.Extension+'\OpenWithProgids'
 [Microsoft.Win32.Registry]::SetValue($openWith,$entry.ProgId,([byte[]]@()),[Microsoft.Win32.RegistryValueKind]::None)
 $commandKey='HKEY_CURRENT_USER\SOFTWARE\Classes\'+$entry.ProgId+'\shell\open\command'
 $openCommand='"'+$wscript+'" "'+$cmd+'" "%1"'
 [Microsoft.Win32.Registry]::SetValue($commandKey,'',$openCommand)
 Set-FTA -ProgId $entry.ProgId -Extension $entry.Extension -Icon $icon -DomainSID
}
$effective=& "$root\query_windows_effective_file_association.ps1" | ConvertFrom-Json
$result=[pscustomobject]@{Timestamp=(Get-Date -Format o);Scope='Current user UserChoice';Program=$cmd;PS_SFTA_SHA256=$expected;Entries=$entries;BackupDirectory=$backupDir;EffectiveAssociation=$effective.Resolved;Rollback='Run rollback_independent_southmap_cold_open_userchoice.ps1 while SouthMap/ZWCAD is closed.';SystemAssociationUntouched=$true;UserOriginalDrawingsTouched=$false}
$result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $backupDir 'install_record.json') -Encoding utf8
$result|ConvertTo-Json -Depth 8
