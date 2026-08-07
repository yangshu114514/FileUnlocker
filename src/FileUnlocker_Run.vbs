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
' 调试日志（%TEMP%\FileUnlocker_debug.log）
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

LogIt "===== FileUnlocker VBS 启动 ====="
LogIt "ScriptFullName=" & WScript.ScriptFullName
LogIt "参数数量=" & WScript.Arguments.Count

' ===================================================
' 1. 清理 30 秒前的陈旧锁/队列（上次崩溃残留）
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
' 2. 检查参数：必须传入至少一个文件/文件夹路径
' ===================================================
If WScript.Arguments.Count = 0 Then
    LogIt "错误: 无参数，显示用法"
    shell.Popup "用法：" & vbCrLf & _
                "wscript.exe """ & WScript.ScriptFullName & """ ""目标路径""" & vbCrLf & vbCrLf & _
                "建议通过右键菜单 -“解除文件占用”调用。", _
                60, "FileUnlocker - 使用说明", 64
    WScript.Quit 1
End If
LogIt "参数0=" & WScript.Arguments(0)

' ===================================================
' 3. 多选合并：把自己的路径写入队列
'    右键多选时，资源管理器会对每个文件各调用一次本脚本，
'    因此把路径先存进队列文件，再由协调者一次性处理。
' ===================================================
Dim qf
On Error Resume Next
Set qf = fso.OpenTextFile(queueFile, 8, True)   ' 8 = ForAppending，不存在则创建
If Err.Number = 0 Then
    qf.WriteLine(Trim(CStr(WScript.Arguments(0))))
    qf.Close
End If
On Error GoTo 0

' ===================================================
' 4. 抢锁：第一个成功创建锁文件的是协调者，其余立即退出
' ===================================================
Dim isCoordinator, lockHandle
isCoordinator = False
On Error Resume Next
Set lockHandle = fso.OpenTextFile(lockFile, 2, True)   ' 2 = ForWriting，独占打开
If Err.Number = 0 Then
    isCoordinator = True
    lockHandle.WriteLine("locked")
End If
On Error GoTo 0

If Not isCoordinator Then
    LogIt "非协调者，退出（已有协调者处理）"
    WScript.Quit 0
End If
LogIt "本实例成为协调者"

' ===================================================
' 5. 协调者：等队列不再增长（最多 3 个稳定周期）
' ===================================================
Dim lastCount, curCount, stableFor, qf2, tmpLine
lastCount = -1
stableFor = 0
curCount  = 0
Do While stableFor < 3
    WScript.Sleep 150
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
' 6. 读队列并去重，然后清理队列/锁
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
    LogIt "队列为空，退出"
    WScript.Quit 1
End If
LogIt "收集到 " & dict.Count & " 个路径"

' ===================================================
' 7. 拼接所有路径（| 分隔）
' ===================================================
Dim sb, k
sb = ""
For Each k In dict.Keys
    If sb <> "" Then sb = sb & "|"
    sb = sb & k
Next

' ===================================================
' 8. 定位 pwsh.exe
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
    LogIt "错误: 找不到 pwsh.exe"
    shell.Popup "找不到 PowerShell 7 (pwsh.exe)。" & vbCrLf & vbCrLf & _
                "请先安装：" & vbCrLf & "https://github.com/PowerShell/PowerShell/releases", _
                60, "FileUnlocker - 缺少依赖", 48
    WScript.Quit 1
End If
LogIt "pwsh=" & pwsh

If Not fso.FileExists(scriptPath) Then
    LogIt "错误: 找不到主脚本 " & scriptPath
    shell.Popup "找不到主脚本：" & vbCrLf & scriptPath, 60, "FileUnlocker - 错误", 48
    WScript.Quit 1
End If
LogIt "scriptPath=" & scriptPath

' ===================================================
' 9. 调用 FileUnlocker.ps1 进行占用检测（同步等待）
' ===================================================
Dim q, args, cmd, code, output
q = Chr(34)
On Error Resume Next
fso.DeleteFile detectFile, True
On Error GoTo 0

args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " & _
       "-File " & q & scriptPath & q & " " & _
       "-Detect -Targets " & q & sb & q & " -OutFile " & q & detectFile & q
cmd = q & pwsh & q & " " & args
LogIt "开始 detect"
LogIt "DETECT_CMD=" & cmd
code = shell.Run(cmd, 0, True)
LogIt "detect 返回退出码=" & code

If code <> 0 Then
    LogIt "detect 失败，退出码=" & code
    If fso.FileExists(detectFile) Then
        output = ReadUtf8File(detectFile)
        LogIt "detect 错误文件内容=" & output
        If InStr(output, "ERROR=") > 0 Then
            Dim errLine
            For Each errLine In Split(output, vbCrLf)
                If Left(errLine, 6) = "ERROR=" Then
                    shell.Popup "检测失败：" & vbCrLf & Mid(errLine, 7), 60, "FileUnlocker - 错误", 48
                    WScript.Quit 1
                End If
            Next
        End If
    End If
    shell.Popup "检测脚本异常退出，退出码: " & code, 60, "FileUnlocker - 错误", 48
    WScript.Quit 1
End If

