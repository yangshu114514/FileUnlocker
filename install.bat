@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: All log output (safe for any codepage)
set "LOG=%TEMP%\FileUnlocker_install.log"
echo [%date% %time%] install.bat started > "%LOG%"
echo [%date% %time%] current dir: %CD% >> "%LOG%"
echo [%date% %time%] script path: %~f0 >> "%LOG%"

:: ============ Admin self-elevation ============
fltmc >nul 2>&1
if errorlevel 1 (
    echo [%date% %time%] not admin, requesting elevation >> "%LOG%"
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >> "%LOG%" 2>&1
    echo [%date% %time%] elevated process launched, exiting original >> "%LOG%"
    exit /b
)
echo [%date% %time%] running as admin >> "%LOG%"

:: ============ Config ============
set "INSTALL_DIR=C:\Program Files\FileUnlocker"
set "REPO_URL=https://github.com/ksyangshu/FileUnlocker"
set "PWSH_URL=https://github.com/PowerShell/PowerShell/releases/download/v7.5.0/PowerShell-7.5.0-win-x64.msi"
set "HANDLE_URL1=https://download.sysinternals.com/files/Handle.zip"
set "HANDLE_URL2=https://mirror.ghproxy.com/https://download.sysinternals.com/files/Handle.zip"

echo [FileUnlocker Install] start > "%LOG%"

:: ============ Detect PowerShell 7 ============
set "PWSH_EXE="
for %%P in ("%ProgramFiles%\PowerShell\7\pwsh.exe" "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe") do (
    if exist %%~P set "PWSH_EXE=%%~P"
)
where pwsh.exe >nul 2>&1
if not errorlevel 1 (
    for /f "delims=" %%i in ('where pwsh.exe') do set "PWSH_EXE=%%i"
)

if not defined PWSH_EXE (
    echo [WARN] PowerShell 7 not found >> "%LOG%"
    call :ask "PowerShell 7 (pwsh.exe) is required by this tool. Install it now? (Cancel aborts install)" "Install Confirm"
    if errorlevel 1 (
        echo [CANCEL] user refused PowerShell 7, exit
        goto :end_cancel
    )
    call :install_pwsh
    if errorlevel 1 goto :end_fail
    for %%P in ("%ProgramFiles%\PowerShell\7\pwsh.exe") do set "PWSH_EXE=%%~P"
    if not exist "!PWSH_EXE!" (
        for /f "delims=" %%i in ('where pwsh.exe 2^>nul') do set "PWSH_EXE=%%i"
    )
)
echo [OK] using PowerShell: %PWSH_EXE% >> "%LOG%"

:: ============ Existing dir prompt ============
if exist "%INSTALL_DIR%" (
    call :ask "Install directory already exists: %INSTALL_DIR%. Overwrite and continue?" "Install Confirm"
    if errorlevel 1 (
        echo [CANCEL] user cancelled overwrite
        goto :end_cancel
    )
)

:: ============ Copy files ============
echo [1/4] deploy to %INSTALL_DIR%
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
xcopy "%~dp0src\*" "%INSTALL_DIR%\" /E /Y /Q >> "%LOG%" 2>&1
set "VBS=%INSTALL_DIR%\FileUnlocker_Run.vbs"
set "HANDLE_EXE=%INSTALL_DIR%\handle.exe"

:: ============ handle.exe ============
echo [2/4] prepare handle.exe
set "HANDLE_OK=0"
if exist "%HANDLE_EXE%" (
    set "HANDLE_OK=1"
)
if "%HANDLE_OK%"=="0" (
    call :download_handle
    if errorlevel 1 goto :end_fail
)

:: ============ Register context menu ============
echo [3/4] register right-click menu
set "CMD=wscript.exe \"%VBS%\" \"%%1\""
for %%S in (* AllFilesystemObjects Directory) do (
    set "KEY=HKLM\Software\Classes\%%S\shell\FileUnlocker"
    reg add "!KEY!" /ve /t REG_SZ /d "Unlock File Occupation" /f >nul 2>&1
    reg add "!KEY!" /v Icon /t REG_SZ /d "shell32.dll,131" /f >nul 2>&1
    reg add "!KEY!\command" /ve /t REG_SZ /d "%CMD%" /f >nul 2>&1
    echo   registered %%S
)
:: clean stale HKCU entries
reg delete "HKCU\Software\Classes\*\shell\FileUnlocker" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Directory\shell\FileUnlocker" /f >nul 2>&1

:: ============ Restart explorer ============
echo [4/4] restart explorer
echo Restarting explorer to apply context menu...
taskkill /IM explorer.exe /F >nul 2>&1
start "" explorer.exe
echo.
echo ========== DISCLAIMER ==========
echo This tool force-terminates processes holding file locks. Risk of unsaved data loss or abnormal program exit.
echo Use at your own risk. The author is not liable for any data loss or system issues caused by this tool.
echo Do NOT terminate system critical processes (lsass, svchost, etc.) - doing so may destabilize the system.
echo handle.exe is provided by Sysinternals (Microsoft). Free to use; download from official source.
echo ==============================
echo.
echo Right-click any file or folder to use "Unlock File Occupation".
echo Install log: %LOG%
pause
exit /b 0

:: ============ Functions ============
:ask
:: %1=message %2=title  returns errorlevel 1=No/Cancel 0=Yes
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
echo [INFO] PowerShell 7 ...
set "MSI=%TEMP%\PowerShell-7.msi"
curl -L --max-time 120 -o "%MSI%" "%PWSH_URL%" 2>>"%LOG%"
if not exist "%MSI%" (
    echo [FAIL] PowerShell 7 download failed (no network?). Install manually from:
    echo https://github.com/PowerShell/PowerShell/releases
    pause
    exit /b 1
)
echo [INSTALL] installing PowerShell 7 silently ...
msiexec /i "%MSI%" /quiet /norestart >> "%LOG%" 2>&1
del /f /q "%MSI%" 2>nul
exit /b 0

:download_handle
set "ZIP=%TEMP%\Handle.zip"
for %%U in ("%HANDLE_URL1%" "%HANDLE_URL2%") do (
    echo   trying: %%U
    curl -L --max-time 90 -o "%ZIP%" "%%U" 2>>"%LOG%"
    if exist "%ZIP%" (
        powershell -NoProfile -Command "Expand-Archive -Path '%ZIP%' -DestinationPath '%TEMP%\handle_tmp' -Force" >> "%LOG%" 2>&1
        for /f "delims=" %%f in ('dir /b /s "%TEMP%\handle_tmp\handle.exe" 2^>nul') do (
            copy /Y "%%f" "%HANDLE_EXE%" >nul 2>&1
        )
        del /f /q "%ZIP%" 2>nul
        rmdir /s /q "%TEMP%\handle_tmp" 2>nul
        if exist "%HANDLE_EXE%" (
            echo   downloaded
            exit /b 0
        )
    )
)
echo [FAIL] handle.exe download failed. Place it manually at %HANDLE_EXE%
pause
exit /b 1

:end_cancel
echo Install cancelled by user
pause
exit /b 0

:end_fail
echo Install failed. Check log: %LOG%
pause
exit /b 1
