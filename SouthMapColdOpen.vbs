Option Explicit

Dim shell, fso, rootFolder, psScript, psExe, fileArg, commandLine
If WScript.Arguments.Count <> 1 Then
  WScript.Quit 87
End If

fileArg = WScript.Arguments.Item(0)
Set fso = CreateObject("Scripting.FileSystemObject")
rootFolder = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = fso.BuildPath(rootFolder, "SouthMapColdOpen.ps1")
psExe = "C:\Program Files\PowerShell\7\pwsh.exe"

If Not fso.FileExists(psExe) Then WScript.Quit 2
If Not fso.FileExists(psScript) Then WScript.Quit 3
If Not fso.FileExists(fileArg) Then WScript.Quit 4

commandLine = Chr(34) & psExe & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & psScript & Chr(34) & " " & Chr(34) & fileArg & Chr(34)
Set shell = CreateObject("WScript.Shell")
shell.Run commandLine, 0, False
