@echo off
rem Reads the list of finished random NPC quests from your save so the radar can hide their markers.
rem Run this while the game is running with your save loaded.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync_completed_quests.ps1"
echo.
pause
