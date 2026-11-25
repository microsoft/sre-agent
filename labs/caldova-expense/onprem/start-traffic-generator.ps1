<#
.SYNOPSIS
    Registers (or stops/removes) a lightweight Windows Scheduled Task that sends steady baseline
    traffic to http://localhost:8080 so IIS W3C logs, SQL Perf counters, and app logs continuously
    populate Log Analytics for SRE Agent investigations.

.EXAMPLE
    .\onprem\start-traffic-generator.ps1 -Port 8080
    .\onprem\start-traffic-generator.ps1 -Stop
#>
[CmdletBinding()]
param(
    [int]    $Port = 8080,
    [int]    $IntervalSeconds = 15,
    [string] $TaskName = "CaldovaExpense-BaselineTraffic",
    [switch] $Stop
)

$ErrorActionPreference = "Stop"

$runnerDir  = "C:\ProgramData\CaldovaExpense"
$runnerPath = Join-Path $runnerDir "traffic-loop.ps1"

if ($Stop) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Stopped and removed scheduled task '$TaskName'." -ForegroundColor Yellow
    }
    return
}

New-Item -ItemType Directory -Force -Path $runnerDir | Out-Null

$loopContent = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$baseUrl = 'http://localhost:$Port'
`$iteration = 0
while (`$true) {
    `$iteration++
    try {
        Invoke-WebRequest -Uri "`$baseUrl/api/expenses?top=10" -UseBasicParsing -TimeoutSec 12 | Out-Null
    } catch {}

    if ((`$iteration % 4) -eq 0) {
        try {
            `$body = @{
                employeeName  = 'Synthetic Monitor'
                employeeEmail = 'monitor@caldovagroup.com'
                department    = 'Finance Ops'
                category      = 'Reimbursement Check'
                amount        = 625.00
                description   = 'Automated hybrid synthetic transaction'
                syncSap       = `$true
            } | ConvertTo-Json -Compress
            Invoke-WebRequest -Uri "`$baseUrl/api/expenses" -Method Post -ContentType 'application/json' -Body `$body -UseBasicParsing -TimeoutSec 12 | Out-Null
        } catch {}
    }

    if ((`$iteration % 2) -eq 0) {
        try {
            Invoke-WebRequest -Uri "`$baseUrl/api/health" -UseBasicParsing -TimeoutSec 10 | Out-Null
        } catch {}
    }

    # Flush IIS HTTP.sys log buffer periodically so W3CIISLog ingests quickly during demos
    if ((`$iteration % 4) -eq 0) {
        & netsh.exe http flush logbuffer | Out-Null
    }

    Start-Sleep -Seconds $IntervalSeconds
}
"@

Set-Content -Path $runnerPath -Value $loopContent -Encoding utf8

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runnerPath`""
$trigger  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host "Started baseline traffic generator task '$TaskName' (every ${IntervalSeconds}s against port $Port)." -ForegroundColor Green
