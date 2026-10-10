param(
    [string]$BuildId = (Get-Date -Format 'yyyyMMdd-HHmmss'),
    [string]$ReleaseDirectory = 'build\windows\x64\runner\Release',
    [string]$InnoCompiler = ''
)
$ErrorActionPreference = 'Stop'
if ($BuildId -notmatch '^[0-9]{8}-[0-9]{6}$') { throw '잘못된 빌드 ID입니다.' }
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskVersion = ([regex]::Match([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'pubspec.yaml')),'(?m)^version: ([0-9]+\.[0-9]+\.[0-9]+)\r?$')).Groups[1].Value
if (-not $taskVersion -or [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib\app_release.dart')) -notmatch ([regex]::Escape("const appVersion = '$taskVersion';"))) { throw '앱/배포 버전이 일치하지 않습니다.' }
$taskRelease = if ([IO.Path]::IsPathRooted($ReleaseDirectory)) {
    [IO.Path]::GetFullPath($ReleaseDirectory)
} else {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $ReleaseDirectory))
}
$taskStage = Join-Path $taskRoot ".local\packages\$BuildId"
$taskOutput = Join-Path $taskRoot "dist\windows\$BuildId"
$taskPayload = Join-Path $taskStage 'payload'
$taskShortcutIcons = @(
    'googledrive.svg', 'notion.svg', 'jira.svg', 'discord.svg',
    'kakaotalk.svg', 'github.svg', 'figma.svg', 'slack.svg'
)
foreach ($taskRequired in @(
    'ieum_flutter.exe', 'flutter_windows.dll', 'sqlite3.dll',
    'file_selector_windows_plugin.dll', 'screen_retriever_windows_plugin.dll',
    'window_manager_plugin.dll', 'data\app.so', 'data\icudtl.dat',
    'data\flutter_assets\AssetManifest.bin',
    'data\flutter_assets\NativeAssetsManifest.json',
    'data\flutter_assets\assets\branding\app_icon.png',
    'data\flutter_assets\fonts\MaterialIcons-Regular.otf'
    foreach ($taskShortcutIcon in $taskShortcutIcons) {
        "data\flutter_assets\assets\shortcut-services\$taskShortcutIcon"
    }
)) {
    $taskRequiredPath = Join-Path $taskRelease $taskRequired
    if (-not (Test-Path -LiteralPath $taskRequiredPath -PathType Leaf) -or (Get-Item -LiteralPath $taskRequiredPath).Length -eq 0) {
        throw "배포 필수 파일이 없거나 비어 있습니다. Windows Release를 다시 빌드하세요: $taskRequired"
    }
}
$taskShortcutLicenseSource = Join-Path $PSScriptRoot 'third_party\simple-icons'
$taskShortcutLicenseFiles = @('LICENSE.md', 'DISCLAIMER.md', 'NOTICE.md', 'icon-metadata.json')
foreach ($taskShortcutLicenseFile in $taskShortcutLicenseFiles) {
    $taskShortcutLicensePath = Join-Path $taskShortcutLicenseSource $taskShortcutLicenseFile
    if (-not (Test-Path -LiteralPath $taskShortcutLicensePath -PathType Leaf) -or (Get-Item -LiteralPath $taskShortcutLicensePath).Length -eq 0) {
        throw "바로가기 아이콘의 배포 고지가 없거나 비어 있습니다: $taskShortcutLicenseFile"
    }
}
$taskBinaryVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $taskRelease 'ieum_flutter.exe')).ProductVersion
if ($taskBinaryVersion -ne $taskVersion) {
    throw "빌드된 실행 파일 버전($taskBinaryVersion)과 소스 버전($taskVersion)이 다릅니다. 최신 ReleaseDirectory를 지정하세요."
}
if ((Test-Path -LiteralPath $taskStage) -or (Test-Path -LiteralPath $taskOutput)) {
    throw '같은 빌드 ID의 패키지 폴더가 이미 있습니다. 새로운 BuildId로 실행하세요.'
}
if (-not $InnoCompiler) {
    $InnoCompiler = & (Join-Path $PSScriptRoot 'windows\distribution\get-inno-compiler.ps1')
}
if (-not (Test-Path -LiteralPath $InnoCompiler -PathType Leaf)) { throw 'Inno Setup 컴파일러를 찾을 수 없습니다.' }
New-Item -ItemType Directory -Path $taskPayload,$taskOutput | Out-Null
Copy-Item -Path "$taskRelease\*" -Destination $taskPayload -Recurse
$taskShortcutLicenseTarget = Join-Path $taskPayload 'data\licenses\simple-icons'
New-Item -ItemType Directory -Path $taskShortcutLicenseTarget -Force | Out-Null
foreach ($taskShortcutLicenseFile in $taskShortcutLicenseFiles) {
    Copy-Item -LiteralPath (Join-Path $taskShortcutLicenseSource $taskShortcutLicenseFile) -Destination $taskShortcutLicenseTarget
}
# Flutter's build-side manifest may contain an absolute development path.
# Both runtime manifests refer only to DLLs copied into this bundle.
foreach ($taskNativeManifest in @('native_assets.json', 'data\flutter_assets\NativeAssetsManifest.json')) {
    $taskNativePath = Join-Path $taskPayload $taskNativeManifest
    if (-not (Test-Path -LiteralPath $taskNativePath -PathType Leaf)) { continue }
    $taskNativeData = Get-Content -LiteralPath $taskNativePath -Raw | ConvertFrom-Json
    foreach ($taskAsset in $taskNativeData.'native-assets'.windows_x64.PSObject.Properties) {
        if ($taskAsset.Value[0] -ne 'absolute') { continue }
        $taskNativeFile = [IO.Path]::GetFileName($taskAsset.Value[1])
        if (-not (Test-Path -LiteralPath (Join-Path $taskPayload $taskNativeFile) -PathType Leaf)) {
            throw "네이티브 라이브러리가 배포본에 없습니다: $taskNativeFile"
        }
        $taskAsset.Value[1] = $taskNativeFile
    }
    [IO.File]::WriteAllText($taskNativePath, ($taskNativeData | ConvertTo-Json -Depth 12 -Compress), (New-Object Text.UTF8Encoding($false)))
}
# Vendor redistributables stay beside the executable; no machine-wide install.
$taskVswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$taskVs = & $taskVswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | ConvertFrom-Json
if (-not $taskVs) { throw 'Visual C++ 배포 런타임을 찾으려면 MSVC 빌드 도구가 필요합니다.' }
$taskRedist = Get-ChildItem -LiteralPath (Join-Path $taskVs.installationPath 'VC\Redist\MSVC') -Directory |
    Where-Object Name -Match '^\d+\.' | Sort-Object Name -Descending | Select-Object -First 1
