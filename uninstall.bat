@echo off
chcp 936 >nul
setlocal EnableExtensions EnableDelayedExpansion

rem ===================================================
rem  FileUnlocker 卸载脚本
rem  功能：移除右键菜单、注销计划任务、删除安装目录
rem ===================================================

set "INSTALL_DIR=C:\Program Files\FileUnlocker"
set "LOG=%TEMP%\FileUnlocker_uninstall.log"

echo. > "%LOG%"
echo ================================================  >> "%LOG%"
echo  FileUnlocker 卸载日志                              >> "%LOG%"
echo  时间: %date% %time%                               >> "%LOG%"
echo ================================================  >> "%LOG%"

call :log "开始卸载 FileUnlocker"

rem ---------- 1. 检查管理员权限 ----------
fltmc >nul 2>&1
if errorlevel 1 (
    call :log "未检测到管理员权限，正在请求 UAC 提权..."
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >> "%LOG%" 2>&1
    exit /b 0
)
call :log "已确认管理员权限"

rem ---------- 2. 确认卸载 ----------
call :ask "确定要卸载 FileUnlocker 吗？`n`n将执行：`n  ^^^! 移除右键菜单`n  ^^^! 注销 SYSTEM 计划任务`n  ^^^! 删除 %INSTALL_DIR%" "卸载确认"
if errorlevel 1 (
    call :log "用户取消卸载"
    echo.
    echo [已取消] 未执行卸载
    pause
    exit /b 0
)

rem ---------- 3. 移除右键菜单 ----------
echo.
echo [1/4] 移除右键菜单
call :log "删除右键菜单注册表项"
for %%S in (AllFilesystemObjects Directory) do (
    reg delete "HKLM\Software\Classes\%%S\shell\FileUnlocker" /f >nul 2>&1
    echo       已移除 %%S
)
reg delete "HKLM\Software\Classes\*\shell\FileUnlocker" /f >nul 2>&1
echo       已移除 *
reg delete "HKCU\Software\Classes\*\shell\FileUnlocker" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Directory\shell\FileUnlocker" /f >nul 2>&1
call :log "右键菜单移除完成"

rem ---------- 4. 注销 SYSTEM 计划任务 ----------
echo [2/4] 注销 SYSTEM 计划任务
call :log "注销 WinDiag_Unlock_SYSTEM 计划任务"
powershell -NoProfile -Command "Unregister-ScheduledTask -TaskName 'WinDiag_Unlock_SYSTEM' -Confirm:$false -ErrorAction SilentlyContinue" >> "%LOG%" 2>&1
call :log "计划任务已清理"

rem ---------- 5. 删除安装目录 ----------
echo [3/4] 删除安装目录
call :log "删除 %INSTALL_DIR%"
if exist "%INSTALL_DIR%" (
    rmdir /s /q "%INSTALL_DIR%" 2>nul
    if exist "%INSTALL_DIR%" (
        call :log "警告：无法完全删除 %INSTALL_DIR%"
        echo       [警告] 无法完全删除安装目录（可能有文件被占用）
        echo              请手动删除：%INSTALL_DIR%
    ) else (
        echo       已删除 %INSTALL_DIR%
        call :log "安装目录已删除"
    )
) else (
    echo       目录不存在，跳过
    call :log "目录不存在，跳过"
)

rem ---------- 6. 重启资源管理器 ----------
echo [4/4] 重启资源管理器
call :log "重启 explorer.exe"
taskkill /IM explorer.exe /F >nul 2>&1
start "" explorer.exe
call :log "卸载完成"

rem ---------- 完成 ----------
echo.
echo ================================================
echo  卸载完成！
echo ================================================
echo.
echo  日志文件: %LOG%
echo.
pause
exit /b 0


rem ===================================================
rem  子函数
rem ===================================================

:ask
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


:log
echo [%date% %time%] %~1 >> "%LOG%"
exit /b 0
