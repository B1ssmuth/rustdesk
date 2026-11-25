#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Operator', 'Endpoint')][string] $Role,
    [Parameter(Mandatory)][string] $CaCertificate,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string] $CaSha256
)

$ErrorActionPreference = 'Stop'
$computer = Get-CimInstance Win32_ComputerSystem
$expectedName = "YD38-$Role"
if ($computer.PartOfDomain -or $computer.Name -ne $expectedName -or
    $computer.Manufacturer -ne 'Microsoft Corporation' -or $computer.Model -ne 'Virtual Machine') {
    throw "Use only the dedicated Hyper-V workgroup guest named $expectedName."
}
$active = @(Get-NetAdapter | Where-Object Status -eq 'Up')
if ($active.Count -ne 1 -or @(Get-NetRoute -ErrorAction Stop | Where-Object DestinationPrefix -in '0.0.0.0/0','::/0').Count) {
    throw 'The guest must have one active adapter and no default IPv4 or IPv6 route.'
}
$ca = Get-Item -LiteralPath $CaCertificate
if ($ca.Extension -ne '.cer' -or (Get-FileHash -LiteralPath $ca.FullName -Algorithm SHA256).Hash -ne $CaSha256) {
    throw 'Lab root certificate SHA-256 mismatch. Verify the digest on the backend console.'
}
$cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($ca.FullName)
if ($cert.Subject -ne 'CN=YESDesk 38 Lab Server CA' -or $cert.Issuer -ne $cert.Subject -or
    $cert.HasPrivateKey -or $cert.NotAfter -le (Get-Date)) {
    throw 'Unexpected lab root certificate.'
}

$ip = if ($Role -eq 'Operator') { '192.168.237.21' } else { '192.168.237.22' }
$index = $active[0].ifIndex
$addresses = @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 |
    Where-Object IPAddress -NotLike '169.254.*')
if ($addresses.Count -and ($addresses.Count -ne 1 -or $addresses[0].IPAddress -ne $ip -or $addresses[0].PrefixLength -ne 24)) {
    throw 'Unexpected IPv4 configuration. Recheck the guest network in Hyper-V.'
}
Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled
Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses
if (!$addresses.Count) { New-NetIPAddress -InterfaceIndex $index -IPAddress $ip -PrefixLength 24 | Out-Null }
if (!(Test-Path -LiteralPath "Cert:\LocalMachine\Root\$($cert.Thumbprint)")) {
    Import-Certificate -FilePath $ca.FullName -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
}
Write-Host "Guest $expectedName configured at $ip/24. Verify HTTPS with the backend IP 192.168.237.10."
