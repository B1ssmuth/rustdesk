#Requires -Version 7.2
[CmdletBinding()]
param([string] $ExpectedComputerName = 'YESSPB-006')

$ErrorActionPreference = 'Stop'
if (!$IsWindows -or $env:COMPUTERNAME -ine $ExpectedComputerName) {
    throw "Run locally on the Windows computer named $ExpectedComputerName."
}

$families = @{
    '{1A8AC87B-B936-5AA9-AE11-219B6D3A8B59}' = 'YES Desk'
    '{D3DC41E3-3C37-5D52-BB47-F6673705C01B}' = 'RustDesk or legacy YES Desk'
    '{4250C5DB-5E09-44AB-816C-4082BB30DEB6}' = 'Standalone YESDeskAgent'
}
$reasons = [Collections.Generic.List[string]]::new()
$serviceNames = @('RustDesk', 'YES Desk', 'YESDeskAgent')
$services = @(Get-CimInstance -ClassName Win32_Service | Where-Object Name -In $serviceNames)
$serviceReport = foreach ($service in $services) {
    # Only output the executable path. Service command arguments may contain credentials.
    $expanded = [Environment]::ExpandEnvironmentVariables($service.PathName)
    $binary = if ($expanded -match '^\s*"([^"]+\.exe)"') { $Matches[1] }
              elseif ($expanded -match '^\s*(.+?\.exe)(?:\s|$)') { $Matches[1] }
    $version = if ($binary -and (Test-Path -LiteralPath $binary -PathType Leaf)) {
        (Get-Item -LiteralPath $binary).VersionInfo
    }
    [pscustomobject]@{
        Name = $service.Name
        DisplayName = $service.DisplayName
        State = $service.State
        StartMode = $service.StartMode
        Account = $service.StartName
        Executable = $binary
        Product = $version.ProductName
        FileVersion = $version.FileVersion
    }
    if (!$version) { $reasons.Add("Cannot identify the binary for service $($service.Name).") }
    if ($service.StartName -notin @('LocalSystem', 'NT AUTHORITY\SYSTEM', 'NT AUTHORITY\LocalService', 'NT AUTHORITY\NetworkService')) {
        $reasons.Add("The profile for service account $($service.StartName) needs an ownership review.")
    }
}

function Read-MsiValue($database, [string] $name) {
    $sql = 'SELECT `Value` FROM `Property` WHERE `Property` = ''{0}''' -f $name
    $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @($sql))
    try {
        [void] $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        $row = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if ($row) {
            try { $row.GetType().InvokeMember('StringData', 'GetProperty', $null, $row, @(1)) }
            finally { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($row) }
        }
    } finally {
        [void] $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
        [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
    }
}

$uninstall = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$products = @(Get-ItemProperty -Path $uninstall -ErrorAction SilentlyContinue |
    Where-Object DisplayName -Match '^(RustDesk|YES Desk|YESDesk)')
$installer = New-Object -ComObject WindowsInstaller.Installer
try {
    $productReport = foreach ($entry in $products) {
        $productCode = $null
        $upgradeCode = $null
        $knownFamily = $null
        $cacheVerified = $false
        if ($entry.WindowsInstaller -eq 1 -and $entry.PSChildName -match '^\{[0-9a-fA-F-]{36}\}$') {
            $productCode = $entry.PSChildName
            try {
                [string] $package = $installer.GetType().InvokeMember(
                    'ProductInfo', 'GetProperty', $null, $installer, @($productCode, 'LocalPackage'))
                if ($package -and (Test-Path -LiteralPath $package -PathType Leaf)) {
                    $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($package, 0))
                    try {
                        $upgradeCode = Read-MsiValue $db 'UpgradeCode'
                        if ($upgradeCode) { $knownFamily = $families[$upgradeCode] }
                        $cacheVerified = (Read-MsiValue $db 'ProductCode') -eq $productCode
                    } finally { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($db) }
                }
            } catch {
                $reasons.Add("Cannot read the Windows Installer cache for $productCode.")
            }
        }
        if (!$cacheVerified -or !$knownFamily) {
            $reasons.Add("Original installer and service ownership need confirmation for $($entry.DisplayName).")
        }
        [pscustomobject]@{
            Name = $entry.DisplayName
            Publisher = $entry.Publisher
            Version = $entry.DisplayVersion
            ProductCode = $productCode
            UpgradeCode = $upgradeCode
            Family = $knownFamily
            CachedProductCodeMatches = $cacheVerified
        }
    }
} finally { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) }

$profiles = [ordered]@{
    CurrentUser   = $env:APPDATA
    LocalSystem   = Join-Path $env:SystemRoot 'System32\config\systemprofile\AppData\Roaming'
    LocalService  = Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\AppData\Roaming'
    NetworkService = Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Roaming'
}
$configReport = foreach ($profile in $profiles.Keys) {
    foreach ($brand in @('RustDesk', 'YES Desk')) {
        foreach ($relative in @("$brand\config", "com.yesapart\$brand\config")) {
            $directory = Join-Path $profiles[$profile] $relative
            $identity = $null
            $rendezvous = $null
            try {
                $identity = Test-Path -LiteralPath (Join-Path $directory "$brand.toml") -PathType Leaf
                $rendezvous = Test-Path -LiteralPath (Join-Path $directory "${brand}2.toml") -PathType Leaf
            } catch {
                $reasons.Add("Cannot read $directory. Check it from a local elevated session.")
            }
            [pscustomobject]@{
                Profile = $profile
                Directory = $directory
                IdentityFile = $identity
                RendezvousSettingsFile = $rendezvous
            }
        }
    }
}
$agent = Join-Path $env:ProgramData 'YESDeskAgent'
$agentToken = $null
$agentConfig = $null
try {
    $agentToken = Test-Path -LiteralPath (Join-Path $agent 'agent.token') -PathType Leaf
    $agentConfig = Test-Path -LiteralPath (Join-Path $agent 'config.json') -PathType Leaf
} catch {
    $reasons.Add('Cannot read the agent state directory. Check it from a local elevated session.')
}
if ($services.Name -contains 'RustDesk') {
    $reasons.Add('RustDesk and YES Desk use different service and profile names. The running profile, original package and an identity-preserving conversion require verification.')
}
if ($services.Count -or $products.Count) {
    $reasons.Add('The current unified MSI blocks in-place replacement of previously registered products and services.')
}
if ($services.Name -contains 'YESDeskAgent' -and $agentToken -eq $false) {
    $reasons.Add('The expected protected YESDeskAgent token file was not found.')
}
[pscustomobject]@{
    Computer = $env:COMPUTERNAME
    Status = if ($reasons.Count) { 'MigrationBlocked' } else { 'NoConflictingInstallationDetected' }
    Services = @($serviceReport)
    Products = @($productReport)
    TransportProfiles = @($configReport)
    AgentDirectory = $agent
    AgentTokenPresent = $agentToken
    AgentConfigPresent = $agentConfig
    CertificateThumbprints = @(Get-ChildItem Cert:\LocalMachine\My | ForEach-Object Thumbprint)
    Reasons = @($reasons.ToArray())
} | ConvertTo-Json -Depth 6
