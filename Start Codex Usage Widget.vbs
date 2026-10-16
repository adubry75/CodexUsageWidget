Set sh = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
folder = fs.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File " & Chr(34) & folder & "\CodexUsageWidget.ps1" & Chr(34)
If WScript.Arguments.Named.Exists("test") Then
    command = command & " -SelfTest"
    result = sh.Run(command, 0, True)
    WScript.Quit result
Else
    sh.Run command, 0, False
End If
