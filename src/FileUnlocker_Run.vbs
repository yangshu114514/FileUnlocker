' FileUnlocker_Run.vbs -- coordinator + GUI layer
' ALL user-visible popups live HERE (VBS runs in the interactive session).
' The PowerShell worker (FileUnlocker.ps1) is a SILENT worker: it writes
' .fu_detect.txt / .fu_kill.txt and NEVER shows a MessageBox.
' Multi-select: Explorer launches us once per selected item; we collapse N
' instances into ONE queue, ONE coordinator, ONE worker, ONE popup each.

Dim fso, vbsPath, dir, q, lockFile, queueFile, target
Set fso = CreateObject("Scripting.FileSystemObject")
vbsPath = WScript.ScriptFullName
dir = fso.GetParentFolderName(vbsPath)
lockFile  = dir & "\.fu_lock"
queueFile = dir & "\.fu_queue.txt"

If WScript.Arguments.Count = 0 Then WScript.Quit 1
target = WScript.Arguments(0)
If target = "" Then WScript.Quit 1

' append this target to the shared queue
On Error Resume Next
Set qf = fso.OpenTextFile(queueFile, 8, True)
qf.WriteLine(target)
qf.Close
On Error GoTo 0

' grab coordinator lock; second instance fails to open for writing
Dim isCoordinator, lf
isCoordinator = False
On Error Resume Next
Set lf = fso.OpenTextFile(lockFile, 2, True)
If Err.Number = 0 Then
    isCoordinator = True
    lf.WriteLine("locked")
End If
On Error GoTo 0

If Not isCoordinator Then WScript.Quit 0

' coordinator: wait for stragglers to write their targets
WScript.Sleep 1200

' read + dedupe queue
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

' release lock + queue now that we have the deduped target set
On Error Resume Next
lf.Close
fso.DeleteFile queueFile, True
fso.DeleteFile lockFile, True
On Error GoTo 0

If dict.Count = 0 Then WScript.Quit 1

' locate pwsh.exe without spawning a visible cmd window (P10)
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
    Dim sh2, execObj, stdOut, line2
    Set sh2 = CreateObject("WScript.Shell")
    Set execObj = sh2.Exec("cmd.exe /c where pwsh.exe 2>nul")
    stdOut = execObj.StdOut.ReadAll
    For Each line2 In Split(stdOut, vbCrLf)
        If InStr(line2, "pwsh.exe") > 0 Then
            pwshPath = Trim(line2)
            Exit For
        End If
    Next
End If
If pwshPath = "" Then
    MsgBox "未找到 PowerShell 7 (pwsh.exe)。请先安装 PowerShell 7 后重试。" & vbCrLf & _
           "下载: https://github.com/PowerShell/PowerShell/releases", _
           vbExclamation, "解除文件占用"
    WScript.Quit 1
End If

' build |-joined target string for the worker
q = Chr(34)
Dim sb, k, ps1Path, detectFile, killFile
sb = ""
For Each k In dict.Keys
    If sb <> "" Then sb = sb & "|"
    sb = sb & k
Next
ps1Path    = dir & "\FileUnlocker.ps1"
detectFile = dir & "\.fu_detect.txt"
killFile   = dir & "\.fu_kill.txt"

On Error Resume Next
fso.DeleteFile detectFile, True
fso.DeleteFile killFile, True
On Error GoTo 0

' step 1: worker in DETECT mode (silent, writes .fu_detect.txt)
Dim detectArg
detectArg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & ps1Path & q & _
            " -Detect -Targets " & q & sb & q & " -OutFile " & q & detectFile & q

Dim wsh
Set wsh = CreateObject("WScript.Shell")
wsh.Run pwshPath & " " & detectArg, 0, True

' read detection result
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
    MsgBox "检测出错：" & parts("ERROR"), vbExclamation, "解除文件占用"
    WScript.Quit 1
End If

If occ = "0" Or pids = "" Then
    MsgBox "所选 " & total & " 个项目均未被任何进程占用。", vbInformation, "解除占用"
    WScript.Quit 0
End If

' occupied: ask to kill (process-level, not file-level)
Dim nameArr, dispName, confirmMsg, rc, i
nameArr = Split(names, ";")
dispName = ""
For i = 0 To UBound(nameArr)
    If nameArr(i) <> "" Then
        If dispName <> "" Then dispName = dispName & "、"
        dispName = dispName & nameArr(i)
    End If
Next
confirmMsg = "所选 " & total & " 个项目中，有 " & occ & " 个被以下进程占用：" & vbCrLf & vbCrLf & _
             dispName & vbCrLf & vbCrLf & _
             "是否终止这些进程以解除占用？"
rc = MsgBox(confirmMsg, vbYesNo + vbExclamation, "确认解锁")
If rc <> vbYes Then WScript.Quit 0

' step 2: worker in KILL mode as admin via scheduled task (silent)
Dim killArg
killArg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & ps1Path & q & _
          " -Kill -PidList " & q & pids & q

Dim sh
Set sh = CreateObject("Shell.Application")
sh.ShellExecute pwshPath, killArg, "", "runas", 0

' wait for .fu_kill.txt
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
If detail = "" Then detail = "(无详细信息)"

Dim resultMsg
resultMsg = "已请求终止 " & killed & " 个进程。" & vbCrLf & vbCrLf & detail
MsgBox resultMsg, vbInformation, "解除占用完成"
