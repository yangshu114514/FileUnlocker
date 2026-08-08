param(
    [switch]$Detect,
    [switch]$Kill,
    [string]$Targets,
    [string]$PidList,
    [string]$OutFile
)

# All output files are derived from $PSScriptRoot so the tool works no matter
# which drive/dir it is installed to (C:\Program Files, D:\Tools, etc).
$root    = $PSScriptRoot
$handle  = Join-Path $root 'handle.exe'   # 仅作遗留兜底；主检测走 Restart Manager
$runner  = Join-Path $root 'unlock_system_runner.ps1'

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

# Restart Manager(rstrtmgr.dll)是微软官方的『文件→占用进程』查询 API，
# 右键菜单里的"解除占用"就是它驱动的；不依赖 handle.exe，中完整性也能查。
function Add-RMType {
    if ([System.AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetType('RestartManager', $false) }) { return }
    $src = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class RestartManager {
    [StructLayout(LayoutKind.Sequential)]
    public struct RM_UNIQUE_PROCESS {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)]  public string strServiceShortName;
        public uint ApplicationType; public uint AppStatus; public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)]
    public static extern int RmStartSession(out uint h, int flags, string key);
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)]
    public static extern int RmRegisterResources(uint h,
        uint nFiles, string[] filenames,
        uint nApps, IntPtr apps,
        uint nServices, string[] services);
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)]
    public static extern int RmGetList(uint h, out uint needed,
        ref uint count, [In,Out] RM_PROCESS_INFO[] arr, ref uint reasons);
    [DllImport("rstrtmgr.dll")]
    public static extern int RmEndSession(uint h);

    public static List<int> GetLockers(string filePath) {
        var result = new List<int>();
        if (string.IsNullOrEmpty(filePath)) return result;
        uint h = 0;
        if (RmStartSession(out h, 0, Guid.NewGuid().ToString()) != 0) return result;
        try {
            if (RmRegisterResources(h, 1, new[]{ filePath }, 0, IntPtr.Zero, 0, null) != 0) return result;
            uint needed = 0, count = 0, reason = 0;
            int r = RmGetList(h, out needed, ref count, null, ref reason);
            if (r != 0 && r != 234) return result;
            if (needed == 0) return result;
            var arr = new RM_PROCESS_INFO[needed];
            count = needed;
            if (RmGetList(h, out needed, ref count, arr, ref reason) != 0) return result;
            for (int i = 0; i < count; i++) result.Add(arr[i].Process.dwProcessId);
            return result;
        } finally {
            try { RmEndSession(h); } catch { }
        }
    }
}
'@
    try { Add-Type -TypeDefinition $src -ErrorAction Stop | Out-Null }
    catch { }
}

# 返回 @{ pids=hashset; method='RM|HANDLE' }
function Find-LockingProcesses([string[]]$normPaths, [string]$rootDir) {
    Add-RMType
    $owners = @{}
    # 对每一个具体文件跑一次 RM；文件夹在入库前已被展开成子文件，
    # 绝大多数情况下最多只检测十几个文件，毫秒级。
    foreach ($p in $normPaths) {
        if (-not $p -or [string]::IsNullOrWhiteSpace($p)) { continue }
        foreach ($id in [RestartManager]::GetLockers($p)) {
            if ($id -gt 0) { $owners[$id] = $true }
        }
    }
    return $owners
}

    # ===================== DETECT mode =====================
if ($Detect) {
    $DebugStart = Get-Date
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
    # 检测走 Restart Manager，handle.exe 仅作遗留不再调用。
    # matchSet 已被展开成「所有具体文件」，对每个文件调用一次 RM（毫秒级）。
    # RM 只认真实文件路径。把 matchSet 里的目录剔除,补上递归展开失败的目录本身(防漏)。
    $targetFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($m in $matchSet) {
        if (Test-Path -LiteralPath $m -PathType Container) { continue }   # 目录不进RM
        if (-not [string]::IsNullOrWhiteSpace($m)) { [void]$targetFiles.Add($m) }
    }
    Log-PS1 "detect: paths=$($paths.Count) files=$($targetFiles.Count) folderSet=$($folderSet.Count)"
    if ($targetFiles.Count -eq 0 -and $paths.Count -gt 0) {
        # 文件夹展开为空(可能权限不足)时,至少对目录本身跑一次 RM
        # 某些程序会直接持有目录路径句柄
        foreach ($tp in $paths) {
            if (Test-Path -LiteralPath $tp -PathType Container) {
                [void]$targetFiles.Add($tp.TrimEnd('\'))
            }
        }
        if ($targetFiles.Count -eq 0) {
            foreach ($tp in $paths) { [void]$targetFiles.Add($tp.TrimEnd('\')) }
        }
    }
    $owners = Find-LockingProcesses -normPaths $targetFiles
    $durMs = [int]((Get-Date) - $DebugStart).TotalMilliseconds
    Log-PS1 "detect: RM 耗时=${durMs}ms owners=$($owners.Count)"

    # RM 正常时至少能正确返回空集;若 RM 程序本身失败(极少数机器权限/集成限制),
    # 当 handle.exe 也读到不足时(owners=0)做一个双写探针 —— 有写锁就是「未被占用」。
    # 这一层仅用于兜底,避免早期 RM 缺失时出现永远 OK 的 false negative。
    if ($owners.Count -eq 0 -and $targetFiles.Count -gt 0) {
        $probe = $targetFiles[0]
        $hasWriteLock = $false
        try { [System.IO.File]::Open($probe,'Open','ReadWrite','None').Close() } catch { $hasWriteLock = $true }
        if ($hasWriteLock) {
            # 有写锁但 RM 没发现,把当前进程当作占位,让上层告诉用户"有风险"
            $owners[$pid] = $true
        }
    }
    $usePerFile = $true
    Push-Location -Path $env:TEMP
    try { } finally { Pop-Location }

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
