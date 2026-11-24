#Requires -Version 7.2
[CmdletBinding(DefaultParameterSetName = 'Diagnostic')]
param(
    [string] $Root,
    [ValidateRange(1, 1000)][int] $MinFreeGiB = 80,
    [Parameter(ParameterSetName = 'Diagnostic')][switch] $Diagnostic,
    [Parameter(Mandatory, ParameterSetName = 'Install')][switch] $Install
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'windows-build-common.ps1')
. (Join-Path $PSScriptRoot 'windows-build-flutter.ps1')

function Install-VsBuildTools($Layout) {
    $systemVolume = [IO.Path]::GetPathRoot($Layout.VsInstall)
    Assert-FreeSpace $systemVolume 20
    $answer = Read-Host "Visual Studio Build Tools $($pins.vs.version) requires administrator rights. Install into '$($Layout.VsInstall)'? [y/N]"
    if ($answer -notmatch '^(y|yes)$') { throw 'Visual Studio installation was declined.' }

    $bootstrapper = Get-PinnedDownload $Layout 'vs'
    $signature = Get-AuthenticodeSignature -LiteralPath $bootstrapper
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN=Microsoft Corporation(?:,|$)') {
        throw "Visual Studio bootstrapper did not pass Microsoft Authenticode validation: $($signature.Status)."
    }
    $arguments = @('--passive', '--norestart', '--wait', '--installPath', ('"{0}"' -f $Layout.VsInstall))
    foreach ($component in $vsComponents) { $arguments += @('--add', $component) }
    Write-Host "> $bootstrapper $($arguments -join ' ')"
    $process = Start-Process -FilePath $bootstrapper -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -eq 3010 -or $process.ExitCode -eq 1641) {
        throw 'Visual Studio setup requires a restart. Restart Windows and re-run setup.'
    }
    if ($process.ExitCode -ne 0) {
        throw "Visual Studio setup returned $($process.ExitCode). See the dd_*.log files in the installer account's TEMP directory."
    }
}

function Install-ManagedTool($Layout, [string] $Id, [string] $Destination, [string] $SevenZip) {
    if (Test-Path -LiteralPath $Destination) {
        throw "Managed $Id installation is incomplete or different at $Destination. Move that directory before retrying."
    }
    $archive = Get-PinnedDownload $Layout $Id
    $stage = New-BuildStage $Layout
    try {
        switch ($Id) {
            'flutter' {
                [IO.Compression.ZipFile]::ExtractToDirectory($archive, $stage)
                $SDK = Join-Path $stage 'flutter'
                if (!(Test-Path -LiteralPath (Join-Path $SDK 'bin\flutter.bat'))) { throw 'Flutter archive layout is unexpected.' }
                Set-Content -LiteralPath (Join-Path $SDK '.yesdesk-sdk.sha256') -Value $pins.flutter.sha256 -NoNewline
                Publish-ToolDirectory $Layout $SDK $Destination
            }
            'llvm' {
                Invoke-BuildCommand $SevenZip @('x', '-y', "-o$stage", $archive)
                if (!(Test-Path -LiteralPath (Join-Path $stage 'bin\libclang.dll'))) { throw 'LLVM archive layout is unexpected.' }
                $version = Invoke-BuildCommand (Join-Path $stage 'bin\clang.exe') @('--version') -Capture
                if ($version -notmatch '\b15\.0\.6\b') { throw 'LLVM did not report version 15.0.6.' }
                Set-Content -LiteralPath (Join-Path $stage '.yesdesk-llvm.sha256') -Value $pins.llvm.sha256 -NoNewline
                Publish-ToolDirectory $Layout $stage $Destination
            }
            'dotnet' {
                [IO.Compression.ZipFile]::ExtractToDirectory($archive, $stage)
                if (!(Test-Path -LiteralPath (Join-Path $stage "sdk\$($pins.dotnet.version)\MSBuild.dll"))) {
                    throw '.NET SDK archive layout is unexpected.'
                }
                Publish-ToolDirectory $Layout $stage $Destination
            }
            'python' {
                [IO.Compression.ZipFile]::ExtractToDirectory($archive, $stage)
                $python = Join-Path $stage 'tools'
                if (!(Test-Path -LiteralPath (Join-Path $python 'python.exe')) -or
                    !(Test-Path -LiteralPath (Join-Path $python 'Lib\site-packages\pip\__init__.py'))) {
                    throw 'CPython NuGet archive did not contain the interpreter and pip.'
                }
                Publish-ToolDirectory $Layout $python $Destination
            }
        }
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-BuildStage $Layout $stage }
    }
}

function Install-YesDeskRust($Layout) {
    $rustup = Join-Path $Layout.CargoBin 'rustup.exe'
    if (!(Test-PinnedHash $rustup $pins.rustup.sha256)) {
        if (Test-Path -LiteralPath $rustup) { throw "Unrecognized Rustup at $rustup. Use a clean build root or move the existing installation." }
        $bootstrapper = Get-PinnedDownload $Layout 'rustup'
        Invoke-BuildCommand $bootstrapper @('-y', '--no-modify-path', '--default-host', 'x86_64-pc-windows-msvc',
            '--default-toolchain', 'none', '--profile', 'minimal')
    }
    Invoke-BuildCommand $rustup @('toolchain', 'install', $rustToolchain, '--profile', 'minimal',
        '--component', 'rustfmt', '--no-self-update')
}

