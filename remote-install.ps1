# FileUnlocker 远程一键安装
# 在 PowerShell 窗口中粘贴运行:
#   iex (irm https://raw.githubusercontent.com/yangshu114514/FileUnlocker/main/remote-install.ps1)
#
# 如果 raw.githubusercontent.com 慢/被墙,把 URL 换成镜像:
#   iex (irm https://gh-proxy.com/https://raw.githubusercontent.com/yangshu114514/FileUnlocker/main/remote-install.ps1)
#
# 也支持本地执行: powershell -NoProfile -ExecutionPolicy Bypass -File remote-install.ps1

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$RepoOwner = "yangshu114514"
$RepoName  = "FileUnlocker"
$InstallDir = Join-Path $env:LOCALAPPDATA "FileUnlocker"
$ExeName = "FileUnlocker.exe"           # Release 上的资源名(英文,防止 URL 乱码)
$TargetExeName = "文件解锁器.exe"         # 装好后在本地的实际名字(中文)

# GitHub 镜像列表(按经验排序),任何一个能通就用它
# 源站放最后,最稳但慢
$Mirrors = @(
    "https://gh-proxy.com",          # 验证过 RC=0, 速度快
    "https://ghproxy.net",
    "https://ghfast.top",
    "https://mirror.ghproxy.com",
    ""                               # 最后的直连源站
)

function Test-Mirror {
    <# 快速测镜像,返回 true=能用 #>
    param([string]$Base)
    $testUrl = if ($Base) {
        "$Base/https://raw.githubusercontent.com/$RepoOwner/$RepoName/main/README.md"
    } else {
        "https://raw.githubusercontent.com/$RepoOwner/$RepoName/main/README.md"
    }
    try {
        $r = & curl.exe -sS -o NUL -m 8 -w "%{http_code}" $testUrl 2>&1
        return ($r -eq "200")
    } catch {
        return $false
    }
}

function Get-ReleaseJson {
    <# 拉最新 release JSON。镜像对 api.github.com 支持参差,做 fallback:
         1) 镜像代理 api
         2) 源站 api(慢但稳) #>
    param([string]$Mirror)
    $apiPath = "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"
    $candidates = @()
    if ($Mirror) { $candidates += "$Mirror/$apiPath" }
    $candidates += $apiPath

    foreach ($u in $candidates) {
        try {
            $json = & curl.exe -sS -L -m 15 -H "User-Agent: FileUnlocker" $u 2>$null
            if ($LASTEXITCODE -ne 0) { continue }
            $obj = $json | ConvertFrom-Json -ErrorAction Stop
            if ($obj.tag_name) { return $obj }
        } catch {
            continue
        }
    }
    throw "所有 release API 通道都失败"
}

Write-Host "====================================" -ForegroundColor Cyan
Write-Host "  FileUnlocker 远程一键安装" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host ""

# 1. 选一个能用的镜像
Write-Host "正在探测可用镜像..."
$Mirror = $null
foreach ($m in $Mirrors) {
    $name = if ($m) { $m } else { "(源站)" }
    Write-Host "  试 $name ... " -NoNewline
    if (Test-Mirror -Base $m) {
        Write-Host "OK" -ForegroundColor Green
        $Mirror = $m
        break
    } else {
        Write-Host "失败" -ForegroundColor DarkGray
    }
}
if ($null -eq $Mirror) {
    Write-Host "[错误] 所有镜像都不通,请检查网络" -ForegroundColor Red
    exit 1
}
$MirrorName = if ($Mirror) { $Mirror } else { "GitHub 源站" }
Write-Host "使用: $MirrorName" -ForegroundColor Cyan
Write-Host ""

# 2. 直接使用 main 分支的 FileUnlocker.exe
# 不查 release,这样:
#   - 不必依赖 release 是不是最新
#   - 仓库里 ExeName = "FileUnlocker.exe" 固定
$RawPath = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/main/$ExeName"
$downloadUrl = if ($Mirror) {
    "$Mirror/$RawPath"
} else {
    $RawPath
}
$tagName = "main(最新)"
Write-Host "版本: $tagName" -ForegroundColor Green
Write-Host "下载: $downloadUrl"
Write-Host ""

# 3. 下载 exe
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$dstExe = Join-Path $InstallDir $TargetExeName

Write-Host "正在下载到: $dstExe"
Write-Host "(11.5 MB,请稍等,会显示 curl 下载进度)"
# curl 借了 cmd /c 跑可以避免 PowerShell 7 的 stream redirect 留 handle 残留
$curlArgs = "curl.exe -L --retry 3 --connect-timeout 15 -o `"$dstExe`" -# `"$downloadUrl`""
& cmd.exe /c $curlArgs
$curlRc = $LASTEXITCODE
# 等 OS 释放文件写锁(PyInstaller onefile 启动会立即打开它,可能赶上没释放)
Start-Sleep -Milliseconds 500

if ($curlRc -ne 0 -or -not (Test-Path $dstExe)) {
    Write-Host ""
    Write-Host "[错误] 下载失败(rc=$curlRc)" -ForegroundColor Red
    exit 1
}
$sizeMB = [math]::Round((Get-Item $dstExe).Length / 1MB, 1)
if ($sizeMB -lt 5) {
    Write-Host "[错误] 下载的 exe 只有 $sizeMB MB,内容可能不完整" -ForegroundColor Red
    Remove-Item $dstExe -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Host ""
Write-Host "下载完成,大小 $sizeMB MB" -ForegroundColor Green
Write-Host ""
Write-Host ""
Write-Host "下载完成,大小 $sizeMB MB" -ForegroundColor Green
Write-Host ""

# 4. 调用 exe 自己的 --install 注册右键菜单 + 卸载入口
Write-Host "正在注册右键菜单和卸载入口..."
$p = Start-Process -FilePath $dstExe -ArgumentList "--install","--quiet" -PassThru -Wait -WindowStyle Hidden
if ($p.ExitCode -ne 0) {
    Write-Host "[错误] 注册失败,错误码 $($p.ExitCode)" -ForegroundColor Red
    Write-Host "日志: $env:TEMP\FileUnlocker_install.log"
    exit $p.ExitCode
}

Write-Host ""
Write-Host "安装完成!" -ForegroundColor Green
Write-Host "现在右键任意文件或文件夹,选择【解除文件占用】即可使用。" -ForegroundColor Green
Write-Host ""
Write-Host "卸载方式:"
Write-Host "  设置 → 应用 → 已安装的应用 → FileUnlocker → 卸载"