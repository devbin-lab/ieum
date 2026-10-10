param([string]$ToolDirectory = '')
$ErrorActionPreference = 'Stop'
if (-not $ToolDirectory) {
    $taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $ToolDirectory = Join-Path $taskRoot '.local\installer-tools'
}
$taskTools = [IO.Path]::GetFullPath($ToolDirectory)
$taskCompilerRoot = Join-Path $taskTools 'inno-6.7.3'
$taskCompiler = Join-Path $taskCompilerRoot 'ISCC.exe'
if (Test-Path -LiteralPath $taskCompiler -PathType Leaf) { return $taskCompiler }

# Official immutable Inno Setup release, verified before it is unpacked.
# The unpacker is a build-only tool; nothing is installed or registered globally.
$taskDownloads = @(
    @{
        Name = 'innosetup-6.7.3.exe'
        Uri = 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe'
        Sha256 = '9c73c3bae7ed48d44112a0f48e66742c00090bdb5bef71d9d3c056c66e97b732'
    },
    @{
        Name = 'innounp-2.zip'
        Uri = 'https://github.com/jrathlev/InnoUnpacker-Windows-GUI/releases/download/oi_2_2_11/innounp-2.zip'
        Sha256 = '851772538a041229102ad9964542d49dc00c74002e3091a70469c079ae368f52'
    }
)
New-Item -ItemType Directory -Path $taskTools -Force | Out-Null
foreach ($taskDownload in $taskDownloads) {
    $taskFile = Join-Path $taskTools $taskDownload.Name
    if (-not (Test-Path -LiteralPath $taskFile -PathType Leaf)) {
        Invoke-WebRequest -Uri $taskDownload.Uri -OutFile $taskFile
    }
    if ((Get-FileHash -LiteralPath $taskFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskDownload.Sha256) {
        throw "Installer build-tool hash mismatch: $($taskDownload.Name)"
    }
}
$taskOfficialInstaller = Join-Path $taskTools 'innosetup-6.7.3.exe'
$taskSignature = Get-AuthenticodeSignature -LiteralPath $taskOfficialInstaller
if ($taskSignature.Status -ne 'Valid' -or $taskSignature.SignerCertificate.Subject -notmatch 'Pyrsys B\.V\.') {
    throw 'The official Inno Setup compiler download has an invalid publisher signature.'
}
$taskUnpackerRoot = Join-Path $taskTools 'unpacker'
if (-not (Test-Path -LiteralPath $taskUnpackerRoot)) {
    Expand-Archive -LiteralPath (Join-Path $taskTools 'innounp-2.zip') -DestinationPath $taskUnpackerRoot
}
$taskUnpacker = Get-ChildItem -LiteralPath $taskUnpackerRoot -Recurse -Filter innounp.exe | Select-Object -First 1
if (-not $taskUnpacker) { throw 'The verified unpacker archive contains no unpacker.' }
$taskExtraction = Join-Path $taskTools ('extracted-' + [Guid]::NewGuid().ToString('N'))
try {
    & $taskUnpacker.FullName -x -y ("-d$taskExtraction") $taskOfficialInstaller | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to unpack the official Inno Setup compiler.' }
    $taskExtractedCompiler = Get-ChildItem -LiteralPath $taskExtraction -Recurse -Filter ISCC.exe | Select-Object -First 1
    if (-not $taskExtractedCompiler) { throw 'The official compiler was not found after extraction.' }
    Copy-Item -LiteralPath $taskExtractedCompiler.Directory.FullName -Destination $taskCompilerRoot -Recurse
} finally {
    $taskResolved = [IO.Path]::GetFullPath($taskExtraction)
    if (-not $taskResolved.StartsWith($taskTools + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unsafe build-tool cleanup path.'
    }
    if (Test-Path -LiteralPath $taskResolved) { Remove-Item -LiteralPath $taskResolved -Recurse -Force }
}
if (-not (Test-Path -LiteralPath $taskCompiler -PathType Leaf)) { throw 'Installer compiler extraction failed.' }
return $taskCompiler
