Option Explicit

' ===================================================
'  FileUnlocker 右键入口 (VBS 协调器)
'  必须在 wscript.exe 下运行（弹窗需要 GUI）
' ===================================================

Dim fso, shell
Dim paths, path, i
Dim pwsh, scriptDir, scriptPath
Dim detectFile, killFile
Dim cmd, args, output
Dim total, occupied, pids, names, killed, detail
Dim code, codeLine, line
Dim confirmMsg, resultMsg, userChoice
Dim timeout, elapsed
Dim tempFile

Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir  = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = scriptDir & "\FileUnlocker.ps1"
detectFile = scriptDir & "\.fu_detect.txt"
killFile   = scriptDir & "\.fu_kill.txt"

' ===================================================
' 1. 检查参数：必须传入至少一个文件/文件夹路径
' ===================================================
If WScript.Arguments.Count = 0 Then
    shell.Popup "用法：" & vbCrLf & _
                "wscript.exe """ & WScript.ScriptFullName & """ ""目标路径""" & vbCrLf & vbCrLf & _
                "建议通过右键菜单 -“解除文件占用”调用。", _
                0, "FileUnlocker - 使用说明", 64
    WScript.Quit 1
End If

' 收集所有传入路径（多选时会传多个）
paths = ""
For i = 0 To WScript.Arguments.Count - 1
    path = CStr(WScript.Arguments(i))
    path = Trim(path)
    ' 去掉尾部多余的引号/反斜杠
    Do While Len(path) > 0
        If Right(path, 1) = """" Or Right(path, 1) = "\" Then
            path = Left(path, Len(path) - 1)
        Else
            Exit Do
        End If
    Loop
    If path <> "" Then
        If paths <> "" Then paths = paths & "|"
        paths = paths & path
    End If
Next

If paths = "" Then
    shell.Popup "收到的路径为空，无法处理。", 0, "FileUnlocker - 错误", 48
    WScript.Quit 1
End If

' ===================================================
' 2. 定位 pwsh.exe
' ===================================================
pwsh = ""
If fso.FileExists("C:\Program Files\PowerShell\7\pwsh.exe") Then
    pwsh = "C:\Program Files\PowerShell\7\pwsh.exe"
ElseIf fso.FileExists("C:\Program Files (x86)\PowerShell\7\pwsh.exe") Then
    pwsh = "C:\Program Files (x86)\PowerShell\7\pwsh.exe"
Else
    On Error Resume Next
    Dim proc : Set proc = shell.Exec("where pwsh.exe 2>nul")
    If Err.Number = 0 Then
        Dim rawOut : rawOut = proc.StdOut.ReadAll()
        Dim firstLine : firstLine = Split(rawOut, vbCrLf)(0)
        pwsh = Trim(firstLine)
    End If
    On Error GoTo 0
End If

If pwsh = "" Or Not fso.FileExists(pwsh) Then
    shell.Popup "找不到 PowerShell 7 (pwsh.exe)。" & vbCrLf & vbCrLf & _
                "请先安装：" & vbCrLf & "https://github.com/PowerShell/PowerShell/releases", _
                0, "FileUnlocker - 缺少依赖", 48
    WScript.Quit 1
End If

If Not fso.FileExists(scriptPath) Then
    shell.Popup "找不到主脚本：" & vbCrLf & scriptPath, 0, "FileUnlocker - 错误", 48
    WScript.Quit 1
End If

' ===================================================
' 3. 单次启动预处理（清理残留）
' ===================================================
On Error Resume Next
fso.DeleteFile detectFile, True
fso.DeleteFile killFile, True
On Error GoTo 0

' ===================================================
' 4. 调用 FileUnlocker.ps1 进行占用检测
' ===================================================
args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " & _
       "-File """ & scriptPath & """ " & _
       "-Detect -Targets """ & paths & """ -OutFile """ & detectFile & """"
cmd = """" & pwsh & """ " & args

' 直接同步执行，等待完成返回 exit code
code = shell.Run(cmd, 0, True)

If code <> 0 Then
    ' 如果脚本报错，看看有没有错误文件
    If fso.FileExists(detectFile) Then
        output = ReadUtf8File(detectFile)
        If InStr(output, "ERROR=") > 0 Then
            Dim errLine
            For Each errLine In Split(output, vbCrLf)
                If Left(errLine, 6) = "ERROR=" Then
                    shell.Popup "检测失败：" & vbCrLf & Mid(errLine, 7), 0, "FileUnlocker - 错误", 48
                    WScript.Quit 1
                End If
            Next
        End If
    End If
    shell.Popup "检测脚本异常退出，退出码: " & code, 0, "FileUnlocker - 错误", 48
    WScript.Quit 1
End If

If Not fso.FileExists(detectFile) Then
    shell.Popup "未能生成检测结果文件，脚本可能未正确执行。", 0, "FileUnlocker - 错误", 48
    WScript.Quit 1
End If

output = ReadUtf8File(detectFile)

' ===================================================
' 5. 解析检测结果，展示给用户
' ===================================================
total    = GetValue(output, "TARGETS", "?")
occupied = GetValue(output, "OCCUPIED", "0")
pids     = GetValue(output, "PIDS", "")
names    = GetValue(output, "PROCNAMES", "")

If occupied = "0" Then
    shell.Popup "所选 " & total & " 个项目均未被占用。" & vbCrLf & vbCrLf & _
                "可直接进行删除/移动/重命名。", _
                0, "FileUnlocker - 未被占用", 64
    WScript.Quit 0
End If

confirmMsg = "所选 " & total & " 个项目中，被以下 " & occupied & " 个进程占用：" & vbCrLf & vbCrLf & names & _
             vbCrLf & vbCrLf & "注意：强制结束进程可能导致未保存数据丢失！" & vbCrLf & _
             "请确认这些进程可以安全结束后，再继续。" & vbCrLf & vbCrLf & "是否强制结束这些进程并解除文件占用？"
userChoice = shell.Popup(confirmMsg, 0, "FileUnlocker - 确认强制结束", 33)  ' 33 = vbYesNo + vbQuestion

If userChoice <> 6 Then  ' vbYes
    WScript.Quit 0
End If

' ===================================================
' 6. 调用 Kill 模式（会注册 SYSTEM 计划任务真正终止）
' ===================================================
args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " & _
       "-File """ & scriptPath & """ " & _
       "-Kill -PidList """ & pids & """ -OutFile """ & killFile & """"
cmd = """" & pwsh & """ " & args

code = shell.Run(cmd, 0, True)

' 读取 kill 结果
Dim killDetail, killCount
If fso.FileExists(killFile) Then
    output = ReadUtf8File(killFile)
    killCount = GetValue(output, "KILLED", "?")
    killDetail = GetValue(output, "DETAIL", "(无返回)")
Else
    killCount = "0"
    killDetail = "未生成 kill 结果文件，可能未正确执行"
End If

' 清理临时文件
On Error Resume Next
fso.DeleteFile detectFile, True
fso.DeleteFile killFile, True
On Error GoTo 0

' ===================================================
' 7. 显示最终结果
' ===================================================
resultMsg = "处理完成！共强制结束 " & killCount & " 个进程。" & vbCrLf & vbCrLf & _
            "详细信息：" & vbCrLf & killDetail
shell.Popup resultMsg, 0, "FileUnlocker - 完成", 64

WScript.Quit 0


' ===================================================
' 辅助函数：从 KEY=VALUE 列表中取值
' ===================================================
Function GetValue(text, key, defaultValue)
    Dim lines, line
    If text = "" Then GetValue = defaultValue: Exit Function
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
