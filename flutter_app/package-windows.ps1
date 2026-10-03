param([string]$BuildId = (Get-Date -Format 'yyyyMMdd-HHmmss'))
$ErrorActionPreference = 'Stop'
if ($BuildId -notmatch '^[0-9]{8}-[0-9]{6}$') { throw '잘못된 빌드 ID입니다.' }
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskVersion = ([regex]::Match([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'pubspec.yaml')),'(?m)^version: ([0-9]+\.[0-9]+\.[0-9]+)\r?$')).Groups[1].Value
if (-not $taskVersion -or [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib\app_release.dart')) -notmatch ([regex]::Escape("const appVersion = '$taskVersion';"))) { throw '앱/배포 버전이 일치하지 않습니다.' }
$taskRelease = Join-Path $PSScriptRoot 'build\windows\x64\runner\Release'
$taskStage = Join-Path $taskRoot ".local\packages\$BuildId"
$taskOutput = Join-Path $taskRoot "dist\windows\$BuildId"
$taskPayload = Join-Path $taskStage 'payload'
if (-not (Test-Path -LiteralPath (Join-Path $taskRelease 'ieum_flutter.exe'))) { throw '먼저 Windows Release를 빌드하세요.' }
New-Item -ItemType Directory -Path $taskPayload,$taskOutput | Out-Null
Copy-Item -Path "$taskRelease\*" -Destination $taskPayload -Recurse
# Vendor redistributables stay beside the executable; no machine-wide install.
$taskVswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$taskVs = & $taskVswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | ConvertFrom-Json
$taskRedist = Get-ChildItem -LiteralPath (Join-Path $taskVs.installationPath 'VC\Redist\MSVC') -Directory |
    Where-Object Name -Match '^\d+\.' | Sort-Object Name -Descending | Select-Object -First 1
foreach ($taskDll in @('msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll')) {
    $taskSource = Get-ChildItem -LiteralPath (Join-Path $taskRedist.FullName 'x64') -Recurse -Filter $taskDll | Select-Object -First 1
    if (-not $taskSource) { throw "런타임을 찾을 수 없습니다: $taskDll" }
    Copy-Item -LiteralPath $taskSource.FullName -Destination $taskPayload
}
$taskFiles = Get-ChildItem -LiteralPath $taskPayload -Recurse -File
if ($taskFiles | Where-Object { $_.Name -match '\.(sqlite|db)(-wal|-shm)?$|project-preferences|demo-snapshot' }) {
    throw '개인 DB, 설정 또는 테스트 예시가 배포본에 포함되어 있습니다.'
}
Compress-Archive -Path "$taskPayload\*" -DestinationPath (Join-Path $taskStage 'payload.zip') -CompressionLevel Optimal
Copy-Item -LiteralPath (Join-Path $taskStage 'payload.zip') -Destination (Join-Path $taskOutput 'Ieum-Windows-x64.zip')
$taskExe = Join-Path $taskOutput 'Ieum-Windows-x64.exe'
$taskLauncherTemplate = Join-Path $PSScriptRoot 'windows\distribution\portable_launcher.cs'
$taskLauncher = Join-Path $taskStage 'portable_launcher.cs'
[IO.File]::WriteAllText($taskLauncher,[IO.File]::ReadAllText($taskLauncherTemplate).Replace('__BUILD_ID__',$BuildId).Replace('__APP_VERSION__',$taskVersion),(New-Object Text.UTF8Encoding($true)))
$taskFramework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$taskCompiler = Join-Path $taskFramework 'csc.exe'
$taskCompilerArgs = @('/nologo','/target:winexe','/platform:x64','/optimize+',('/out:'+$taskExe),('/resource:'+(Join-Path $taskStage 'payload.zip')+',Ieum.Payload.zip'),('/win32icon:'+(Join-Path $PSScriptRoot 'windows\runner\resources\app_icon.ico')),('/reference:'+(Join-Path $taskFramework 'System.IO.Compression.dll')),('/reference:'+(Join-Path $taskFramework 'System.IO.Compression.FileSystem.dll')),('/reference:'+(Join-Path $taskFramework 'System.Windows.Forms.dll')),('/reference:'+(Join-Path $taskFramework 'System.Runtime.Serialization.dll')),$taskLauncher)
& $taskCompiler @taskCompilerArgs
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $taskExe)) { throw 'EXE 패키징에 실패했습니다.' }
$taskInstructions = @"
이음 테스트 클라이언트 / Windows x64 / $BuildId

EXE 하나만 다른 PC로 복사해서 실행하세요.
앱 파일은 %LOCALAPPDATA%\Ieum\builds\$BuildId 에 풀립니다.
Flutter SDK와 개발 도구는 필요하지 않습니다.
ZIP 배포본을 사용할 때에는 전체 압축을 풀고 ieum_flutter.exe를 실행하세요.

