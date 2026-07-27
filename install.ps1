#Requires -Version 5.1
<#
.SYNOPSIS
    安装 FileUnlocker 右键菜单（解除文件占用）。
.DESCRIPTION
    1. 检测并自动请求管理员权限
    2. 检测 PowerShell 7 (pwsh)，缺失则提示国内安装命令
    3. 复制 src\ 到 $InstallDir (默认 C:\Program Files\FileUnlocker)
    4. 下载 handle.exe：优先官方源，失败回退国内镜像
    5. 注册文件/文件夹/AllFilesystemObjects 右键菜单
.PARAMETER InstallDir
    安装目录，默认 C:\Program Files\FileUnlocker
.PARAMETER HandleUrl
    官方 handle.exe 下载地址（可被镜像覆盖）
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

# 检测 PowerShell 7
$pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $pwsh) {
    Write-Host "[错误] 未检测到 PowerShell 7 (pwsh.exe)。" -ForegroundColor Red
    Write-Host "本工具依赖 PowerShell 7，请先安装：" -ForegroundColor Yellow
    Write-Host "  国内镜像(推荐): winget install Microsoft.PowerShell  (或访问 https://mirrors.tuna.tsinghua.edu.cn/GitHub-release/PowerShell/PowerShell/)" -ForegroundColor Cyan
    Write-Host "  官方:           https://github.com/PowerShell/PowerShell/releases" -ForegroundColor Cyan
    Write-Host "安装完成后重新运行本脚本。" -ForegroundColor Yellow
    exit 1
}
Write-Host "[0/4] 检测到 PowerShell 7: $pwsh"

$root = Split-Path $scriptPath -Parent
$src  = Join-Path $root 'src'

Write-Host "[1/4] 部署文件到 $InstallDir"
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
Copy-Item (Join-Path $src '*') $InstallDir -Recurse -Force

$vbs = Join-Path $InstallDir 'FileUnlocker_Run.vbs'
$handleExe = Join-Path $InstallDir 'handle.exe'

Write-Host "[2/4] 准备 handle.exe"
$handleOk = $false
if (Test-Path $handleExe) {
    # 存在性 + 可执行校验：能正常输出版本号才算有效
    try {
        $ver = & $handleExe /accepteula 2>&1 | Select-Object -First 1
        if ($ver -match 'Nthandle|Sysinternals') { $handleOk = $true }
    } catch {}
    if ($handleOk) { Write-Host "  已存在且可用，跳过下载" }
    else { Write-Host "  已存在但损坏，重新下载"; Remove-Item $handleExe -Force }
}

if (-not $handleOk) {
    $mirrors = @(
        $HandleUrl,
        "https://mirror.ghproxy.com/https://download.sysinternals.com/files/Handle.zip",
        "https://ghproxy.net/https://download.sysinternals.com/files/Handle.zip"
    )
    $done = $false
    foreach ($u in $mirrors) {
        try {
            Write-Host "  尝试下载: $u"
            $zip = Join-Path $env:TEMP 'Handle.zip'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $u -OutFile $zip -UseBasicParsing -TimeoutSec 60
            Expand-Archive -Path $zip -DestinationPath $InstallDir -Force
            $extracted = Get-ChildItem $InstallDir -Filter 'handle.exe' -Recurse | Select-Object -First 1
            if ($extracted) { Move-Item $extracted.FullName $handleExe -Force }
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            if (Test-Path $handleExe) { $done = $true; Write-Host "  完成"; break }
        } catch {
            Write-Host "    失败: $($_.Exception.Message)"
        }
    }
    if (-not $done) { throw "handle.exe 下载失败（官方源与国内镜像均不可达），请手动下载放到 $handleExe" }
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
# 清理旧版可能残留的 HKCU 项，避免重复/冲突
reg delete "HKCU\Software\Classes\*\shell\FileUnlocker" /f 2>$null | Out-Null
reg delete "HKCU\Software\Classes\Directory\shell\FileUnlocker" /f 2>$null | Out-Null

Write-Host "[4/4] 完成"
Write-Host "现在右键点击文件或文件夹即可看到『解除文件占用』。" -ForegroundColor Green
