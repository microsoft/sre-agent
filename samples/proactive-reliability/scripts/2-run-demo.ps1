<#
.SYNOPSIS
    Demo script for SRE Agent - performs swap, generates load, waits for remediation

.DESCRIPTION
    This script runs the live demo:
    1. Shows current state (prod=healthy, staging=slow)
    2. Swaps staging to production (bad deployment)
    3. Generates load to trigger alerts
    4. Waits for SRE Agent to detect and fix
    5. Verifies recovery

.PARAMETER RequestCount
    Number of requests to generate (default: 50)

.PARAMETER WaitForRecovery
    If true, polls health endpoint until recovery (default: true)

.EXAMPLE
    .\2-run-demo.ps1

.EXAMPLE
    .\2-run-demo.ps1 -RequestCount 100
#>

param(
    [Parameter(Mandatory=$false)]
    [int]$RequestCount = 50,

    [Parameter(Mandatory=$false)]
    [switch]$WaitForRecovery = $true
)

$ErrorActionPreference = "Stop"

# Get paths and load config
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigPath = Join-Path $ProjectRoot "demo-config.json"

if (-not (Test-Path $ConfigPath)) {
    Write-Host "[ERROR] demo-config.json not found. Run 1-setup-demo.ps1 first." -ForegroundColor Red
    exit 1
}

$config = Get-Content $ConfigPath | ConvertFrom-Json
$ResourceGroupName = $config.ResourceGroupName
$AppServiceName = $config.AppServiceName
$ProdUrl = $config.ProductionUrl
$StagingUrl = $config.StagingUrl

# Helper functions
function Write-Step { Write-Host "`n[STEP] $args" -ForegroundColor Cyan }
function Write-Success { Write-Host "[OK] $args" -ForegroundColor Green }
function Write-Info { Write-Host "[INFO] $args" -ForegroundColor Gray }
function Write-Warn { Write-Host "[WARN] $args" -ForegroundColor Yellow }
function Write-Err { Write-Host "[ERROR] $args" -ForegroundColor Red }

function Show-Banner {
    param([string]$Title, [string]$Color = "White")
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor $Color
    Write-Host "  $Title" -ForegroundColor $Color
    Write-Host ("=" * 60) -ForegroundColor $Color
    Write-Host ""
}

function Test-Endpoint {
    param([string]$Url, [string]$Name)
    
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-WebRequest -Uri $Url -TimeoutSec 60 -ErrorAction Stop
        $sw.Stop()
        return @{
            Success = $true
            StatusCode = $response.StatusCode
            TimeMs = $sw.ElapsedMilliseconds
        }
    } catch {
        $sw.Stop()
        return @{
            Success = $false
            StatusCode = 0
            TimeMs = $sw.ElapsedMilliseconds
            Error = $_.Exception.Message
        }
    }
}

# ============================================================
# INTRO
# ============================================================
Show-Banner "SRE AGENT DEMO" "Magenta"

Write-Host "  App Service:    $AppServiceName" -ForegroundColor White
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor White
Write-Host "  Production:     $ProdUrl" -ForegroundColor White
Write-Host "  Staging:        $StagingUrl" -ForegroundColor White
Write-Host ""

# ============================================================
# STEP 1: Show current state
# ============================================================
Write-Step "Checking current state"

Write-Info "Testing production (should be FAST)..."
$prodTest = Test-Endpoint -Url "$ProdUrl/api/products" -Name "Production"
if ($prodTest.Success) {
    if ($prodTest.TimeMs -lt 500) {
        Write-Success "Production: $($prodTest.TimeMs)ms - HEALTHY"
    } else {
        Write-Warn "Production: $($prodTest.TimeMs)ms - SLOW (unexpected)"
    }
} else {
    Write-Err "Production: Failed - $($prodTest.Error)"
}

Write-Info "Testing staging (should be SLOW)..."
$stagingTest = Test-Endpoint -Url "$StagingUrl/api/products" -Name "Staging"
if ($stagingTest.Success) {
    if ($stagingTest.TimeMs -gt 1000) {
        Write-Success "Staging: $($stagingTest.TimeMs)ms - SLOW (as expected)"
    } else {
        Write-Warn "Staging: $($stagingTest.TimeMs)ms - FAST (unexpected - should be slow)"
    }
} else {
    Write-Err "Staging: Failed - $($stagingTest.Error)"
}

# ============================================================
# STEP 2: Wait for user to start
# ============================================================
Write-Host ""
Show-Banner "READY TO SIMULATE BAD DEPLOYMENT" "Yellow"
Write-Host "  The next step will SWAP staging (bad code) to production." -ForegroundColor White
Write-Host "  This simulates a developer deploying buggy code." -ForegroundColor White
Write-Host ""
$null = Read-Host "  Press ENTER to perform the swap..."

# ============================================================
# STEP 3: Perform the swap
# ============================================================
Write-Step "Swapping staging to production..."

