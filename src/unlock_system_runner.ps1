# 以 SYSTEM 身份运行：接收 PID 列表强制终止。
# 由主脚本通过计划任务(NT AUTHORITY\SYSTEM)调用。
param([string]$PidList, [string]$ResultFile)

$out = if ($ResultFile) { $ResultFile } else { Join-Path $PSScriptRoot 'unlock_system_result.txt' }

$Critical = @('system','idle','svchost','csrss','lsass','smss','wininit','services','winlogon','explorer','dwm','fontdrvhost','lsaiso')
$lines = @()

if (-not $PidList) {
    "无 PID 传入" | Out-File -FilePath $out -Encoding utf8
    exit 0
}

$pids = $PidList -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
foreach ($pidStr in $pids) {
    $id = [int]$pidStr
    try {
        $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop
        $nm = $ci.Name.ToLower()
        if ($nm -in $Critical) { $lines += "跳过关键进程 PID $id ($($ci.Name))"; continue }
        Stop-Process -Id $id -Force -ErrorAction Stop
        $lines += "已终止 PID $id ($($ci.Name))"
    } catch {
        $lines += "终止 PID $id 失败：$($_.Exception.Message)"
    }
}

$lines -join "`n" | Out-File -FilePath $out -Encoding utf8
