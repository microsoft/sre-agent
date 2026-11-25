<#
.SYNOPSIS
    Remotely injects, checks, or resets Caldova Expense chaos scenarios on win-caldova-exp01 from Azure
    using 'az connectedmachine run-command create' over Azure Arc's outbound 443 channel.

.PARAMETER Mode
    - status          : Check IIS AppPool/Site state, chaos.json, and /api/health
    - sap-unavailable : Simulate upstream SAP FI (10.42.1.25:8443) timeout -> HTTP 502 + EventID 5002
    - sql-lock        : Simulate SQL lock/query timeout on dbo.ExpenseReports -> HTTP 500 + EventID 5001
    - db-auth-broken  : Simulate SQL login/catalog permission failure -> HTTP 500 + EventID 5003
    - cpu-pressure    : Simulate worker pool CPU saturation (~85-95%) -> EventID 5004
    - apppool-stop    : Stop IIS CaldovaExpensePool -> HTTP 503 Service Unavailable + EventID 5005
    - reset           : Restore IIS AppPool, reset chaos mode to normal, and verify HTTP 200

.EXAMPLE
    .\azure\invoke-arc-chaos.ps1 -SubscriptionId "66a7fcba-dac3-46d8-b509-202f305618c8" -Mode sap-unavailable
    .\azure\invoke-arc-chaos.ps1 -SubscriptionId "66a7fcba-dac3-46d8-b509-202f305618c8" -Mode reset
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId = "",
    [string] $HybridResourceGroup = "rg-hybrid-connectivity",
    [string] $Location = "eastus2",
    [string] $MachineName = "win-caldova-exp01",

    [Parameter(Mandatory)]
    [ValidateSet("status", "sap-unavailable", "sql-lock", "db-auth-broken", "cpu-pressure", "apppool-stop", "reset")]
    [string] $Mode,

    [int] $DurationMinutes = 20,
    [int] $Port = 8080
)

$ErrorActionPreference = "Stop"

if ($SubscriptionId) {
    & az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription '$SubscriptionId'." }
}

& az extension add --name connectedmachine --upgrade --yes --only-show-errors | Out-Null

# Self-contained PowerShell payload executed on win-caldova-exp01 by the Arc agent
$remoteScript = @"
`$ErrorActionPreference = 'Stop'
`$mode = '$Mode'
`$duration = $DurationMinutes
`$port = $Port
`$pool = 'CaldovaExpensePool'
`$site = 'CaldovaExpense'
`$dataRoot = 'C:\ProgramData\CaldovaExpense'
`$chaosFile = Join-Path `$dataRoot 'chaos.json'
New-Item -ItemType Directory -Force -Path `$dataRoot | Out-Null
Import-Module WebAdministration -ErrorAction SilentlyContinue

if (`$mode -eq 'reset') {
    @{ mode = 'normal'; updatedUtc = (Get-Date).ToUniversalTime().ToString('o'); expiresUtc = `$null; notes = 'Reset via Azure Arc Run Command' } |
        ConvertTo-Json | Set-Content -Path `$chaosFile -Encoding utf8
    if ((Test-Path "IIS:\AppPools\`$pool") -and ((Get-WebAppPoolState -Name `$pool).Value -ne 'Started')) {
        Start-WebAppPool -Name `$pool
        Start-Sleep -Seconds 2
    }
    if ((Get-Website -Name `$site -ErrorAction SilentlyContinue) -and ((Get-Website -Name `$site).State -ne 'Started')) {
        Start-Website -Name `$site
    }
    try {
        Invoke-WebRequest -Uri "http://localhost:`$port/api/admin/chaos" -Method Post -ContentType 'application/json' -Body '{"mode":"normal"}' -UseBasicParsing -TimeoutSec 6 | Out-Null
    } catch {}
    & netsh.exe http flush logbuffer | Out-Null
}
elseif (`$mode -eq 'apppool-stop') {
    Stop-WebAppPool -Name `$pool
    if ([System.Diagnostics.EventLog]::SourceExists('CaldovaExpense')) {
        [System.Diagnostics.EventLog]::WriteEntry('CaldovaExpense', "IIS Application Pool '`$pool' stopped via Arc chaos drill (HTTP 503 expected).", [System.Diagnostics.EventLogEntryType]::Error, 5005)
    }
    & netsh.exe http flush logbuffer | Out-Null
}
elseif (`$mode -ne 'status') {
    `$exp = (Get-Date).ToUniversalTime().AddMinutes(`$duration).ToString('o')
    @{ mode = `$mode; updatedUtc = (Get-Date).ToUniversalTime().ToString('o'); expiresUtc = `$exp; notes = 'Injected via Azure Arc Run Command' } |
        ConvertTo-Json | Set-Content -Path `$chaosFile -Encoding utf8
    try {
        `$b = @{ mode = `$mode; durationMinutes = `$duration; notes = 'Injected via Azure Arc Run Command' } | ConvertTo-Json -Compress
        Invoke-WebRequest -Uri "http://localhost:`$port/api/admin/chaos" -Method Post -ContentType 'application/json' -Body `$b -UseBasicParsing -TimeoutSec 8 | Out-Null
    } catch {}
    try {
        Invoke-WebRequest -Uri "http://localhost:`$port/api/expenses" -Method Post -ContentType 'application/json' -Body '{"employeeName":"Arc Chaos Probe","amount":720.00,"syncSap":true}' -UseBasicParsing -TimeoutSec 10 | Out-Null
    } catch {}
    try {
        Invoke-WebRequest -Uri "http://localhost:`$port/api/expenses?top=5" -UseBasicParsing -TimeoutSec 10 | Out-Null
    } catch {}
    & netsh.exe http flush logbuffer | Out-Null
}

`$poolState = if (Test-Path "IIS:\AppPools\`$pool") { (Get-WebAppPoolState -Name `$pool).Value } else { 'Missing' }
`$chaosNow  = if (Test-Path `$chaosFile) { (Get-Content `$chaosFile -Raw).Trim() } else { '{"mode":"normal"}' }
`$healthStr = ''
try {
    `$r = Invoke-WebRequest -Uri "http://localhost:`$port/api/health" -UseBasicParsing -TimeoutSec 8
    `$healthStr = "HTTP `$(`$r.StatusCode) `$(`$r.Content)"
} catch {
    `$c = if (`$_.Exception.Response) { [int]`$_.Exception.Response.StatusCode } else { 'Unreachable' }
    `$healthStr = "HTTP `$c `$(`$_.Exception.Message)"
}
Write-Output "Host=`$env:COMPUTERNAME | AppPool=`$poolState | Chaos=`$chaosNow | Health=`$healthStr"
"@

Write-Host "Dispatching Arc Run Command (Mode='$Mode') to '$MachineName' in '$HybridResourceGroup'..." -ForegroundColor Cyan
$raw = & az connectedmachine run-command create `
    --resource-group $HybridResourceGroup `
    --machine-name $MachineName `
    --run-command-name "caldova-chaos" `
    --location $Location `
    --script $remoteScript `
    -o json

if ($LASTEXITCODE -ne 0) {
    throw "az connectedmachine run-command create failed."
}

$res = ($raw -join "`n") | ConvertFrom-Json
Write-Host "Execution State : $($res.instanceView.executionState) (exitCode=$($res.instanceView.exitCode))" -ForegroundColor Green
Write-Host "Output          :`n$($res.instanceView.output)"
if ($res.instanceView.error) {
    Write-Warning "Stderr          :`n$($res.instanceView.error)"
}