foreach ($taskDll in @('msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll')) {
    $taskSource = Get-ChildItem -LiteralPath (Join-Path $taskRedist.FullName 'x64') -Recurse -Filter $taskDll | Select-Object -First 1
    if (-not $taskSource) { throw "런타임을 찾을 수 없습니다: $taskDll" }
    Copy-Item -LiteralPath $taskSource.FullName -Destination $taskPayload
}
$taskFiles = Get-ChildItem -LiteralPath $taskPayload -Recurse -File
if ($taskFiles | Where-Object { $_.Name -match '\.(sqlite|db)(-wal|-shm)?$|project-preferences|demo-snapshot|^\.env($|\.)|^credentials' }) {
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
$taskSetup = Join-Path $taskOutput 'Ieum-Setup-x64.exe'
$taskSetupIcon = Join-Path $PSScriptRoot 'windows\runner\resources\app_icon.ico'
& $InnoCompiler /Qp ("/DAppVersion=$taskVersion") ("/DLauncherPath=$taskExe") ("/DAppIcon=$taskSetupIcon") ("/DOutputDirectory=$taskOutput") (Join-Path $PSScriptRoot 'windows\distribution\ieum-setup.iss')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $taskSetup)) { throw '설치 파일 패키징에 실패했습니다.' }
$taskInstructions = @"
이음 $taskVersion / Windows x64 / $BuildId

설치: Ieum-Setup-x64.exe를 실행하고 설치 위치와 바로가기를 선택하세요.
현재 Windows 계정에 설치하며 관리자 권한이 필요하지 않습니다.
시작 메뉴에서 이음을 열 수 있습니다. 바탕 화면 바로가기는 선택 사항입니다.
Windows 설정 → 앱에서 제거할 수 있습니다. 프로젝트와 개인 설정은 유지됩니다.

포터블: Ieum-Windows-x64.exe 하나만 다른 PC로 복사해서 실행하세요.
앱 파일은 %LOCALAPPDATA%\Ieum\builds\$BuildId 에 풀립니다.
Flutter SDK와 개발 도구, Git 설치는 필요하지 않습니다.
ZIP 배포본은 전체 압축을 풀고 ieum_flutter.exe를 실행하세요.

