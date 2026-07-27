@echo off
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

set "INSTALL_DIR=C:\Program Files\FileUnlocker"
set "LOG=%TEMP%\FileUnlocker_uninstall.log"

:: 管理员自提权
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

echo [FileUnlocker 卸载] 开始 > "%LOG%"

:: 确认（VBScript 弹窗，避免 powershell 转义问题）
set "VBS_TMP=%TEMP%\fu_ask_uninstall.vbs"
(
    echo MsgBox WScript.Arguments(0), vbYesNo + vbQuestion, WScript.Arguments(1)
    echo If vbYes = MsgBox(WScript.Arguments(0), vbYesNo + vbQuestion, WScript.Arguments(1) Then
    echo     WScript.Quit 0
    echo Else
    echo     WScript.Quit 1
    echo End If
) > "%VBS_TMP%"
cscript //NoLogo "%VBS_TMP%" "确定要卸载 FileUnlocker 并删除右键菜单吗？" "卸载确认"
if errorlevel 1 (
    del /f /q "%VBS_TMP%" 2>nul
    echo 已取消卸载。
    pause
    exit /b 0
)
del /f /q "%VBS_TMP%" 2>nul

:: 删注册表
echo 清理注册表项
for %%S in (* AllFilesystemObjects Directory) do (
    reg delete "HKLM\Software\Classes\%%S\shell\FileUnlocker" /f >nul 2>&1
    echo   已删除 %%S
)
reg delete "HKCU\Software\Classes\*\shell\FileUnlocker" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Directory\shell\FileUnlocker" /f >nul 2>&1

:: 注销计划任务
schtasks /Delete /TN "WinDiag_Unlock_SYSTEM" /F >nul 2>&1

:: 删目录
echo 删除安装目录 %INSTALL_DIR%
if exist "%INSTALL_DIR%" rmdir /s /q "%INSTALL_DIR%"

:: 重启资源管理器
echo 重启资源管理器以刷新右键菜单
taskkill /IM explorer.exe /F >nul 2>&1
start "" explorer.exe

echo 卸载完成。
pause
exit /b 0
