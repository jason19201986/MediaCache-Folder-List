@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>&1
if not errorlevel 1 (
    py -3 "%~dp0ZoomPlayer_MediaCache_Builder_Offline_TV_Episodes.py"
) else (
    python "%~dp0ZoomPlayer_MediaCache_Builder_Offline_TV_Episodes.py"
)
if errorlevel 1 pause
endlocal
