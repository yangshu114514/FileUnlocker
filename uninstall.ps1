#Requires -Version 5.1
<#
.SYNOPSIS
    卸载 FileUnlocker 右键菜单并清理安装目录。
#>
param([string]$InstallDir = "C:\Program Files\FileUnlocker")

$scriptPath = $MyInvocation.MyCommand.Path

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process pwsh.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -InstallDir `"$InstallDir`""
    exit
}

Write-Host "清理注册表项"
$scopes = @('*', 'AllFilesystemObjects', 'Directory')
foreach ($scope in $scopes) {
    $baseKey = "HKLM\Software\Classes\$scope\shell\FileUnlocker"
    reg delete $baseKey /f 2>$null | Out-Null
    Write-Host "  已删除 $scope"
}

try { Unregister-ScheduledTask -TaskName "WinDiag_Unlock_SYSTEM" -Confirm:$false -ErrorAction SilentlyContinue } catch {}

Write-Host "删除安装目录 $InstallDir"
if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
Write-Host "卸载完成"
