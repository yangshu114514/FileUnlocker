Dim fso, vbsPath, dir, q, lockFile, queueFile, target, me
Set fso = CreateObject("Scripting.FileSystemObject")
vbsPath = WScript.ScriptFullName
dir = fso.GetParentFolderName(vbsPath)
lockFile  = dir & "\.fu_lock"
queueFile = dir & "\.fu_queue.txt"

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
    ' 非协调者：已写入队列，直接退出（协调者会处理）
    WScript.Quit 0
End If

' 协调者：等待其他实例写入（最多 1.2 秒）
WScript.Sleep 1200

' 读取并去重队列
Dim dict, line
Set dict = CreateObject("Scripting.Dictionary")
dict.CompareMode = 1 ' 文本比较
If fso.FileExists(queueFile) Then
    Set qf = fso.OpenTextFile(queueFile, 1) ' 1 = ForReading
    Do While Not qf.AtEndOfStream
        line = Trim(qf.ReadLine)
        If line <> "" Then dict(line) = True
    Loop
    qf.Close
End If

' 清理队列与锁
On Error Resume Next
fso.DeleteFile queueFile, True
fso.DeleteFile lockFile, True
On Error GoTo 0

If dict.Count = 0 Then WScript.Quit 1

' 拼成位置参数列表（不带参数名，主 PS1 从 $args 收集）
q = Chr(34)
ps1 = dir & "\FileUnlocker.ps1"
Dim sb, i
sb = ""
For i = 0 To UBound(items)
    sb = sb & " " & q & items(i) & q
Next

args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & ps1 & q & sb

Set sh = CreateObject("Shell.Application")
sh.ShellExecute "C:\Program Files\PowerShell\7\pwsh.exe", args, "", "runas", 0
