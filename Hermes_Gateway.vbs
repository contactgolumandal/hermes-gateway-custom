Set objFSO = CreateObject("Scripting.FileSystemObject")
strPath = objFSO.GetParentFolderName(WScript.ScriptFullName)
strMonitorPath = objFSO.BuildPath(strPath, "Hermes_Gateway_Monitor.ps1")
CreateObject("Wscript.Shell").Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strMonitorPath & """", 0, False
