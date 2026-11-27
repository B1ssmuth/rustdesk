function Assert-X64Executable([string] $Path, [string] $OriginalName) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw "Missing DOS signature in $Path." }
        $reader.BaseStream.Position = 0x3c
        $reader.BaseStream.Position = $reader.ReadUInt32()
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) {
            throw "Expected an x64 PE file: $Path."
        }
    } finally {
        $reader.Dispose()
    }
    if ($OriginalName) {
        $version = (Get-Item -LiteralPath $Path).VersionInfo
        if ($version.OriginalFilename -ne $OriginalName -or $version.ProductName -ne 'YES Desk' -or
            $version.CompanyName -ne 'YES Apart') { throw "Unexpected YES Desk file metadata: $Path." }
    }
}

function Get-MsiStrings($Database, [string] $Query) {
    $view = $Database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $Database, @($Query))
    try {
        [void] $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        while ($record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)) {
            try {
                $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
            } finally {
                [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($record)
            }
        }
    } finally {
        [void] $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
        [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
    }
}

function Assert-YesDeskMsi([string] $Path, [string] $Version) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    try {
        $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        try {
            $properties = @{
                ProductName = 'YES Desk'
                Manufacturer = 'YES Apart'
                UpgradeCode = '{1A8AC87B-B936-5AA9-AE11-219B6D3A8B59}'
                ProductVersion = $Version
            }
            foreach ($entry in $properties.GetEnumerator()) {
                $query = 'SELECT `Value` FROM `Property` WHERE `Property` = ''{0}''' -f $entry.Key
                $value = Get-MsiStrings $database $query
                if ($entry.Key -eq 'ProductVersion') { $value = ($value -split '\.' | Select-Object -First 3) -join '.' }
                if ($value -ne $entry.Value) { throw "MSI property $($entry.Key) is '$value', expected '$($entry.Value)'." }
            }
            $files = @(Get-MsiStrings $database 'SELECT `FileName` FROM `File`' | ForEach-Object { ($_ -split '\|')[-1] })
            if (@($files -eq 'YES_Desk.exe').Count -ne 1 -or $files -match '\.msi$|^(rustdesk|YES Desk)\.exe$') {
                throw 'MSI file table has an unexpected runner or a nested MSI.'
            }
            $services = @(Get-MsiStrings $database 'SELECT `Name` FROM `ServiceInstall`')
            $controls = @(Get-MsiStrings $database 'SELECT `Name` FROM `ServiceControl`')
            if ($services.Count -ne 1 -or $services[0] -ne 'YES Desk' -or
                $controls.Count -ne 1 -or $controls[0] -ne 'YES Desk' -or
                $files -contains 'YesDeskAgent.exe') {
                throw 'The client MSI must own only the YES Desk transport service and contain no agent.'
            }
            $summary = $database.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $database, @(0))
            try {
                $template = $summary.GetType().InvokeMember('Property', 'GetProperty', $null, $summary, @(7))
                if ($template -notmatch '^x64;') { throw "MSI is not x64 (template '$template')." }
            } finally {
                [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary)
            }
        } finally {
            [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
        }
    } finally {
        [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
    }
}

function Assert-YesDeskAgentMsi([string] $Path) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    try {
        $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        try {
            $files = @(Get-MsiStrings $database 'SELECT `FileName` FROM `File`' | ForEach-Object { ($_ -split '\|')[-1] })
            $services = @(Get-MsiStrings $database 'SELECT `Name` FROM `ServiceInstall`')
            $controls = @(Get-MsiStrings $database 'SELECT `Name` FROM `ServiceControl`')
            if ($files.Count -ne 1 -or $files[0] -ne 'YesDeskAgent.exe' -or
                $services.Count -ne 1 -or $services[0] -ne 'YESDeskAgent' -or
                $controls.Count -ne 1 -or $controls[0] -ne 'YESDeskAgent') {
                throw 'The agent MSI must own only YESDeskAgent and contain only its executable.'
            }
            $summary = $database.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $database, @(0))
            try {
                $template = $summary.GetType().InvokeMember('Property', 'GetProperty', $null, $summary, @(7))
                if ($template -notmatch '^x64;') { throw "Agent MSI is not x64 (template '$template')." }
            } finally {
                [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary)
            }
        } finally {
            [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
        }
    } finally {
        [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
    }
}

