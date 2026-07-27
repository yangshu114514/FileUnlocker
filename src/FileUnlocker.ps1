param(
    [switch]$WhatIf
)

# 所有目标都从位置参数 $args 收集（避免首个位置参数被绑定到具名参数而丢失）
$TargetPaths = @($args)
if ($TargetPaths.Count -eq 0) { throw "未指定文件路径" }
$TargetPaths = $TargetPaths | ForEach-Object {
    $t = $_
    try { [System.IO.Path]::GetFullPath($t) } catch { $t }
}

$root       = $PSScriptRoot
$logFile    = Join-Path $root 'unlock_log.txt'
$handle     = Join-Path $root 'handle.exe'
$runner     = Join-Path $root 'unlock_system_runner.ps1'
$currentPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
$Critical   = @('system','idle','svchost','csrss','lsass','smss','wininit','services','winlogon','explorer','dwm','fontdrvhost','lsaiso')

try {
    if ($TargetPaths.Count -eq 0) { throw "未指定文件路径" }
    foreach ($tp in $TargetPaths) {
        if (-not (Test-Path -LiteralPath $tp)) { throw "路径不存在：$tp" }
    }
    if (-not (Test-Path -LiteralPath $handle)) { throw "找不到 handle.exe：$handle" }

    # 收集自身进程树，避免误杀自己
    $ownPids = @{}; $ownPids[$currentPid] = $true
    try {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$currentPid" -ErrorAction Stop
        while ($p -and $p.ParentProcessId -ne 0) {
            $ownPids[$p.ParentProcessId] = $true
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)" -ErrorAction SilentlyContinue
        }
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$currentPid" -ErrorAction SilentlyContinue |
            ForEach-Object { $ownPids[$_.ProcessId] = $true }
    } catch {}

    # ===== 构建匹配目标集（含文件夹及其所有子文件，仅一次递归）=====
    # 目标规范化：统一尾部反斜杠，便于前缀匹配
    $matchSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $folderSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($tp in $TargetPaths) {
        $norm = $tp.TrimEnd('\')
        [void]$matchSet.Add($norm)
        if (Test-Path -LiteralPath $tp -PathType Container) {
            [void]$folderSet.Add($norm)
            # 递归收集子文件路径（PowerShell 原生递归，远快于反复启动 handle）
            Get-ChildItem -LiteralPath $tp -Recurse -File -ErrorAction SilentlyContinue |
                ForEach-Object { [void]$matchSet.Add($_.FullName.TrimEnd('\')) }
        }
    }

    # ===== 单次 handle 全系统扫描，本地匹配所有目标 =====
    # 只在存在文件夹目标时加 -a（列出全部句柄）；纯文件目标直接用路径参数更快
    $owners = @{}
    if ($folderSet.Count -gt 0) {
        # 文件夹场景：dump 全系统句柄一次，逐行匹配前缀
        & $handle /accepteula -nobanner -a 2>$null | ForEach-Object {
            if ($_ -match 'pid:\s*(\d+)\s+type:\s*\S+\s+[0-9A-Fa-f]+:\s+(.+)$') {
                $pid = [int]$matches[1]
                $hpath = $matches[2].Trim().TrimEnd('\')
                # 命中：路径等于某目标，或以某目标\ 开头（含子路径/子文件）
                $hit = $false
                if ($matchSet.Contains($hpath)) { $hit = $true }
                else {
                    foreach ($m in $matchSet) {
                        if ($hpath.StartsWith($m + '\') -or $hpath.StartsWith($m + '/')) { $hit = $true; break }
                    }
                }
                if ($hit) { $owners[$pid] = $true }
            }
        }
    } else {
        # 纯文件场景：每个文件单独跑 handle（文件数通常少，handle 直接过滤快）
        foreach ($m in $matchSet) {
            & $handle /accepteula -nobanner $m 2>$null | ForEach-Object {
                if ($_ -match 'pid:\s*(\d+)') { $owners[[int]$matches[1]] = $true }
            }
        }
    }

    $candidates = foreach ($procId in $owners.Keys) {
        if ($procId -eq $currentPid -or $ownPids.ContainsKey($procId)) { continue }
        try {
            $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop
            if ($ci.Name.ToLower() -in $Critical) { continue }
            [pscustomobject]@{ Pid=$procId; Name=$ci.Name; Path=if($ci.ExecutablePath){$ci.ExecutablePath}else{'(未知)'} }
        } catch {}
    }
    $candidates = $candidates | Sort-Object Pid -Unique

    if ($WhatIf) {
        if ($candidates.Count -eq 0) { "未检测到占用进程（共 $($TargetPaths.Count) 个目标）" }
        else {
            "检测到 $($candidates.Count) 个占用进程（共 $($TargetPaths.Count) 个目标）："
            $candidates | ForEach-Object { "  PID $($_.Pid)  $($_.Name)  $($_.Path)" }
        }
        exit 0
    }

    if ($candidates.Count -eq 0) {
        $resultText = "所选 $($TargetPaths.Count) 个项目均未被任何进程占用"
        $title = "解除占用"
    } else {
        $list = ($candidates | ForEach-Object { "• $($_.Name) (PID $($_.Pid))`n  $($_.Path)" }) -join "`n`n"
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        $ans = [System.Windows.Forms.MessageBox]::Show("将终止以下 $($candidates.Count) 个持有句柄的进程（来自 $($TargetPaths.Count) 个目标）：`n`n$list`n`n确定终止？", "解除占用", "OKCancel", "Warning")
        if ($ans -ne [System.Windows.Forms.DialogResult]::OK) { "已取消操作" | Out-File -FilePath $logFile -Encoding utf8; exit 0 }

        $pidStr = ($candidates | ForEach-Object { $_.Pid }) -join ','
        $sysResult = Join-Path $root 'unlock_system_result.txt'
        if (Test-Path $sysResult) { Remove-Item $sysResult -Force }
        $taskName = "WinDiag_Unlock_SYSTEM"
        $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -PidList `"$pidStr`" -ResultFile `"$sysResult`""
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            $action = New-ScheduledTaskAction -Execute "C:\Program Files\PowerShell\7\pwsh.exe" -Argument $arg
            $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
            Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
            $waited = 0
            while ($waited -lt 15) {
                Start-Sleep -Seconds 1; $waited++
                if ((Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State -eq 'Ready') { break }
            }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            $sysOut = if (Test-Path $sysResult) { (Get-Content $sysResult -Raw).Trim() } else { "(SYSTEM 未返回结果)" }
            $resultText = "共终止 $($candidates.Count) 个进程（来自 $($TargetPaths.Count) 个目标）：`n`n$sysOut"
        } catch {
            $resultText = "注册 SYSTEM 任务失败：$($_.Exception.Message)`n`n可改用普通管理员模式重试。"
        }
        $title = "解除占用"
    }

    $resultText | Out-File -FilePath $logFile -Encoding utf8
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.MessageBox]::Show($resultText, $title, "OK", "Information")
} catch {
    "错误：$($_.Exception.Message)" | Out-File -FilePath $logFile -Encoding utf8
    try {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        [System.Windows.Forms.MessageBox]::Show("错误：$($_.Exception.Message)`n`n日志：$logFile", "解除占用", "OK", "Error")
    } catch {}
}
