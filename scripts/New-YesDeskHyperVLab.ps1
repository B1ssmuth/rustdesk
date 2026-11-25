#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $LabRoot,
    [Parameter(Mandatory)][string] $OperatorVhdx,
    [Parameter(Mandatory)][string] $EndpointVhdx,
    [Parameter(Mandatory)][string] $BackendVhdx,
    [ValidatePattern('^[a-zA-Z0-9-]{1,32}$')][string] $Name = 'YESDesk38Lab',
    [switch] $Create
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $LabRoot).Path
$switch = "$Name-Private"
$machines = @(
    @{ Role = 'Operator'; Disk = $OperatorVhdx; IP = '192.168.237.21'; RAM = 4GB },
    @{ Role = 'Endpoint'; Disk = $EndpointVhdx; IP = '192.168.237.22'; RAM = 4GB },
    @{ Role = 'Backend'; Disk = $BackendVhdx; IP = '192.168.237.10'; RAM = 3GB }
)
foreach ($machine in $machines) {
    $disk = Get-Item -LiteralPath $machine.Disk
    if ($disk.PSIsContainer -or $disk.Extension -ne '.vhdx' -or $disk.DirectoryName -ne $root -or
        $disk.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        throw 'Use three dedicated VHDX copies directly inside the lab root.'
    }
    $machine.Disk = $disk.FullName
    $machine.VMName = "$Name-$($machine.Role)"
}
if (@($machines.Disk | Sort-Object -Unique).Count -ne 3) { throw 'Each VM requires its own disk.' }
$machines | ForEach-Object { Write-Host "$($_.VMName) $($_.IP)/24 $($_.Disk)" }
if (!$Create) { return }

$currentUser = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open an elevated PowerShell on the Hyper-V lab host.'
}
Import-Module Hyper-V
if ((Get-Service -Name vmms).Status -ne 'Running') { throw 'Hyper-V VM management service is not running.' }
if ((Get-Item -LiteralPath $root).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
    throw 'Use a dedicated lab directory with no junction.'
}
if ((Get-VMSwitch | Where-Object Name -eq $switch) -or (Get-VM | Where-Object Name -in $machines.VMName)) {
    throw 'A lab name already exists. Inspect the existing inventory before making further changes.'
}
$diskPaths = @(Get-VM | Get-VMHardDiskDrive | ForEach-Object Path)
foreach ($machine in $machines) {
    $disk = Get-VHD -Path $machine.Disk
    if ($disk.ParentPath -or $disk.Attached -or $machine.Disk -in $diskPaths) {
        throw "VHDX must be a detached, independent lab disk: $($machine.Disk)"
    }
}
New-VMSwitch -Name $switch -SwitchType Private | Out-Null
foreach ($machine in $machines) {
    $vm = New-VM -Name $machine.VMName -Generation 2 -Path $root -VHDPath $machine.Disk `
        -MemoryStartupBytes $machine.RAM -BootDevice VHD -SwitchName $switch
    Set-VMProcessor -VM $vm -Count 2
    if ($machine.Role -eq 'Backend') {
        Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
    } else {
        Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
        Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
        Enable-VMTPM -VM $vm
    }
    $adapter = @(Get-VMNetworkAdapter -VM $vm)
    if ($adapter.Count -ne 1 -or $adapter[0].SwitchName -ne $switch) {
        throw "Unexpected network attachment for $($vm.Name). Leave the VM powered off."
    }
}
Write-Host 'Lab VMs are powered off. Use VMConnect and configure the isolated guest addresses before testing.'
