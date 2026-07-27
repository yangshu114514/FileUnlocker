@echo off
setlocal EnableExtensions

set "INSTALL_DIR=C:\Program Files\FileUnlocker"
set "LOG=%TEMP%\FileUnlocker_uninstall.log"
echo [%date% %time%] ���� uninstall.bat > "%LOG%"

:: ����Ա����Ȩ
fltmc >nul 2>&1
if errorlevel 1 (
    echo [%date% %time%] �ǹ���Ա��������Ȩ >> "%LOG%"
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >> "%LOG%" 2>&1
    exit /b
)
echo [%date% %time%] ���ǹ���Ա >> "%LOG%"

echo [FileUnlocker ж��] ��ʼ > "%LOG%"

:: ȷ�ϣ�VBScript ���������� powershell ת�����⣩
set "VBS_TMP=%TEMP%\fu_ask_uninstall.vbs"
(
    echo result = MsgBox(WScript.Arguments(0^), vbYesNo + vbQuestion, WScript.Arguments(1^)^)
    echo If result = vbYes Then
    echo     WScript.Quit 0
    echo Else
    echo     WScript.Quit 1
    echo End If
) > "%VBS_TMP%"
cscript //NoLogo "%VBS_TMP%" "ȷ��Ҫж�� FileUnlocker ��ɾ���Ҽ��˵���" "ж��ȷ��"
if errorlevel 1 (
    del /f /q "%VBS_TMP%" 2>nul
    echo ��ȡ��ж�ء�
    pause
    exit /b 0
)
del /f /q "%VBS_TMP%" 2>nul

:: ɾע���?
echo ����ע�����?
for %%S in (* AllFilesystemObjects Directory) do (
    reg delete "HKLM\Software\Classes\%%S\shell\FileUnlocker" /f >nul 2>&1
    echo   ��ɾ�� %%S
)
reg delete "HKCU\Software\Classes\*\shell\FileUnlocker" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Directory\shell\FileUnlocker" /f >nul 2>&1

:: ע���ƻ�����
schtasks /Delete /TN "WinDiag_Unlock_SYSTEM" /F >nul 2>&1

:: ɾĿ¼
echo ɾ����װĿ¼ %INSTALL_DIR%
if exist "%INSTALL_DIR%" rmdir /s /q "%INSTALL_DIR%"

:: ������Դ������
echo ������Դ��������ˢ���Ҽ��˵�
taskkill /IM explorer.exe /F >nul 2>&1
start "" explorer.exe

echo ж����ɡ�?
pause
exit /b 0
