#Requires -Version 7.2
param(
    [Parameter(Mandatory)][ValidateSet('Admin', 'Endpoint')][string] $Role,
    [Parameter(Mandatory)][string] $Msi,
    [Parameter(Mandatory)][string] $BackupDirectory,
    [switch] $InstallClean
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (!$IsWindows) { throw 'Run on the designated Windows PC.' }
$msi = (Get-Item -LiteralPath $Msi).FullName
$package = Split-Path -Leaf $msi
if ($package -notmatch '^YES_Desk-Enterprise-\d+\.\d+\.\d+-x86_64\.msi$') { throw 'Expected the Enterprise x64 MSI.' }
$checksums = Join-Path (Split-Path -Parent $msi) 'SHA256SUMS.txt'
$expected = @(
    Get-Content -LiteralPath $checksums | Where-Object { $_ -match "^([a-fA-F0-9]{64})\s+$([regex]::Escape($package))$" }
)
if ($expected.Count -ne 1 -or ($expected[0] -split '\s+')[0] -ne (Get-FileHash -LiteralPath $msi).Hash) {
    throw 'MSI SHA-256 mismatch. Verify the manifest against the separately supplied digest.'
}
$signature = (Get-AuthenticodeSignature -LiteralPath $msi).Status
Write-Host "MSI signature: $signature"

$backup = [IO.Path]::GetFullPath($BackupDirectory)
if ($backup -notmatch '^[A-Za-z]:\\' -or (Test-Path -LiteralPath $backup)) {
    throw 'Specify a new local backup directory.'
}
$parent = Get-Item -LiteralPath (Split-Path -Parent $backup)
if (!$parent.PSIsContainer -or $parent.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
    throw 'Use an existing local parent directory without a junction.'
}
$current = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @($current, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
}
[IO.FileSystemAclExtensions]::CreateDirectory($acl, $backup) | Out-Null
$serviceNames = @('RustDesk', 'YES Desk', 'YESDeskAgent')
$services = @(Get-CimInstance Win32_Service | Where-Object { $_.Name -in $serviceNames })
$services | Select-Object Name, State, StartMode, StartName, PathName |
    Export-Csv -LiteralPath (Join-Path $backup 'services.csv') -NoTypeInformation
$products = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match '^(RustDesk|YES Desk|YESDesk)' })
$products | Select-Object DisplayName, DisplayVersion, PSChildName, InstallLocation |
    Export-Csv -LiteralPath (Join-Path $backup 'products.csv') -NoTypeInformation

$homes = [ordered]@{ user = $env:APPDATA }
if ($Role -eq 'Endpoint') {
    $homes.system = Join-Path $env:SystemRoot 'System32\config\systemprofile\AppData\Roaming'
    $homes.localservice = Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\AppData\Roaming'
    $homes.networkservice = Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Roaming'
    $homes.programdata = $env:ProgramData
    $identity = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid
    Set-Content -LiteralPath (Join-Path $backup 'machine-guid.txt') -Value $identity
    Get-ChildItem Cert:\LocalMachine\My | Select-Object Thumbprint, Subject, Issuer, NotAfter |
        Export-Csv -LiteralPath (Join-Path $backup 'certificates.csv') -NoTypeInformation
}
foreach ($name in $homes.Keys) {
    foreach ($product in @('RustDesk','YES Desk','YESDesk','YESDeskAgent',
            'com.yesapart\RustDesk','com.yesapart\YES Desk')) {
        $source = Join-Path $homes[$name] $product
        if (!(Test-Path -LiteralPath $source -PathType Container)) { continue }
        $root = Get-Item -LiteralPath $source
        if ($root.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { throw "Unexpected config junction: $source" }
        $label = $product -replace '\\', '-'
        $dest = Join-Path $backup "$name-$label"
        & robocopy.exe $source $dest /E /COPY:DAT /DCOPY:DAT /XJ /R:0 /W:0 /NFL /NDL /NJH /NJS /NP
        if ($LASTEXITCODE -ge 8) { throw "Configuration backup failed: $source" }
    }
}
foreach ($reg in @('HKCU\SOFTWARE\RustDesk','HKLM\SOFTWARE\RustDesk','HKLM\SOFTWARE\YES Apart\YES Desk')) {
    if (Test-Path -LiteralPath ("Registry::" + $reg)) {
        $output = Join-Path $backup (($reg -replace '[^a-zA-Z0-9]+','-') + '.reg')
        & reg.exe export $reg $output /y
        if ($LASTEXITCODE -ne 0) { throw "Registry backup failed: $reg" }
    }
}
Write-Host "Backup written to $backup. Retain it on the original PC."
$running = @(Get-Process -Name 'rustdesk','YES_Desk','YESDeskAgent' -ErrorAction SilentlyContinue)
if ($services.Count -or $products.Count -or $running.Count) {
    Write-Host 'Existing installation detected. This unified MSI does not provide a verified migration path.'
    if ($InstallClean) { throw 'Clean installation blocked by detected services or products.' }
    return
}
if ($InstallClean) {
    $log = Join-Path $backup 'install.log'
    $proc = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -WindowStyle Hidden -Wait -PassThru `
        -ArgumentList @('/i', ('"' + $msi + '"'), '/qn', '/norestart', '/l*v', ('"' + $log + '"'))
    if ($proc.ExitCode -notin 0, 3010) { throw "Windows Installer exited with $($proc.ExitCode). See $log." }
    Write-Host "Windows Installer exit code $($proc.ExitCode). See $log."
}
