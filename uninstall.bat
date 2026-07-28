@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "INSTALL_DIR=C:\Program Files\FileUnlocker"
set "LOG=%TEMP%\FileUnlocker_uninstall.log"
echo [%date% %time%] 卸载开始 > "%LOG%"

:: 管理员自提权
fltmc >nul 2>&1
if errorlevel 1 (
    echo [%date% %time%] 非管理员，请求提权 >> "%LOG%"
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >> "%LOG%" 2>&1
    echo [%date% %time%] 已启动提权进程，退出原进程 >> "%LOG%"
    exit /b
)
echo [%date% %time%] 已是管理员 >> "%LOG%"

call :ask "确定卸载 FileUnlocker？这将移除右键菜单并删除 %INSTALL_DIR%" "卸载确认"
if errorlevel 1 (
    echo [取消] 用户取消卸载
    goto :end_cancel
)

echo [1/3] 移除右键菜单注册表项
for %%S in (* AllFilesystemObjects Directory) do (
    reg delete "HKLM\Software\Classes\%%S\shell\FileUnlocker" /f >nul 2>&1
    echo   已移除 %%S
)
reg delete "HKCU\Software\Classes\*\shell\FileUnlocker" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Directory\shell\FileUnlocker" /f >nul 2>&1

echo [2/3] 注销计划任务
powershell -NoProfile -Command "Unregister-ScheduledTask -TaskName 'WinDiag_Unlock_SYSTEM' -Confirm:$false -ErrorAction SilentlyContinue" >> "%LOG%" 2>&1

echo [3/3] 删除安装目录
if exist "%INSTALL_DIR%" (
    rmdir /s /q "%INSTALL_DIR%" 2>nul
    if exist "%INSTALL_DIR%" (
        echo [警告] 无法完全删除 %INSTALL_DIR%，请关闭相关文件后重试
    ) else (
        echo   已删除 %INSTALL_DIR%
    )
)

echo 正在重启资源管理器以刷新右键菜单...
taskkill /IM explorer.exe /F >nul 2>&1
start "" explorer.exe
echo.
echo FileUnlocker 已卸载。日志: %LOG%
pause
exit /b 0

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

:end_cancel
echo 已取消卸载
pause
exit /b 0
