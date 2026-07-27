@echo off
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

:: ============ 配置 ============
set "INSTALL_DIR=C:\Program Files\FileUnlocker"
set "REPO_URL=https://github.com/ksyangshu/FileUnlocker"
set "PWSH_URL=https://github.com/PowerShell/PowerShell/releases/download/v7.5.0/PowerShell-7.5.0-win-x64.msi"
set "HANDLE_URL1=https://download.sysinternals.com/files/Handle.zip"
set "HANDLE_URL2=https://mirror.ghproxy.com/https://download.sysinternals.com/files/Handle.zip"
set "LOG=%TEMP%\FileUnlocker_install.log"

:: ============ 管理员自提权 ============
fltmc >nul 2>&1
if errorlevel 1 (
    echo [提权] 请求管理员权限，请在弹出的窗口中点击"是"...
    powershell -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c \"\"%~f0\" %*\"' -Verb RunAs"
    if errorlevel 1 (
        echo 提权失败，请右键本文件选择"以管理员身份运行"。
        pause
    )
    exit /b
)

echo [FileUnlocker 安装] 开始 > "%LOG%"

:: ============ 检查 PowerShell 7 ============
set "PWSH_EXE="
for %%P in ("%ProgramFiles%\PowerShell\7\pwsh.exe" "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe") do (
    if exist %%~P set "PWSH_EXE=%%~P"
)
where pwsh.exe >nul 2>&1
if not errorlevel 1 (
    for /f "delims=" %%i in ('where pwsh.exe') do set "PWSH_EXE=%%i"
)

if not defined PWSH_EXE (
    echo [检测] 未发现 PowerShell 7 >> "%LOG%"
    call :ask "未检测到 PowerShell 7 (pwsh.exe)，这是本工具的必需依赖。`n是否现在下载并安装？`n(取消则退出安装)" "安装确认"
    if errorlevel 1 (
        echo [取消] 用户拒绝安装 PowerShell 7，退出。
        goto :end_cancel
    )
    call :install_pwsh
    if errorlevel 1 goto :end_fail
    :: 重新定位
    for %%P in ("%ProgramFiles%\PowerShell\7\pwsh.exe") do set "PWSH_EXE=%%~P"
    if not exist "!PWSH_EXE!" (
        for /f "delims=" %%i in ('where pwsh.exe 2^>nul') do set "PWSH_EXE=%%i"
    )
)
echo [检测] 使用 PowerShell: %PWSH_EXE% >> "%LOG%"

:: ============ 目录已存在则询问 ============
if exist "%INSTALL_DIR%" (
    call :ask "检测到安装目录已存在：`n%INSTALL_DIR%`n是否覆盖并继续安装？" "安装确认"
    if errorlevel 1 (
        echo [取消] 用户取消覆盖。
        goto :end_cancel
    )
)

:: ============ 部署文件 ============
echo [1/4] 部署文件到 %INSTALL_DIR%
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
xcopy "%~dp0src\*" "%INSTALL_DIR%\" /E /Y /Q >> "%LOG%" 2>&1
set "VBS=%INSTALL_DIR%\FileUnlocker_Run.vbs"
set "HANDLE_EXE=%INSTALL_DIR%\handle.exe"

:: ============ handle.exe ============
echo [2/4] 准备 handle.exe
set "HANDLE_OK=0"
if exist "%HANDLE_EXE%" (
    set "HANDLE_OK=1"
)
if "%HANDLE_OK%"=="0" (
    call :download_handle
    if errorlevel 1 goto :end_fail
)

:: ============ 注册表 ============
echo [3/4] 注册右键菜单
set "CMD=wscript.exe \"%VBS%\" \"%%1\""
for %%S in (* AllFilesystemObjects Directory) do (
    set "KEY=HKLM\Software\Classes\%%S\shell\FileUnlocker"
    reg add "!KEY!" /ve /t REG_SZ /d "解除文件占用" /f >nul 2>&1
    reg add "!KEY!" /v Icon /t REG_SZ /d "shell32.dll,131" /f >nul 2>&1
    reg add "!KEY!\command" /ve /t REG_SZ /d "%CMD%" /f >nul 2>&1
    echo   已注册 %%S
)
:: 清理旧 HKCU 残留
reg delete "HKCU\Software\Classes\*\shell\FileUnlocker" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Directory\shell\FileUnlocker" /f >nul 2>&1

