# FileUnlocker 一键卸载
# 也可以从 设置→应用→已安装的应用 里点击"卸载"(自动走这里的逻辑)。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$Exe = Join-Path $env:LOCALAPPDATA "FileUnlocker\文件解锁器.exe"

if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Host "[错误] 找不到已安装的 $Exe" -ForegroundColor Red
    Write-Host "可能未安装,或已被手动删除。"
    Read-Host "按回车退出"
    exit 1
}

$p = Start-Process -FilePath $Exe -ArgumentList "--uninstall","--quiet" -PassThru -Wait -WindowStyle Hidden
exit $p.ExitCode