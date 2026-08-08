param(
    [switch]$Detect,
    [switch]$Kill,
    [string]$Targets,
    [string]$PidList,
    [string]$OutFile
)

# All output files are derived from $PSScriptRoot so the tool works no matter
# which drive/dir it is installed to (C:\Program Files, D:\Tools, etc).
$root   = $PSScriptRoot
$handle = Join-Path $root 'handle.exe'
$runner = Join-Path $root 'unlock_system_runner.ps1'

if (-not $OutFile) { $OutFile = Join-Path $root '.fu_detect.txt' }

# ========== 调试日志 ==========
$DebugLog = Join-Path $env:TEMP 'FileUnlocker_ps1_debug.log'
function Log-PS1($msg) {
    try {
        Add-Content -LiteralPath $DebugLog -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $msg" -Encoding utf8 -ErrorAction Stop
    } catch {}
}
Log-PS1 "===== PS1 启动 ====="
Log-PS1 "Detect=$Detect Kill=$Kill Targets=[$Targets] PidList=[$PidList] OutFile=[$OutFile]"
Log-PS1 "PSCommandPath=[$PSCommandPath]"
$isAdminNow = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log-PS1 "isAdmin=$isAdminNow"

function Write-Out($lines) {
    $lines -join "`r`n" | Out-File -FilePath $OutFile -Encoding utf8
    Log-PS1 "Write-Out → $OutFile : $($lines -join ' | ')"
}

