Set objFSO = CreateObject("Scripting.FileSystemObject")
strPath = objFSO.GetParentFolderName(WScript.ScriptFullName)
strMonitorPath = objFSO.BuildPath(strPath, "Hermes_Gateway_Monitor.ps1")
strArgs = ""
For Each arg In WScript.Arguments
    strArgs = strArgs & " """ & arg & """"
Next
CreateObject("Wscript.Shell").Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strMonitorPath & """" & strArgs, 0, False
