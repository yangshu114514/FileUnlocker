Dim fso, scriptFullName, scriptDir, q, lockFile, queueFile, target
Set fso = CreateObject("Scripting.FileSystemObject")
scriptFullName = WScript.ScriptFullName
scriptDir = fso.GetParentFolderName(scriptFullName)
lockFile  = scriptDir & "\.fu_lock"
queueFile = scriptDir & "\.fu_queue.txt"

' F1: Clean up stale lock/queue files from crashed previous invocations.
On Error Resume Next
fso.DeleteFile lockFile, True
fso.DeleteFile queueFile, True
On Error GoTo 0

If WScript.Arguments.Count = 0 Then WScript.Quit 1
target = WScript.Arguments(0)
If target = "" Then WScript.Quit 1

On Error Resume Next
Set qf = fso.OpenTextFile(queueFile, 8, True)
qf.WriteLine(target)
qf.Close
On Error GoTo 0

' F1: Coordinator lock — only one instance processes the queue at a time.
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

' F2: Locate pwsh.exe
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
    Dim wsh1
    Set wsh1 = CreateObject("WScript.Shell")
    wsh1.Popup "PowerShell 7 not found. Please install PowerShell 7 first." & vbCrLf & _
               "Download: https://github.com/PowerShell/PowerShell/releases", _
               60, "File Unlocker", 48
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

' F3: 使用 ShellExecute 启动 pwsh，但用独立的 wscript 实例包装器，避免阻塞主脚本
' 这样主脚本的 WScript.Shell 不会被破坏，Popup 可以正常显示
Dim shApp
Set shApp = CreateObject("Shell.Application")

' 清理旧的检测文件
On Error Resume Next
fso.DeleteFile detectFile, True
On Error GoTo 0

' 通过 ShellExecute 启动 pwsh（非阻塞，窗口隐藏）
shApp.ShellExecute pwshPath, detectArg, "", "open", 0

' F4: Poll for the detect output file (max 30 seconds)
Dim waited, ok
waited = 0
ok = False
Do While waited < 60
    WScript.Sleep 500
    waited = waited + 1
    If fso.FileExists(detectFile) Then
        ok = True
        Exit Do
    End If
Loop

Dim content, parts, kv, total, occ, pids, names
content = ""
If ok And fso.FileExists(detectFile) Then
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
If total = "" Then total = "0"
If occ   = "" Then occ   = "0"

If parts.Exists("ERROR") Then
    Dim wsh2
    Set wsh2 = CreateObject("WScript.Shell")
    wsh2.Popup "Detection error: " & parts("ERROR"), 60, "File Unlocker", 48
    WScript.Quit 1
End If

if Not ok Then
    Dim wshT
    Set wshT = CreateObject("WScript.Shell")
    wshT.Popup "Detection timed out. Please try again.", 60, "File Unlocker", 48
    WScript.Quit 1
End If

' F5: All Popup calls now use a 60-second timeout instead of 0 (infinite).
' This prevents zombie processes when the dialog fails to display.
Dim wshPop
Set wshPop = CreateObject("WScript.Shell")

If occ = "0" Or pids = "" Then
    wshPop.Popup "None of the " & total & " selected items are locked.", _
                 60, "File Unlocker", 64
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
rc = wshPop.Popup(confirmMsg, 60, "Confirm Unlock", 36)
If rc <> 6 Then WScript.Quit 0

killArg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & ps1Path & q & _
          " -Kill -PidList " & q & pids & q

' KILL 模式也用 ShellExecute (runas 提权)
shApp.ShellExecute pwshPath, killArg, "", "runas", 1

waited = 0
killContent = ""
Do While waited < 30
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
wshPop.Popup resultMsg, 60, "Unlock Complete", 64