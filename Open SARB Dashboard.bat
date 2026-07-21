@echo off
rem ============================================================
rem  Open SARB Dashboard -- opens the dashboard immediately, then
rem  refreshes local data in a minimised background window.
rem  The page live-refreshes from the SARB API on its own while
rem  the updater tops up the offline archive for next time.
rem ============================================================
cd /d "%~dp0"

start "" "SARB_Dashboard.html"
start /min "" powershell -NoProfile -ExecutionPolicy Bypass -File "Update-SARB-Data.ps1" -Quiet
