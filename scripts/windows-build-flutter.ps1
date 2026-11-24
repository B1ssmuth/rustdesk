function Initialize-YesDeskFlutterEngine($Layout) {
    if (!(Test-FlutterSdk $Layout)) {
        throw 'The managed Flutter 3.24.5 SDK is missing or changed. Run setup-windows-build.ps1 -Install first.'
    }
    if (Test-FlutterEngine $Layout) {
        Write-Host 'The managed Flutter SDK already has the verified engine and framework patch.'
        return
    }
    $zip = Get-PinnedDownload $Layout 'engine'
    $git = Find-Application 'git.exe'
    Invoke-BuildCommand $Layout.FlutterExe @('precache', '--windows')
    if (!(Test-Path -LiteralPath $Layout.EngineDir -PathType Container)) {
        throw 'Flutter precache did not create the Windows x64 release engine cache.'
    }
    $patch = Get-FlutterFrameworkPatch
    $patch | & $git -C $Layout.Flutter apply --ignore-space-change --reverse --check - 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Applying the framework patch to $($Layout.Flutter)"
        $patch | & $git -C $Layout.Flutter apply --ignore-space-change --check -
        if ($LASTEXITCODE -ne 0) { throw 'The dropdown patch does not apply to the managed Flutter SDK.' }
        $patch | & $git -C $Layout.Flutter apply --ignore-space-change -
        if ($LASTEXITCODE -ne 0) { throw 'Git failed to apply the dropdown patch.' }
    }

    $stage = New-BuildStage $Layout
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $stage)
        foreach ($name in @('flutter_windows.dll', 'flutter_windows.dll.lib', 'flutter_texture_registrar.h', 'gen_snapshot.exe')) {
            if (!(Test-Path -LiteralPath (Join-Path $stage $name) -PathType Leaf)) {
                throw "The verified Flutter Engine archive has no $name at its root."
            }
        }
        $files = [ordered]@{}
        foreach ($file in Get-ChildItem -LiteralPath $stage -Recurse -File) {
            $relative = [IO.Path]::GetRelativePath($stage, $file.FullName)
            $destination = Join-Path $Layout.EngineDir $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
            $files[$relative] = (Get-FileHash -LiteralPath $file.FullName).Hash
        }
        @{ archive = $pins.engine.sha256; files = $files } | ConvertTo-Json |
            Set-Content -LiteralPath $Layout.EngineReceipt -Encoding utf8
        if (!(Test-FlutterEngine $Layout)) { throw 'Flutter Engine or framework patch verification failed.' }
    } finally {
        Remove-BuildStage $Layout $stage
    }
}
