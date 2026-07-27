@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions EnableDelayedExpansion

:: 全锟斤拷锟斤拷志锟斤拷锟斤拷使锟斤拷锟斤拷也锟斤拷锟阶ｏ拷
set "LOG=%TEMP%\FileUnlocker_install.log"
echo [%date% %time%] 锟斤拷锟斤拷 install.bat > "%LOG%"
echo [%date% %time%] 锟斤拷前目录: %CD% >> "%LOG%"
echo [%date% %time%] 锟脚憋拷路锟斤拷: %~f0 >> "%LOG%"

:: ============ 锟斤拷锟斤拷员锟斤拷锟斤拷权 ============
fltmc >nul 2>&1
if errorlevel 1 (
    echo [%date% %time%] 锟角癸拷锟斤拷员锟斤拷锟斤拷锟斤拷锟斤拷权 >> "%LOG%"
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >> "%LOG%" 2>&1
    echo [%date% %time%] 锟窖凤拷锟斤拷锟斤拷权锟斤拷锟剿筹拷原锟斤拷锟斤拷 >> "%LOG%"
    exit /b
)
echo [%date% %time%] 锟斤拷锟角癸拷锟斤拷员 >> "%LOG%"

:: ============ 锟斤拷锟斤拷 ============
set "INSTALL_DIR=C:\Program Files\FileUnlocker"
set "REPO_URL=https://github.com/ksyangshu/FileUnlocker"
set "PWSH_URL=https://github.com/PowerShell/PowerShell/releases/download/v7.5.0/PowerShell-7.5.0-win-x64.msi"
set "HANDLE_URL1=https://download.sysinternals.com/files/Handle.zip"
set "HANDLE_URL2=https://mirror.ghproxy.com/https://download.sysinternals.com/files/Handle.zip"

echo [FileUnlocker 锟斤拷装] 锟斤拷始 > "%LOG%"

:: ============ 锟斤拷锟� PowerShell 7 ============
set "PWSH_EXE="
for %%P in ("%ProgramFiles%\PowerShell\7\pwsh.exe" "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe") do (
    if exist %%~P set "PWSH_EXE=%%~P"
)
where pwsh.exe >nul 2>&1
if not errorlevel 1 (
    for /f "delims=" %%i in ('where pwsh.exe') do set "PWSH_EXE=%%i"
)

