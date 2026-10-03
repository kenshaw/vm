@echo off
rem ---------------------------------------------------------------------------
rem dockur/windows copies this whole folder to C:\OEM and runs install.bat at
rem the final step of the unattended install. That stage runs as SYSTEM, where
rem winget does not exist -- it is a per-user MSIX package. So do the machine
rem level work now, and queue the winget half for the first interactive logon.
rem ---------------------------------------------------------------------------

set SCRIPT=%~dp0setup-dev.ps1

echo [OEM] running setup-dev.ps1 (activation, updates, ssh, browser)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -SkipWinget

echo [OEM] queueing the winget phase for first logon
copy /y "%SCRIPT%" "%SystemDrive%\OEM\setup-dev.ps1" >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" ^
  /v setup-dev /t REG_SZ /f ^
  /d "powershell -NoProfile -ExecutionPolicy Bypass -File \"%SystemDrive%\OEM\setup-dev.ps1\" -SkipUpdates"

echo [OEM] done
exit /b 0
