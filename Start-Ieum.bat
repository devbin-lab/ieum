@echo off
chcp 65001 >nul
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo Node.js를 설치한 뒤 다시 실행해 주세요.
  pause
  exit /b 1
)
if not exist node_modules (
  call npm ci
  if errorlevel 1 exit /b 1
)
call npm run build
if errorlevel 1 (
  pause
  exit /b 1
)
set ELECTRON_RUN_AS_NODE=
call node node_modules/electron/install.js
if errorlevel 1 exit /b 1
start "이음" "node_modules\electron\dist\electron.exe" .
