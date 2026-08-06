@echo off
chcp 936 >nul
setlocal EnableExtensions EnableDelayedExpansion

rem ===================================================
rem  FileUnlocker 安装脚本
rem  功能：自动安装到 C:\Program Files\FileUnlocker
rem        注册右键菜单，下载依赖 handle.exe
rem ===================================================

set "LOG=%TEMP%\FileUnlocker_install.log"
set "INSTALL_DIR=C:\Program Files\FileUnlocker"
set "PWSH_URL=https://github.com/PowerShell/PowerShell/releases/download/v7.5.0/PowerShell-7.5.0-win-x64.msi"
set "HANDLE_URL1=https://download.sysinternals.com/files/Handle.zip"
set "HANDLE_URL2=https://mirror.ghproxy.com/https://download.sysinternals.com/files/Handle.zip"

echo. > "%LOG%"
echo ================================================  >> "%LOG%"
echo  FileUnlocker 安装日志                              >> "%LOG%"
echo  时间: %date% %time%                               >> "%LOG%"
echo  脚本: %~f0                                        >> "%LOG%"
echo ================================================  >> "%LOG%"

call :log "开始安装 FileUnlocker"

rem ---------- 1. 检查管理员权限 ----------
fltmc >nul 2>&1
if errorlevel 1 (
    call :log "未检测到管理员权限，正在请求 UAC 提权..."
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >> "%LOG%" 2>&1
    exit /b 0
)
call :log "已确认管理员权限"

rem ---------- 2. 检测 PowerShell 7 ----------
call :log "检测 PowerShell 7 (pwsh.exe)..."
set "PWSH_EXE="
for %%P in (
    "%ProgramFiles%\PowerShell\7\pwsh.exe"
    "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
) do (
    if exist %%~P set "PWSH_EXE=%%~P"
)
if not defined PWSH_EXE (
    for /f "delims=" %%i in ('where pwsh.exe 2^>nul') do set "PWSH_EXE=%%i"
)

if not defined PWSH_EXE (
    call :log "未找到 PowerShell 7"
    call :ask "未检测到 PowerShell 7。`n`n这是本工具必需的依赖，是否立即下载并安装？" "安装依赖"
    if errorlevel 1 (
        call :log "用户拒绝安装 PowerShell 7，退出"
        echo.
        echo [已取消] 未安装 PowerShell 7，安装中止
        pause
        exit /b 1
    )
    call :install_pwsh
    if errorlevel 1 goto :fail
    for %%P in ("%ProgramFiles%\PowerShell\7\pwsh.exe") do set "PWSH_EXE=%%~P"
)
call :log "使用 PowerShell: %PWSH_EXE%"

rem ---------- 3. 覆盖旧版本询问 ----------
if exist "%INSTALL_DIR%" (
    call :ask "检测到已存在的安装目录：`n%INSTALL_DIR%`n`n是否覆盖并重新安装？" "重新安装确认"
    if errorlevel 1 (
        call :log "用户取消覆盖安装"
        echo.
        echo [已取消] 未覆盖现有安装
        pause
        exit /b 0
    )
)

rem ---------- 4. 复制文件 ----------
echo.
echo [1/4] 复制脚本文件到 %INSTALL_DIR%
call :log "创建目录 %INSTALL_DIR%"
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
xcopy "%~dp0src\*" "%INSTALL_DIR%\" /E /Y /Q >> "%LOG%" 2>&1
if errorlevel 1 (
    call :log "复制文件失败"
    echo [失败] 复制文件失败
    goto :fail
)
set "VBS=%INSTALL_DIR%\FileUnlocker_Run.vbs"
set "HANDLE_EXE=%INSTALL_DIR%\handle.exe"
call :log "文件复制完成"

rem ---------- 5. 下载 handle.exe ----------
echo [2/4] 准备 handle.exe
if exist "%HANDLE_EXE%" (
    call :log "handle.exe 已存在，跳过下载"
    echo       已存在，跳过下载
) else (
    call :download_handle
    if errorlevel 1 goto :fail
)

rem ---------- 6. 注册右键菜单 ----------
echo [3/4] 注册右键菜单
call :log "开始注册右键菜单"
set "CMD=wscript.exe \"%VBS%\" \"%%1\""
for %%S in (AllFilesystemObjects Directory) do (
    set "KEY=HKLM\Software\Classes\%%S\shell\FileUnlocker"
    reg add "!KEY!" /ve /t REG_SZ /d "解除文件占用" /f >nul 2>&1
    reg add "!KEY!" /v Icon /t REG_SZ /d "shell32.dll,131" /f >nul 2>&1
    reg add "!KEY!\command" /ve /t REG_SZ /d "%CMD%" /f >nul 2>&1
    echo       已注册 %%S
)
rem 通配符 * 不能用 for 遍历（会展开成文件名），单独显式注册
reg add "HKLM\Software\Classes\*\shell\FileUnlocker" /ve /t REG_SZ /d "解除文件占用" /f >nul 2>&1
reg add "HKLM\Software\Classes\*\shell\FileUnlocker" /v Icon /t REG_SZ /d "shell32.dll,131" /f >nul 2>&1
reg add "HKLM\Software\Classes\*\shell\FileUnlocker\command" /ve /t REG_SZ /d "%CMD%" /f >nul 2>&1
echo       已注册 *
rem 清理旧的 HKCU 注册（兼容旧版本）
reg delete "HKCU\Software\Classes\*\shell\FileUnlocker" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Directory\shell\FileUnlocker" /f >nul 2>&1
call :log "右键菜单注册完成"

