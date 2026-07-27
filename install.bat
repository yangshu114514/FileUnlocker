@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: ȫ����־����ʹ����Ҳ���ף�
set "LOG=%TEMP%\FileUnlocker_install.log"
echo [%date% %time%] ���� install.bat > "%LOG%"
echo [%date% %time%] ��ǰĿ¼: %CD% >> "%LOG%"
echo [%date% %time%] �ű�·��: %~f0 >> "%LOG%"

:: ============ ����Ա����Ȩ ============
fltmc >nul 2>&1
if errorlevel 1 (
    echo [%date% %time%] �ǹ���Ա��������Ȩ >> "%LOG%"
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >> "%LOG%" 2>&1
    echo [%date% %time%] �ѷ�����Ȩ���˳�ԭ���� >> "%LOG%"
    exit /b
)
echo [%date% %time%] ���ǹ���Ա >> "%LOG%"

:: ============ ���� ============
set "INSTALL_DIR=C:\Program Files\FileUnlocker"
set "REPO_URL=https://github.com/ksyangshu/FileUnlocker"
set "PWSH_URL=https://github.com/PowerShell/PowerShell/releases/download/v7.5.0/PowerShell-7.5.0-win-x64.msi"
set "HANDLE_URL1=https://download.sysinternals.com/files/Handle.zip"
set "HANDLE_URL2=https://mirror.ghproxy.com/https://download.sysinternals.com/files/Handle.zip"

echo [FileUnlocker ��װ] ��ʼ > "%LOG%"

:: ============ ���? PowerShell 7 ============
set "PWSH_EXE="
for %%P in ("%ProgramFiles%\PowerShell\7\pwsh.exe" "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe") do (
    if exist %%~P set "PWSH_EXE=%%~P"
)
where pwsh.exe >nul 2>&1
if not errorlevel 1 (
    for /f "delims=" %%i in ('where pwsh.exe') do set "PWSH_EXE=%%i"
)

if not defined PWSH_EXE (
    echo [���] δ���� PowerShell 7 >> "%LOG%"
    call :ask "δ���? PowerShell 7 (pwsh.exe)�����Ǳ����ߵı���������`n�Ƿ��������ز���װ��`n(ȡ�����˳���װ)" "��װȷ��"
    if errorlevel 1 (
        echo [ȡ��] �û��ܾ���װ PowerShell 7���˳���
        goto :end_cancel
    )
    call :install_pwsh
    if errorlevel 1 goto :end_fail
    :: ���¶�λ
    for %%P in ("%ProgramFiles%\PowerShell\7\pwsh.exe") do set "PWSH_EXE=%%~P"
    if not exist "!PWSH_EXE!" (
        for /f "delims=" %%i in ('where pwsh.exe 2^>nul') do set "PWSH_EXE=%%i"
    )
)
echo [���] ʹ�� PowerShell: %PWSH_EXE% >> "%LOG%"

:: ============ Ŀ¼�Ѵ�����ѯ�� ============
if exist "%INSTALL_DIR%" (
    call :ask "��⵽��װĿ¼�Ѵ��ڣ�`n%INSTALL_DIR%`n�Ƿ񸲸ǲ�������װ��" "��װȷ��"
    if errorlevel 1 (
        echo [ȡ��] �û�ȡ�����ǡ�
        goto :end_cancel
    )
)

:: ============ �����ļ� ============
echo [1/4] �����ļ��� %INSTALL_DIR%
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
xcopy "%~dp0src\*" "%INSTALL_DIR%\" /E /Y /Q >> "%LOG%" 2>&1
set "VBS=%INSTALL_DIR%\FileUnlocker_Run.vbs"
set "HANDLE_EXE=%INSTALL_DIR%\handle.exe"

:: ============ handle.exe ============
echo [2/4] ׼�� handle.exe
set "HANDLE_OK=0"
if exist "%HANDLE_EXE%" (
    set "HANDLE_OK=1"
)
if "%HANDLE_OK%"=="0" (
    call :download_handle
    if errorlevel 1 goto :end_fail
)

