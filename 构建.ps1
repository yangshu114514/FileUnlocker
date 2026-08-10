# 用 PyInstaller 把 run.py 打包成单个 "文件解锁器.exe"
# 输出位置: dist\文件解锁器.exe
# 完成后请把它复制到本目录,再双击 安装.ps1

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $Root

Write-Host "====================================" -ForegroundColor Cyan
Write-Host "  正在构建 文件解锁器.exe" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Get-Command pyinstaller -ErrorAction SilentlyContinue)) {
    Write-Host "未检测到 pyinstaller,正在安装..." -ForegroundColor Yellow
    python -m pip install --upgrade pyinstaller
}

python -m PyInstaller `
  --onefile `
  --noconsole `
  --name 文件解锁器 `
  --clean `
  --noconfirm `
  run.py

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "构建失败,请往上翻看错误信息。" -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}

Write-Host ""
Write-Host "构建完成,输出位置:" -ForegroundColor Green
$dist = Join-Path $Root "dist\文件解锁器.exe"
Write-Host "  $dist"
Write-Host ""
Write-Host "把 dist\文件解锁器.exe 复制到本目录,再运行 安装.ps1 即可。" -ForegroundColor Green

# 自动复制一份到根目录,方便用户直接安装
try {
    Copy-Item -LiteralPath $dist -Destination (Join-Path $Root "文件解锁器.exe") -Force
    Write-Host "已自动复制到本目录: $(Join-Path $Root '文件解锁器.exe')" -ForegroundColor Green
} catch {
    Write-Host "自动复制失败: $_" -ForegroundColor Yellow
}

Read-Host "按回车退出"