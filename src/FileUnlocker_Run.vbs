Option Explicit

' ============================================================
' FileUnlocker launcher (VBScript).
' NOTE: All user-facing text is ASCII-only on purpose. This file
' must stay readable by WSH as ANSI in ANY locale; a single
' mojibake byte previously caused error 800A0409 / 800A0402.
' Debug log goes to %TEMP%\FileUnlocker_debug.log
' ============================================================

Dim fso, shell
Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

Dim scriptDir, scriptPath, detectFile, killFile, lockFile, queueFile
scriptDir  = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = scriptDir & "\FileUnlocker.ps1"
detectFile = scriptDir & "\.fu_detect.txt"
killFile   = scriptDir & "\.fu_kill.txt"
lockFile   = scriptDir & "\.fu_lock"
queueFile  = scriptDir & "\.fu_queue.txt"

Dim DEBUG_LOG
DEBUG_LOG = shell.ExpandEnvironmentStrings("%TEMP%") & "\FileUnlocker_debug.log"
On Error Resume Next
fso.DeleteFile DEBUG_LOG, True
On Error GoTo 0

Sub LogIt(msg)
    Dim f
    On Error Resume Next
    Set f = fso.OpenTextFile(DEBUG_LOG, 8, True)
    If Err.Number = 0 Then
        f.WriteLine CStr(Now) & " | " & msg
        f.Close
    End If
    On Error GoTo 0
End Sub

LogIt "===== FileUnlocker VBS start ====="
LogIt "ScriptFullName=" & WScript.ScriptFullName
LogIt "argc=" & WScript.Arguments.Count

' ---- 1. drop stale lock/queue older than 30s ----
On Error Resume Next
If fso.FileExists(lockFile) Then
    If DateDiff("s", fso.GetFile(lockFile).DateLastModified, Now) > 30 Then
        fso.DeleteFile lockFile, True
        fso.DeleteFile queueFile, True
    End If
End If
On Error GoTo 0

' ---- 2. need one path argument ----
If WScript.Arguments.Count = 0 Then
    LogIt "no args, show usage"
    shell.Popup "Usage: right-click a file/folder and choose ""FileUnlocker"".", 60, "FileUnlocker", 64
    WScript.Quit 1
End If
LogIt "arg0=" & WScript.Arguments(0)

' ---- 3. enqueue our path (multi-select launches one instance per file) ----
Dim qf
On Error Resume Next
Set qf = fso.OpenTextFile(queueFile, 8, True)
If Err.Number = 0 Then
    qf.WriteLine(Trim(CStr(WScript.Arguments(0))))
    qf.Close
End If
On Error GoTo 0

' ---- 4. coordinator election: first instance grabbing the lock wins ----
Dim isCoordinator, lockHandle
isCoordinator = False
On Error Resume Next
Set lockHandle = fso.OpenTextFile(lockFile, 2, True)
If Err.Number = 0 Then
    isCoordinator = True
    lockHandle.WriteLine("locked")
End If
On Error GoTo 0

If Not isCoordinator Then
    LogIt "not coordinator, exit (coordinator will handle us)"
    WScript.Quit 0
End If
LogIt "became coordinator"

' ---- 5. wait until queue stable (2 consecutive equal counts) ----
Dim lastCount, curCount, stableFor, qf2, ln
lastCount = -1
stableFor = 0
curCount  = 0
Do While stableFor < 2
    WScript.Sleep 70
    curCount = 0
    If fso.FileExists(queueFile) Then
        Set qf2 = fso.OpenTextFile(queueFile, 1)
        Do While Not qf2.AtEndOfStream
            qf2.ReadLine
            curCount = curCount + 1
        Loop
        qf2.Close
    End If
    If curCount = lastCount Then
        stableFor = stableFor + 1
    Else
        lastCount = curCount
        stableFor = 0
    End If
Loop

' ---- 6. dedupe queued paths ----
Dim dict
Set dict = CreateObject("Scripting.Dictionary")
dict.CompareMode = 1
If fso.FileExists(queueFile) Then
    Set qf2 = fso.OpenTextFile(queueFile, 1)
    Do While Not qf2.AtEndOfStream
        ln = Trim(qf2.ReadLine)
        If ln <> "" Then dict(ln) = True
    Loop
    qf2.Close
End If

On Error Resume Next
lockHandle.Close
fso.DeleteFile queueFile, True
fso.DeleteFile lockFile, True
On Error GoTo 0

If dict.Count = 0 Then
    LogIt "empty queue, exit"
    WScript.Quit 1
End If
LogIt "collected " & dict.Count & " path(s)"

' ---- 7. join paths with | ----
Dim sb, k
sb = ""
For Each k In dict.Keys
    If sb <> "" Then sb = sb & "|"
    sb = sb & k
Next

' ---- 8. locate pwsh.exe ----
Dim pwsh, probe
pwsh = ""
For Each probe In Array("C:\Program Files\PowerShell\7\pwsh.exe", "C:\Program Files (x86)\PowerShell\7\pwsh.exe")
    If fso.FileExists(probe) Then pwsh = probe : Exit For
Next
If pwsh = "" Then
    On Error Resume Next
    Dim wproc : Set wproc = shell.Exec("where pwsh.exe 2>nul")
    If Err.Number = 0 Then
        pwsh = Trim(Split(wproc.StdOut.ReadAll(), vbCrLf)(0))
    End If
    On Error GoTo 0
End If

If pwsh = "" Or Not fso.FileExists(pwsh) Then
    LogIt "pwsh.exe not found"
    shell.Popup "PowerShell 7 (pwsh.exe) not found." & vbCrLf & _
                "Install it first: https://github.com/PowerShell/PowerShell/releases", _
                60, "FileUnlocker - missing dependency", 48
    WScript.Quit 1
