#Requires -Version 7.2
[CmdletBinding(DefaultParameterSetName = 'Diagnostic')]
param(
    [string] $Root,
    [string] $Ref = 'HEAD',
    [ValidateSet('Native', 'Wsl')][string] $BridgeMode = 'Native',
    [ValidateNotNullOrEmpty()][string] $WslDistribution = 'Ubuntu-22.04',
    [ValidateRange(0, 1000)][int] $MinFreeGiB = 0,
    [Parameter(ParameterSetName = 'Diagnostic')][switch] $Diagnostic,
    [Parameter(Mandatory, ParameterSetName = 'Build')][switch] $Build,
    [Parameter(ParameterSetName = 'Build')][string] $ResumeRun,
    [Parameter(ParameterSetName = 'Build')][string] $EnterpriseConfig,
    [Parameter(Mandatory, ParameterSetName = 'Bridge')][switch] $BridgeOnly
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'windows-build-common.ps1')
$flutterBuildArguments = @('build', 'windows', '--release', '--no-pub', '-v')
if ($EnterpriseConfig) {
    $configPath = (Resolve-Path -LiteralPath $EnterpriseConfig).Path
    $clientConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
    $allowedKeys = @('YESDESK_MANAGEMENT_URL', 'YESDESK_OIDC_AUTHORIZE', 'YESDESK_OIDC_TOKEN',
        'YESDESK_OIDC_CLIENT_ID', 'YESDESK_OIDC_SCOPE')
    foreach ($key in $clientConfig.Keys) {
        if ($key -notin $allowedKeys -or $clientConfig[$key] -isnot [string]) {
            throw "Unexpected public corporate client configuration key: $key."
        }
    }
    $flutterBuildArguments += "--dart-define-from-file=$configPath"
}
. (Join-Path $PSScriptRoot 'windows-build-bridge.ps1')
. (Join-Path $PSScriptRoot 'windows-build-verify.ps1')

$layout = Get-YesDeskLayout $Root
$report = Get-EnvironmentReport $layout
if (!$Build -and !$BridgeOnly) {
    Show-EnvironmentReport $layout $report
    Write-Host "Bridge mode: $BridgeMode. Requested Git ref: $Ref"
    return
}

