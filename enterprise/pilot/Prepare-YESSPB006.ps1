#Requires -Version 7.2
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory)][string] $Msi,
    [Parameter(Mandatory)][string] $BackupDirectory
)
if ($env:COMPUTERNAME -ine 'YESSPB-006') { throw 'Run this on YESSPB-006.' }
& (Join-Path $PSScriptRoot 'Prepare-PilotPc.ps1') -Role Endpoint -Msi $Msi `
    -BackupDirectory $BackupDirectory
