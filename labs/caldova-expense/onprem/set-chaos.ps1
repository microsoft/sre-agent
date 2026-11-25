<#
.SYNOPSIS
    Injects, inspects, or resets fault scenarios on the on-premises Caldova Expense server.
    Can be run locally on win-caldova-exp01 or invoked remotely via .\azure\invoke-arc-chaos.ps1.

.PARAMETER Mode
    - status          : Prints current chaos mode, IIS site/pool state, and /api/health output
    - sap-unavailable : Upstream SAP FI posting endpoint (10.42.1.25:8443) timeouts -> HTTP 502 + EventID 5002
    - sql-lock        : Database query lock/timeout on dbo.ExpenseReports -> HTTP 500 + EventID 5001 + high time-taken
    - db-auth-broken  : SQL database access denied -> HTTP 500 + EventID 5003
    - cpu-pressure    : Worker CPU saturation (~85-95% CPU) + EventID 5004
    - apppool-stop    : Stops IIS CaldovaExpensePool -> kernel HTTP 503 Service Unavailable
    - reset           : Restores IIS AppPool, resets chaos state to normal, flushes IIS logs, and verifies HTTP 200

.EXAMPLE
    .\onprem\set-chaos.ps1 -Mode sap-unavailable -DurationMinutes 20
    .\onprem\set-chaos.ps1 -Mode reset
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("status", "sap-unavailable", "sql-lock", "db-auth-broken", "cpu-pressure", "apppool-stop", "reset")]
    [string] $Mode,

    [int]    $DurationMinutes = 20,
    [int]    $Port = 8080,
    [string] $AppPoolName = "CaldovaExpensePool",
    [string] $SiteName = "CaldovaExpense"
)

$ErrorActionPreference = "Stop"

$dataRoot  = "C:\ProgramData\CaldovaExpense"
$chaosFile = Join-Path $dataRoot "chaos.json"
New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null

Import-Module WebAdministration -ErrorAction SilentlyContinue

function Show-Status {
    $poolState = if (Test-Path "IIS:\AppPools\$AppPoolName") { (Get-WebAppPoolState -Name $AppPoolName).Value } else { "Missing" }
    $siteState = if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) { (Get-Website -Name $SiteName).State } else { "Missing" }
    $chaosJson = if (Test-Path $chaosFile) { Get-Content -Path $chaosFile -Raw } else { '{"mode":"normal"}' }

    Write-Host "Host            : $env:COMPUTERNAME"
    Write-Host "IIS AppPool     : $AppPoolName ($poolState)"
    Write-Host "IIS Website     : $SiteName ($siteState)"
    Write-Host "Chaos State     : $($chaosJson.Trim())"

    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$Port/api/health" -UseBasicParsing -TimeoutSec 8
        Write-Host "Health Endpoint : HTTP $($resp.StatusCode) -> $($resp.Content)"
    }
    catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "Unreachable" }
        Write-Host "Health Endpoint : HTTP $code -> $($_.Exception.Message)"
    }
}

if ($Mode -eq "status") {
    Show-Status
    return
}

if ($Mode -eq "reset") {
    $normalState = @{
        mode       = "normal"
        updatedUtc = (Get-Date).ToUniversalTime().ToString("o")
        expiresUtc = $null
        notes      = "Reset to healthy baseline"
    }
    $normalState | ConvertTo-Json | Set-Content -Path $chaosFile -Encoding utf8

    if (Test-Path "IIS:\AppPools\$AppPoolName") {
        if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne "Started") {
            Start-WebAppPool -Name $AppPoolName
            Start-Sleep -Seconds 2
        }
    }
    if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) {
        if ((Get-Website -Name $SiteName).State -ne "Started") {
            Start-Website -Name $SiteName
        }
    }

    # Touch loopback admin endpoint so in-memory CPU workers stop immediately
    try {
        $body = @{ mode = "normal" } | ConvertTo-Json -Compress
        Invoke-WebRequest -Uri "http://localhost:$Port/api/admin/chaos" -Method Post -ContentType "application/json" -Body $body -UseBasicParsing -TimeoutSec 6 | Out-Null
    } catch {}

    & netsh.exe http flush logbuffer | Out-Null
    Write-Host "Reset complete." -ForegroundColor Green
    Show-Status
    return
}

if ($Mode -eq "apppool-stop") {
    if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
        throw "IIS AppPool '$AppPoolName' does not exist."
    }
    Stop-WebAppPool -Name $AppPoolName
    if ([System.Diagnostics.EventLog]::SourceExists("CaldovaExpense")) {
        [System.Diagnostics.EventLog]::WriteEntry("CaldovaExpense", "IIS Application Pool '$AppPoolName' was stopped during chaos drill (HTTP 503 Service Unavailable expected).", [System.Diagnostics.EventLogEntryType]::Error, 5005)
    }
    & netsh.exe http flush logbuffer | Out-Null
    Write-Host "Stopped IIS Application Pool '$AppPoolName'." -ForegroundColor Yellow
    Show-Status
    return
}

# Application-level chaos modes (sap-unavailable, sql-lock, db-auth-broken, cpu-pressure)
$expires = (Get-Date).ToUniversalTime().AddMinutes($DurationMinutes).ToString("o")
$stateObj = @{
    mode       = $Mode
    updatedUtc = (Get-Date).ToUniversalTime().ToString("o")
    expiresUtc = $expires
    notes      = "Injected on $env:COMPUTERNAME for $DurationMinutes minutes"
}
$stateObj | ConvertTo-Json | Set-Content -Path $chaosFile -Encoding utf8

try {
    $body = @{ mode = $Mode; durationMinutes = $DurationMinutes; notes = "Injected via set-chaos.ps1" } | ConvertTo-Json -Compress
    Invoke-WebRequest -Uri "http://localhost:$Port/api/admin/chaos" -Method Post -ContentType "application/json" -Body $body -UseBasicParsing -TimeoutSec 8 | Out-Null
} catch {}

# Trigger an immediate request so telemetry & Windows Event Log capture the onset right away
try {
    $probeBody = @{ employeeName = "Chaos Probe"; amount = 750.00; syncSap = $true } | ConvertTo-Json -Compress
    Invoke-WebRequest -Uri "http://localhost:$Port/api/expenses" -Method Post -ContentType "application/json" -Body $probeBody -UseBasicParsing -TimeoutSec 10 | Out-Null
} catch {}
try {
    Invoke-WebRequest -Uri "http://localhost:$Port/api/expenses?top=5" -UseBasicParsing -TimeoutSec 10 | Out-Null
} catch {}

& netsh.exe http flush logbuffer | Out-Null
Write-Host "Chaos mode '$Mode' active until $expires." -ForegroundColor Yellow
Show-Status
