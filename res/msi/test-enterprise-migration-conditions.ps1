#Requires -Version 7.2
param([Parameter(Mandatory)][string] $Msi)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../scripts/windows-build-verify.ps1')
[string] $package = (Get-Item -LiteralPath $Msi).FullName
Assert-YesDeskMsi $package '1.4.6'
Assert-CorporateMsi $package

$installer = New-Object -ComObject WindowsInstaller.Installer
try {
    $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($package, 0))
    try {
        $conditions = @(Get-MsiStrings $database 'SELECT `Condition` FROM `LaunchCondition`' |
            Where-Object { $_ -match 'YESDESK_(UPSTREAM_SERVICE|STANDALONE_AGENT_MSI)' })
        if ($conditions.Count -ne 2) { throw 'Expected both Enterprise ownership guards.' }
    } finally {
        [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
    }
} finally {
    [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
}

# MSIOPENPACKAGEFLAGS_IGNOREMACHINESTATE creates a session that cannot change the current machine.
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class YesDeskInstallerCondition {
    [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern uint MsiOpenPackageExW(string path, uint options, out uint handle);
    [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern uint MsiSetPropertyW(uint handle, string name, string value);
    [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int MsiEvaluateConditionW(uint handle, string condition);
    [DllImport("msi.dll", ExactSpelling = true)]
    public static extern uint MsiCloseHandle(uint handle);
}
'@

$cases = @(
    @{ Name = 'Clean'; Set = @(); Accept = $true },
    @{ Name = 'Native RustDesk service'; Set = @('YESDESK_UPSTREAM_SERVICE'); Accept = $false },
    @{ Name = 'RustDesk and separate agent'; Set = @('YESDESK_UPSTREAM_SERVICE','YESDESK_AGENT_EXISTING'); Accept = $false },
    @{ Name = 'Unregistered YES Desk service'; Set = @('YESDESK_EXISTING_SERVICE'); Accept = $false },
    @{ Name = 'Agent MSI with missing service'; Set = @('YESDESK_STANDALONE_AGENT_MSI'); Accept = $false },
    @{ Name = 'Earlier YES Desk product'; Set = @('WIX_UPGRADE_DETECTED','YESDESK_EXISTING_SERVICE'); Accept = $false },
    @{ Name = 'Same installed Enterprise product'; Set = @('Installed','YESDESK_EXISTING_SERVICE','YESDESK_AGENT_EXISTING'); Accept = $true }
)
foreach ($case in $cases) {
    [uint32] $handle = 0
    $rc = [YesDeskInstallerCondition]::MsiOpenPackageExW($package, 1, [ref] $handle)
    if ($rc) { throw "Could not open restricted MSI session (error $rc)." }
    try {
        foreach ($name in $case.Set) {
            $rc = [YesDeskInstallerCondition]::MsiSetPropertyW($handle, $name, '1')
            if ($rc) { throw "Could not set simulation property $name (error $rc)." }
        }
        $values = @($conditions | ForEach-Object {
            [YesDeskInstallerCondition]::MsiEvaluateConditionW($handle, $_)
        })
        if (($values | Where-Object { $_ -notin 0,1 }) -or (($values -notcontains 0) -ne $case.Accept)) {
            throw "Unexpected result for $($case.Name): $values."
        }
        Write-Host "$($case.Name): accepted=$($case.Accept)"
    } finally { [void] [YesDeskInstallerCondition]::MsiCloseHandle($handle) }
}
