@echo off
chcp 65001 >nul
cd /d "%~dp0flutter_app"
if not exist "build\windows\x64\runner\Release\ieum_flutter.exe" (
  echo 먼저 Flutter Release 빌드를 실행해 주세요.
  pause
  exit /b 1
)
start "이음 Flutter" "build\windows\x64\runner\Release\ieum_flutter.exe"
