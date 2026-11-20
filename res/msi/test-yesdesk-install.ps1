param(
    [Parameter(Mandatory)][string] $Msi,
    [Parameter(Mandatory)][string] $PortableExe
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') {
    throw 'Run on a disposable GitHub Actions Windows runner.'
}

function Assert-YesDesk($Condition, [string] $Message) {
    if (!$Condition) { throw $Message }
}

function Invoke-YesDeskMsi([string] $Arguments) {
    $process = Start-Process "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $Arguments -Wait -PassThru
    return $process.ExitCode
}

$msiFile = (Resolve-Path -LiteralPath $Msi).Path
$portable = (Get-Item -LiteralPath $PortableExe).VersionInfo
$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($msiFile, 0))

function Get-YesDeskMsiProperty([string] $Name) {
    $query = "SELECT ``Value`` FROM ``Property`` WHERE ``Property`` = '$Name'"
    $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @($query))
    try {
        [void] $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        try {
            return $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
        } finally {
            [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($record)
        }
    } finally {
        [void] $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
        [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
    }
}

$productCode = Get-YesDeskMsiProperty 'ProductCode'
Assert-YesDesk (Test-Path -LiteralPath $msiFile) 'MSI artifact is missing.'
Assert-YesDesk ($portable.ProductName -eq 'YES Desk') 'Portable EXE product name is incorrect.'
Assert-YesDesk ((Get-YesDeskMsiProperty 'ProductName') -eq 'YES Desk') 'MSI product name is incorrect.'
Assert-YesDesk ((Get-YesDeskMsiProperty 'Manufacturer') -eq 'YES Apart') 'MSI manufacturer is incorrect.'
Assert-YesDesk ((Get-YesDeskMsiProperty 'UpgradeCode') -eq '{1A8AC87B-B936-5AA9-AE11-219B6D3A8B59}') 'MSI UpgradeCode is incorrect.'
[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)

$uninstallRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$legacyKey = Join-Path $uninstallRoot 'YES Desk'
$arpKey = Join-Path $uninstallRoot $productCode
$installerKey = 'HKLM:\SOFTWARE\YES Apart\YES Desk\Installer'
$installDirectory = Join-Path $env:ProgramFiles 'YES Desk'
$runner = Join-Path $installDirectory 'YES_Desk.exe'
$serviceName = 'YES Desk'
Assert-YesDesk (!(Test-Path $legacyKey) -and !(Test-Path $installerKey) -and
    !(Test-Path $installDirectory) -and !(Get-Service $serviceName -ErrorAction SilentlyContinue)) 'The Windows runner has a previous installation.'

$temp = Join-Path $env:RUNNER_TEMP 'YES Desk MSI smoke'
New-Item -ItemType Directory $temp | Out-Null
$package = Join-Path $temp 'YES Desk.msi'
Copy-Item -LiteralPath $msiFile -Destination $package
function Assert-InstallState([string] $Exe, [string] $Expected) {
    $stdout = Join-Path $temp 'install-state.txt'
    $process = Start-Process -FilePath $Exe -ArgumentList '--install-state' -Wait -PassThru -RedirectStandardOutput $stdout
    Assert-YesDesk ($process.ExitCode -eq 0 -and
        (Select-String -LiteralPath $stdout -SimpleMatch $Expected -Quiet)) "Unexpected installation state for $Exe."
}

$portableCache = Join-Path $env:LOCALAPPDATA 'YES Desk Portable'
$portableRunner = Join-Path $portableCache 'YES_Desk.exe'
$embeddedMsi = Join-Path $portableCache 'YES_Desk.msi'
Assert-InstallState ((Resolve-Path -LiteralPath $PortableExe).Path) 'installed=false current_exe_installed=false'
Assert-YesDesk (Test-Path -LiteralPath $portableRunner) 'The portable launcher did not extract the branded runner.'
Assert-YesDesk ((Get-ChildItem -LiteralPath $portableCache -File -Filter '*.exe' |
    Where-Object Name -ne 'RuntimeBroker_rustdesk.exe').Count -eq 1) 'The portable payload contains duplicate runners.'
Assert-YesDesk ((Get-FileHash -LiteralPath $embeddedMsi).Hash -eq (Get-FileHash -LiteralPath $package).Hash) 'The embedded MSI differs from the standalone artifact.'

$installArgs = "/i `"$package`" /qn /norestart YESDESK_LAUNCH_APP=0 YESDESK_DEFER_SERVICE_START=1 INSTALLPRINTER=0"

# Simulate a registered legacy native installation without providing any app files or settings.
$blockedLog = Join-Path $temp 'blocked.log'
New-Item $legacyKey | Out-Null
try {
    New-ItemProperty -Path $legacyKey -Name InstallLocation -Value (Join-Path $temp 'legacy') | Out-Null
    $code = Invoke-YesDeskMsi "$installArgs /l*v `"$blockedLog`""
    Assert-YesDesk ($code -eq 1603 -and
        (Select-String -LiteralPath $blockedLog -SimpleMatch 'An earlier or unidentified remote-support installation was found' -Quiet)) 'The MSI did not block a legacy registration.'
    Assert-YesDesk (!(Test-Path $installerKey)) 'Blocked install unexpectedly wrote the new registration.'
} finally {
    Remove-Item $legacyKey
}