# ===================== DETECT mode =====================
if ($Detect) {
    $paths = $Targets -split '[|]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    $matchSet  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $folderSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($tp in $paths) {
        $norm = $tp.TrimEnd('\')
        if (-not (Test-Path -LiteralPath $norm)) { continue }
        [void]$matchSet.Add($norm)
        if (Test-Path -LiteralPath $tp -PathType Container) {
            [void]$folderSet.Add($norm)
            Get-ChildItem -LiteralPath $tp -Recurse -File -ErrorAction SilentlyContinue |
                ForEach-Object { [void]$matchSet.Add($_.FullName.TrimEnd('\')) }
        }
    }

    if (-not (Test-Path -LiteralPath $handle)) {
        Write-Out @("ERROR=handle.exe missing", "PATH=$handle")
        exit 1
    }

    # P7: $pid is READ-ONLY (=$PID auto-var). NEVER use $pid as a variable.
    # P4: handle -a output is per-process BLOCKED: pid lives on a header line,
    #     file path on the following indented line. Track curPid across lines.
    # P8: handle.exe extracts a helper binary into the CURRENT DIRECTORY, so it
    #     must run from a writable dir. When launched from the context menu the
    #     cwd is often read-only (C:\Windows\System32) -> force a writable cwd.
    $owners = @{}
    # handle.exe 单次启动 ~200ms：目标 ≤2 个时用按名精确查（快且准）；
    # 目标 >2(多选/文件夹)时用一次 -a 全扫描更划算，但必须先把前缀判断做快，
    # 否则系统文件多时每条句柄都要循环全部目标，呈 O(n²) 会拖慢到秒级以上。
    $usePerFile = ($matchSet.Count -le 2)
    Log-PS1 "detect: paths=$($paths.Count) matchSet=$($matchSet.Count) folderSet=$($folderSet.Count) perFile=$usePerFile"
    Push-Location -Path $env:TEMP
    try {
        if ($usePerFile) {
            # 1-2 个纯文件：按名精确查。
            foreach ($m in $matchSet) {
                & $handle /accepteula -nobanner $m 2>$null | ForEach-Object {
                    if ($_ -match 'pid:\s*(\d+)') { $owners[[int]$matches[1]] = $true }
                }
            }
        } else {
            # 多选 / 文件夹：一次全量 -a 扫描。
            # 性能关键：folderSet 按盘符分组，每条句柄先 O(1) 取到自己的盘符再比对，
            # 避免对每条 File 句柄都遍历全部目标路径（O(句柄数 × 目标数)）。
            $foldersByDrive = @{}
            foreach ($fd in $folderSet) {
                if ($fd -match '^([a-zA-Z]):') {
                    $d = $matches[1].ToUpper()
                    if (-not $foldersByDrive.ContainsKey($d)) {
                        $foldersByDrive[$d] = [System.Collections.Generic.List[string]]::new()
                    }
                    $foldersByDrive[$d].Add($fd)
                }
            }
            $curPid = 0
            & $handle /accepteula -nobanner -a 2>$null | ForEach-Object {
                if ($_ -match 'pid:\s*(\d+)') { $curPid = [int]$matches[1] }
                elseif ($_ -match '^\s*\S+:\\?\s*File\s+\S*\s+(.+)$' -or
                        $_ -match '^\s*\S+:\s*File\s+\S*\s+(.+)$') {
                    $hpath = $matches[1].Trim().TrimEnd('\')
                    if ($matchSet.Contains($hpath)) {   # O(1) 精确命中
                        if ($curPid -gt 0) { $owners[$curPid] = $true }
                    } elseif ($hpath -match '^([a-zA-Z]):') {
                        $sameDrive = $foldersByDrive[$matches[1].ToUpper()]
                        foreach ($fd in $sameDrive) {   # 只比同盘符、且数量很少的文件夹
                            if ($hpath.StartsWith($fd + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                                if ($curPid -gt 0) { $owners[$curPid] = $true }
                                break
                            }
                        }
                    }
                }
            }
        }
    } finally {
        Pop-Location
    }

    # Collect own process tree so we never suggest killing ourselves.
    $currentPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
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

    $Critical = @('system','idle','svchost','csrss','lsass','smss','wininit','services','winlogon','explorer','dwm','fontdrvhost','lsaiso')
    $candidates = @()
    foreach ($procId in $owners.Keys) {
        if ($procId -eq $currentPid -or $ownPids.ContainsKey($procId)) { continue }
        try {
            $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop
            if ($ci.Name.ToLower() -in $Critical) { continue }
            $candidates += [pscustomobject]@{
                Pid  = $procId
                Name = $ci.Name
                Path = if ($ci.ExecutablePath) { $ci.ExecutablePath } else { '(unknown)' }
            }
        } catch {}
    }
    $candidates = $candidates | Sort-Object Pid -Unique

    $pids  = ($candidates | ForEach-Object { $_.Pid })  -join ','
    $names = ($candidates | ForEach-Object { $_.Name }) -join ';'
    Log-PS1 "detect 完成: candidates=$($candidates.Count) pids=[$pids] names=[$names]"
    Write-Out @(
        "TARGETS=$($paths.Count)"
        "OCCUPIED=$($candidates.Count)"
        "PIDS=$pids"
        "PROCNAMES=$names"
    )
    exit 0
}

# ===================== KILL mode =====================
if ($Kill) {
    $killOut = $OutFile
    if (-not $killOut) { $killOut = Join-Path $root '.fu_kill.txt' }
    if (Test-Path $killOut) { Remove-Item $killOut -Force }

    # P9: 右键菜单进程是中等完整性，Register-ScheduledTask 以 SYSTEM 身份
    # 运行需要管理员权限，中等完整性下会静默失败。这里检测权限，不足则
    # 以 runas 提权重启自身，等待完成后 VBS 读取结果文件。
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Kill -PidList `"$PidList`" -OutFile `"$killOut`""
        try {
            Start-Process -FilePath "C:\Program Files\PowerShell\7\pwsh.exe" -ArgumentList $argList -Verb RunAs -Wait -WindowStyle Hidden
        } catch {
            "KILLED=0`r`nDETAIL=提权被拒绝：$($_.Exception.Message)" | Out-File -FilePath $killOut -Encoding utf8
        }
        exit 0
    }

    $pids = $PidList -split ',' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    Log-PS1 "kill: 解析 PID=[$($pids -join ',')]"
    if ($pids.Count -eq 0) {
        Log-PS1 "kill: 无有效 PID，写 no pid"
        "KILLED=0`r`nDETAIL=no pid" | Out-File -FilePath $killOut -Encoding utf8
        exit 0
    }

    # P10: 已提权（管理员）直接 Stop-Process -Force。大多数占用文件的进程
    # 管理员权限即可强杀，无需 SYSTEM 计划任务，响应快且不会卡死。
    $killed = 0
    $detail = @()
    foreach ($id in $pids) {
        try {
            $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop
            $nm = $ci.Name.ToLower()
            if ($nm -in @('system','idle','svchost','csrss','lsass','smss','wininit','services','winlogon','explorer','dwm','fontdrvhost','lsaiso')) {
                Log-PS1 "kill: 跳过关键进程 PID $id ($($ci.Name))"
                $detail += "跳过关键进程 PID $id ($($ci.Name))"
                continue
            }
            Stop-Process -Id $id -Force -ErrorAction Stop
            $killed++
            $detail += "已终止 PID $id ($($ci.Name))"
            Log-PS1 "kill: 已终止 PID $id ($($ci.Name))"
        } catch {
            Log-PS1 "kill: 终止 PID $id 失败: $($_.Exception.Message)"
            $detail += "终止 PID $id 失败：$($_.Exception.Message)"
        }
    }

    # P11: 仍有进程杀不掉（例如 SYSTEM 特权句柄）时，回退到 SYSTEM 计划任务
    $stillAlive = @($pids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($stillAlive.Count -gt 0) {
        $sysResult = Join-Path $root 'unlock_system_result.txt'
        if (Test-Path $sysResult) { Remove-Item $sysResult -Force }
        $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -PidList `"$($stillAlive -join ',')`" -ResultFile `"$sysResult`""
        try {
            Unregister-ScheduledTask -TaskName "WinDiag_Unlock_SYSTEM" -Confirm:$false -ErrorAction SilentlyContinue
            $action    = New-ScheduledTaskAction    -Execute "C:\Program Files\PowerShell\7\pwsh.exe" -Argument $arg
            $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
            $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
            Register-ScheduledTask -TaskName "WinDiag_Unlock_SYSTEM" -Action $action -Principal $principal -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName "WinDiag_Unlock_SYSTEM"
            $waited = 0
            while ($waited -lt 12 -and -not (Test-Path $sysResult)) {
                Start-Sleep -Seconds 1; $waited++
            }
            Unregister-ScheduledTask -TaskName "WinDiag_Unlock_SYSTEM" -Confirm:$false -ErrorAction SilentlyContinue
            $sysOut = if (Test-Path $sysResult) { (Get-Content $sysResult -Raw).Trim() } else { "(SYSTEM no output)" }
            $detail += "SYSTEM 兜底：$sysOut"
        } catch {
            $detail += "SYSTEM 兜底失败：$($_.Exception.Message)"
        }
        if (Test-Path $sysResult) { Remove-Item $sysResult -Force }
    }

    "KILLED=$killed`r`nDETAIL=$($detail -join ' | ')" | Out-File -FilePath $killOut -Encoding utf8
    Log-PS1 "kill 完成: KILLED=$killed DETAIL=$($detail -join ' | ') → $killOut"
    exit 0
}

Write-Out @("ERROR=unknown mode")
exit 1
