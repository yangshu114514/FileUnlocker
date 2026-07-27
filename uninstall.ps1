#Requires -Version 5.1
<#
.SYNOPSIS
    卸载 FileUnlocker 右键菜单并清理安装目录。
.DESCRIPTION
    1. 自动请求管理员权限
    2. 删除文件/文件夹/AllFilesystemObjects 三处注册表项
    3. 注销 SYSTEM 计划任务
    4. 删除安装目录
    5. 重启资源管理器使右键菜单立即生效
#>
param([string]$InstallDir = "C:\Program Files\FileUnlocker")

$scriptPath = $MyInvocation.MyCommand.Path
$ErrorActionPreference = 'Stop'

# 管理员自提升
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process pwsh.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -InstallDir `"$InstallDir`""
    exit
}

Write-Host "清理注册表项"
$scopes = @('*', 'AllFilesystemObjects', 'Directory')
foreach ($scope in $scopes) {
    $baseKey = "HKLM\Software\Classes\$scope\shell\FileUnlocker"
    reg delete $baseKey /f 2>$null | Out-Null
    Write-Host "  已删除 HKLM\$scope"
}
# 清理旧版可能写入 HKCU 的残留
reg delete "HKCU\Software\Classes\*\shell\FileUnlocker" /f 2>$null | Out-Null
reg delete "HKCU\Software\Classes\Directory\shell\FileUnlocker" /f 2>$null | Out-Null

try { Unregister-ScheduledTask -TaskName "WinDiag_Unlock_SYSTEM" -Confirm:$false -ErrorAction SilentlyContinue } catch {}

Write-Host "删除安装目录 $InstallDir"
if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
Write-Host "  已删除"

Write-Host "重启资源管理器以刷新右键菜单"
# 结束 explorer 进程，系统会自动重启它（刷新 Shell 缓存）
taskkill /IM explorer.exe /F 2>$null | Out-Null
Start-Process explorer.exe
Write-Host "卸载完成"