$installLog = Join-Path $temp 'install.log'
try {
    $code = Invoke-YesDeskMsi "$installArgs /l*v `"$installLog`""
    Assert-YesDesk ($code -in 0, 3010) "MSI install returned $code. Log: $installLog"
    Assert-YesDesk (Test-Path -LiteralPath $runner) 'The native runner was not installed.'
    Assert-YesDesk ((Get-ChildItem -LiteralPath $installDirectory -File -Filter '*.exe').Count -eq 1) 'The install root contains duplicate runners.'

    $registration = Get-ItemProperty $installerKey
    Assert-YesDesk ($registration.ExecutableName -eq 'YES_Desk.exe' -and
        $registration.ProductCode -eq $productCode -and
        $registration.InstallLocation.TrimEnd('\') -eq $installDirectory) 'The native installation marker is incorrect.'
    $arp = Get-ItemProperty $arpKey
    Assert-YesDesk ($arp.DisplayName -eq 'YES Desk' -and $arp.Publisher -eq 'YES Apart') 'The Installed apps entry is incorrect.'
    Assert-YesDesk ($arp.SystemComponent -ne 1 -and !(Test-Path $legacyKey)) 'The MSI should publish only the standard ARP entry.'

    Assert-InstallState $runner 'installed=true current_exe_installed=true'
    Assert-InstallState $portableRunner 'installed=true current_exe_installed=false'
    $exe = (Get-Item -LiteralPath $runner).VersionInfo
    Assert-YesDesk ($exe.OriginalFilename -eq 'YES_Desk.exe' -and
        $exe.ProductName -eq 'YES Desk' -and $exe.CompanyName -eq 'YES Apart') 'The installed EXE metadata is incorrect.'

    $service = Get-CimInstance Win32_Service -Filter "Name = 'YES Desk'"
    Assert-YesDesk ($service.DisplayName -eq 'YES Desk Service' -and
        $service.StartMode -eq 'Auto' -and $service.State -eq 'Stopped' -and
        $service.PathName -eq "`"$runner`" --service") 'The SCM registration or service image path is incorrect.'
} finally {
    if (Test-Path $arpKey) {
        $uninstallLog = Join-Path $temp 'uninstall.log'
        $code = Invoke-YesDeskMsi "/x $productCode /qn /norestart /l*v `"$uninstallLog`""
        Assert-YesDesk ($code -in 0, 3010) "MSI uninstall returned $code. Log: $uninstallLog"
    }
}

Assert-YesDesk (!(Test-Path $runner) -and !(Test-Path $installerKey) -and !(Test-Path $arpKey)) 'Uninstall left the executable or registration.'
Assert-YesDesk (!(Get-Service $serviceName -ErrorAction SilentlyContinue)) 'Uninstall left the YES Desk service.'
Assert-InstallState $portableRunner 'installed=false current_exe_installed=false'
Write-Host 'Portable payload, installed state, MSI metadata, legacy guard, SCM registration and uninstall passed.'