function Assert-EmbeddedMsi([string] $Payload, [string] $Portable, [string] $MsiHash) {
    # The packer includes data.bin unchanged. Verify its presence before inspecting its records.
    $payloadBytes = [IO.File]::ReadAllBytes($Payload)
    $portableBytes = [IO.File]::ReadAllBytes($Portable)
    $portableText = [Text.Encoding]::Latin1.GetString($portableBytes)
    $expected = (Get-FileHash -LiteralPath $Payload).Hash
    $offset = $portableText.IndexOf('rustdesk', [StringComparison]::Ordinal)
    $digest = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $found = $false
    try {
        while ($offset -ge 0 -and $offset + $payloadBytes.Length -le $portableBytes.Length) {
            $digest.AppendData($portableBytes, $offset, $payloadBytes.Length)
            if ([Convert]::ToHexString($digest.GetHashAndReset()) -eq $expected) {
                $found = $true
                break
            }
            $offset = $portableText.IndexOf('rustdesk', $offset + 1, [StringComparison]::Ordinal)
        }
    } finally {
        $digest.Dispose()
    }
    if (!$found) { throw 'The portable EXE does not contain the generated payload.' }

    $reader = [IO.BinaryReader]::new([IO.MemoryStream]::new($payloadBytes, $false))
    try {
        if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(8)) -ne 'rustdesk') {
            throw 'Unexpected portable archive signature.'
        }
        $embedded = 0
        $runners = 0
        while ($reader.BaseStream.Position -lt $reader.BaseStream.Length) {
            $prefix = $reader.ReadBytes(4)
            if ([Text.Encoding]::ASCII.GetString($prefix) -ceq 'rust') {
                if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -cne 'desk') {
                    throw 'Malformed portable archive footer.'
                }
                break
            }
            [Array]::Reverse($prefix)
            $nameLength = [BitConverter]::ToUInt32($prefix, 0)
            if ($nameLength -lt 1 -or $nameLength -gt 32768) { throw 'Invalid portable record name length.' }
            $file = [Text.Encoding]::UTF8.GetString($reader.ReadBytes($nameLength)) -replace '^\.[\\/]', ''
            $size = $reader.ReadBytes(4)
            [Array]::Reverse($size)
            $length = [BitConverter]::ToUInt32($size, 0)
            $start = $reader.BaseStream.Position
            if ($start + $length + 32 -gt $reader.BaseStream.Length) { throw 'Truncated portable archive.' }
            if ($file -eq 'YES_Desk.exe') { $runners++ }
            if ($file -eq 'YES_Desk.msi') {
                $embedded++
                $compressed = [IO.MemoryStream]::new($payloadBytes, $start, $length, $false)
                $brotli = [IO.Compression.BrotliStream]::new($compressed, [IO.Compression.CompressionMode]::Decompress)
                $sha256 = [Security.Cryptography.SHA256]::Create()
                try {
                    if ([Convert]::ToHexString($sha256.ComputeHash($brotli)) -ne $MsiHash) {
                        throw 'The portable EXE embeds a different MSI.'
                    }
                } finally {
                    $sha256.Dispose()
                    $brotli.Dispose()
                }
            }
            $reader.BaseStream.Position = $start + $length + 32
        }
        $runner = [Text.Encoding]::UTF8.GetString($reader.ReadBytes($payloadBytes.Length - $reader.BaseStream.Position))
        if ($runner -notin '.\YES_Desk.exe', './YES_Desk.exe' -or $runners -ne 1 -or $embedded -ne 1) {
            throw 'The portable archive must contain one branded runner and one matching MSI.'
        }
    } finally {
        $reader.Dispose()
    }
}
