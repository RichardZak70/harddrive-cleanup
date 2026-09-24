@echo off
setlocal
REM ============================================================
REM  System drive cleanup - launcher
REM
REM  Double-click to run. It runs unattended, asks once for
REM  administrator rights (UAC), and shows a live progress board
REM  with a percentage per task and a heartbeat line.
REM
REM  Keep cleanup_c_drive_portable.ps1 in the same folder as this
REM  file; copy both together to another PC.
REM
REM  Optional switches:
REM    -DryRun      report what would be freed; delete nothing
REM    -NoElevate   per-user caches only; no UAC prompt
REM    -NoWait      close as soon as the run ends
REM
REM  Every rule about what it may touch is written at the top of
REM  the .ps1 file.
REM ============================================================

title System drive cleanup

set "PS1=%~dp0cleanup_c_drive_portable.ps1"
if not exist "%PS1%" (
    echo.
    echo cleanup_c_drive_portable.ps1 was not found next to this file.
    echo Copy both files into the same folder and run this again.
    echo Nothing was changed.
    echo.
    timeout /t 60
    exit /b 1
)

REM A 32-bit caller would start 32-bit PowerShell; Sysnative reaches
REM the 64-bit one, which DISM needs.
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

REM Exit code 1 means PowerShell could not start the script at all
REM (for example a company policy blocks scripts). Keep the message
REM on screen. The script itself returns 0, or 3 after its own wait.
if "%RC%"=="1" (
    echo.
    echo PowerShell could not run the cleanup script - see the message above.
    echo Nothing was changed.
    timeout /t 60
)
endlocal & exit /b %RC%