$lock = Enter-BuildLock $layout
$log = $null
try {
    $log = Start-BuildLog $layout 'build'
    Show-EnvironmentReport $layout $report
    Write-Host "Bridge mode: $BridgeMode. Requested Git ref: $Ref"
    $missing = @($report.GetEnumerator() | Where-Object { !$_.Value } | ForEach-Object Key)
    if ($missing.Count -gt 0) {
        throw "Missing tools: $($missing -join ', '). Run setup-windows-build.ps1 -Install."
    }
    if (!$MinFreeGiB) { $MinFreeGiB = if ($BridgeOnly) { 10 } else { 45 } }
    Assert-FreeSpace $layout.Volume $MinFreeGiB

    $git = Find-Application 'git.exe'
    $commit = Invoke-BuildCommand $git @('-C', $repoRoot, 'rev-parse', '--verify', '--end-of-options', "$Ref^{commit}") -Capture
    $stamp = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
    $run = if ($ResumeRun) {
        $directory = Get-Item -LiteralPath $ResumeRun
        if (!$directory.PSIsContainer -or $directory.Parent.FullName -ne $layout.Runs -or
            $directory.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            throw "-ResumeRun must name a direct run directory under $($layout.Runs)."
        }
        $directory.FullName
    } else {
        Join-Path $layout.Runs "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$($commit.Substring(0, 9))-$PID"
    }
    $source = Join-Path $run 'src'
    $archive = Join-Path $run 'source.tar'
    $output = Join-Path $run 'SignOutput'
    if ($ResumeRun) {
        if (Test-Path -LiteralPath $output) { throw "Final artifact directory already exists: $output" }
        $verifySnapshot = @'
import pathlib
import sys
import tarfile

archive, source, commit = sys.argv[1:]
with tarfile.open(archive) as snapshot:
    if snapshot.pax_headers.get('comment') != commit:
        raise SystemExit(f'Resume archive does not belong to {commit}.')
    for lockfile in ('Cargo.lock', 'flutter/pubspec.lock'):
        if snapshot.extractfile(lockfile).read() != (pathlib.Path(source) / lockfile).read_bytes():
            raise SystemExit(f'{lockfile} differs from the original snapshot.')
'@
        Invoke-BuildCommand $layout.Python @('-I', '-c', $verifySnapshot, $archive, $source, $commit)
        Write-Host "Resuming with existing bridge and Rust DLLs in $source"
    } else {
        New-Item -ItemType Directory -Path $source | Out-Null
        Invoke-BuildCommand $git @('-C', $repoRoot, 'archive', '--format=tar', "--output=$archive", $commit)
        Invoke-BuildCommand (Find-Application 'tar.exe') @('-xf', $archive, '-C', $source)
    }
    Write-Host "Source snapshot $commit at $source"

    $vs = Find-VsBuildTools
    Set-YesDeskEnvironment $layout
    Enter-YesDeskVsEnvironment $vs
    $cargo = Join-Path $layout.CargoBin 'cargo.exe'
    Invoke-BuildCommand (Join-Path $layout.CargoBin 'rustc.exe') @('-vV')
    Invoke-BuildCommand $layout.FlutterExe @('--version')
    if (!(Test-FlutterEngine $layout)) {
        throw 'Flutter cache changed. Re-run setup-windows-flutter.ps1 -Configure.'
    }

    if ($ResumeRun) {
        if (!(Test-Path -LiteralPath (Join-Path $source 'flutter\.dart_tool\package_config.json') -PathType Leaf)) {
            throw 'The resumed run is missing the resolved Flutter package configuration.'
        }
        if (!(Test-Path -LiteralPath (Join-Path $source 'flutter\windows\flutter\generated_plugins.cmake') -PathType Leaf)) {
            Invoke-WindowsFlutterPubGet $layout $source
        }
    } else {
        Invoke-WindowsFlutterPubGet $layout $source
        if ($BridgeMode -eq 'Native') {
            Invoke-NativeBridge $layout $source
        } else {
            Invoke-WslBridge $layout $WslDistribution $source $archive
        }
    }
    Assert-BridgeFiles $source
    if ($BridgeOnly) {
        Write-Host "Generated bridge files: $source"
        return
    }

    Push-Location -LiteralPath $source
    try {
        $cargoLockHash = (Get-FileHash -LiteralPath 'Cargo.lock').Hash
        $pubLockHash = (Get-FileHash -LiteralPath 'flutter\pubspec.lock').Hash
        $vcpkgManifest = Get-Content -LiteralPath 'vcpkg.json' -Raw | ConvertFrom-Json -AsHashtable
        if ($vcpkgManifest['vcpkg-configuration']['default-registry'].baseline -ne $vcpkgCommit) {
            throw 'The selected ref uses a different vcpkg baseline. Update the local tool pin after reviewing CI.'
        }
        if (!$ResumeRun) {
            Invoke-BuildCommand (Join-Path $layout.Vcpkg 'vcpkg.exe') @('install', '--triplet', $triplet,
                "--x-install-root=$($env:VCPKG_INSTALLED_ROOT)")
            Invoke-BuildCommand $cargo @('fetch', '--locked', '--target', 'x86_64-pc-windows-msvc')
            # Same Windows Rust targets and features as build.py.
            Invoke-BuildCommand $cargo @('build', '--locked', '--release', '-p', 'dylib_virtual_display')
            Invoke-BuildCommand $cargo @('build', '--locked', '--release', '--lib', '--features', 'hwcodec,vram,flutter')
        }
        $rustLibrary = Join-Path $source 'target\release\librustdesk.dll'
        $virtualDisplay = Join-Path $source 'target\release\dylib_virtual_display.dll'
        Assert-X64Executable $rustLibrary
        Assert-X64Executable $virtualDisplay
        Push-Location -LiteralPath (Join-Path $source 'flutter')
        try {
            Invoke-BuildCommand $layout.FlutterExe $flutterBuildArguments
        } finally {
            Pop-Location
        }
        if (!(Test-FlutterEngine $layout)) { throw 'The custom engine cache changed during the build.' }

        $release = Join-Path $source 'flutter\build\windows\x64\runner\Release'
        Copy-Item -LiteralPath $virtualDisplay -Destination $release -Force
        foreach ($file in @('YES_Desk.exe', 'librustdesk.dll', 'dylib_virtual_display.dll', 'flutter_windows.dll',
                'data\app.so', 'data\icudtl.dat')) {
            if (!(Test-Path -LiteralPath (Join-Path $release $file) -PathType Leaf)) { throw "Release is missing $file." }
        }
        $version = [regex]::Match((Get-Content -LiteralPath 'Cargo.toml' -Raw), '(?m)^version\s*=\s*"(\d+\.\d+\.\d+)"').Groups[1].Value
        if (!$version) { throw 'Could not determine the three-part build version from Cargo.toml.' }
        $packaging = Join-Path $run "package-$stamp"
        New-Item -ItemType Directory -Path $packaging | Out-Null
        $dist = Join-Path $packaging 'rustdesk'
        Copy-Item -LiteralPath $release -Destination $dist -Recurse
        Assert-X64Executable (Join-Path $dist 'YES_Desk.exe') 'YES_Desk.exe'
        foreach ($dll in @('librustdesk.dll', 'dylib_virtual_display.dll', 'flutter_windows.dll')) {
            Assert-X64Executable (Join-Path $dist $dll)
        }
        $engineHash = (Get-FileHash -LiteralPath (Join-Path $layout.EngineDir 'flutter_windows.dll')).Hash
        if (!(Test-PinnedHash (Join-Path $dist 'flutter_windows.dll') $engineHash)) {
            throw 'The release payload does not contain the configured Flutter Engine DLL.'
        }
        $driver = Get-PinnedDownload $layout 'driver'
        [IO.Compression.ZipFile]::ExtractToDirectory($driver, $dist)
        if (!(Test-Path -LiteralPath (Join-Path $dist 'usbmmidd_v2\usbmmIdd.inf') -PathType Leaf)) {
            throw 'The driver archive did not yield its expected INF file.'
        }

        $msiArchive = Join-Path $packaging 'msi-source.tar'
        Invoke-BuildCommand $git @('-C', $repoRoot, 'archive', '--format=tar', "--output=$msiArchive",
            $commit, 'res/msi', 'res/icon.ico')
        Invoke-BuildCommand (Find-Application 'tar.exe') @('-xf', $msiArchive, '-C', $packaging)
        $msiDir = Join-Path $packaging 'res\msi'
        Push-Location -LiteralPath $msiDir
        try {
            Invoke-BuildCommand $layout.Python @('preprocess.py', '--yesdesk', '-d', '../../rustdesk',
                '--product-url', 'https://github.com/B1ssmuth/rustdesk',
                '--support-url', 'https://github.com/B1ssmuth/rustdesk/issues')
            Restore-MsiPackages $layout $vs $msiDir
            Invoke-BuildCommand $vs.MSBuild @('msi.sln', '-p:Configuration=Release', '-p:Platform=x64',
                '-p:TargetVersion=Windows10', '-nr:false', "-bl:$packaging\msbuild.binlog")
        } finally {
            Pop-Location
        }
        $msi = Join-Path $msiDir 'Package\bin\x64\Release\en-us\Package.msi'
        Assert-YesDeskMsi $msi $version
        Copy-Item -LiteralPath $msi -Destination (Join-Path $dist 'YES_Desk.msi')

        # Reproduce the portable-only manifest edit in the snapshot.
        $manifest = Join-Path $source 'res\manifest.xml'
        $originalManifest = [IO.File]::ReadAllBytes($manifest)
        $lines = Get-Content -LiteralPath $manifest | Where-Object { $_ -cnotmatch 'dpiAware' }
        Push-Location -LiteralPath (Join-Path $source 'libs\portable')
        try {
            Set-Content -LiteralPath $manifest -Value $lines -Encoding utf8
            Invoke-BuildCommand $layout.Python @('generate.py', '-f', $dist, '-o', '.', '-e', 'YES_Desk.exe')
        } finally {
            [IO.File]::WriteAllBytes($manifest, $originalManifest)
            Pop-Location
        }
        if (!(Test-PinnedHash 'Cargo.lock' $cargoLockHash) -or !(Test-PinnedHash 'flutter\pubspec.lock' $pubLockHash)) {
            throw 'Cargo.lock or pubspec.lock changed during the build.'
        }
        $portable = Join-Path $source 'target\release\rustdesk-portable-packer.exe'
        Assert-X64Executable $portable 'YES_Desk.exe'
        $msiHash = (Get-FileHash -LiteralPath $msi).Hash
        Assert-EmbeddedMsi (Join-Path $source 'libs\portable\data.bin') $portable $msiHash

        New-Item -ItemType Directory -Path $output | Out-Null
        $prefix = "YES_Desk-$version-x86_64"
        Copy-Item -LiteralPath $msi -Destination (Join-Path $output "$prefix.msi")
        Copy-Item -LiteralPath $portable -Destination (Join-Path $output "$prefix.exe")
        Get-ChildItem -LiteralPath $output -File | Get-FileHash -Algorithm SHA256 | ForEach-Object {
            "$($_.Hash.ToLowerInvariant())  $(Split-Path -Leaf $_.Path)"
        } | Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Encoding ascii
        Write-Host "Verified Windows x64 artifacts: $output"
    } finally {
        Pop-Location
    }
} catch {
    Write-Host "Build stopped: $_" -ForegroundColor Red
    throw
} finally {
    if ($log) { Stop-Transcript | Out-Null }
    $lock.Dispose()
}
