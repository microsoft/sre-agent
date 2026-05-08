<#
.SYNOPSIS
    Generates load on the demo app's /api/data endpoint to create latency data
    in Application Insights. This data is what the SRE Agent correlates with drift.

.DESCRIPTION
    Sends repeated requests to the /api/data endpoint with a configurable payload size.
    The app has an intentional O(n² log n) blocking bug that causes severe latency
    under load on a B1 App Service Plan. This creates the "incident" that motivates
    the on-call engineer to induce drift (scale up, change TLS, add tags).

    Run this AFTER deploying the app and BEFORE inducing drift,
    so Application Insights has latency data for the agent to find.

.PARAMETER AppUrl
    Base URL of the App Service (default: https://iacdemo-webapp.azurewebsites.net)

.PARAMETER Size
    Data size parameter for /api/data — larger = slower. 3000-5000 recommended.

.PARAMETER Requests
    Number of requests to send (default: 10)

.PARAMETER TimeoutSec
    Timeout per request in seconds (default: 120, since requests can take 30-60s)

.EXAMPLE
    .\generate-load.ps1
    .\generate-load.ps1 -Size 5000 -Requests 15
    .\generate-load.ps1 -AppUrl "https://myapp.azurewebsites.net" -Size 3000
#>

param(
    [string]$AppUrl = "https://iacdemo-webapp.azurewebsites.net",
    [int]$Size = 3000,
    [int]$Requests = 10,
    [int]$TimeoutSec = 120
)

$ErrorActionPreference = "Stop"
$endpoint = "$AppUrl/api/data?size=$Size"

Write-Host "`n=== Load Generator for SRE Agent IaC Demo ===" -ForegroundColor Cyan
Write-Host "Endpoint:   $endpoint"
Write-Host "Requests:   $Requests"
Write-Host "Size:       $Size (larger = slower due to O(n² log n) bug)"
Write-Host "Timeout:    ${TimeoutSec}s per request"
Write-Host ""
Write-Host "This will create latency data in Application Insights." -ForegroundColor Yellow
Write-Host "Expect 25-60 second response times and some 502 errors — that's the point!" -ForegroundColor Yellow
Write-Host ""

$results = @()
$startTime = Get-Date

for ($i = 1; $i -le $Requests; $i++) {
    Write-Host "[$i/$Requests] Sending request..." -ForegroundColor DarkGray -NoNewline
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $response = Invoke-RestMethod -Uri $endpoint -TimeoutSec $TimeoutSec
        $sw.Stop()
        $duration = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        $serverMs = $response.processingTimeMs
        Write-Host " ${duration}s (server: ${serverMs}ms)" -ForegroundColor Green
        $results += @{ Status = "OK"; Duration = $duration; ServerMs = $serverMs }
    }
    catch {
        $sw.Stop()
        $duration = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        $errorMsg = $_.Exception.Message
        if ($errorMsg -match "502") {
            Write-Host " ${duration}s — 502 Bad Gateway (server timed out)" -ForegroundColor Red
            $results += @{ Status = "502"; Duration = $duration; ServerMs = $null }
        }
        else {
            Write-Host " ${duration}s — Error: $errorMsg" -ForegroundColor Red
            $results += @{ Status = "Error"; Duration = $duration; ServerMs = $null }
        }
    }
}

$endTime = Get-Date
$totalTime = [math]::Round(($endTime - $startTime).TotalSeconds, 0)
$okCount = ($results | Where-Object { $_.Status -eq "OK" }).Count
$failCount = $Requests - $okCount
$avgDuration = [math]::Round(($results | Measure-Object -Property Duration -Average).Average, 1)

Write-Host "`n=== Load test complete ===" -ForegroundColor Cyan
Write-Host "Duration:     ${totalTime}s"
Write-Host "Successful:   $okCount / $Requests"
Write-Host "Failed:       $failCount / $Requests"
Write-Host "Avg response: ${avgDuration}s"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Wait 2-3 minutes for data to flow into Application Insights"
Write-Host "  2. Run .\induce-drift.ps1 to create the drift"
Write-Host "  3. Run .\simulate-tfc-notification.ps1 to trigger the agent"
Write-Host ""