첫 PC: GitHub 로그인 -> 프로젝트 생성 -> 팀 데이터 저장소 -> 개인 DB 폴더 선택.
다른 PC: 본인의 다른 GitHub 계정으로 로그인 -> 같은 저장소에 프로젝트 참여 -> 개인 DB 폴더 선택.
설정 → 일반에서 이름을 변경하면 이 컴퓨터에 연결된 모든 참여 프로젝트에 커밋합니다. 실패한 프로젝트는 다음에 열 때 재전송합니다.
설정 → 역할 · 권한에서 관리자 또는 역할 관리 권한을 받은 참여자가 역할을 생성·수정·삭제할 수 있습니다.
설정 → 참여자 관리에서 역할을 배정합니다. 역할 · 권한에서 검색, 권한 확인, 참여자 현황과 역할 삭제를 관리합니다.
PD·PM 같은 직무 역할은 자동 생성하지 않습니다. 역할 추가에서 직접 만드세요.
사용 중인 역할은 다른 역할로 재배정하면서 삭제할 수 있습니다. 권한이 줄어들면 진행 중인 작업과 PR의 인수인계를 먼저 확인합니다.
활성화·비활성화는 참여자 상태 관리 권한이 있는 관리자만 변경합니다. 비활성화되면 작업 수정·진행·업로드가 차단됩니다.
새로운 상태 관리 권한을 사용자 지정 역할에 사용하려면 팀원 모두 0.5.0 이상으로 업데이트하세요.
사용자 지정 역할을 사용하기 전에 팀원 모두 0.4.0 이상으로 업데이트하세요. 기존 기본 역할은 그대로 사용할 수 있습니다.
관리자가 먼저 참여자의 GitHub 계정을 저장소 협업자로 초대해야 합니다.
프로젝트를 만든 사람이 전체 관리 권한을 가진 관리자가 됩니다. 관리자와 참여자 관리 권한을 받은 사람이 가입을 승인하고 역할을 배정합니다.
관리자는 프로젝트 설정에서 소유권을 이전할 수 있습니다. 이전 전에 팀원을 0.3.0 이상으로 업데이트하세요. GitHub 저장소 자체의 소유권은 별도로 관리합니다.
작업을 저장하면 자동 커밋 -> 작업별 PR -> 검증 후 자동 통합 -> 개인 DB 가져오기를 진행합니다.
자동 통합은 앱 실행 중 동작하며, GitHub 연결에서 켜거나 끌 수 있습니다.
저장 직후 전송하고 약 10초마다 변경을 확인합니다. 전송 시 연결을 재사용하고 불필요한 조회를 줄였습니다. 통신 오류와 GitHub 요청 제한 때는 재시도 간격을 늘립니다.
왼쪽 위에서 여러 프로젝트를 전환하거나 생성·참여할 수 있습니다.
로그인 유지 시 마지막 프로젝트와 마지막 목록·칸반 화면을 자동으로 엽니다.
검토 중 내용은 잠기며 완료 작업은 수정할 수 없습니다. 담당 작업·검토 요청은 앱 알림함에서 확인합니다.
같은 작업의 오래된 변경, 권한 밖의 변경, 충돌과 보호 브랜치는 보류 사유를 표시합니다.
작업 결과의 검토·재작업 결정과 참여자 가입 승인은 담당자가 처리합니다.
같은 GitHub 계정이면 두 PC에서도 같은 참여자로 취급합니다.
Git이 없는 PC도 GitHub로 로그인을 누르고 브라우저에서 앱의 인증 코드를 입력하면 됩니다. 로그인 유지를 켜면 Windows 자격 증명 관리자에 안전하게 보관합니다.
계정 토큰과 기존 프로젝트 DB, 작업 데이터는 배포본에 포함하지 않았습니다.
앱 버전: $taskVersion
앱 시작 시와 4시간마다 새 배포 버전을 자동 확인하고 검증하여 다운로드합니다.
다운로드가 끝나면 다음 실행 시 적용하거나 설정 → 일반 → 앱 정보의 업데이트 후 재시작을 누르세요.
실행 실패한 배포본은 반복 적용하지 않으며 가능한 이전 버전으로 복구합니다.
EXE 실행 시 설치 파일의 손상을 확인하고 손상된 폴더를 보존한 뒤 다시 압축을 풉니다.
공개 배포 저장소의 릴리즈를 사용하므로 프로젝트 초대 없이 자동 업데이트를 받을 수 있습니다.
개발자는 GitHub Releases에 태그 v$taskVersion 와 Ieum-Windows-x64.exe 파일을 배포합니다.
"@
[IO.File]::WriteAllText((Join-Path $taskOutput '사용안내.txt'),$taskInstructions,(New-Object Text.UTF8Encoding($true)))
Get-FileHash -LiteralPath $taskExe -Algorithm SHA256 | Format-List
Get-Item -LiteralPath $taskExe | Select-Object FullName,Length
