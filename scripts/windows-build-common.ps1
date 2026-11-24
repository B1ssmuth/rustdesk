# Shared paths and checks for the YES Desk Windows scripts.
$repoRoot = Split-Path -Parent $PSScriptRoot
$pins = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-build-dependencies.json') -Raw | ConvertFrom-Json -AsHashtable
$rustToolchain = '1.75.0-x86_64-pc-windows-msvc'
$flutterRevision = 'dec2ee5c1f98f8e84a7d5380c05eb8a3d0a81668'
$vcpkgCommit = '120deac3062162151622ca4860575a33844ba10b'
$triplet = 'x64-windows-static'
$wixVersion = '4.0.5'
$vsComponents = @(
    'Microsoft.VisualStudio.Workload.VCTools'
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
    'Microsoft.VisualStudio.Component.Windows11SDK.26100'
    'Microsoft.VisualStudio.Component.VC.CMake.Project'
    'Microsoft.Component.MSBuild'
)
$bridgeFiles = @(
    'src/bridge_generated.rs'
    'src/bridge_generated.io.rs'
    'flutter/lib/generated_bridge.dart'
    'flutter/lib/generated_bridge.freezed.dart'
    'flutter/macos/Runner/bridge_generated.h'
    'flutter/ios/Runner/bridge_generated.h'
)

function Get-YesDeskLayout([string] $Root) {
    if (!$IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64' -or
        [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64') {
        throw 'Run these scripts in PowerShell 7 x64 on Windows x64.'
    }
    if (!$Root) { $Root = Join-Path (Split-Path -Parent $repoRoot) 'YESDesk-local' }
    if ($Root -notmatch '^[a-zA-Z]:[\\/]') { throw '-Root must be an absolute local drive path.' }
    $Root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Root))
    $volume = [IO.Path]::GetPathRoot($Root)
    foreach ($parent in @($repoRoot, $env:ProgramFiles, [Environment]::GetFolderPath('ProgramFilesX86'), $env:SystemRoot)) {
        if ($Root -eq $parent -or $Root.StartsWith("$parent\", [StringComparison]::OrdinalIgnoreCase)) {
            throw '-Root must be outside the repository and Windows system directories.'
        }
    }
    if ($Root -eq $volume -or $repoRoot.StartsWith("$Root\", [StringComparison]::OrdinalIgnoreCase)) {
        throw '-Root must be a dedicated subdirectory separate from the repository.'
    }
    $toolsDir = Join-Path $Root 'tools'
    $flutterDir = Join-Path $toolsDir 'flutter-3.24.5'
    $pythonDir = Join-Path $toolsDir "python-$($pins.python.version)"
    $llvmDir = Join-Path $toolsDir 'llvm-15.0.6'
    $cargoDir = Join-Path $Root 'cargo'
    $engineDir = Join-Path $flutterDir 'bin\cache\artifacts\engine\windows-x64-release'
    for ($path = $engineDir; $path -ne $volume; $path = Split-Path -Parent $path) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($item -and $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            throw "The managed Flutter path must not contain junctions or symlinks: $path"
        }
    }
    @{
        Root = $Root
        Volume = $volume
        Downloads = Join-Path $Root 'downloads'
        Logs = Join-Path $Root 'logs'
        Runs = Join-Path $Root 'runs'
        Flutter = $flutterDir
        FlutterExe = Join-Path $flutterDir 'bin\flutter.bat'
        EngineDir = $engineDir
        EngineReceipt = Join-Path $flutterDir '.yesdesk-engine.json'
        Python = Join-Path $pythonDir 'python.exe'
        PythonDir = $pythonDir
        Llvm = $llvmDir
        LlvmBin = Join-Path $llvmDir 'bin'
        Dotnet = Join-Path $toolsDir "dotnet-$($pins.dotnet.version)"
        NuGet = Join-Path $toolsDir $pins.nuget.file
        Cargo = $cargoDir
        CargoBin = Join-Path $cargoDir 'bin'
        Rustup = Join-Path $Root 'rustup'
        RustBin = Join-Path $Root "rustup\toolchains\$rustToolchain\bin"
        Vcpkg = Join-Path $toolsDir 'vcpkg'
        VsInstall = Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\BuildTools-YESDesk'
    }
}

