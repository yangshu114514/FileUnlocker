Option Explicit

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

' ===================================================
' ������־��%TEMP%\FileUnlocker_debug.log��
' ===================================================
Dim DEBUG_LOG, debugErr
DEBUG_LOG = shell.ExpandEnvironmentStrings("%TEMP%") & "\FileUnlocker_debug.log"
On Error Resume Next
fso.DeleteFile DEBUG_LOG, True
debugErr = Err.Number
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

LogIt "===== FileUnlocker VBS ���� ====="
LogIt "ScriptFullName=" & WScript.ScriptFullName
LogIt "��������=" & WScript.Arguments.Count

' ===================================================
' 1. ���� 30 ��ǰ�ĳ¾���/���У��ϴα���������
' ===================================================
On Error Resume Next
If fso.FileExists(lockFile) Then
    If DateDiff("s", fso.GetFile(lockFile).DateLastModified, Now) > 30 Then
        fso.DeleteFile lockFile, True
        fso.DeleteFile queueFile, True
    End If
End If
On Error GoTo 0

' ===================================================
' 2. �����������봫������һ���ļ�/�ļ���·��
' ===================================================
If WScript.Arguments.Count = 0 Then
    LogIt "����: �޲�������ʾ�÷�"
    shell.Popup "�÷���" & vbCrLf & _
                "wscript.exe """ & WScript.ScriptFullName & """ ""Ŀ��·��""" & vbCrLf & vbCrLf & _
                "����ͨ���Ҽ��˵� -������ļ�ռ�á����á�", _
                60, "FileUnlocker - ʹ��˵��", 64
    WScript.Quit 1
End If
LogIt "����0=" & WScript.Arguments(0)

' ===================================================
' 3. ��ѡ�ϲ������Լ���·��д�����
'    �Ҽ���ѡʱ����Դ���������ÿ���ļ�������һ�α��ű���
'    ��˰�·���ȴ�������ļ�������Э����һ���Դ�����
' ===================================================
Dim qf
On Error Resume Next
Set qf = fso.OpenTextFile(queueFile, 8, True)   ' 8 = ForAppending���������򴴽�
If Err.Number = 0 Then
    qf.WriteLine(Trim(CStr(WScript.Arguments(0))))
    qf.Close
End If
On Error GoTo 0

' ===================================================
' 4. ��������һ���ɹ��������ļ�����Э���ߣ����������˳�
' ===================================================
Dim isCoordinator, lockHandle
isCoordinator = False
On Error Resume Next
Set lockHandle = fso.OpenTextFile(lockFile, 2, True)   ' 2 = ForWriting����ռ��
If Err.Number = 0 Then
    isCoordinator = True
    lockHandle.WriteLine("locked")
End If
On Error GoTo 0

If Not isCoordinator Then
    LogIt "��Э���ߣ��˳�������Э���ߴ�����"
    WScript.Quit 0
End If
LogIt "��ʵ����ΪЭ����"

' ===================================================
' 5. Э���ߣ��ȶ��в������������ 3 ���ȶ����ڣ�
' ===================================================
Dim lastCount, curCount, stableFor, qf2, tmpLine
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

' ===================================================
' 6. �����в�ȥ�أ�Ȼ����������/��
' ===================================================
Dim dict, ln
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
    LogIt "����Ϊ�գ��˳�"
    WScript.Quit 1
End If
LogIt "�ռ��� " & dict.Count & " ��·��"

' ===================================================
' 7. ƴ������·����| �ָ���
' ===================================================
Dim sb, k
sb = ""
For Each k In dict.Keys
    If sb <> "" Then sb = sb & "|"
    sb = sb & k
Next

' ===================================================
' 8. ��λ pwsh.exe
' ===================================================
Dim pwsh, probe, proc, rawOut, firstLine
pwsh = ""
For Each probe In Array("C:\Program Files\PowerShell\7\pwsh.exe", "C:\Program Files (x86)\PowerShell\7\pwsh.exe")
    If fso.FileExists(probe) Then pwsh = probe : Exit For
Next
If pwsh = "" Then
    On Error Resume Next
    Set proc = shell.Exec("where pwsh.exe 2>nul")
    If Err.Number = 0 Then
        rawOut = proc.StdOut.ReadAll()
        firstLine = Split(rawOut, vbCrLf)(0)
        pwsh = Trim(firstLine)
    End If
    On Error GoTo 0
