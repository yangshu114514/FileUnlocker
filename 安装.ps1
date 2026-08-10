# FileUnlocker 一键安装
# 双击 安装.ps1 即可,自动完成:
#   1. 把 文件解锁器.exe 复制到 %LOCALAPPDATA%\FileUnlocker
#   2. 注册右键菜单
#   3. 在【设置 → 应用】中注册卸载入口
# 需要:当前目录下已有 "文件解锁器.exe"(由 构建.ps1 生成)。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$Root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Exe   = Join-Path $Root "文件解锁器.exe"
$InstallDir = Join-Path $env:LOCALAPPDATA "FileUnlocker"

if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Host "[错误] 找不到 $Exe" -ForegroundColor Red
    Write-Host "请先运行 构建.ps1 生成 exe,然后把它放到本目录"
    Read-Host "按回车退出"
    exit 1
}

Write-Host "====================================" -ForegroundColor Cyan
Write-Host "  正在安装 解除文件占用" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host "  目标目录: $InstallDir"
Write-Host ""

# 用 Start-Process -Wait 等待 exe 退出(GUI 进程必须显式 Wait,
# 否则 $LASTEXITCODE 拿不到值)。
# 传 --quiet 让 exe 不弹自己的 UI(我们用 PowerShell 提示就够了)
$p = Start-Process -FilePath $Exe -ArgumentList "--install","--quiet" -PassThru -Wait -WindowStyle Hidden
$rc = $p.ExitCode

if ($rc -eq 0) {
    Write-Host ""
    Write-Host "安装成功!" -ForegroundColor Green
    Write-Host "右键任意文件/文件夹,选择【解除文件占用】即可使用。"
} else {
    Write-Host ""
    Write-Host "安装失败,错误码 $rc" -ForegroundColor Red
    Write-Host "日志: $env:TEMP\FileUnlocker_install.log"
}
Read-Host "按回车退出"
exit $rc