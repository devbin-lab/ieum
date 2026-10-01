$ErrorActionPreference = 'Stop'
$taskProject = $PSScriptRoot
$taskFlutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
$taskFlutter = if ($taskFlutterCommand) { $taskFlutterCommand.Source } else { Join-Path $env:USERPROFILE 'develop\flutter\bin\flutter.bat' }
if (-not (Test-Path -LiteralPath $taskFlutter)) { throw 'Flutter SDK를 설치하거나 PATH에 추가해 주세요.' }
Push-Location -LiteralPath $taskProject
try {
    & $taskFlutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Flutter 의존성 준비에 실패했습니다.' }
    # Windows PowerShell 5 treats redirected native stderr as an error record.
    # Capture the exit code so the supported CMake fallback can still run.
    $taskSavedErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $taskOutput = & $taskFlutter build windows --release 2>&1
        $taskCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $taskSavedErrorPreference }
    $taskOutput | ForEach-Object { Write-Host $_ }
    if ($taskCode -eq 0) { exit 0 }
    if (($taskOutput -join "`n") -notmatch 'Unable to find suitable Visual Studio toolchain') { throw 'Flutter 빌드에 실패했습니다.' }
    # Existing game-development MSVC and a portable CMake can build the standard
    # Flutter runner without modifying Visual Studio workloads or the Flutter SDK.
    $taskVswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $taskVs = & $taskVswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | ConvertFrom-Json
    $taskCmake = Get-Command cmake -ErrorAction SilentlyContinue
    if (-not $taskVs -or -not $taskCmake) { throw 'MSVC C++ 도구와 CMake가 필요합니다.' }
    if (-not (Test-Path -LiteralPath 'windows\flutter\ephemeral\generated_config.cmake')) { throw 'Flutter의 Windows 생성 설정이 없습니다.' }
    $taskMajor = ([version]$taskVs.installationVersion).Major
    $taskGenerator = switch ($taskMajor) { 18 { 'Visual Studio 18 2026' } 17 { 'Visual Studio 17 2022' } 16 { 'Visual Studio 16 2019' } default { throw '지원하지 않는 Visual Studio 버전입니다.' } }
    & $taskCmake.Source -S windows -B build/windows/x64 -G $taskGenerator -A x64 '-DFLUTTER_TARGET_PLATFORM=windows-x64'
    if ($LASTEXITCODE -ne 0) { throw 'CMake 구성에 실패했습니다.' }
    & $taskCmake.Source --build build/windows/x64 --config Release --target INSTALL --parallel 4
    if ($LASTEXITCODE -ne 0) { throw 'Windows Release 빌드에 실패했습니다.' }
    if (-not (Test-Path -LiteralPath 'build\windows\x64\runner\Release\ieum_flutter.exe')) { throw '빌드 실행파일을 찾을 수 없습니다.' }
} finally { Pop-Location }
