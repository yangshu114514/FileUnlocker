@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: 全程日志
set "LOG=%TEMP%\FileUnlocker_install.log"
echo [%date% %time%] 安装开始 > "%LOG%"
echo [%date% %time%] 当前目录: %CD% >> "%LOG%"
echo [%date% %time%] 脚本路径: %~f0 >> "%LOG%"

:: ============ 管理员自提权 ============
fltmc >nul 2>&1
if errorlevel 1 (
    echo [%date% %time%] 非管理员，请求提权 >> "%LOG%"
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >> "%LOG%" 2>&1
    echo [%date% %time%] 已启动提权进程，退出原进程 >> "%LOG%"
    exit /b
)
echo [%date% %time%] 已是管理员 >> "%LOG%"

:: ============ 配置 ============
set "INSTALL_DIR=C:\Program Files\FileUnlocker"
set "REPO_URL=https://github.com/ksyangshu/FileUnlocker"
set "PWSH_URL=https://github.com/PowerShell/PowerShell/releases/download/v7.5.0/PowerShell-7.5.0-win-x64.msi"
set "HANDLE_URL1=https://download.sysinternals.com/files/Handle.zip"
set "HANDLE_URL2=https://mirror.ghproxy.com/https://download.sysinternals.com/files/Handle.zip"

echo [FileUnlocker 安装] 开始 > "%LOG%"

:: ============ 检测 PowerShell 7 ============
set "PWSH_EXE="
for %%P in ("%ProgramFiles%\PowerShell\7\pwsh.exe" "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe") do (
    if exist %%~P set "PWSH_EXE=%%~P"
)
where pwsh.exe >nul 2>&1
if not errorlevel 1 (
    for /f "delims=" %%i in ('where pwsh.exe') do set "PWSH_EXE=%%i"
)

if not defined PWSH_EXE (
    echo [警告] 未找到 PowerShell 7 >> "%LOG%"
    call :ask "未找到 PowerShell 7 (pwsh.exe)，它是本工具的运行依赖。是否现在安装？(取消则中止安装)" "安装确认"
    if errorlevel 1 (
        echo [取消] 用户拒绝安装 PowerShell 7，退出
        goto :end_cancel
    )
    call :install_pwsh
    if errorlevel 1 goto :end_fail
    for %%P in ("%ProgramFiles%\PowerShell\7\pwsh.exe") do set "PWSH_EXE=%%~P"
    if not exist "!PWSH_EXE!" (
        for /f "delims=" %%i in ('where pwsh.exe 2^>nul') do set "PWSH_EXE=%%i"
    )
)
echo [确定] 使用 PowerShell: %PWSH_EXE% >> "%LOG%"

:: ============ 已存在目录询问 ============
if exist "%INSTALL_DIR%" (
    call :ask "检测到安装目录已存在：%INSTALL_DIR%，是否覆盖并继续安装？" "安装确认"
    if errorlevel 1 (
        echo [取消] 用户取消覆盖
        goto :end_cancel
    )
)

:: ============ 复制文件 ============
echo [1/4] 部署到 %INSTALL_DIR%
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

:: ============ 注册右键菜单 ============
echo [3/4] 注册右键菜单
set "CMD=wscript.exe \"%VBS%\" \"%%1\""
for %%S in (* AllFilesystemObjects Directory) do (
    set "KEY=HKLM\Software\Classes\%%S\shell\FileUnlocker"
    reg add "!KEY!" /ve /t REG_SZ /d "解除文件占用" /f >nul 2>&1
    reg add "!KEY!" /v Icon /t REG_SZ /d "shell32.dll,131" /f >nul 2>&1
    reg add "!KEY!\command" /ve /t REG_SZ /d "%CMD%" /f >nul 2>&1
    echo   已注册 %%S
)
reg delete "HKCU\Software\Classes\*\shell\FileUnlocker" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Directory\shell\FileUnlocker" /f >nul 2>&1

:: ============ 重启资源管理器 ============
echo [4/4] 重启资源管理器
echo 正在重启资源管理器使右键菜单生效...
taskkill /IM explorer.exe /F >nul 2>&1
start "" explorer.exe
echo.
echo ========== 免责声明 ==========
echo 本工具通过强制终止占用文件的进程来解锁，可能导致未保存数据丢失或程序异常退出。
echo 使用即代表你已知晓风险并自行承担后果，作者不对任何数据丢失或系统问题负责。
echo 切勿终止系统关键进程(如 lsass、svchost 等)，否则可能导致系统不稳定。
echo handle.exe 由 Sysinternals(微软)提供，可免费使用，请从官方源获取。
echo ==============================
echo.
echo 右键点击任意文件或文件夹即可使用"解除文件占用"。
echo 安装日志: %LOG%
pause
exit /b 0

:: ============ 函数 ============
:ask
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
echo [信息] 安装 PowerShell 7...
set "MSI=%TEMP%\PowerShell-7.msi"
curl -L --max-time 120 -o "%MSI%" "%PWSH_URL%" 2>>"%LOG%"
if not exist "%MSI%" (
    echo [失败] PowerShell 7 下载失败(可能无网络)。请手动安装：
    echo https://github.com/PowerShell/PowerShell/releases
    pause
    exit /b 1
)
echo [安装] 正在静默安装 PowerShell 7...
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
            echo   已下载
            exit /b 0
        )
    )
)
echo [失败] handle.exe 下载失败，请手动放置到 %HANDLE_EXE%
pause
exit /b 1

:end_cancel
echo 用户取消安装
pause
exit /b 0

:end_fail
echo 安装失败，请查看日志: %LOG%
pause
exit /b 1