function Install-YesDeskPython($Layout) {
    if (!(Test-PythonPackages $Layout)) {
        Install-ManagedTool $Layout 'python' $Layout.PythonDir
        if (!(Test-PythonPackages $Layout)) { throw 'The extracted CPython failed the version, architecture or pip check.' }
    }
    if (!(Test-PythonPackages $Layout -Brotli)) {
        $wheel = Get-PinnedDownload $Layout 'brotli'
        Invoke-BuildCommand $Layout.Python @('-I', '-m', 'pip', '--isolated', 'install', '--no-index', '--no-deps', $wheel)
    }
}

function Install-YesDeskVcpkg($Layout, [string] $Git) {
    if (!(Test-Path -LiteralPath $Layout.Vcpkg)) {
        $stage = New-BuildStage $Layout
        try {
            Invoke-BuildCommand $Git @('clone', '--no-checkout', 'https://github.com/microsoft/vcpkg.git', $stage)
            Invoke-BuildCommand $Git @('-C', $stage, 'checkout', '--detach', $vcpkgCommit)
            Publish-ToolDirectory $Layout $stage $Layout.Vcpkg
        } finally {
            if (Test-Path -LiteralPath $stage) { Remove-BuildStage $Layout $stage }
        }
    }
    if (!(Test-Path -LiteralPath (Join-Path $Layout.Vcpkg '.git')) -or
        (Invoke-BuildCommand $Git @('-C', $Layout.Vcpkg, 'rev-parse', 'HEAD') -Capture) -ne $vcpkgCommit) {
        throw "Unexpected vcpkg checkout at $($Layout.Vcpkg). Expected $vcpkgCommit."
    }
    $destination = Join-Path $Layout.Vcpkg 'vcpkg.exe'
    if (!(Test-PinnedHash $destination $pins.vcpkg.sha256)) {
        $executable = Get-PinnedDownload $Layout 'vcpkg'
        Copy-Item -LiteralPath $executable -Destination $destination -Force
    }
    Invoke-BuildCommand $destination @('version')
}

function Initialize-WixPackages($Layout, $Vs) {
    if (Test-WixCache $Layout) { return }
    $stage = New-BuildStage $Layout
    try {
        $archive = Join-Path $stage 'msi.tar'
        Invoke-BuildCommand (Find-Application 'git.exe') @('-C', $repoRoot, 'archive', '--format=tar',
            "--output=$archive", 'HEAD', 'res/msi')
        Invoke-BuildCommand (Find-Application 'tar.exe') @('-xf', $archive, '-C', $stage)
        $msiDir = Join-Path $stage 'res\msi'
        Restore-MsiPackages $Layout $Vs $msiDir
        $wixDir = Join-Path $Layout.Root 'wix'
        New-Item -ItemType Directory -Path $wixDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $msiDir 'packages') -Destination $wixDir -Recurse -Force
    } finally {
        Remove-BuildStage $Layout $stage
    }
}

$layout = Get-YesDeskLayout $Root
$report = Get-EnvironmentReport $layout
if (!$Install) {
    Show-EnvironmentReport $layout $report
    return
}

$lock = Enter-BuildLock $layout
$log = $null
try {
    $log = Start-BuildLog $layout 'setup'
    Show-EnvironmentReport $layout $report
    if (!$report.Git -or !$report.Tar) { throw 'Git for Windows and the Windows tar.exe must be available on PATH.' }
    $sevenZip = Find-SevenZip
    if (!$report['LLVM 15.0.6 / libclang'] -and !$sevenZip) { throw 'LLVM 15.0.6 extraction requires the full 7-Zip console (7z.exe).' }
    $minimum = if ($report.Values -contains $false) { $MinFreeGiB } else { 5 }
    Assert-FreeSpace $layout.Volume $minimum
    $vs = Find-VsBuildTools
    if (!$vs) {
        Install-VsBuildTools $layout
        $vs = Find-VsBuildTools
        if (!$vs) { throw 'Visual Studio Setup completed but the required workload or a component is missing.' }
        if ($vs.Path -eq $layout.VsInstall -and $vs.Version -ne '17.14.37827.9') {
            throw "Expected new Build Tools $($pins.vs.version), but found build $($vs.Version)."
        }
    }
    Set-YesDeskEnvironment $layout
    Enter-YesDeskVsEnvironment $vs

    if (!$report['Flutter 3.24.5 (managed)']) { Install-ManagedTool $layout 'flutter' $layout.Flutter }
    if (!$report['LLVM 15.0.6 / libclang']) { Install-ManagedTool $layout 'llvm' $layout.Llvm $sevenZip }
    if (!$report[".NET SDK $($pins.dotnet.version)"]) { Install-ManagedTool $layout 'dotnet' $layout.Dotnet }
    if (!$report["Rust $rustToolchain + rustfmt"]) { Install-YesDeskRust $layout }
    Install-YesDeskPython $layout
    if (!$report["NuGet $($pins.nuget.version)"]) {
        Copy-Item -LiteralPath (Get-PinnedDownload $layout 'nuget') -Destination $layout.NuGet -Force
    }
    Install-YesDeskVcpkg $layout (Find-Application 'git.exe')
    Initialize-YesDeskFlutterEngine $layout
    Initialize-WixPackages $layout $vs

    $report = Get-EnvironmentReport $layout
    Show-EnvironmentReport $layout $report
    if ($report.Values -contains $false) { throw 'One or more tools failed the final setup check.' }
} catch {
    Write-Host "Setup stopped: $_" -ForegroundColor Red
    throw
} finally {
    if ($log) { Stop-Transcript | Out-Null }
    $lock.Dispose()
}
