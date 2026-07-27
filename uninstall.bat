@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions EnableDelayedExpansion

set "INSTALL_DIR=C:\Program Files\FileUnlocker"
set "LOG=%TEMP%\FileUnlocker_uninstall.log"
echo [%date% %time%] 锟斤拷锟斤拷 uninstall.bat > "%LOG%"

:: 锟斤拷锟斤拷员锟斤拷锟斤拷权
fltmc >nul 2>&1
if errorlevel 1 (
    echo [%date% %time%] 锟角癸拷锟斤拷员锟斤拷锟斤拷锟斤拷锟斤拷权 >> "%LOG%"
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >> "%LOG%" 2>&1
    exit /b
)
echo [%date% %time%] 锟斤拷锟角癸拷锟斤拷员 >> "%LOG%"

echo [FileUnlocker 卸锟斤拷] 锟斤拷始 > "%LOG%"

:: 确锟较ｏ拷VBScript 锟斤拷锟斤拷锟斤拷锟斤拷锟斤拷 powershell 转锟斤拷锟斤拷锟解）
set "VBS_TMP=%TEMP%\fu_ask_uninstall.vbs"
(
    echo result = MsgBox(WScript.Arguments(0^), vbYesNo + vbQuestion, WScript.Arguments(1^)^)
    echo If result = vbYes Then
    echo     WScript.Quit 0
    echo Else
    echo     WScript.Quit 1
    echo End If
) > "%VBS_TMP%"
cscript //NoLogo "%VBS_TMP%" "确锟斤拷要卸锟斤拷 FileUnlocker 锟斤拷删锟斤拷锟揭硷拷锟剿碉拷锟斤拷" "卸锟斤拷确锟斤拷"
if errorlevel 1 (
    del /f /q "%VBS_TMP%" 2>nul
    echo 锟斤拷取锟斤拷卸锟截★拷
    pause
    exit /b 0
)
del /f /q "%VBS_TMP%" 2>nul

:: 删注锟斤拷锟�?
echo 锟斤拷锟斤拷注锟斤拷锟斤拷锟�?
for %%S in (* AllFilesystemObjects Directory) do (
    reg delete "HKLM\Software\Classes\%%S\shell\FileUnlocker" /f >nul 2>&1
    echo   锟斤拷删锟斤拷 %%S
)
reg delete "HKCU\Software\Classes\*\shell\FileUnlocker" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Directory\shell\FileUnlocker" /f >nul 2>&1

:: 注锟斤拷锟狡伙拷锟斤拷锟斤拷
schtasks /Delete /TN "WinDiag_Unlock_SYSTEM" /F >nul 2>&1

:: 删目录
echo 删锟斤拷锟斤拷装目录 %INSTALL_DIR%
if exist "%INSTALL_DIR%" rmdir /s /q "%INSTALL_DIR%"

:: 锟斤拷锟斤拷锟斤拷源锟斤拷锟斤拷锟斤拷
echo 锟斤拷锟斤拷锟斤拷源锟斤拷锟斤拷锟斤拷锟斤拷刷锟斤拷锟揭硷拷锟剿碉拷
taskkill /IM explorer.exe /F >nul 2>&1
start "" explorer.exe

echo 卸锟斤拷锟斤拷伞锟�?
pause
exit /b 0