:: ============ 完成 ============
echo [4/4] 完成
echo 重启资源管理器使右键菜单立即生效...
taskkill /IM explorer.exe /F >nul 2>&1
start "" explorer.exe
echo.
echo ========== 免责声明 ==========
echo 本工具以强制终止进程方式解除文件/文件夹占用，可能导致未保存数据丢失或程序异常退出。
echo 使用者须自行承担由此产生的任何后果，作者不承担任何直接或间接责任。
echo 请勿用于终止系统关键进程（lsass、svchost 等，本工具已内置保护），否则可能导致系统不稳定。
echo handle.exe 由 Sysinternals(微软) 提供，本工具仅在使用时从其官方源下载，仓库不打包该二进制。
echo ==============================
echo.
echo 现在右键点击文件或文件夹即可看到『解除文件占用』。
echo 安装日志: %LOG%
pause
exit /b 0

:: ============ 函数 ============
:ask
:: %1=消息 %2=标题  返回 errorlevel 1=否/取消 0=是
set "MSG=%~1"
set "TITLE=%~2"
set "VBS_TMP=%TEMP%\fu_ask.vbs"
(
    echo result = MsgBox(WScript.Arguments(0^), vbYesNo + vbQuestion, WScript.Arguments(1^)^)
    echo If result = vbYes Then
    echo     WScript.Quit 0
    echo Else
    echo     WScript.Quit 1
    echo End If
) > "%VBS_TMP%"
cscript //NoLogo "%VBS_TMP%" "%MSG%" "%TITLE%"
set "RC=%errorlevel%"
del /f /q "%VBS_TMP%" 2>nul
exit /b %RC%

:install_pwsh
echo [下载] PowerShell 7 ...
set "MSI=%TEMP%\PowerShell-7.msi"
curl -L --max-time 120 -o "%MSI%" "%PWSH_URL%" 2>>"%LOG%"
if not exist "%MSI%" (
    echo [失败] PowerShell 7 下载失败（镜像不可达），请手动安装后重试。
    echo 官方: https://github.com/PowerShell/PowerShell/releases
    pause
    exit /b 1
)
echo [安装] 静默安装 PowerShell 7 ...
msiexec /i "%MSI%" /quiet /norestart >> "%LOG%" 2>&1
del /f /q "%MSI%" 2>nul
exit /b 0

:download_handle
set "ZIP=%TEMP%\Handle.zip"
for %%U in ("%HANDLE_URL1%" "%HANDLE_URL2%") do (
    echo   尝试: %%U
    curl -L --max-time 90 -o "%ZIP%" "%%U" 2>>"%LOG%"
    if exist "%ZIP%" (
        powershell -NoProfile -Command "Expand-Archive -Path '%ZIP%' -DestinationPath '%TEMP%\handle_tmp' -Force" >> "%LOG%" 2>&1
        for /f "delims=" %%f in ('dir /b /s "%TEMP%\handle_tmp\handle.exe" 2^>nul') do (
            copy /Y "%%f" "%HANDLE_EXE%" >nul 2>&1
        )
        del /f /q "%ZIP%" 2>nul
        rmdir /s /q "%TEMP%\handle_tmp" 2>nul
        if exist "%HANDLE_EXE%" (
            echo   完成
            exit /b 0
        )
    )
)
echo [失败] handle.exe 下载失败，请手动下载放到 %HANDLE_EXE%
pause
exit /b 1

:end_cancel
echo 安装已取消。
pause
exit /b 0

:end_fail
echo 安装失败，详见日志 %LOG%
pause
exit /b 1
