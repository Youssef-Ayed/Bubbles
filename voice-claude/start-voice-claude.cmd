@echo off
start "" /min powershell.exe -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0voice-claude.ps1"
