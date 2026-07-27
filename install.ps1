#Requires -Version 5.1
<#
.SYNOPSIS
    安装 FileUnlocker 右键菜单（解除文件占用）。
.DESCRIPTION
    1. 自动请求管理员权限
    2. 复制 src\ 到 $InstallDir (默认 C:\Program Files\FileUnlocker)

$scriptPath = $MyInvocation.MyCommand.Path
    3. 自动下载 handle.exe (Sysinternals) 到安装目录
    4. 注册文件与文件夹右键菜单，调用 VBS 提权壳
#>
param(
    [string]$InstallDir = "C:\Program Files\FileUnlocker",
    [string]$HandleUrl  = "https://download.sysinternals.com/files/Handle.zip"
)

$scriptPath = $MyInvocation.MyCommand.Path
$ErrorActionPreference = 'Stop'

# 管理员自提升
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process pwsh.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -InstallDir `"$InstallDir`""
    exit
}

$root = Split-Path $scriptPath -Parent
$src  = Join-Path $root 'src'

Write-Host "[1/4] 部署文件到 $InstallDir"
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
Copy-Item (Join-Path $src '*') $InstallDir -Recurse -Force

$vbs = Join-Path $InstallDir 'FileUnlocker_Run.vbs'
$handleExe = Join-Path $InstallDir 'handle.exe'

Write-Host "[2/4] 下载 handle.exe (Sysinternals)"
if (Test-Path $handleExe) {
    Write-Host "  已存在，跳过下载"
} else {
    $zip = Join-Path $env:TEMP 'Handle.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $HandleUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $InstallDir -Force
    $extracted = Get-ChildItem $InstallDir -Filter 'handle.exe' -Recurse | Select-Object -First 1
    if ($extracted) { Move-Item $extracted.FullName $handleExe -Force }
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $handleExe)) { throw "handle.exe 下载或解压失败" }
    Write-Host "  完成"
}

Write-Host "[3/4] 注册右键菜单"
$cmd = 'wscript.exe "' + $vbs + '" "%1"'
$scopes = @('*', 'AllFilesystemObjects', 'Directory')
foreach ($scope in $scopes) {
    $baseKey = "HKLM\Software\Classes\$scope\shell\FileUnlocker"
    reg add $baseKey /ve /t REG_SZ /d "解除文件占用" /f | Out-Null
    reg add $baseKey /v Icon /t REG_SZ /d "shell32.dll,131" /f | Out-Null
    reg add "$baseKey\command" /ve /t REG_SZ /d $cmd /f | Out-Null
    Write-Host "  已注册 $scope"
}

Write-Host "[4/4] 完成"
Write-Host "现在右键点击文件或文件夹即可看到『解除文件占用』。"