:: ============ ע���? ============
echo [3/4] ע���Ҽ��˵�
set "CMD=wscript.exe \"%VBS%\" \"%%1\""
for %%S in (* AllFilesystemObjects Directory) do (
    set "KEY=HKLM\Software\Classes\%%S\shell\FileUnlocker"
    reg add "!KEY!" /ve /t REG_SZ /d "����ļ�ռ��?" /f >nul 2>&1
    reg add "!KEY!" /v Icon /t REG_SZ /d "shell32.dll,131" /f >nul 2>&1
    reg add "!KEY!\command" /ve /t REG_SZ /d "%CMD%" /f >nul 2>&1
    echo   ��ע�� %%S
)
:: ������ HKCU ����
reg delete "HKCU\Software\Classes\*\shell\FileUnlocker" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Directory\shell\FileUnlocker" /f >nul 2>&1

:: ============ ���? ============
echo [4/4] ���?
echo ������Դ������ʹ�Ҽ��˵�������Ч...
taskkill /IM explorer.exe /F >nul 2>&1
start "" explorer.exe
echo.
echo ========== �������� ==========
echo ��������ǿ����ֹ���̷�ʽ����ļ�?/�ļ���ռ�ã����ܵ���δ�������ݶ�ʧ������쳣�˳���?
echo ʹ���������ге��ɴ˲������κκ�������߲��е��κ�ֱ�ӻ������Ρ�?
echo ����������ֹϵͳ�ؼ����̣�lsass��svchost �ȣ������������ñ�������������ܵ���ϵͳ���ȶ���?
echo handle.exe �� Sysinternals(΢��) �ṩ�������߽���ʹ��ʱ����ٷ�Դ���أ��ֿⲻ����ö����ơ�
echo ==============================
echo.
echo �����Ҽ�����ļ����ļ��м��ɿ���������ļ�ռ�á���
echo ��װ��־: %LOG%
pause
exit /b 0

:: ============ ���� ============
:ask
:: %1=��Ϣ %2=����  ���� errorlevel 1=��/ȡ�� 0=��
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
echo [����] PowerShell 7 ...
set "MSI=%TEMP%\PowerShell-7.msi"
curl -L --max-time 120 -o "%MSI%" "%PWSH_URL%" 2>>"%LOG%"
if not exist "%MSI%" (
    echo [ʧ��] PowerShell 7 ����ʧ�ܣ����񲻿ɴ�����ֶ���װ�����ԡ�
    echo �ٷ�: https://github.com/PowerShell/PowerShell/releases
    pause
    exit /b 1
)
echo [��װ] ��Ĭ��װ PowerShell 7 ...
msiexec /i "%MSI%" /quiet /norestart >> "%LOG%" 2>&1
del /f /q "%MSI%" 2>nul
exit /b 0

:download_handle
set "ZIP=%TEMP%\Handle.zip"
for %%U in ("%HANDLE_URL1%" "%HANDLE_URL2%") do (
    echo   ����: %%U
    curl -L --max-time 90 -o "%ZIP%" "%%U" 2>>"%LOG%"
    if exist "%ZIP%" (
        powershell -NoProfile -Command "Expand-Archive -Path '%ZIP%' -DestinationPath '%TEMP%\handle_tmp' -Force" >> "%LOG%" 2>&1
        for /f "delims=" %%f in ('dir /b /s "%TEMP%\handle_tmp\handle.exe" 2^>nul') do (
            copy /Y "%%f" "%HANDLE_EXE%" >nul 2>&1
        )
        del /f /q "%ZIP%" 2>nul
        rmdir /s /q "%TEMP%\handle_tmp" 2>nul
        if exist "%HANDLE_EXE%" (
            echo   ���?
            exit /b 0
        )
    )
)
echo [ʧ��] handle.exe ����ʧ�ܣ����ֶ����طŵ� %HANDLE_EXE%
pause
exit /b 1

:end_cancel
echo ��װ��ȡ����
pause
exit /b 0

:end_fail
echo ��װʧ�ܣ�������? %LOG%
pause
exit /b 1