function Get-FreeGiB([string] $Volume) {
    $drive = [IO.DriveInfo]::new($Volume)
    if (!$drive.IsReady -or $drive.DriveType -notin @('Fixed', 'Removable')) {
        throw "Build volume $Volume is unavailable or is not a local drive."
    }
    [Math]::Round($drive.AvailableFreeSpace / 1GB, 1)
}

function Assert-FreeSpace([string] $Volume, [int] $Minimum) {
    $free = Get-FreeGiB $Volume
    if ($free -lt $Minimum) { throw "$Volume has $free GiB free. This step requires $Minimum GiB." }
}

function Find-Application([string] $Name) {
    (Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}

function Find-SevenZip {
    $command = Find-Application '7z.exe'
    if ($command) { return $command }
    $standardPath = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (Test-Path -LiteralPath $standardPath -PathType Leaf) { return $standardPath }
}

function Invoke-BuildCommand {
    param([string] $File, [string[]] $Arguments = @(), [switch] $Capture)
    Write-Host "> $File $($Arguments -join ' ')"
    if ($Capture) {
        $output = & $File @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $output | Out-Host
        if ($exitCode -ne 0) { throw "$File exited with code $exitCode." }
        return ($output -join [Environment]::NewLine)
    }
    & $File @Arguments 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$File exited with code $LASTEXITCODE." }
}

function Start-BuildLog($Layout, [string] $Name) {
    New-Item -ItemType Directory -Path $Layout.Logs -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $path = Join-Path $Layout.Logs "$Name-$stamp-$PID.log"
    Start-Transcript -LiteralPath $path -NoClobber | Out-Null
    Write-Host "Log: $path"
    $path
}

function Enter-BuildLock($Layout) {
    New-Item -ItemType Directory -Path $Layout.Root -Force | Out-Null
    try {
        [IO.File]::Open((Join-Path $Layout.Root '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch {
        throw "Cannot lock $($Layout.Root). Check permissions and close any other YES Desk setup/build process. $_"
    }
}

function New-BuildStage($Layout) {
    $stage = Join-Path $Layout.Root "stage-$([guid]::NewGuid().ToString('N'))"
    (New-Item -ItemType Directory -Path $stage).FullName
}

function Remove-BuildStage($Layout, [string] $Stage) {
    $resolved = (Resolve-Path -LiteralPath $Stage).ProviderPath
    if ((Split-Path -Parent $resolved) -ne $Layout.Root -or
        (Split-Path -Leaf $resolved) -notmatch '^stage-[0-9a-f]{32}$' -or
        (Get-Item -LiteralPath $resolved).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing to remove a directory outside the build staging area: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Publish-ToolDirectory($Layout, [string] $Stage, [string] $Destination) {
    $source = (Resolve-Path -LiteralPath $Stage).ProviderPath
    $destination = [IO.Path]::GetFullPath($Destination)
    if (!$source.StartsWith("$($Layout.Root)\stage-", [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Parent $destination) -ne (Join-Path $Layout.Root 'tools')) {
        throw "Unexpected managed tool paths: $source -> $destination"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    [IO.Directory]::Move($source, $destination)
}

function Test-PinnedHash([string] $Path, [string] $Sha256) {
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Sha256)
}

function Get-PinnedDownload($Layout, [string] $Id) {
    $asset = $pins[$Id]
    if (!$asset -or $asset.sha256 -notmatch '^[0-9a-f]{64}$' -or
        $asset.url -notmatch '^https://' -or [IO.Path]::GetFileName($asset.file) -ne $asset.file) {
        throw "Invalid trusted manifest entry: $Id."
    }
    $path = Join-Path $Layout.Downloads $asset.file
    if (Test-PinnedHash $path $asset.sha256) {
        Write-Host "Verified cached $Id ($($asset.sha256))"
        return $path
    }
    if (Test-Path -LiteralPath $path) {
        throw "SHA-256 mismatch for $path. Expected $($asset.sha256). Inspect the cached file and move it before retrying."
    }
    New-Item -ItemType Directory -Path $Layout.Downloads -Force | Out-Null
    $partial = "$path.$([guid]::NewGuid()).partial"
    try {
        Write-Host "Downloading $Id from $($asset.url)"
        Invoke-WebRequest -Uri $asset.url -OutFile $partial -TimeoutSec 1800
        if (!(Test-PinnedHash $partial $asset.sha256)) {
            throw "SHA-256 mismatch for $Id. Expected $($asset.sha256). The download was rejected."
        }
        Move-Item -LiteralPath $partial -Destination $path
        Write-Host "Verified $Id ($($asset.sha256))"
        return $path
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial }
    }
}

function Find-VsBuildTools {
    $vswhere = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (!(Test-Path -LiteralPath $vswhere -PathType Leaf)) { return }
    $result = & $vswhere -products '*' -version '[17.0,18.0)' -requires @vsComponents -format json -utf8
    if ($LASTEXITCODE -ne 0) { throw 'vswhere.exe could not enumerate Visual Studio installations.' }
    foreach ($instance in ($result | ConvertFrom-Json)) {
        $msbuild = Join-Path $instance.installationPath 'MSBuild\Current\Bin\amd64\MSBuild.exe'
        $devShell = Join-Path $instance.installationPath 'Common7\Tools\Launch-VsDevShell.ps1'
        $cmake = Join-Path $instance.installationPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
        if ((Test-Path -LiteralPath $msbuild) -and (Test-Path -LiteralPath $devShell) -and
            (Test-Path -LiteralPath $cmake) -and !$instance.isRebootRequired) {
            return [pscustomobject]@{
                Path = $instance.installationPath
                Version = $instance.installationVersion
                MSBuild = $msbuild
                DevShell = $devShell
                CMake = $cmake
            }
        }
    }
}

function Test-FlutterSdk($Layout) {
    $receipt = Join-Path $Layout.Flutter '.yesdesk-sdk.sha256'
    if (!(Test-Path -LiteralPath $Layout.FlutterExe -PathType Leaf) -or
        !(Test-Path -LiteralPath $receipt -PathType Leaf) -or
        (Get-Content -LiteralPath $receipt -Raw).Trim() -ne $pins.flutter.sha256) { return $false }
    $git = Find-Application 'git.exe'
    if (!$git) { return $false }
    $revision = & $git -C $Layout.Flutter rev-parse --verify HEAD 2>$null
    return $LASTEXITCODE -eq 0 -and $revision -eq $flutterRevision
}

function Get-FlutterFrameworkPatch {
    $path = Join-Path $repoRoot '.github\patches\flutter_3.24.4_dropdown_menu_enableFilter.diff'
    (Get-Content -LiteralPath $path -Raw).Replace("`r`n", "`n")
}

function Test-FlutterEngine($Layout) {
    if (!(Test-FlutterSdk $Layout) -or !(Test-Path -LiteralPath $Layout.EngineReceipt -PathType Leaf)) {
        return $false
    }
    $git = Find-Application 'git.exe'
    Get-FlutterFrameworkPatch | & $git -C $Layout.Flutter apply --ignore-space-change --reverse --check - 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    try {
        $receipt = Get-Content -LiteralPath $Layout.EngineReceipt -Raw | ConvertFrom-Json -AsHashtable
        if ($receipt.archive -ne $pins.engine.sha256 -or !$receipt.files.Contains('flutter_windows.dll')) {
            return $false
        }
        foreach ($file in $receipt.files.GetEnumerator()) {
            $path = [IO.Path]::GetFullPath((Join-Path $Layout.EngineDir $file.Key))
            if (!$path.StartsWith("$($Layout.EngineDir)\", [StringComparison]::OrdinalIgnoreCase) -or
                !(Test-PinnedHash $path $file.Value)) { return $false }
        }
        return $true
    } catch {
        Write-Warning "Unable to validate the Flutter Engine receipt: $_"
        return $false
    }
}

function Set-YesDeskEnvironment($Layout) {
    $env:CARGO_HOME = $Layout.Cargo
    $env:RUSTUP_HOME = $Layout.Rustup
    $env:RUSTUP_TOOLCHAIN = $rustToolchain
    $env:PUB_CACHE = Join-Path $Layout.Root 'pub-cache'
    $env:NUGET_PACKAGES = Join-Path $Layout.Root 'nuget-cache'
    $env:NUGET_HTTP_CACHE_PATH = Join-Path $Layout.Root 'nuget-http-cache'
    $env:DOTNET_ROOT = $Layout.Dotnet
    $env:DOTNET_MSBUILD_SDK_RESOLVER_CLI_DIR = $Layout.Dotnet
    $env:DOTNET_MSBUILD_SDK_RESOLVER_SDKS_DIR = Join-Path $Layout.Dotnet "sdk\$($pins.dotnet.version)\Sdks"
    $env:DOTNET_MSBUILD_SDK_RESOLVER_SDKS_VER = $pins.dotnet.version
    $env:DOTNET_CLI_HOME = Join-Path $Layout.Root 'dotnet-home'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:LIBCLANG_PATH = $Layout.LlvmBin
    $env:VCPKG_ROOT = $Layout.Vcpkg
    $env:VCPKG_INSTALLED_ROOT = Join-Path $Layout.Vcpkg 'installed'
    $env:VCPKG_DEFAULT_HOST_TRIPLET = $triplet
    $env:VCPKG_DISABLE_METRICS = '1'
    $env:VCPKG_BINARY_SOURCES = "clear;files,$($Layout.Root)\vcpkg-cache,readwrite"
    $env:CARGO_TARGET_DIR = $null
    $env:CARGO_BUILD_TARGET = $null
    $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.googleapis.com'
    $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
    $env:PUB_HOSTED_URL = 'https://pub.dev'
    $env:PYTHONNOUSERSITE = '1'
    $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
    $bins = @($Layout.CargoBin, (Split-Path -Parent $Layout.FlutterExe), $Layout.PythonDir, $Layout.LlvmBin,
        $Layout.Dotnet, (Split-Path -Parent $Layout.NuGet), $Layout.Vcpkg)
    $env:PATH = ($bins + $env:PATH) -join ';'
}

function Enter-YesDeskVsEnvironment($Vs) {
    if (!$Vs) { throw 'Visual Studio 2022 with the required C++ workload was not found. Run setup first.' }
    & $Vs.DevShell -Arch amd64 -HostArch amd64 -SkipAutomaticLocation | Out-Host
    if ($env:VSCMD_ARG_TGT_ARCH -notin @('x64', 'amd64') -or !(Find-Application 'cl.exe')) {
        throw "Failed to load the x64 MSVC environment from $($Vs.Path)."
    }
    $env:VCPKG_VISUAL_STUDIO_PATH = $Vs.Path
    Write-Host "MSBuild: $($Vs.MSBuild); MSVC: $env:VCToolsVersion; Windows SDK: $env:WindowsSDKVersion"
    Invoke-BuildCommand $Vs.CMake @('--version')
}

function Restore-MsiPackages($Layout, $Vs, [string] $MsiDir) {
    $config = Join-Path $MsiDir 'NuGet.Config'
    @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
'@ | Set-Content -LiteralPath $config -Encoding utf8
    $packages = Join-Path $MsiDir 'packages'
    Push-Location -LiteralPath $MsiDir
    try {
        Invoke-BuildCommand $Layout.NuGet @('restore', 'CustomActions\packages.config',
            '-PackagesDirectory', $packages, '-ConfigFile', $config, '-NonInteractive')
        Invoke-BuildCommand $Vs.MSBuild @('msi.sln', '-t:Restore', '-p:Configuration=Release',
            '-p:Platform=x64', '-p:TargetVersion=Windows10', "-p:RestoreConfigFile=$config", '-nr:false')
    } finally {
        Pop-Location
    }
}

function Test-WixCache($Layout) {
    foreach ($package in @('sdk', 'firewall.wixext', 'heat', 'netfx.wixext', 'ui.wixext', 'util.wixext')) {
        if (!(Test-Path -LiteralPath (Join-Path $Layout.Root "nuget-cache\wixtoolset.$package\$wixVersion\.nupkg.metadata"))) {
            return $false
        }
    }
    foreach ($package in @('DUtil', 'WcaUtil')) {
        if (!(Test-Path -LiteralPath (Join-Path $Layout.Root "wix\packages\WixToolset.$package.$wixVersion\build\WixToolset.$package.props"))) {
            return $false
        }
    }
    return $true
}

function Test-PythonPackages($Layout, [switch] $Brotli) {
    if (!(Test-Path -LiteralPath $Layout.Python -PathType Leaf)) { return $false }
    $code = "import sys,struct,pip; assert sys.version.split()[0]=='$($pins.python.version)' and struct.calcsize('P')==8"
    if ($Brotli) { $code += "; import brotli; assert brotli.__version__=='$($pins.brotli.version)'" }
    & $Layout.Python -I -B -c $code 2>$null
    return $LASTEXITCODE -eq 0
}

function Test-RustToolchain($Layout) {
    $rustc = Join-Path $Layout.RustBin 'rustc.exe'
    foreach ($tool in @('rustc.exe', 'cargo.exe', 'rustfmt.exe')) {
        if (!(Test-Path -LiteralPath (Join-Path $Layout.RustBin $tool) -PathType Leaf)) { return $false }
    }
    if (!(Test-PinnedHash (Join-Path $Layout.CargoBin 'rustup.exe') $pins.rustup.sha256)) { return $false }
    $details = (& $rustc -vV 2>$null) -join "`n"
    return $LASTEXITCODE -eq 0 -and $details -match '(?m)^release: 1\.75\.0$' -and
        $details -match '(?m)^host: x86_64-pc-windows-msvc$'
}

function Get-EnvironmentReport($Layout) {
    $vs = Find-VsBuildTools
    $git = Find-Application 'git.exe'
    $commit = if ($git -and (Test-Path -LiteralPath (Join-Path $Layout.Vcpkg '.git'))) {
        & $git -C $Layout.Vcpkg rev-parse --verify HEAD 2>$null
    }
    [ordered]@{
        Git = [bool] $git
        Tar = [bool] (Find-Application 'tar.exe')
        'Visual Studio 2022 / CMake / MSBuild' = [bool] $vs
        "Rust $rustToolchain + rustfmt" = Test-RustToolchain $Layout
        'Flutter 3.24.5 (managed)' = Test-FlutterSdk $Layout
        'Custom Flutter Engine and framework patch' = Test-FlutterEngine $Layout
        'LLVM 15.0.6 / libclang' = (Test-Path -LiteralPath (Join-Path $Layout.LlvmBin 'libclang.dll')) -and
            (Test-Path -LiteralPath (Join-Path $Layout.LlvmBin 'clang.exe')) -and
            ((Get-Content -LiteralPath (Join-Path $Layout.Llvm '.yesdesk-llvm.sha256') -Raw -ErrorAction SilentlyContinue) -eq $pins.llvm.sha256)
        "Python $($pins.python.version) / pip / Brotli" = Test-PythonPackages $Layout -Brotli
        "NuGet $($pins.nuget.version)" = Test-PinnedHash $Layout.NuGet $pins.nuget.sha256
        ".NET SDK $($pins.dotnet.version)" = (Test-Path -LiteralPath (Join-Path $Layout.Dotnet 'dotnet.exe')) -and
            (Test-Path -LiteralPath (Join-Path $Layout.Dotnet "sdk\$($pins.dotnet.version)\MSBuild.dll"))
        "WiX $wixVersion SDK and packages" = Test-WixCache $Layout
        "vcpkg $vcpkgCommit" = $commit -eq $vcpkgCommit -and
            (Test-PinnedHash (Join-Path $Layout.Vcpkg 'vcpkg.exe') $pins.vcpkg.sha256)
    }
}

function Show-EnvironmentReport($Layout, $Report) {
    Write-Host "Build root: $($Layout.Root)"
    Write-Host "Free space on $($Layout.Volume): $(Get-FreeGiB $Layout.Volume) GiB"
    $Report.GetEnumerator() | ForEach-Object {
        $state = if ($_.Value) { 'OK' } else { 'MISSING' }
        Write-Host "[$state] $($_.Key)"
    }
    if (!(Find-SevenZip) -and !$Report['LLVM 15.0.6 / libclang']) {
        Write-Host '[MISSING] 7-Zip command (needed to extract LLVM)'
    }
}
