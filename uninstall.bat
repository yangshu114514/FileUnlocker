@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "INSTALL_DIR=C:\Program Files\FileUnlocker"
set "LOG=%TEMP%\FileUnlocker_uninstall.log"
echo [%date% %time%] uninstall.bat started > "%LOG%"

:: Admin self-elevation
fltmc >nul 2>&1
if errorlevel 1 (
    echo [%date% %time%] not admin, requesting elevation >> "%LOG%"
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >> "%LOG%" 2>&1
    echo [%date% %time%] elevated process launched, exiting original >> "%LOG%"
    exit /b
)
echo [%date% %time%] running as admin >> "%LOG%"

call :ask "Uninstall FileUnlocker? This removes the context menu and deletes %INSTALL_DIR%" "Uninstall Confirm"
if errorlevel 1 (
    echo [CANCEL] user cancelled uninstall
    goto :end_cancel
)

echo [1/3] remove context menu registry keys
for %%S in (* AllFilesystemObjects Directory) do (
    reg delete "HKLM\Software\Classes\%%S\shell\FileUnlocker" /f >nul 2>&1
    echo   removed %%S
)
reg delete "HKCU\Software\Classes\*\shell\FileUnlocker" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Directory\shell\FileUnlocker" /f >nul 2>&1

echo [2/3] unregister scheduled task
powershell -NoProfile -Command "Unregister-ScheduledTask -TaskName 'WinDiag_Unlock_SYSTEM' -Confirm:$false -ErrorAction SilentlyContinue" >> "%LOG%" 2>&1

echo [3/3] delete install directory
if exist "%INSTALL_DIR%" (
    rmdir /s /q "%INSTALL_DIR%" 2>nul
    if exist "%INSTALL_DIR%" (
        echo [WARN] could not fully delete %INSTALL_DIR%, close files and retry
    ) else (
        echo   deleted %INSTALL_DIR%
    )
)

echo restarting explorer to refresh context menu...
taskkill /IM explorer.exe /F >nul 2>&1
start "" explorer.exe
echo.
echo FileUnlocker uninstalled. Log: %LOG%
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
echo Uninstall cancelled
pause
exit /b 0
