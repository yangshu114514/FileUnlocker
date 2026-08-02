Dim fso, scriptFullName, scriptDir, q, lockFile, queueFile, target
Set fso = CreateObject("Scripting.FileSystemObject")
scriptFullName = WScript.ScriptFullName
scriptDir = fso.GetParentFolderName(scriptFullName)
lockFile  = scriptDir & "\.fu_lock"
queueFile = scriptDir & "\.fu_queue.txt"

If WScript.Arguments.Count = 0 Then WScript.Quit 1
target = WScript.Arguments(0)
If target = "" Then WScript.Quit 1

On Error Resume Next
Set qf = fso.OpenTextFile(queueFile, 8, True)
qf.WriteLine(target)
qf.Close
On Error GoTo 0

Dim isCoordinator, lockHandle
isCoordinator = False
On Error Resume Next
Set lockHandle = fso.OpenTextFile(lockFile, 2, True)
If Err.Number = 0 Then
    isCoordinator = True
    lockHandle.WriteLine("locked")
End If
On Error GoTo 0

If Not isCoordinator Then WScript.Quit 0

WScript.Sleep 1200

Dim dict, ln
Set dict = CreateObject("Scripting.Dictionary")
dict.CompareMode = 1
If fso.FileExists(queueFile) Then
    Set qf = fso.OpenTextFile(queueFile, 1)
    Do While Not qf.AtEndOfStream
        ln = Trim(qf.ReadLine)
        If ln <> "" Then dict(ln) = True
    Loop
    qf.Close
End If

On Error Resume Next
lockHandle.Close
fso.DeleteFile queueFile, True
fso.DeleteFile lockFile, True
On Error GoTo 0

If dict.Count = 0 Then WScript.Quit 1

Dim pwshPath, probe
pwshPath = ""
For Each probe In Array( _
    "C:\Program Files\PowerShell\7\pwsh.exe", _
    "C:\Program Files (x86)\PowerShell\7\pwsh.exe" )
    If fso.FileExists(probe) Then
        pwshPath = probe
        Exit For
    End If
Next
If pwshPath = "" Then
    Dim shellExec, execObj, stdOut, line2
    Set shellExec = CreateObject("WScript.Shell")
    Set execObj = shellExec.Exec("cmd.exe /c where pwsh.exe 2>nul")
    stdOut = execObj.StdOut.ReadAll
    For Each line2 In Split(stdOut, vbCrLf)
        If InStr(line2, "pwsh.exe") > 0 Then
            pwshPath = Trim(line2)
            Exit For
        End If
    Next
End If
If pwshPath = "" Then
    MsgBox "PowerShell 7 not found. Please install PowerShell 7 first." & vbCrLf & _
           "Download: https://github.com/PowerShell/PowerShell/releases", _
           vbExclamation, "File Unlocker"
    WScript.Quit 1
End If

q = Chr(34)
Dim sb, k, ps1Path, detectFile, killFile
sb = ""
For Each k In dict.Keys
    If sb <> "" Then sb = sb & "|"
    sb = sb & k
Next
ps1Path    = scriptDir & "\FileUnlocker.ps1"
detectFile = scriptDir & "\.fu_detect.txt"
killFile   = scriptDir & "\.fu_kill.txt"

On Error Resume Next
fso.DeleteFile detectFile, True
fso.DeleteFile killFile, True
On Error GoTo 0

detectArg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & ps1Path & q & _
            " -Detect -Targets " & q & sb & q & " -OutFile " & q & detectFile & q

Dim wshExec
Set wshExec = CreateObject("WScript.Shell")
wshExec.Run Chr(34) & pwshPath & Chr(34) & " " & detectArg, 0, True

Dim content, parts, kv, total, occ, pids, names
content = ""
If fso.FileExists(detectFile) Then
    Dim cf
    Set cf = fso.OpenTextFile(detectFile, 1)
    content = cf.ReadAll
    cf.Close
End If

Set parts = CreateObject("Scripting.Dictionary")
For Each ln In Split(content, vbCrLf)
    ln = Trim(ln)
    If ln <> "" And InStr(ln, "=") > 0 Then
        kv = Split(ln, "=", 2)
        parts(kv(0)) = kv(1)
    End If
Next
total = parts("TARGETS")
occ   = parts("OCCUPIED")
pids  = parts("PIDS")
names = parts("PROCNAMES")
If total = "" Then total = "?"
If occ   = "" Then occ   = "?"

If parts.Exists("ERROR") Then
    MsgBox "Detection error: " & parts("ERROR"), vbExclamation, "File Unlocker"
    WScript.Quit 1
End If

If occ = "0" Or pids = "" Then
    MsgBox "None of the " & total & " selected items are locked.", vbInformation, "File Unlocker"
    WScript.Quit 0
End If

Dim nameArr, dispName, confirmMsg, rc, i
nameArr = Split(names, ";")
dispName = ""
For i = 0 To UBound(nameArr)
    If nameArr(i) <> "" Then
        If dispName <> "" Then dispName = dispName & ", "
        dispName = dispName & nameArr(i)
    End If
Next
confirmMsg = "Of the " & total & " selected items, " & occ & " are locked by:" & vbCrLf & vbCrLf & _
             dispName & vbCrLf & vbCrLf & _
             "Kill these processes to unlock?"
rc = MsgBox(confirmMsg, vbYesNo + vbExclamation, "Confirm Unlock")
If rc <> vbYes Then WScript.Quit 0

killArg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & ps1Path & q & _
          " -Kill -PidList " & q & pids & q

Dim shApp
Set shApp = CreateObject("Shell.Application")
shApp.ShellExecute pwshPath, killArg, "", "runas", 0

Dim waited, killContent
waited = 0
killContent = ""
Do While waited < 20
    WScript.Sleep 500
    waited = waited + 1
    If fso.FileExists(killFile) Then
        Dim kf
        Set kf = fso.OpenTextFile(killFile, 1)
        killContent = kf.ReadAll
        kf.Close
        If InStr(killContent, "KILLED=") > 0 Then Exit Do
    End If
Loop

Dim kParts, killed, detail
Set kParts = CreateObject("Scripting.Dictionary")
For Each ln In Split(killContent, vbCrLf)
    ln = Trim(ln)
    If ln <> "" And InStr(ln, "=") > 0 Then
        kv = Split(ln, "=", 2)
        kParts(kv(0)) = kv(1)
    End If
Next
killed = kParts("KILLED")
detail = kParts("DETAIL")
If killed = "" Then killed = "?"
If detail = "" Then detail = "(no details)"

Dim resultMsg
resultMsg = "Killed " & killed & " process(es)." & vbCrLf & vbCrLf & detail
MsgBox resultMsg, vbInformation, "Unlock Complete"
