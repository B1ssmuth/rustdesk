#Requires -Version 7.2
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory)][uri] $Api,
    [securestring] $EnrollmentCode,
    [uri] $Broker,
    [string] $CertificateIssuer
)

$ErrorActionPreference = 'Stop'
if (!$IsWindows -or !$Api.IsAbsoluteUri -or $Api.Scheme -ne 'https' -or $Api.UserInfo -or
    $Api.Query -or $Api.Fragment) { throw 'An approved HTTPS Management API URL is required.' }
if ($Broker -and ($EnrollmentCode -or !$CertificateIssuer -or !$Broker.IsAbsoluteUri -or
    $Broker.Scheme -ne 'https' -or $Broker.UserInfo -or $Broker.Query -or $Broker.Fragment)) {
    throw 'Certificate enrollment requires HTTPS and an approved issuer without a manual code.'
}
$root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'YESDeskAgent'
$admin = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetOwner($admin)
$acl.SetAccessRuleProtection($true, $false)
foreach ($principal in @($admin, $system)) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $principal, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
}
if (!(Test-Path -LiteralPath $root)) {
    [IO.FileSystemAclExtensions]::CreateDirectory($acl, $root) | Out-Null
}
$directory = Get-Item -LiteralPath $root
if (!$directory.PSIsContainer -or $directory.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
    throw 'Unexpected agent state path.'
}
$presentAcl = Get-Acl -LiteralPath $root
$owner = $presentAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
if (!$presentAcl.AreAccessRulesProtected -or $owner -notin @($admin.Value, $system.Value) -or
    @($presentAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
        Where-Object { $_.IdentityReference.Value -notin @($admin.Value, $system.Value) }).Count) {
    throw 'Unexpected agent state directory permissions. Use a fresh protected directory.'
}
foreach ($entry in Get-ChildItem -LiteralPath $root -Force) {
    if ($entry.PSIsContainer -or $entry.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        throw 'Unexpected entry in agent state directory.'
    }
    $entryAcl = Get-Acl -LiteralPath $entry.FullName
    if ($entryAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @($admin.Value, $system.Value) -or
        @($entryAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
            Where-Object { $_.IdentityReference.Value -notin @($admin.Value, $system.Value) }).Count) {
        throw 'Unexpected agent state file permissions.'
    }
}
if (Test-Path -LiteralPath (Join-Path $root 'agent.token')) {
    throw 'This device already has an identity. Rotate it using the documented operator procedure.'
}
if ($Broker) {
    $config = Join-Path $root 'config.json'
    @{
        api = $Api.AbsoluteUri.TrimEnd('/')
        broker = $Broker.AbsoluteUri.TrimEnd('/')
        client_certificate_issuer = $CertificateIssuer
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $config -Encoding utf8NoBOM
    $configAcl = Get-Acl -LiteralPath $config
    $configAcl.SetOwner($admin)
    Set-Acl -LiteralPath $config -AclObject $configAcl
    return
}
if (!$EnrollmentCode) { $EnrollmentCode = Read-Host 'Device-specific enrollment code' -AsSecureString }
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($EnrollmentCode)
try {
    $code = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if ($code -cnotmatch '^[A-Za-z0-9_-]{43}$') { throw 'Invalid enrollment code format.' }
    $bytes = [Text.Encoding]::ASCII.GetBytes($code)
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        @{api = $Api.AbsoluteUri.TrimEnd('/')} | ConvertTo-Json -Compress |
            Set-Content -LiteralPath (Join-Path $root 'config.json') -Encoding utf8NoBOM
        [IO.File]::WriteAllBytes((Join-Path $root 'enrollment.token'), $protected)
        foreach ($name in @('config.json','enrollment.token')) {
            $path = Join-Path $root $name
            $fileAcl = Get-Acl -LiteralPath $path
            $fileAcl.SetOwner($admin)
            Set-Acl -LiteralPath $path -AclObject $fileAcl
        }
    } finally { [Array]::Clear($bytes) }
} finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
