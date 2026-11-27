#Requires -Version 7.2
param([string] $Root)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot '..\..\scripts\windows-build-common.ps1')
. (Join-Path $PSScriptRoot '..\..\scripts\windows-build-verify.ps1')
$layout = Get-YesDeskLayout $Root
Set-YesDeskEnvironment $layout
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$dotnet = Join-Path $layout.Dotnet 'dotnet.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$run = Join-Path $layout.Runs "agent-$stamp-$PID"
$agent = Join-Path $run 'publish'
$packages = Join-Path $run 'artifacts'
$log = Start-BuildLog $layout 'agent-build'
try {
    $source = 'https://api.nuget.org/v3/index.json'
    Invoke-BuildCommand $dotnet @('publish', (Join-Path $PSScriptRoot 'WindowsAgent\WindowsAgent.csproj'),
        '-c', 'Release', '-o', $agent, "-p:RestoreSources=$source")
    $exe = Join-Path $agent 'YesDeskAgent.exe'
    Assert-X64Executable $exe
    Invoke-BuildCommand $exe @('--version')
    Invoke-BuildCommand $dotnet @('build', (Join-Path $PSScriptRoot 'msi\Agent.wixproj'),
        '-c', 'Release', '-o', $packages, "-p:AgentOutput=$agent", "-p:RestoreSources=$source")
    $msi = Get-Item -LiteralPath (Join-Path $packages 'YESDesk-Agent-x64.msi')
    Assert-YesDeskAgentMsi $msi.FullName
    $checksum = (Get-FileHash -LiteralPath $msi.FullName).Hash.ToLowerInvariant()
    "$checksum  $($msi.Name)" | Set-Content -LiteralPath (Join-Path $packages 'SHA256SUMS.txt') -Encoding ascii
    Write-Host "Verified Windows service MSI: $($msi.FullName)"
} finally {
    Stop-Transcript | Out-Null
}
