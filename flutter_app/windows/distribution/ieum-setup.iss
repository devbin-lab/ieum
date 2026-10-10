; Installer copies the stable launcher. The launcher owns versioned runtime
; files and follows the same verified update pointer as the portable EXE.
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef LauncherPath
  #error LauncherPath is required
#endif
#ifndef OutputDirectory
  #error OutputDirectory is required
#endif
#ifndef AppIcon
  #define AppIcon "..\runner\resources\app_icon.ico"
#endif

[Setup]
AppId={{CBE5EC73-3E9D-4A6D-A675-A403A5883D63}
AppName=이음 · IEUM
AppVersion={#AppVersion}
AppVerName=이음 · IEUM {#AppVersion}
AppPublisher=devbin-lab
AppPublisherURL=https://github.com/devbin-lab/ieum
AppSupportURL=https://github.com/devbin-lab/ieum/issues
AppUpdatesURL=https://github.com/devbin-lab/ieum/releases/latest
DefaultDirName={localappdata}\Programs\Ieum
DefaultGroupName=Ieum
DisableProgramGroupPage=yes
DisableDirPage=no
DisableWelcomePage=no
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDirectory}
OutputBaseFilename=Ieum-Setup-x64
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\Ieum.exe
UninstallDisplayName=이음 · IEUM
WizardStyle=modern dynamic
WizardSizePercent=110,110
Compression=lzma2/fast
SolidCompression=yes
CloseApplications=no
RestartApplications=no
SetupLogging=yes
VersionInfoVersion={#AppVersion}.0
VersionInfoDescription=Ieum Setup
VersionInfoProductName=Ieum
VersionInfoProductVersion={#AppVersion}
Uninstallable=yes
#ifdef TestHarness
CreateUninstallRegKey=no
UsePreviousAppDir=no
UsePreviousTasks=no
UsePreviousLanguage=no
UsePreviousGroup=no
#endif

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
korean.WelcomeLabel1=팀의 작업을 잇는 이음
korean.WelcomeLabel2=작업과 일정, 팀의 변경 사항을 한곳에서 관리하세요.%n%n설치 후 언어와 디자인을 설정하고 GitHub 계정으로 시작할 수 있습니다.
korean.SelectDirLabel3=이음을 설치할 위치를 선택하세요.
korean.SelectDirDesc=현재 Windows 계정에 이음을 설치합니다.
korean.SelectTasksLabel2=이음을 편하게 실행할 수 있도록 바로가기를 만듭니다.
korean.FinishedLabel=이음 설치가 완료되었습니다.
korean.FinishedLabel2=이제 첫 설정을 마치고 팀의 작업 공간을 시작하세요.%n%n앱을 삭제해도 프로젝트와 개인 설정은 보존됩니다.
english.WelcomeLabel1=Bring your team's work together
english.WelcomeLabel2=Manage work, schedules, and team activity in one place.%n%nAfter installing, choose your language and appearance, then get started with GitHub.
english.SelectDirLabel3=Choose where to install Ieum.
english.SelectDirDesc=Ieum will be installed for your Windows account.
english.SelectTasksLabel2=Create shortcuts to make Ieum easy to open.
english.FinishedLabel=Ieum is ready.
english.FinishedLabel2=Complete the first-run setup and open your team's workspace.%n%nUninstalling the app keeps your projects and personal settings.

[CustomMessages]
korean.ShortcutGroup=바로가기
korean.StartMenuShortcut=시작 메뉴에 추가
korean.DesktopShortcut=바탕 화면에 바로가기 만들기
korean.LaunchIeum=이음 시작하기
korean.CloseIeumBeforeInstall=이음을 종료한 뒤 다시 시도해 주세요.%n앱이 실행 중이거나 설치 파일이 사용 중이어서 설치를 진행할 수 없습니다.
korean.CloseIeumBeforeUninstall=이음을 종료한 뒤 제거를 다시 실행해 주세요.%n앱이 실행 중이거나 설치 파일이 사용 중이어서 제거를 진행할 수 없습니다.
english.ShortcutGroup=Shortcuts
english.StartMenuShortcut=Add to the Start menu
english.DesktopShortcut=Create a desktop shortcut
english.LaunchIeum=Open Ieum
english.CloseIeumBeforeInstall=Close Ieum, then try again.%nThe app is running or its launcher is in use, so installation cannot continue.
english.CloseIeumBeforeUninstall=Close Ieum, then run uninstall again.%nThe app is running or its launcher is in use, so uninstall cannot continue.

[Tasks]
Name: "startmenuicon"; Description: "{cm:StartMenuShortcut}"; GroupDescription: "{cm:ShortcutGroup}"; Flags: checkedonce
Name: "desktopicon"; Description: "{cm:DesktopShortcut}"; GroupDescription: "{cm:ShortcutGroup}"; Flags: unchecked

[Files]
Source: "{#LauncherPath}"; DestDir: "{app}"; DestName: "Ieum.exe"; Flags: ignoreversion

[Icons]
#ifdef TestHarness
Name: "{app}\test-start-menu\Ieum"; Filename: "{app}\Ieum.exe"; WorkingDir: "{app}"; Tasks: startmenuicon
Name: "{app}\test-desktop\Ieum"; Filename: "{app}\Ieum.exe"; WorkingDir: "{app}"; Tasks: desktopicon
#else
Name: "{userprograms}\Ieum"; Filename: "{app}\Ieum.exe"; WorkingDir: "{app}"; Tasks: startmenuicon
Name: "{userdesktop}\Ieum"; Filename: "{app}\Ieum.exe"; WorkingDir: "{app}"; Tasks: desktopicon
#endif

[Run]
#ifndef TestHarness
Filename: "{app}\Ieum.exe"; Description: "{cm:LaunchIeum}"; Flags: nowait postinstall skipifsilent
#endif

; Deliberately no [UninstallDelete], credential cleanup, or project deletion.
; Inno Setup removes only its own program files, shortcuts, and registration.

[Code]
function OpenLauncherExclusively(FileName: String; DesiredAccess, ShareMode: Cardinal;
  SecurityAttributes: Integer; CreationDisposition, Flags: Cardinal;
  TemplateFile: THandle): THandle;
  external 'CreateFileW@kernel32.dll stdcall';

function CloseLauncherHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';

function InstalledLauncherAvailable: Boolean;
var
  FileName: String;
  Handle: THandle;
begin
  FileName := ExpandConstant('{app}\Ieum.exe');
  Result := True;
  if not FileExists(FileName) then Exit;
  { Request exclusive read/write access without changing the file. The launcher
    remains mapped while its app runs; never terminate it or its child process. }
  Handle := OpenLauncherExclusively(FileName, $C0000000, 0, 0, 3, 0, 0);
  Result := Handle <> THandle(-1);
  if Result then CloseLauncherHandle(Handle)
  else Log('IEUM_LAUNCHER_IN_USE: waiting for the user to close Ieum.');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not InstalledLauncherAvailable then
    Result := CustomMessage('CloseIeumBeforeInstall');
end;

function InitializeUninstall: Boolean;
begin
  Result := InstalledLauncherAvailable;
  if not Result then
    SuppressibleMsgBox(CustomMessage('CloseIeumBeforeUninstall'),
      mbInformation, MB_OK, IDOK);
end;
