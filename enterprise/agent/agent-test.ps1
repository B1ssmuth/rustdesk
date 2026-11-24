#Requires -Version 7.2
param(
    [Parameter(Mandatory)][uri] $Api,
    [Parameter(Mandatory)][guid] $DeviceId,
    [Parameter(Mandatory)][switch] $TestEnvironment,
    [ValidateSet('Enroll', 'Heartbeat', 'Session')][string] $Action = 'Heartbeat',
    [guid] $SessionInstance,
    [ValidateSet('logon','active','locked','disconnected','logoff')][string] $Kind
)

$ErrorActionPreference = 'Stop'
if (!$IsWindows -or !$TestEnvironment -or $Api.Scheme -ne 'https' -or
    $Api.UserInfo -or $Api.Query -or $Api.Fragment) {
    throw 'The Windows test agent requires an explicitly selected HTTPS lab endpoint.'
}

$state = Join-Path $env:LOCALAPPDATA 'YES Desk\Enterprise Test'
$credential = Join-Path $state "$DeviceId.token"
$base = $Api.AbsoluteUri.TrimEnd('/')

function Send-AgentRequest([string] $Path, [hashtable] $Payload, [securestring] $Secret) {
    $requestArgs = @{
        Uri = "$base/v1/agents/$Path"
        Method = 'Post'
        ContentType = 'application/json'
        Body = ($Payload | ConvertTo-Json -Depth 4 -Compress)
        TimeoutSec = 10
        MaximumRedirection = 0
    }
    if ($Secret) {
        $requestArgs.Authentication = 'Bearer'
        $requestArgs.Token = $Secret
    }
    try {
        Invoke-RestMethod @requestArgs
    } catch {
        $status = $_.Exception.Response.StatusCode
        throw "Management API request '$Path' failed (HTTP $status)."
    }
}

if ($Action -eq 'Enroll') {
    if (Test-Path -LiteralPath $credential) {
        throw 'This Windows user already has an identity for this device.'
    }
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    $code = Read-Host 'One-time lab enrollment code' -MaskInput
    try {
        $response = Send-AgentRequest 'enroll' @{device_id = "$DeviceId"; enrollment_code = $code}
        if ($response.agent_token -cnotmatch '^[A-Za-z0-9_-]{43}$') {
            throw 'The server did not provide a valid agent credential.'
        }
        $protected = ConvertTo-SecureString $response.agent_token -AsPlainText -Force |
            ConvertFrom-SecureString
        New-Item -ItemType File -Path $credential -Value $protected | Out-Null
    } finally {
        $code = $null
        $response = $null
    }
    return
}

$token = Get-Content -LiteralPath $credential -Raw | ConvertTo-SecureString
if ($Action -eq 'Heartbeat') {
    $machine = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $disks = @(
        Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' |
            Select-Object -First 32 | ForEach-Object {
                @{name = [string] $_.DeviceID; bytes = [long] $_.Size}
            }
    )
    Send-AgentRequest 'heartbeat' @{
        os = [string] $os.Caption
        model = [string] $machine.Model
        cpu = [string] $cpu.Name
        ram_bytes = [long] $machine.TotalPhysicalMemory
        disks = $disks
    } $token
    return
}

if ($SessionInstance -eq [guid]::Empty -or !$Kind) {
    throw 'Lab session reporting requires a session-instance UUID and a known event type.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($sessionId -eq 0 -or !$identity.User) {
    throw 'Run the lab session reporter within an interactive Windows session.'
}
$transport = if ($env:SESSIONNAME -like 'RDP-*') { 'rdp' } else { 'console' }
Send-AgentRequest 'session' @{
    event_id = [guid]::NewGuid().ToString()
    employee_sid = $identity.User.Value
    session_instance = "$SessionInstance"
    windows_session_id = $sessionId
    kind = $Kind
    transport = $transport
    observed_at = [DateTimeOffset]::UtcNow.ToString('O')
} $token
