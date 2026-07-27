Dim fso, vbsPath, dir, q, lockFile, queueFile, target
Set fso = CreateObject("Scripting.FileSystemObject")
vbsPath = WScript.ScriptFullName
dir = fso.GetParentFolderName(vbsPath)
lockFile  = dir & "\.fu_lock"
queueFile = dir & "\.fu_queue.txt"

If WScript.Arguments.Count = 0 Then WScript.Quit 1
target = WScript.Arguments(0)
If target = "" Then WScript.Quit 1

' 写自己的目标到队列（追加）
On Error Resume Next
Set qf = fso.OpenTextFile(queueFile, 8, True) ' 8 = ForAppending
qf.WriteLine(target)
qf.Close
On Error GoTo 0

' 抢协调者锁：第二个实例打开已存在的锁文件会失败
Dim isCoordinator
isCoordinator = False
On Error Resume Next
Set lf = fso.OpenTextFile(lockFile, 2, True) ' 2 = ForWriting, Create, 独占
If Err.Number = 0 Then
    isCoordinator = True
    lf.WriteLine("locked")
    lf.Close
End If
On Error GoTo 0

If Not isCoordinator Then
    WScript.Quit 0
End If

' 协调者：等待其他实例写入（最多 1.2 秒）
WScript.Sleep 1200

' 读取并去重队列
Dim dict, line
Set dict = CreateObject("Scripting.Dictionary")
dict.CompareMode = 1
If fso.FileExists(queueFile) Then
    Set qf = fso.OpenTextFile(queueFile, 1) ' 1 = ForReading
    Do While Not qf.AtEndOfStream
        line = Trim(qf.ReadLine)
        If line <> "" Then dict(line) = True
    Loop
    qf.Close
End If

On Error Resume Next
fso.DeleteFile queueFile, True
fso.DeleteFile lockFile, True
On Error GoTo 0

If dict.Count = 0 Then WScript.Quit 1

' 动态定位 pwsh.exe（不写死路径，兼容不同安装位置）
Dim pwshPath, shell2, execObj, stdOut, line2, found
pwshPath = ""
Set shell2 = CreateObject("WScript.Shell")
Set execObj = shell2.Exec("cmd.exe /c where pwsh.exe 2>nul")
stdOut = execObj.StdOut.ReadAll
For Each line2 In Split(stdOut, vbCrLf)
    If InStr(line2, "pwsh.exe") > 0 Then
        pwshPath = Trim(line2)
        found = True
        Exit For
    End If
Next
If pwshPath = "" Then
    MsgBox "未找到 PowerShell 7 (pwsh.exe)。请先安装 PowerShell 7 后重试。" & vbCrLf & "下载: https://github.com/PowerShell/PowerShell/releases", vbExclamation, "解除文件占用"
    WScript.Quit 1
End If

' 拼成位置参数列表（主 PS1 从 $args 收集）
q = Chr(34)
ps1 = dir & "\FileUnlocker.ps1"
Dim sb, k
sb = ""
For Each k In dict.Keys
    sb = sb & " " & q & k & q
Next

args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & ps1 & q & sb

Set sh = CreateObject("Shell.Application")
sh.ShellExecute pwshPath, args, "", "runas", 0