End If

If pwsh = "" Or Not fso.FileExists(pwsh) Then
    LogIt "����: �Ҳ��� pwsh.exe"
    shell.Popup "�Ҳ��� PowerShell 7 (pwsh.exe)��" & vbCrLf & vbCrLf & _
                "���Ȱ�װ��" & vbCrLf & "https://github.com/PowerShell/PowerShell/releases", _
                60, "FileUnlocker - ȱ������", 48
    WScript.Quit 1
End If
LogIt "pwsh=" & pwsh

If Not fso.FileExists(scriptPath) Then
    LogIt "����: �Ҳ������ű� " & scriptPath
    shell.Popup "�Ҳ������ű���" & vbCrLf & scriptPath, 60, "FileUnlocker - ����", 48
    WScript.Quit 1
End If
LogIt "scriptPath=" & scriptPath

' ===================================================
' 9. ���� FileUnlocker.ps1 ����ռ�ü�⣨ͬ���ȴ���
' ===================================================
Dim q, args, cmd, code, output
q = Chr(34)
On Error Resume Next
fso.DeleteFile detectFile, True
On Error GoTo 0

args = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden " & _
       "-File " & q & scriptPath & q & " " & _
       "-Detect -Targets " & q & sb & q & " -OutFile " & q & detectFile & q
cmd = q & pwsh & q & " " & args
LogIt "��ʼ detect"
LogIt "DETECT_CMD=" & cmd
code = shell.Run(cmd, 0, True)
LogIt "detect �����˳���=" & code

If code <> 0 Then
    LogIt "detect ʧ�ܣ��˳���=" & code
    If fso.FileExists(detectFile) Then
        output = ReadUtf8File(detectFile)
        LogIt "detect �����ļ�����=" & output
        If InStr(output, "ERROR=") > 0 Then
            Dim errLine
            For Each errLine In Split(output, vbCrLf)
                If Left(errLine, 6) = "ERROR=" Then
                    shell.Popup "���ʧ�ܣ�" & vbCrLf & Mid(errLine, 7), 60, "FileUnlocker - ����", 48
                    WScript.Quit 1
                End If
            Next
        End If
    End If
    shell.Popup "���ű��쳣�˳����˳���: " & code, 60, "FileUnlocker - ����", 48
    WScript.Quit 1
End If

If Not fso.FileExists(detectFile) Then
    LogIt "����: detect δ���ɽ���ļ�"
    shell.Popup "δ�����ɼ�����ļ����ű�����δ��ȷִ�С�", 60, "FileUnlocker - ����", 48
    WScript.Quit 1
End If

output = ReadUtf8File(detectFile)
LogIt "detect ���: " & output

' ===================================================
' 10. �����������չʾ���û�
' ===================================================
Dim total, occupied, pids, names
total    = GetValue(output, "TARGETS", "?")
occupied = GetValue(output, "OCCUPIED", "0")
pids     = GetValue(output, "PIDS", "")
names    = GetValue(output, "PROCNAMES", "")

If occupied = "0" Then
    shell.Popup "��ѡ " & total & " ����Ŀ��δ��ռ�á�" & vbCrLf & vbCrLf & _
                "��ֱ�ӽ���ɾ��/�ƶ�/��������", _
                60, "FileUnlocker - δ��ռ��", 64
    WScript.Quit 0
End If

Dim confirmMsg, userChoice
confirmMsg = "��ѡ " & total & " ����Ŀ�У������� " & occupied & " ������ռ�ã�" & vbCrLf & vbCrLf & names & _
             vbCrLf & vbCrLf & "ע�⣺ǿ�ƽ������̿��ܵ���δ�������ݶ�ʧ��" & vbCrLf & _
             "��ȷ����Щ���̿��԰�ȫ�������ټ�����" & vbCrLf & vbCrLf & "�Ƿ�ǿ�ƽ�����Щ���̲�����ļ�ռ�ã�"
userChoice = shell.Popup(confirmMsg, 0, "FileUnlocker - ȷ��ǿ�ƽ���", 33)   ' 33 = vbYesNo + vbQuestion
LogIt "�û�ȷ�Ͽ򷵻�=" & userChoice & " (6=��, 7=��)"

