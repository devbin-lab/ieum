param([string]$InnoCompiler = '')
$ErrorActionPreference = 'Stop'
if (-not $InnoCompiler) { $InnoCompiler = & (Join-Path $PSScriptRoot 'get-inno-compiler.ps1') }
$taskRoot = Join-Path ([IO.Path]::GetTempPath()) ('ieum-installer-test-' + [Guid]::NewGuid().ToString('N'))
$taskInstall = Join-Path $taskRoot 'installed'
$taskProfile = Join-Path $taskRoot 'user-data'
$taskRegistry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{CBE5EC73-3E9D-4A6D-A675-A403A5883D63}_is1'
$taskRegistryExisted = Test-Path -LiteralPath $taskRegistry
$taskFramework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$taskCompiler = Join-Path $taskFramework 'csc.exe'
function Assert-Installer([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Output "PASS $Message"
}
function Invoke-TestInstaller([string]$Executable, [string]$Arguments, [switch]$AllowFailure) {
    $taskProcess = Start-Process -FilePath $Executable -ArgumentList $Arguments -WindowStyle Hidden -PassThru -Wait
    if ($AllowFailure) { return $taskProcess.ExitCode }
    if ($taskProcess.ExitCode -ne 0) { throw "Sandbox installer exited with $($taskProcess.ExitCode)." }
}
try {
    New-Item -ItemType Directory -Path $taskRoot,$taskProfile | Out-Null
    # Fixtures are never executed; the sandbox installer has no [Run] entries.
    $taskFixture = Join-Path $taskRoot 'fixture.cs'
    [IO.File]::WriteAllText($taskFixture, 'class Fixture { static void Main() { throw new System.Exception("Fixture must never run"); } }')
    $taskLauncher = Join-Path $taskRoot 'launcher.exe'
    & $taskCompiler /nologo /target:winexe ("/out:$taskLauncher") $taskFixture
    if ($LASTEXITCODE -ne 0) { throw 'Fixture compilation failed.' }
    $taskProject = Join-Path $taskProfile 'project.sqlite'
    $taskPreferences = Join-Path $taskProfile 'preferences.json'
    [IO.File]::WriteAllText($taskProject, 'project-data-fixture')
    [IO.File]::WriteAllText($taskPreferences, '{"appearance":"dark"}')
    $taskProjectHash = (Get-FileHash -LiteralPath $taskProject).Hash
    $taskPreferencesHash = (Get-FileHash -LiteralPath $taskPreferences).Hash
    $taskIcon = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\runner\resources\app_icon.ico'))
    & $InnoCompiler /Qp /DTestHarness=1 /DAppVersion=1.0.0 ("/DLauncherPath=$taskLauncher") ("/DAppIcon=$taskIcon") ("/DOutputDirectory=$taskRoot") (Join-Path $PSScriptRoot 'ieum-setup.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Sandbox installer compilation failed.' }
    $taskSetup = Join-Path $taskRoot 'Ieum-Setup-x64.exe'
    $taskSilent = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
    Invoke-TestInstaller $taskSetup "$taskSilent /LANG=english /DIR=`"$taskInstall`" /LOG=`"$taskRoot\default-install.log`""
    Assert-Installer (Test-Path -LiteralPath (Join-Path $taskInstall 'test-start-menu\Ieum.lnk')) 'Start menu shortcut is selected by default'
    Assert-Installer (-not (Test-Path -LiteralPath (Join-Path $taskInstall 'test-desktop\Ieum.lnk'))) 'desktop shortcut requires an explicit choice'
    Invoke-TestInstaller $taskSetup "$taskSilent /LANG=korean /DIR=`"$taskInstall`" /TASKS=startmenuicon,desktopicon /LOG=`"$taskRoot\install.log`""
    Assert-Installer ((Get-FileHash -LiteralPath (Join-Path $taskInstall 'Ieum.exe')).Hash -eq (Get-FileHash -LiteralPath $taskLauncher).Hash) 'installed launcher matches its payload'
    $taskShell = New-Object -ComObject WScript.Shell
    foreach ($taskShortcutFolder in @('test-start-menu', 'test-desktop')) {
        $taskShortcutFile = Join-Path $taskInstall "$taskShortcutFolder\Ieum.lnk"
        Assert-Installer (Test-Path -LiteralPath $taskShortcutFile -PathType Leaf) "$taskShortcutFolder shortcut created"
        $taskShortcut = $taskShell.CreateShortcut($taskShortcutFile)
        Assert-Installer ($taskShortcut.TargetPath -eq (Join-Path $taskInstall 'Ieum.exe')) "$taskShortcutFolder targets the durable update launcher"
        Assert-Installer ($taskShortcut.WorkingDirectory -eq $taskInstall) "$taskShortcutFolder working directory is correct"
    }
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($taskShell) | Out-Null
    # Same-version rebuilds must refresh the launcher instead of keeping stale code.
    [IO.File]::WriteAllText($taskFixture, 'class Fixture { static void Main() { throw new System.Exception("New fixture must never run"); } }')
    & $taskCompiler /nologo /target:winexe ("/out:$taskLauncher") $taskFixture
    if ($LASTEXITCODE -ne 0) { throw 'Replacement fixture compilation failed.' }
    & $InnoCompiler /Qp /DTestHarness=1 /DAppVersion=1.0.0 ("/DLauncherPath=$taskLauncher") ("/DAppIcon=$taskIcon") ("/DOutputDirectory=$taskRoot") (Join-Path $PSScriptRoot 'ieum-setup.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Replacement sandbox installer compilation failed.' }
    $taskInstalledLauncher = Join-Path $taskInstall 'Ieum.exe'
    $taskOldLauncherHash = (Get-FileHash -LiteralPath $taskInstalledLauncher).Hash
    # Simulate a mapped launcher without starting an app or displaying windows.
    $taskLauncherLock = [IO.File]::Open($taskInstalledLauncher, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $taskBlockedInstall = Invoke-TestInstaller $taskSetup "$taskSilent /LANG=english /DIR=`"$taskInstall`" /LOG=`"$taskRoot\blocked-install.log`"" -AllowFailure
        Assert-Installer ($taskBlockedInstall -ne 0) 'reinstall waits for the user to close a locked launcher'
        Assert-Installer (([IO.File]::ReadAllText((Join-Path $taskRoot 'blocked-install.log'))) -match 'IEUM_LAUNCHER_IN_USE') 'reinstall records the close-app prerequisite'
        Assert-Installer ((Get-FileHash -LiteralPath $taskInstalledLauncher).Hash -eq $taskOldLauncherHash) 'blocked reinstall leaves the old launcher untouched'
        $taskBlockedUninstall = Invoke-TestInstaller (Join-Path $taskInstall 'unins000.exe') "$taskSilent /LOG=`"$taskRoot\blocked-uninstall.log`"" -AllowFailure
        Assert-Installer ($taskBlockedUninstall -ne 0) 'uninstall waits for the user to close a locked launcher'
        Assert-Installer (([IO.File]::ReadAllText((Join-Path $taskRoot 'blocked-uninstall.log'))) -match 'IEUM_LAUNCHER_IN_USE') 'uninstall records the close-app prerequisite'
        Assert-Installer (Test-Path -LiteralPath (Join-Path $taskInstall 'test-start-menu\Ieum.lnk')) 'blocked uninstall preserves the installed shortcut'
    } finally {
        $taskLauncherLock.Dispose()
    }
    Invoke-TestInstaller $taskSetup "$taskSilent /LANG=english /DIR=`"$taskInstall`" /TASKS=startmenuicon,desktopicon /LOG=`"$taskRoot\upgrade.log`""
    Assert-Installer ((Get-FileHash -LiteralPath (Join-Path $taskInstall 'Ieum.exe')).Hash -eq (Get-FileHash -LiteralPath $taskLauncher).Hash) 'same-version reinstall replaces the old launcher'
    Assert-Installer (@(Get-ChildItem -LiteralPath $taskInstall -Filter unins*.exe).Count -eq 1) 'reinstall keeps a single uninstaller'
    $taskUserFile = Join-Path $taskInstall 'user-document.md'
    [IO.File]::WriteAllText($taskUserFile, 'user-created-document')
    Invoke-TestInstaller (Join-Path $taskInstall 'unins000.exe') "$taskSilent /LOG=`"$taskRoot\uninstall.log`""
    Assert-Installer (-not (Test-Path -LiteralPath (Join-Path $taskInstall 'Ieum.exe'))) 'uninstall removes the installed launcher'
    Assert-Installer (-not (Test-Path -LiteralPath (Join-Path $taskInstall 'test-start-menu\Ieum.lnk'))) 'uninstall removes its Start menu shortcut'
    Assert-Installer (-not (Test-Path -LiteralPath (Join-Path $taskInstall 'test-desktop\Ieum.lnk'))) 'uninstall removes its desktop shortcut'
    Assert-Installer ((Get-FileHash -LiteralPath $taskProject).Hash -eq $taskProjectHash) 'uninstall preserves project data'
    Assert-Installer ((Get-FileHash -LiteralPath $taskPreferences).Hash -eq $taskPreferencesHash) 'uninstall preserves user preferences'
    Assert-Installer (([IO.File]::ReadAllText($taskUserFile)) -eq 'user-created-document') 'uninstall preserves files it did not install'
    Assert-Installer ((Test-Path -LiteralPath $taskRegistry) -eq $taskRegistryExisted) 'sandbox leaves the real uninstall registration unchanged'
} finally {
    $taskResolved = [IO.Path]::GetFullPath($taskRoot)
    $taskTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not $taskResolved.StartsWith($taskTemp + '\', [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($taskResolved) -notlike 'ieum-installer-test-*') {
        throw 'Unsafe installer-test cleanup path.'
    }
    if (Test-Path -LiteralPath $taskResolved) { Remove-Item -LiteralPath $taskResolved -Recurse -Force }
}