End If
LogIt "pwsh=" & pwsh

If Not fso.FileExists(scriptPath) Then
    LogIt "ps1 missing: " & scriptPath
    shell.Popup "Main script not found:" & vbCrLf & scriptPath, 60, "FileUnlocker - error", 48
    WScript.Quit 1
End If

' ---- 9. run detect (synchronous) ----
Dim q, args, cmd, code, output
q = Chr(34)
On Error Resume Next
fso.DeleteFile detectFile, True
On Error GoTo 0

args = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden " & _
       "-File " & q & scriptPath & q & " " & _
       "-Detect -Targets " & q & sb & q & " -OutFile " & q & detectFile & q
cmd = q & pwsh & q & " " & args
LogIt "start detect"
LogIt "DETECT_CMD=" & cmd
code = shell.Run(cmd, 0, True)
LogIt "detect exit code=" & code

If code <> 0 Then
    LogIt "detect failed, code=" & code
    shell.Popup "Detect failed, exit code: " & code, 60, "FileUnlocker - error", 48
    WScript.Quit 1
End If

If Not fso.FileExists(detectFile) Then
    LogIt "no detect output file"
    shell.Popup "No detect result was produced.", 60, "FileUnlocker - error", 48
    WScript.Quit 1
End If

output = ReadUtf8File(detectFile)
LogIt "detect result: " & output

' ---- 10. parse and show ----
Dim total, occupied, pids, names
total    = GetValue(output, "TARGETS", "?")
occupied = GetValue(output, "OCCUPIED", "0")
pids     = GetValue(output, "PIDS", "")
names    = GetValue(output, "PROCNAMES", "")

If occupied = "0" Or pids = "" Then
    shell.Popup "Selected " & total & " item(s) are NOT locked." & vbCrLf & vbCrLf & _
                "You can delete/move/rename them directly.", _
                60, "FileUnlocker - not locked", 64
    WScript.Quit 0
End If

Dim confirmMsg, userChoice
confirmMsg = "Found " & occupied & " locking process(es):" & vbCrLf & vbCrLf & names & _
             vbCrLf & vbCrLf & "WARNING: force-killing may lose unsaved data." & vbCrLf & _
             "Kill them now?"
userChoice = shell.Popup(confirmMsg, 0, "FileUnlocker - confirm kill", 33)   ' 33 = vbYesNo + vbQuestion
LogIt "confirm result=" & userChoice & " (6=yes, 7=no)"

If userChoice <> 6 Then
    LogIt "user chose NO (or closed), exit"
    WScript.Quit 0
End If
LogIt "user confirmed, start kill"

' ---- 11. kill: run ps1 asynchronously, poll for result file ----
On Error Resume Next
fso.DeleteFile killFile, True
On Error GoTo 0

args = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden " & _
       "-File " & q & scriptPath & q & " " & _
       "-Kill -PidList " & q & pids & q & " -OutFile " & q & killFile & q
cmd = q & pwsh & q & " " & args
LogIt "start kill, PIDS=[" & pids & "]"
LogIt "KILL_CMD=" & cmd

Dim killProc
Set killProc = Nothing
On Error Resume Next
Set killProc = shell.Exec(cmd)
If Err.Number <> 0 Then
    LogIt "Exec kill failed: " & Err.Number & " " & Err.Description
End If
On Error GoTo 0

Dim killWait, killCount, killDetail
killWait = 0
Do While killWait < 300   ' up to 150s (elevation prompt may take a while)
    WScript.Sleep 500
    killWait = killWait + 1
    If fso.FileExists(killFile) Then
        LogIt "kill result file appeared after " & killWait & " x 0.5s"
        Exit Do
    End If
Loop
If killWait >= 300 Then LogIt "kill wait timeout (150s)"

If fso.FileExists(killFile) Then
    output = ReadUtf8File(killFile)
    killCount  = GetValue(output, "KILLED", "?")
    killDetail = GetValue(output, "DETAIL", "(no detail)")
    LogIt "kill result: " & output
Else
    killCount = "0"
    If killWait >= 300 Then
        killDetail = "Timed out waiting for kill result (150s)."
    Else
        killDetail = "Kill script produced no result file."
    End If
    LogIt "kill failed: " & killDetail
End If

' ---- 12. clean temp files ----
On Error Resume Next
fso.DeleteFile detectFile, True
fso.DeleteFile killFile, True
On Error GoTo 0

' ---- 13. ALWAYS show a final result popup so the user gets feedback ----
Dim resultMsg
resultMsg = "Done. Force-terminated " & killCount & " process(es)." & vbCrLf & vbCrLf & _
            "Detail:" & vbCrLf & killDetail
LogIt "final result: KILLED=" & killCount
shell.Popup resultMsg, 60, "FileUnlocker - result", 64
LogIt "===== VBS end ====="

WScript.Quit 0


' ---- helper: read KEY=VALUE from result text ----
Function GetValue(text, key, defaultValue)
    Dim lines, line
    If text = "" Then GetValue = defaultValue : Exit Function
    lines = Split(text, vbCrLf)
    For Each line In lines
        line = Trim(line)
        If Left(line, Len(key) + 1) = key & "=" Then
            GetValue = Mid(line, Len(key) + 2)
            Exit Function
        End If
    Next
    GetValue = defaultValue
End Function


' ---- helper: read UTF-8 file written by the ps1 ----
Function ReadUtf8File(filePath)
    Dim stream
    Set stream = CreateObject("ADODB.Stream")
    stream.Type = 2
    stream.Charset = "utf-8"
    stream.Open
    stream.LoadFromFile filePath
    ReadUtf8File = stream.ReadText
    stream.Close
    Set stream = Nothing
End Function
