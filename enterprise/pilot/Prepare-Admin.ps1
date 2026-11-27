#Requires -Version 7.2
param(
    [Parameter(Mandatory)][string] $Msi,
    [Parameter(Mandatory)][string] $BackupDirectory,
    [switch] $InstallClean
)
& (Join-Path $PSScriptRoot 'Prepare-PilotPc.ps1') -Role Admin -Msi $Msi `
    -BackupDirectory $BackupDirectory -InstallClean:$InstallClean