rem ---------- 7. 重启资源管理器 ----------
echo [4/4] 重启资源管理器
call :log "重启 explorer.exe"
taskkill /IM explorer.exe /F >nul 2>&1
start "" explorer.exe
call :log "安装完成"

rem ---------- 完成提示 ----------
echo.
echo ================================================
echo  安装完成！
echo ================================================
echo.
echo  使用方法：右键任意文件或文件夹 -^> "解除文件占用"
echo.
echo  注意事项：
echo    ^^^! 本工具会强制终止占用文件的进程
echo    ^^^! 请确认进程可以安全结束，避免数据丢失
echo    ^^^! handle.exe 来自 Sysinternals（微软官方）
echo.
echo  日志文件: %LOG%
echo.
pause
exit /b 0


rem ===================================================
rem  子函数
rem ===================================================

:ask
rem 使用 VBScript 弹出确认对话框（中文界面），替换 `n 为换行
set "MSG=%~1"
set "TITLE=%~2"
set "VBS_ASK=%TEMP%\fu_ask_%RANDOM%%RANDOM%.vbs"
(
    echo Dim result
    echo result = MsgBox^(Replace^(WScript.Arguments^(0^), Chr^(96^) ^& "n", vbCrLf^), vbYesNo + vbQuestion, WScript.Arguments^(1^)^)
    echo If result = vbYes Then WScript.Quit 0 Else WScript.Quit 1
) > "%VBS_ASK%"
cscript //NoLogo "%VBS_ASK%" "%MSG%" "%TITLE%"
set "RC=%errorlevel%"
del /f /q "%VBS_ASK%" 2>nul
exit /b %RC%


:install_pwsh
echo.
echo [信息] 正在下载并安装 PowerShell 7...
echo [信息] 下载地址: %PWSH_URL%
set "MSI=%TEMP%\PowerShell-7.msi"
curl -L --max-time 120 -o "%MSI%" "%PWSH_URL%" 2>>"%LOG%"
if not exist "%MSI%" (
    call :log "PowerShell 7 下载失败"
    echo.
    echo [失败] PowerShell 7 下载失败，请手动安装后重跑
    echo        https://github.com/PowerShell/PowerShell/releases
    echo.
    pause
    exit /b 1
)
call :log "静默安装 PowerShell 7 MSI"
msiexec /i "%MSI%" /quiet /norestart >> "%LOG%" 2>&1
if errorlevel 1 (
    call :log "PowerShell 7 安装失败"
    echo [失败] PowerShell 7 安装失败
    del /f /q "%MSI%" 2>nul
    exit /b 1
)
del /f /q "%MSI%" 2>nul
call :log "PowerShell 7 安装完成"
exit /b 0


:download_handle
call :log "开始下载 handle.exe"
set "ZIP=%TEMP%\Handle.zip"
set "EXTRACT_DIR=%TEMP%\handle_ext_%RANDOM%%RANDOM%"
for %%U in ("%HANDLE_URL1%" "%HANDLE_URL2%") do (
    echo       尝试: %%U
    call :log "尝试下载: %%U"
    curl -L --max-time 90 -o "%ZIP%" "%%U" 2>>"%LOG%"
    if exist "%ZIP%" (
        if not exist "%EXTRACT_DIR%" mkdir "%EXTRACT_DIR%"
        powershell -NoProfile -Command "try { Expand-Archive -Path '%ZIP%' -DestinationPath '%EXTRACT_DIR%' -Force -ErrorAction Stop; exit 0 } catch { exit 1 }" >> "%LOG%" 2>&1
        if not errorlevel 1 (
            for /f "delims=" %%f in ('dir /b /s "%EXTRACT_DIR%\handle.exe" 2^>nul') do (
                copy /Y "%%f" "%HANDLE_EXE%" >nul
            )
            if exist "%HANDLE_EXE%" (
                echo       下载成功
                call :log "handle.exe 下载成功"
                del /f /q "%ZIP%" 2>nul
                rmdir /s /q "%EXTRACT_DIR%" 2>nul
                exit /b 0
            )
        )
        del /f /q "%ZIP%" 2>nul
        rmdir /s /q "%EXTRACT_DIR%" 2>nul
    )
)
call :log "handle.exe 下载失败"
echo.
echo [失败] handle.exe 下载失败，请手动下载：
echo        %HANDLE_URL1%
echo        解压后放到 %INSTALL_DIR%\handle.exe，然后重新运行本脚本
echo.
pause
exit /b 1


:log
echo [%date% %time%] %~1 >> "%LOG%"
exit /b 0


:fail
call :log "安装失败，退出"
echo.
echo ================================================
echo  安装失败！
echo ================================================
echo.
echo  请查看日志文件定位问题：
echo    %LOG%
echo.
pause
exit /b 1
