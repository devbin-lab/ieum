$ErrorActionPreference = 'Stop'
$taskRoot = Join-Path ([IO.Path]::GetTempPath()) ('ieum-launcher-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskRoot | Out-Null
$taskFramework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$taskCompiler = Join-Path $taskFramework 'csc.exe'
try {
    $taskBroken = Join-Path $taskRoot 'broken.cs'
    $taskFallback = Join-Path $taskRoot 'fallback.cs'
    [IO.File]::WriteAllText($taskBroken, @'
class Fixture {
    static int Main() {
        var mode = System.Environment.GetEnvironmentVariable("IEUM_TEST_STARTUP_MODE");
        if (mode == "early-crash" || mode == "late-crash" || mode == "early-close") {
            System.IO.File.WriteAllText(System.Environment.GetEnvironmentVariable("IEUM_STARTUP_MARKER"), "ready");
            System.Threading.Thread.Sleep(mode == "late-crash" ? 6500 : 250);
        }
        return mode == "early-close" ? 0 : 42;
    }
}
'@)
    [IO.File]::WriteAllText($taskFallback, 'class Fixture { static int Main() { System.IO.File.WriteAllText(System.IO.Path.Combine(System.AppDomain.CurrentDomain.BaseDirectory,"restored.txt"),"ok"); return 0; } }')
    $taskPayload = Join-Path $taskRoot 'payload'
    New-Item -ItemType Directory -Path $taskPayload | Out-Null
    & $taskCompiler /nologo /target:winexe ("/out:$taskPayload\ieum_flutter.exe") $taskBroken
    if ($LASTEXITCODE -ne 0) { throw 'Broken fixture compilation failed.' }
    & $taskCompiler /nologo /target:winexe ("/out:$taskRoot\fallback.exe") $taskFallback
    if ($LASTEXITCODE -ne 0) { throw 'Fallback fixture compilation failed.' }
    Compress-Archive -Path "$taskPayload\*" -DestinationPath "$taskRoot\payload.zip"
    $taskLauncher = Join-Path $taskRoot 'launcher.cs'
    [IO.File]::WriteAllText($taskLauncher, [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'portable_launcher.cs')).Replace('__BUILD_ID__','fixture-020').Replace('__APP_VERSION__.0','0.2.0.5').Replace('__APP_VERSION__','0.2.0+5'))
    & $taskCompiler /nologo /target:exe /main:LauncherTests ("/out:$taskRoot\tests.exe") ("/resource:$taskRoot\payload.zip,Ieum.Payload.zip") ("/reference:$taskFramework\System.IO.Compression.dll") ("/reference:$taskFramework\System.IO.Compression.FileSystem.dll") ("/reference:$taskFramework\System.Windows.Forms.dll") ("/reference:$taskFramework\System.Runtime.Serialization.dll") $taskLauncher (Join-Path $PSScriptRoot 'launcher_test.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Launcher test compilation failed.' }
    & "$taskRoot\tests.exe" (Join-Path $taskRoot 'Ieum') (Join-Path $taskRoot 'fallback.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Launcher regression failed.' }
} finally {
    $taskResolved = [IO.Path]::GetFullPath($taskRoot)
    $taskTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $taskResolved.StartsWith($taskTemp, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($taskResolved) -notlike 'ieum-launcher-test-*') { throw 'Unsafe cleanup path.' }
    Remove-Item -LiteralPath $taskResolved -Recurse -Force
}
