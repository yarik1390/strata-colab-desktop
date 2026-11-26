Option Explicit
Dim fso, sh, uiDir, ps1, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
uiDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(uiDir, "StrataLauncher.ps1")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & ps1 & """"
sh.Run cmd, 0, False