If Not fso.FileExists(detectFile) Then
    LogIt "错误: detect 未生成结果文件"
    shell.Popup "未能生成检测结果文件，脚本可能未正确执行。", 60, "FileUnlocker - 错误", 48
    WScript.Quit 1
End If

output = ReadUtf8File(detectFile)
LogIt "detect 结果: " & output

' ===================================================
' 10. 解析检测结果，展示给用户
' ===================================================
Dim total, occupied, pids, names
total    = GetValue(output, "TARGETS", "?")
occupied = GetValue(output, "OCCUPIED", "0")
pids     = GetValue(output, "PIDS", "")
names    = GetValue(output, "PROCNAMES", "")

If occupied = "0" Then
    shell.Popup "所选 " & total & " 个项目均未被占用。" & vbCrLf & vbCrLf & _
                "可直接进行删除/移动/重命名。", _
                60, "FileUnlocker - 未被占用", 64
    WScript.Quit 0
End If

Dim confirmMsg, userChoice
confirmMsg = "所选 " & total & " 个项目中，被以下 " & occupied & " 个进程占用：" & vbCrLf & vbCrLf & names & _
             vbCrLf & vbCrLf & "注意：强制结束进程可能导致未保存数据丢失！" & vbCrLf & _
             "请确认这些进程可以安全结束后，再继续。" & vbCrLf & vbCrLf & "是否强制结束这些进程并解除文件占用？"
userChoice = shell.Popup(confirmMsg, 0, "FileUnlocker - 确认强制结束", 33)   ' 33 = vbYesNo + vbQuestion
LogIt "用户确认框返回=" & userChoice & " (6=是, 7=否)"

' 只有明确点"否"(7)才取消；返回 6(是)、1(默认/回车)等都继续执行
If userChoice = 7 Then   ' 7 = vbNo
    LogIt "用户选择'否'，退出"
    WScript.Quit 0
End If
LogIt "用户确认，继续 kill"

' ===================================================
' 11. 终止占用进程（Exec 启动 + 轮询等待，带超时保护）
'     PS1 会检测当前是否管理员，不是则用 runas 提权重启自身。
'     用 Exec 而非 Run 同步等待，避免 PS1 卡死时结果框永不弹出。
' ===================================================
On Error Resume Next
fso.DeleteFile killFile, True
On Error GoTo 0

args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " & _
       "-File " & q & scriptPath & q & " " & _
       "-Kill -PidList " & q & pids & q & " -OutFile " & q & killFile & q
cmd = q & pwsh & q & " " & args
LogIt "开始 kill，PIDS=[" & pids & "]"
LogIt "KILL_CMD=" & cmd

Dim killProc, killWait, killExited
On Error Resume Next
Set killProc = shell.Exec(cmd)
If Err.Number <> 0 Then
    LogIt "Exec 启动 kill 失败，错误=" & Err.Number & " " & Err.Description
Else
    LogIt "Exec 启动 kill 成功"
End If
On Error GoTo 0
killWait = 0
killExited = False
Do While killWait < 150   ' 最长等 75 秒（150 × 0.5 秒）
    WScript.Sleep 500
    killWait = killWait + 1
    If fso.FileExists(killFile) Then
        LogIt "kill 结果文件出现（等待 " & killWait & " 次×0.5s）"
        Exit Do
    End If
    On Error Resume Next
    If killProc.Status = 1 Then   ' 1 = 进程已结束
        killExited = True
        On Error GoTo 0
        LogIt "kill 进程已退出，但未等到结果文件（等待 " & killWait & " 次×0.5s）"
        Exit Do
    End If
    On Error GoTo 0
Loop
If killWait >= 150 Then LogIt "kill 等待超时（75 秒）"
LogIt "kill 轮询结束: killWait=" & killWait & " killExited=" & killExited

Dim killCount, killDetail
If fso.FileExists(killFile) Then
    output = ReadUtf8File(killFile)
    killCount = GetValue(output, "KILLED", "?")
    killDetail = GetValue(output, "DETAIL", "(无返回)")
    LogIt "kill 结果: " & output
Else
    killCount = "0"
    If killWait >= 150 Then
        killDetail = "等待 kill 结果超时（75 秒）"
    ElseIf killExited Then
        killDetail = "kill 脚本已退出但未生成结果文件"
    Else
        killDetail = "kill 结果文件未生成"
    End If
    LogIt "kill 失败: " & killDetail
End If

' ===================================================
' 12. 清理临时文件
' ===================================================
On Error Resume Next
fso.DeleteFile detectFile, True
fso.DeleteFile killFile, True
On Error GoTo 0

' ===================================================
' 13. 显示最终结果
' ===================================================
Dim resultMsg
resultMsg = "处理完成！共强制结束 " & killCount & " 个进程。" & vbCrLf & vbCrLf & _
            "详细信息：" & vbCrLf & killDetail
LogIt "弹出最终结果框: " & resultMsg
shell.Popup resultMsg, 60, "FileUnlocker - 完成", 64
LogIt "===== VBS 正常结束 ====="

WScript.Quit 0


' ===================================================
' 辅助函数：从 KEY=VALUE 列表中取值
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
' 辅助函数：按 UTF-8 读取文件（PS1 用 Out-File -Encoding utf8 写入）
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
