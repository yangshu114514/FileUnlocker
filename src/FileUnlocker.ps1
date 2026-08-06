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

function Write-Out($lines) {
    $lines -join "`r`n" | Out-File -FilePath $OutFile -Encoding utf8
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
    $handleNeedsSingleScan = ($folderSet.Count -gt 0) -or ($matchSet.Count -gt 2)
    Push-Location -Path $env:TEMP
    try {
        if ($handleNeedsSingleScan) {
            # Folder or many files: ONE full -a scan + prefix match (P4). For a
            # multi-select of dozens of files this is far faster than per-file calls.
            $curPid = 0
            & $handle /accepteula -nobanner -a 2>$null | ForEach-Object {
                if ($_ -match 'pid:\s*(\d+)') { $curPid = [int]$matches[1] }
                elseif ($_ -match '^\s*\S+:\\?\s*File\s+\S*\s+(.+)$' -or
                        $_ -match '^\s*\S+:\s*File\s+\S*\s+(.+)$') {
                    $hpath = $matches[1].Trim().TrimEnd('\')
                    $hit = $false
                    if ($matchSet.Contains($hpath)) { $hit = $true }
                    else {
                        foreach ($m in $matchSet) {
                            if ($hpath.StartsWith($m + '\') -or $hpath.StartsWith($m + '/')) { $hit = $true; break }
                        }
                    }
                    if ($hit -and $curPid -gt 0) { $owners[$curPid] = $true }
                }
            }
        } else {
            # 1-2 pure files: per-target handle call is precise and avoids the
            # cross-line pid parsing (P4).
            foreach ($m in $matchSet) {
                & $handle /accepteula -nobanner $m 2>$null | ForEach-Object {
                    if ($_ -match 'pid:\s*(\d+)') { $owners[[int]$matches[1]] = $true }
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
    $pids = $PidList -split ',' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    if ($pids.Count -eq 0) {
        "KILLED=0`r`nDETAIL=no pid" | Out-File -FilePath $killOut -Encoding utf8
        exit 0
    }

    $sysResult = Join-Path $root 'unlock_system_result.txt'
    if (Test-Path $sysResult) { Remove-Item $sysResult -Force }
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -PidList `"$($pids -join ',')`" -ResultFile `"$sysResult`""
    try {
        Unregister-ScheduledTask -TaskName "WinDiag_Unlock_SYSTEM" -Confirm:$false -ErrorAction SilentlyContinue
        $action    = New-ScheduledTaskAction    -Execute "C:\Program Files\PowerShell\7\pwsh.exe" -Argument $arg
        $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName "WinDiag_Unlock_SYSTEM" -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName "WinDiag_Unlock_SYSTEM"
        $waited = 0
        while ($waited -lt 15) {
            Start-Sleep -Seconds 1; $waited++
            if ((Get-ScheduledTask -TaskName "WinDiag_Unlock_SYSTEM" -ErrorAction SilentlyContinue).State -eq 'Ready') { break }
        }
        Unregister-ScheduledTask -TaskName "WinDiag_Unlock_SYSTEM" -Confirm:$false -ErrorAction SilentlyContinue
        $sysOut = if (Test-Path $sysResult) { (Get-Content $sysResult -Raw).Trim() } else { "(SYSTEM no output)" }
        "KILLED=$($pids.Count)`r`nDETAIL=$sysOut" | Out-File -FilePath $killOut -Encoding utf8
    } catch {
        "KILLED=0`r`nDETAIL=SYSTEM task failed: $($_.Exception.Message)" | Out-File -FilePath $killOut -Encoding utf8
    }
    exit 0
}

Write-Out @("ERROR=unknown mode")
exit 1