if not defined PWSH_EXE (
    echo [锟斤拷锟絔 未锟斤拷锟斤拷 PowerShell 7 >> "%LOG%"
    call :ask "未锟斤拷獾� PowerShell 7 (pwsh.exe)锟斤拷锟斤拷锟角憋拷锟斤拷锟竭的憋拷锟斤拷锟斤拷锟斤拷锟斤拷`n锟角凤拷锟斤拷锟斤拷锟斤拷锟截诧拷锟斤拷装锟斤拷`n(取锟斤拷锟斤拷锟剿筹拷锟斤拷装)" "锟斤拷装确锟斤拷"
    if errorlevel 1 (
        echo [取锟斤拷] 锟矫伙拷锟杰撅拷锟斤拷装 PowerShell 7锟斤拷锟剿筹拷锟斤拷
        goto :end_cancel
    )
    call :install_pwsh
    if errorlevel 1 goto :end_fail
    :: 锟斤拷锟铰讹拷位
    for %%P in ("%ProgramFiles%\PowerShell\7\pwsh.exe") do set "PWSH_EXE=%%~P"
    if not exist "!PWSH_EXE!" (
        for /f "delims=" %%i in ('where pwsh.exe 2^>nul') do set "PWSH_EXE=%%i"
    )
)
echo [锟斤拷锟絔 使锟斤拷 PowerShell: %PWSH_EXE% >> "%LOG%"

:: ============ 目录锟窖达拷锟斤拷锟斤拷询锟斤拷 ============
if exist "%INSTALL_DIR%" (
    call :ask "锟斤拷獾斤拷锟阶澳柯硷拷汛锟斤拷冢锟絗n%INSTALL_DIR%`n锟角否覆盖诧拷锟斤拷锟斤拷锟斤拷装锟斤拷" "锟斤拷装确锟斤拷"
    if errorlevel 1 (
        echo [取锟斤拷] 锟矫伙拷取锟斤拷锟斤拷锟角★拷
        goto :end_cancel
    )
)

:: ============ 锟斤拷锟斤拷锟侥硷拷 ============
echo [1/4] 锟斤拷锟斤拷锟侥硷拷锟斤拷 %INSTALL_DIR%
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
xcopy "%~dp0src\*" "%INSTALL_DIR%\" /E /Y /Q >> "%LOG%" 2>&1
set "VBS=%INSTALL_DIR%\FileUnlocker_Run.vbs"
set "HANDLE_EXE=%INSTALL_DIR%\handle.exe"

:: ============ handle.exe ============
echo [2/4] 准锟斤拷 handle.exe
set "HANDLE_OK=0"
if exist "%HANDLE_EXE%" (
    set "HANDLE_OK=1"
)
if "%HANDLE_OK%"=="0" (
    call :download_handle
    if errorlevel 1 goto :end_fail
)

:: ============ 注锟斤拷锟� ============
echo [3/4] 注锟斤拷锟揭硷拷锟剿碉拷
set "CMD=wscript.exe \"%VBS%\" \"%%1\""
for %%S in (* AllFilesystemObjects Directory) do (
    set "KEY=HKLM\Software\Classes\%%S\shell\FileUnlocker"
    reg add "!KEY!" /ve /t REG_SZ /d "锟斤拷锟斤拷募锟秸硷拷锟�" /f >nul 2>&1
    reg add "!KEY!" /v Icon /t REG_SZ /d "shell32.dll,131" /f >nul 2>&1
    reg add "!KEY!\command" /ve /t REG_SZ /d "%CMD%" /f >nul 2>&1
    echo   锟斤拷注锟斤拷 %%S
)
:: 锟斤拷锟斤拷锟斤拷 HKCU 锟斤拷锟斤拷
reg delete "HKCU\Software\Classes\*\shell\FileUnlocker" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Directory\shell\FileUnlocker" /f >nul 2>&1

:: ============ 锟斤拷锟� ============
echo [4/4] 锟斤拷锟�
echo 锟斤拷锟斤拷锟斤拷源锟斤拷锟斤拷锟斤拷使锟揭硷拷锟剿碉拷锟斤拷锟斤拷锟斤拷效...
taskkill /IM explorer.exe /F >nul 2>&1
start "" explorer.exe
echo.
echo ========== 锟斤拷锟斤拷锟斤拷锟斤拷 ==========
echo 锟斤拷锟斤拷锟斤拷锟斤拷强锟斤拷锟斤拷止锟斤拷锟教凤拷式锟斤拷锟斤拷募锟�/锟侥硷拷锟斤拷占锟矫ｏ拷锟斤拷锟杰碉拷锟斤拷未锟斤拷锟斤拷锟斤拷锟捷讹拷失锟斤拷锟斤拷锟斤拷斐ｏ拷顺锟斤拷锟�
echo 使锟斤拷锟斤拷锟斤拷锟斤拷锟叫承碉拷锟缴此诧拷锟斤拷锟斤拷锟轿何猴拷锟斤拷锟斤拷锟斤拷卟锟斤拷械锟斤拷魏锟街憋拷踊锟斤拷锟斤拷锟斤拷巍锟�
echo 锟斤拷锟斤拷锟斤拷锟斤拷锟斤拷止系统锟截硷拷锟斤拷锟教ｏ拷lsass锟斤拷svchost 锟饺ｏ拷锟斤拷锟斤拷锟斤拷锟斤拷锟斤拷锟矫憋拷锟斤拷锟斤拷锟斤拷锟斤拷锟斤拷锟斤拷艿锟斤拷锟较低筹拷锟斤拷榷锟斤拷锟�
echo handle.exe 锟斤拷 Sysinternals(微锟斤拷) 锟结供锟斤拷锟斤拷锟斤拷锟竭斤拷锟斤拷使锟斤拷时锟斤拷锟斤拷俜锟皆达拷锟斤拷兀锟斤拷挚獠伙拷锟斤拷锟矫讹拷锟斤拷锟狡★拷
echo ==============================
echo.
echo 锟斤拷锟斤拷锟揭硷拷锟斤拷锟斤拷募锟斤拷锟斤拷募锟斤拷屑锟斤拷煽锟斤拷锟斤拷锟斤拷锟斤拷锟侥硷拷占锟矫★拷锟斤拷
echo 锟斤拷装锟斤拷志: %LOG%
pause
exit /b 0

:: ============ 锟斤拷锟斤拷 ============
:ask
:: %1=锟斤拷息 %2=锟斤拷锟斤拷  锟斤拷锟斤拷 errorlevel 1=锟斤拷/取锟斤拷 0=锟斤拷
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
echo [锟斤拷锟斤拷] PowerShell 7 ...
set "MSI=%TEMP%\PowerShell-7.msi"
curl -L --max-time 120 -o "%MSI%" "%PWSH_URL%" 2>>"%LOG%"
if not exist "%MSI%" (
    echo [失锟斤拷] PowerShell 7 锟斤拷锟斤拷失锟杰ｏ拷锟斤拷锟今不可达）锟斤拷锟斤拷锟街讹拷锟斤拷装锟斤拷锟斤拷锟皆★拷
    echo 锟劫凤拷: https://github.com/PowerShell/PowerShell/releases
    pause
    exit /b 1
)
echo [锟斤拷装] 锟斤拷默锟斤拷装 PowerShell 7 ...
msiexec /i "%MSI%" /quiet /norestart >> "%LOG%" 2>&1
del /f /q "%MSI%" 2>nul
exit /b 0

:download_handle
set "ZIP=%TEMP%\Handle.zip"
for %%U in ("%HANDLE_URL1%" "%HANDLE_URL2%") do (
    echo   锟斤拷锟斤拷: %%U
    curl -L --max-time 90 -o "%ZIP%" "%%U" 2>>"%LOG%"
    if exist "%ZIP%" (
        powershell -NoProfile -Command "Expand-Archive -Path '%ZIP%' -DestinationPath '%TEMP%\handle_tmp' -Force" >> "%LOG%" 2>&1
        for /f "delims=" %%f in ('dir /b /s "%TEMP%\handle_tmp\handle.exe" 2^>nul') do (
            copy /Y "%%f" "%HANDLE_EXE%" >nul 2>&1
        )
        del /f /q "%ZIP%" 2>nul
        rmdir /s /q "%TEMP%\handle_tmp" 2>nul
        if exist "%HANDLE_EXE%" (
            echo   锟斤拷锟�
            exit /b 0
        )
    )
)
echo [失锟斤拷] handle.exe 锟斤拷锟斤拷失锟杰ｏ拷锟斤拷锟街讹拷锟斤拷锟截放碉拷 %HANDLE_EXE%
pause
exit /b 1

:end_cancel
echo 锟斤拷装锟斤拷取锟斤拷锟斤拷
pause
exit /b 0

:end_fail
echo 锟斤拷装失锟杰ｏ拷锟斤拷锟斤拷锟街� %LOG%
pause
exit /b 1
