#Requires -Version 7.2
[CmdletBinding(DefaultParameterSetName = 'Diagnostic')]
param(
    [string] $Root,
    [Parameter(ParameterSetName = 'Diagnostic')][switch] $Diagnostic,
    [Parameter(Mandatory, ParameterSetName = 'Configure')][switch] $Configure
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'windows-build-common.ps1')
. (Join-Path $PSScriptRoot 'windows-build-flutter.ps1')
$layout = Get-YesDeskLayout $Root
if (!$Configure) {
    Write-Host "Managed SDK: $($layout.Flutter)"
    Write-Host "Flutter SDK valid: $(Test-FlutterSdk $layout)"
    Write-Host "Engine and framework patch valid: $(Test-FlutterEngine $layout)"
    return
}

Assert-FreeSpace $layout.Volume 5
$lock = Enter-BuildLock $layout
$log = $null
try {
    $log = Start-BuildLog $layout 'flutter'
    Set-YesDeskEnvironment $layout
    Initialize-YesDeskFlutterEngine $layout
} catch {
    Write-Host "Flutter setup stopped: $_" -ForegroundColor Red
    throw
} finally {
    if ($log) { Stop-Transcript | Out-Null }
    $lock.Dispose()
}