' ֻ����ȷ��"��"(7)��ȡ�������� 6(��)��1(Ĭ��/�س�)�ȶ�����ִ��
If userChoice = 7 Then   ' 7 = vbNo
    LogIt "�û�ѡ��'��'���˳�"
    WScript.Quit 0
End If
LogIt "�û�ȷ�ϣ����� kill"

' ===================================================
' 11. ��ֹռ�ý��̣�Exec ���� + ��ѯ�ȴ�������ʱ������
'     PS1 ���⵱ǰ�Ƿ����Ա���������� runas ��Ȩ����������
'     �� Exec ���� Run ͬ���ȴ������� PS1 ����ʱ���������������
' ===================================================
On Error Resume Next
fso.DeleteFile killFile, True
On Error GoTo 0

args = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden " & _
       "-File " & q & scriptPath & q & " " & _
       "-Kill -PidList " & q & pids & q & " -OutFile " & q & killFile & q
cmd = q & pwsh & q & " " & args
LogIt "��ʼ kill��PIDS=[" & pids & "]"
LogIt "KILL_CMD=" & cmd

Dim killProc, killWait, killExited
On Error Resume Next
Set killProc = shell.Exec(cmd)
If Err.Number <> 0 Then
    LogIt "Exec ���� kill ʧ�ܣ�����=" & Err.Number & " " & Err.Description
Else
    LogIt "Exec ���� kill �ɹ�"
End If
On Error GoTo 0
killWait = 0
killExited = False
Do While killWait < 150   ' ��� 75 �루150 �� 0.5 �룩
    WScript.Sleep 500
    killWait = killWait + 1
    If fso.FileExists(killFile) Then
        LogIt "kill ����ļ����֣��ȴ� " & killWait & " �Ρ�0.5s��"
        Exit Do
    End If
    On Error Resume Next
    If killProc.Status = 1 Then   ' 1 = �����ѽ���
        killExited = True
        On Error GoTo 0
        LogIt "kill �������˳�����δ�ȵ�����ļ����ȴ� " & killWait & " �Ρ�0.5s��"
        Exit Do
    End If
    On Error GoTo 0
Loop
If killWait >= 150 Then LogIt "kill �ȴ���ʱ��75 �룩"
LogIt "kill ��ѯ����: killWait=" & killWait & " killExited=" & killExited

Dim killCount, killDetail
If fso.FileExists(killFile) Then
    output = ReadUtf8File(killFile)
    killCount = GetValue(output, "KILLED", "?")
    killDetail = GetValue(output, "DETAIL", "(�޷���)")
    LogIt "kill ���: " & output
Else
    killCount = "0"
    If killWait >= 150 Then
        killDetail = "�ȴ� kill �����ʱ��75 �룩"
    ElseIf killExited Then
        killDetail = "kill �ű����˳���δ���ɽ���ļ�"
    Else
        killDetail = "kill ����ļ�δ����"
    End If
    LogIt "kill ʧ��: " & killDetail
End If

' ===================================================
' 12. ������ʱ�ļ�
' ===================================================
On Error Resume Next
fso.DeleteFile detectFile, True
fso.DeleteFile killFile, True
On Error GoTo 0

' ===================================================
' 13. ��ʾ���ս��
' ===================================================
Dim resultMsg
resultMsg = "������ɣ���ǿ�ƽ��� " & killCount & " �����̡�" & vbCrLf & vbCrLf & _
            "��ϸ��Ϣ��" & vbCrLf & killDetail
LogIt "�������ս����: " & resultMsg
shell.Popup resultMsg, 60, "FileUnlocker - ���", 64
LogIt "===== VBS �������� ====="

WScript.Quit 0


' ===================================================
' ������������ KEY=VALUE �б���ȡֵ
' ===================================================
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


' ===================================================
' ������������ UTF-8 ��ȡ�ļ���PS1 �� Out-File -Encoding utf8 д�룩
' ===================================================
Function ReadUtf8File(filePath)
    Dim stream
    Set stream = CreateObject("ADODB.Stream")
    stream.Type = 2            ' adTypeText
    stream.Charset = "utf-8"
    stream.Open
    stream.LoadFromFile filePath
    ReadUtf8File = stream.ReadText
    stream.Close
    Set stream = Nothing
End Function
