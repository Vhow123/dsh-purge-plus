@echo off
rem Move resources\app.asar aside so Electron loads the patched resources\app tree.
rem Run this by double-clicking: the process must not be a child of the DSH host,
rem otherwise the host's Job Object kills it when the harness exits.
setlocal
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0swap-asar.ps1" %*
echo.
pause