$swapStart = Get-Date
az webapp deployment slot swap `
    --resource-group $ResourceGroupName `
    --name $AppServiceName `
    --slot staging `
    --target-slot production `
    --output none 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Err "Swap failed!"
    exit 1
}

Write-Success "Swap completed at $($swapStart.ToString('HH:mm:ss'))"

# Wait for swap to stabilize
Write-Info "Waiting for swap to stabilize (15 seconds)..."
Start-Sleep -Seconds 15

# ============================================================
# STEP 4: Verify bad code is in production
# ============================================================
Show-Banner "BAD CODE IS NOW IN PRODUCTION!" "Red"

Write-Step "Verifying production is now slow..."
$prodTest = Test-Endpoint -Url "$ProdUrl/api/products" -Name "Production"
if ($prodTest.Success -and $prodTest.TimeMs -gt 1000) {
    Write-Err "Production: $($prodTest.TimeMs)ms - DEGRADED!"
} else {
    Write-Warn "Production: $($prodTest.TimeMs)ms (may take a moment to show degradation)"
}

# ============================================================
# STEP 5: Generate load
# ============================================================
Write-Step "Generating load to trigger alerts ($RequestCount requests)"
Write-Host ""

$endpoints = @(
    "/api/products",
    "/api/products/1",
    "/api/products/2",
    "/api/products/search?query=electronics"
)

$responseTimes = @()
$slowCount = 0
$criticalCount = 0

for ($i = 1; $i -le $RequestCount; $i++) {
    $endpoint = $endpoints | Get-Random
    $url = "$ProdUrl$endpoint"
    
    $result = Test-Endpoint -Url $url -Name "Request"
    
    if ($result.Success) {
        $responseTimes += $result.TimeMs
        
        if ($result.TimeMs -gt 2000) {
            Write-Host "  [$i/$RequestCount] $($result.TimeMs)ms " -NoNewline -ForegroundColor Red
            Write-Host "CRITICAL" -ForegroundColor Red
            $criticalCount++
        } elseif ($result.TimeMs -gt 1000) {
            Write-Host "  [$i/$RequestCount] $($result.TimeMs)ms " -NoNewline -ForegroundColor Yellow
            Write-Host "SLOW" -ForegroundColor Yellow
            $slowCount++
        } else {
            Write-Host "  [$i/$RequestCount] $($result.TimeMs)ms" -ForegroundColor Green
        }
    } else {
        Write-Host "  [$i/$RequestCount] FAILED" -ForegroundColor Red
    }
    
    # Small delay between requests
    Start-Sleep -Milliseconds 200
}

# Summary
Write-Host ""
if ($responseTimes.Count -gt 0) {
    $avg = [Math]::Round(($responseTimes | Measure-Object -Average).Average, 0)
    $max = ($responseTimes | Measure-Object -Maximum).Maximum
    Write-Host "  Load Summary:" -ForegroundColor Cyan
    Write-Host "    Requests: $RequestCount" -ForegroundColor White
    Write-Host "    Average:  ${avg}ms" -ForegroundColor White
    Write-Host "    Max:      ${max}ms" -ForegroundColor White
    Write-Host "    Slow:     $slowCount" -ForegroundColor Yellow
    Write-Host "    Critical: $criticalCount" -ForegroundColor Red
}

# ============================================================
# STEP 6: Wait for SRE Agent
# ============================================================
Show-Banner "WAITING FOR SRE AGENT" "Yellow"

Write-Host "  Azure Monitor alerts should fire within 5 minutes." -ForegroundColor White
Write-Host "  The SRE Agent will detect the issue and swap back." -ForegroundColor White
Write-Host ""
Write-Host "  Remediation command (for reference):" -ForegroundColor Gray
Write-Host "  az webapp deployment slot swap --resource-group $ResourceGroupName --name $AppServiceName --slot staging --target-slot production" -ForegroundColor DarkGray
Write-Host ""

if ($WaitForRecovery) {
    Write-Host "  Polling production health every 30 seconds..." -ForegroundColor White
    Write-Host "  (Press Ctrl+C to stop, or wait for recovery)" -ForegroundColor Gray
    Write-Host ""
    
    $recovered = $false
    $attempts = 0
    $maxAttempts = 20  # 10 minutes max wait
    
    while (-not $recovered -and $attempts -lt $maxAttempts) {
        $attempts++
        
        $result = Test-Endpoint -Url "$ProdUrl/api/products" -Name "Check"
        
        if ($result.Success -and $result.TimeMs -lt 500) {
            $recovered = $true
            Write-Host ""
            Show-Banner "RECOVERY DETECTED!" "Green"
            Write-Success "Production response time: $($result.TimeMs)ms"
            Write-Success "SRE Agent successfully remediated the issue!"
        } else {
            $status = if ($result.Success) { "$($result.TimeMs)ms" } else { "Failed" }
            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Production: $status - Still degraded..." -ForegroundColor Yellow
            Start-Sleep -Seconds 30
        }
    }
    
    if (-not $recovered) {
        Write-Warn "Max wait time reached. Check Azure Portal for alert status."
    }
} else {
    Write-Host "  Monitoring disabled. Check Azure Portal for alerts." -ForegroundColor Gray
}

# ============================================================
# DONE
# ============================================================
Write-Host ""
Show-Banner "DEMO COMPLETE" "Green"
Write-Host "  Production: $ProdUrl" -ForegroundColor White
Write-Host "  Staging:    $StagingUrl" -ForegroundColor White
Write-Host ""
Write-Host "  To reset: Run 1-setup-demo.ps1 again" -ForegroundColor Gray
Write-Host ""