시작하기
1. GitHub로 로그인하고 브라우저에서 인증 코드를 승인합니다.
2. 관리자는 프로젝트를 생성합니다. 팀원은 저장소 초대를 수락한 뒤 프로젝트 참여를 요청합니다.
3. 관리자가 참여 요청을 승인하고 파트를 배정합니다. 파트는 직접 구성합니다.
4. 작업 목록·칸반에서 작업을 관리하고 일정에서 시작일~마감일 기간을 확인합니다.
5. 작업 상세에서 다음 담당자에게 전달하고 필요하면 잠금을 적용합니다.

작업 관리
확인중·진행중·검토중·완료·보류·드랍의 여섯 채널을 사용합니다. 진행중·검토중에서 전달하면 확인중으로 이동합니다.
작성·수정 목적으로 받은 작업을 시작하면 진행중, 검토 목적으로 받은 작업을 시작하면 검토중입니다.
보류에서 재개하면 이전 상태로, 드랍에서 복귀하면 확인중으로 돌아갑니다. 드랍은 일정에서 제외됩니다.
새 작업은 잠금 없음·작성자 잠금·지정 작업자 잠금 중 선택합니다. 최초 작성자·담당자와 최근 전달·검토 이력은 작업 상세에서 확인합니다.
잠금 담당자만 내용 수정과 상태 변경·삭제를 할 수 있으며 다른 참여자는 열람·코멘트를 할 수 있습니다.
잠근 채 전달하면 다음 담당자만 수정할 수 있습니다. 전달 전에 최종 확인합니다.
코멘트로 피드백을 남깁니다. 반려 및 작업 단계 자동화 기능은 사용하지 않습니다.
상단에 고정한 작업은 높은·보통·낮은 우선순위 순으로 목록과 각 칸반 열 위에 표시됩니다.
작업 상세에서 보관·복원·삭제할 수 있습니다. 삭제 표식은 동기화 시 재등장을 막기 위해 보존됩니다.

GitHub 동기화
로컬 저장 → 작업별 커밋·PR → 검증·통합 → 팀 변경 가져오기를 진행합니다.
동기화는 앱이 실행 중일 때 동작하며 오류·요청 제한에는 재시도합니다.
보호 브랜치·Git 충돌·권한 부족은 자동으로 우회하지 않습니다.
프로젝트 DB와 저장 경로는 유지합니다. 샘플 작업과 계정 토큰을 배포본에 넣지 않습니다.
로그인 유지 시 Windows 자격 증명 관리자에 인증 정보를 보관합니다.

로그인 연결
Windows 시스템·사용자 프록시와 인증서 설정을 적용합니다.
실패하면 DNS·인증서·프록시·시간 초과에 따라 안내와 오류 번호를 표시합니다.
인증서 검증을 우회하거나 네트워크 접속 제한을 임의로 해제하지 않습니다.

업데이트
앱 시작 시와 4시간마다 새 배포 버전을 확인합니다.
다운로드 후 다음 실행에 적용하거나 설정 → 일반 → 앱 정보에서 업데이트 후 재시작합니다.
시작 자체에 실패한 배포본은 가능한 이전 버전으로 복구합니다.
SHA256SUMS.txt로 설치 파일, 포터블 EXE와 ZIP의 해시를 확인할 수 있습니다.
이 패키지 생성 스크립트는 GitHub Release 게시를 수행하지 않습니다.

"@
[IO.File]::WriteAllText((Join-Path $taskOutput '사용안내.txt'),$taskInstructions,(New-Object Text.UTF8Encoding($true)))
$taskChecksums = foreach ($taskPackageName in @('Ieum-Setup-x64.exe', 'Ieum-Windows-x64.exe', 'Ieum-Windows-x64.zip')) {
    $taskHash = (Get-FileHash -LiteralPath (Join-Path $taskOutput $taskPackageName) -Algorithm SHA256).Hash.ToLowerInvariant()
    "$taskHash  $taskPackageName"
}
[IO.File]::WriteAllLines((Join-Path $taskOutput 'SHA256SUMS.txt'), $taskChecksums, (New-Object Text.UTF8Encoding($false)))
Get-FileHash -LiteralPath $taskExe -Algorithm SHA256 | Format-List
Get-Item -LiteralPath $taskExe | Select-Object FullName,Length
