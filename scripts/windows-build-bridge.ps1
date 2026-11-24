function Invoke-NativeBridge($Layout, [string] $Source) {
    $cargo = Join-Path $Layout.CargoBin 'cargo.exe'
    Invoke-BuildCommand $cargo @('install', 'cargo-expand', '--version', '=1.0.95', '--locked')
    Invoke-BuildCommand $cargo @('install', 'flutter_rust_bridge_codegen', '--version', '=1.80.1',
        '--features', 'uuid', '--locked')
    Push-Location -LiteralPath $Source
    try {
        $codegen = Join-Path $Layout.CargoBin 'flutter_rust_bridge_codegen.exe'
        Invoke-BuildCommand $codegen @('--rust-input', './src/flutter_ffi.rs', '--dart-output', './flutter/lib/generated_bridge.dart',
            '--c-output', './flutter/macos/Runner/bridge_generated.h', '--llvm-path', $Layout.Llvm)
        Copy-Item -LiteralPath 'flutter/macos/Runner/bridge_generated.h' -Destination 'flutter/ios/Runner/bridge_generated.h'
    } finally {
        Pop-Location
    }
}

function Invoke-WslBridge($Layout, [string] $Distribution, [string] $Source, [string] $Archive) {
    $wsl = Find-Application 'wsl.exe'
    if (!$wsl) { throw 'wsl.exe is unavailable. See the Windows local build guide for the optional WSL2 bridge.' }
    $state = Invoke-BuildCommand $wsl @('--list', '--verbose') -Capture
    if (($state -replace "`0", '') -notmatch "(?m)^\s*\*?\s*$([regex]::Escape($Distribution))\s+.+\s+2\s*\r?$") {
        throw "WSL2 distribution '$Distribution' was not found. Run wsl --list --verbose."
    }
    $flutterArchive = Get-PinnedDownload $Layout 'flutterLinux'
    $bootstrapper = Get-PinnedDownload $Layout 'rustupLinux'
    $shellScript = Join-Path (Split-Path -Parent $Source) 'generate-bridge.sh'
    $content = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'generate-windows-bridge-wsl.sh'))
    [IO.File]::WriteAllText($shellScript, $content.Replace("`r`n", "`n"))
    $paths = foreach ($path in @($shellScript, $Archive, $Source, $flutterArchive, $bootstrapper)) {
        (Invoke-BuildCommand $wsl @('-d', $Distribution, '--exec', 'wslpath', '-a', '-u', $path) -Capture).Trim()
    }
    Invoke-BuildCommand $wsl @('-d', $Distribution, '--exec', 'bash', $paths[0], $paths[1], $paths[2],
        $paths[3], $pins.flutterLinux.sha256, $paths[4], $pins.rustupLinux.sha256)
}

function Assert-BridgeFiles([string] $Source) {
    foreach ($relative in $bridgeFiles) {
        $file = Get-Item -LiteralPath (Join-Path $Source $relative) -ErrorAction SilentlyContinue
        if (!$file -or $file.Length -eq 0) { throw "Missing or empty generated bridge file: $relative." }
    }
    Write-Host "Verified all $($bridgeFiles.Count) bridge files."
}
