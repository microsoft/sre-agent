<#
.SYNOPSIS
    Setup script for SRE Agent Demo - deploys infrastructure and both app versions

.DESCRIPTION
    This script:
    1. Prompts for Azure subscription selection
    2. Deploys Azure infrastructure (App Service, App Insights, Alerts)
    3. Builds and deploys GOOD code to PRODUCTION
    4. Builds and deploys BAD code to STAGING
    
    After running, you'll have:
    - Production: Fast, healthy app
    - Staging: Slow, problematic app (ready to swap)

.PARAMETER ResourceGroupName
    Name of the Azure resource group to create/use

.PARAMETER AppServiceName
    Name of the App Service (must be globally unique)

.PARAMETER Location
    Azure region for deployment (default: westus2)

.PARAMETER SubscriptionId
    Azure subscription ID (optional - will prompt if not provided)

.EXAMPLE
    .\1-setup-demo.ps1 -ResourceGroupName "sre-demo-rg" -AppServiceName "sre-demo-app-12345"

.EXAMPLE
    .\1-setup-demo.ps1 -ResourceGroupName "sre-demo-rg" -AppServiceName "sre-demo-app-12345" -SubscriptionId "12345678-1234-1234-1234-123456789abc"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string]$AppServiceName,

    [Parameter(Mandatory=$false)]
    [string]$Location = "westus2",

    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId
)

$ErrorActionPreference = "Stop"

# Get paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$AppPath = Join-Path $ProjectRoot "SREPerfDemo"
$InfraPath = Join-Path $ProjectRoot "infrastructure"
$ControllerPath = Join-Path $AppPath "Controllers\ProductsController.cs"

# Helper functions
function Write-Step { Write-Host "`n[STEP] $args" -ForegroundColor Cyan }
function Write-Success { Write-Host "[OK] $args" -ForegroundColor Green }
function Write-Info { Write-Host "[INFO] $args" -ForegroundColor Gray }
function Write-Warn { Write-Host "[WARN] $args" -ForegroundColor Yellow }

# ============================================================
# STEP 0: Select Azure Subscription
# ============================================================
Write-Step "Checking Azure subscription"

# Get list of subscriptions
$subscriptions = az account list --query "[].{Name:name, Id:id, IsDefault:isDefault}" --output json | ConvertFrom-Json

if ($subscriptions.Count -eq 0) {
    Write-Error "No Azure subscriptions found. Please run 'az login' first."
    exit 1
}

if ($SubscriptionId) {
    # Use provided subscription
    $selectedSub = $subscriptions | Where-Object { $_.Id -eq $SubscriptionId }
    if (-not $selectedSub) {
        Write-Error "Subscription '$SubscriptionId' not found."
        exit 1
    }
    Write-Info "Using provided subscription: $($selectedSub.Name)"
} else {
    # Show subscription picker
    Write-Host ""
    Write-Host "  Available Azure Subscriptions:" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────" -ForegroundColor Gray
    
    for ($i = 0; $i -lt $subscriptions.Count; $i++) {
        $sub = $subscriptions[$i]
        $default = if ($sub.IsDefault) { " (current)" } else { "" }
        Write-Host "  [$($i + 1)] $($sub.Name)$default" -ForegroundColor White
        Write-Host "      $($sub.Id)" -ForegroundColor DarkGray
    }
    
    Write-Host ""
    $selection = Read-Host "  Select subscription (1-$($subscriptions.Count)) or press Enter for current"
    
    if ([string]::IsNullOrWhiteSpace($selection)) {
        $selectedSub = $subscriptions | Where-Object { $_.IsDefault -eq $true }
        if (-not $selectedSub) {
            $selectedSub = $subscriptions[0]
        }
    } else {
        $index = [int]$selection - 1
        if ($index -lt 0 -or $index -ge $subscriptions.Count) {
            Write-Error "Invalid selection"
            exit 1
        }
        $selectedSub = $subscriptions[$index]
    }
}

# Set the subscription
Write-Info "Setting subscription: $($selectedSub.Name)"
az account set --subscription $selectedSub.Id
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to set subscription"
    exit 1
}

$SubscriptionId = $selectedSub.Id
Write-Success "Using subscription: $($selectedSub.Name) ($SubscriptionId)"

# ============================================================
# STEP 1: Create Resource Group
# ============================================================
Write-Step "Creating resource group: $ResourceGroupName"

az group create --name $ResourceGroupName --location $Location --output none
Write-Success "Resource group ready"

# ============================================================
# STEP 2: Deploy Infrastructure
# ============================================================
Write-Step "Deploying infrastructure (App Service, App Insights, Alerts)"

$deploymentOutput = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file "$InfraPath\main.bicep" `
    --parameters appServiceName=$AppServiceName `
    --query "properties.outputs" `
    --output json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    Write-Error "Infrastructure deployment failed"
    exit 1
}

$prodUrl = $deploymentOutput.appServiceUrl.value
$stagingUrl = $deploymentOutput.stagingUrl.value
$appInsightsName = $deploymentOutput.applicationInsightsName.value

Write-Success "Infrastructure deployed"
Write-Info "  Production URL: $prodUrl"
Write-Info "  Staging URL: $stagingUrl"
Write-Info "  App Insights: $appInsightsName"

# ============================================================
# STEP 3: Build and Deploy GOOD code to Production
# ============================================================
Write-Step "Building GOOD (fast) version for production"

Push-Location $AppPath
try {
    # Ensure code has EnableSlowEndpoints = false
    $content = Get-Content $ControllerPath -Raw
    if ($content -match 'EnableSlowEndpoints = true') {
        $content = $content -replace 'private const bool EnableSlowEndpoints = true;', 'private const bool EnableSlowEndpoints = false;  // GOOD: Fast version'
        Set-Content $ControllerPath -Value $content
        Write-Info "Set EnableSlowEndpoints = false"
    }

    # Build
    Write-Info "Building..."
    dotnet publish -c Release -o ./publish-good --nologo -v q
    if ($LASTEXITCODE -ne 0) { throw "Build failed" }

    # Create zip
    if (Test-Path "./good-app.zip") { Remove-Item "./good-app.zip" -Force }
    Compress-Archive -Path "./publish-good/*" -DestinationPath "./good-app.zip" -Force

    # Deploy to production
    Write-Info "Deploying to production..."
    az webapp deploy --resource-group $ResourceGroupName --name $AppServiceName --src-path "./good-app.zip" --type zip --output none 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Deployment failed" }

    Write-Success "GOOD version deployed to production"
} finally {
    Pop-Location
}

# ============================================================
# STEP 4: Build and Deploy BAD code to Staging
# ============================================================
Write-Step "Building BAD (slow) version for staging"

Push-Location $AppPath
try {
    # Set EnableSlowEndpoints = true for bad version
    $content = Get-Content $ControllerPath -Raw
    $content = $content -replace 'private const bool EnableSlowEndpoints = false;.*', 'private const bool EnableSlowEndpoints = true;   // BAD: Slow version - simulates performance bug'
    Set-Content $ControllerPath -Value $content
    Write-Info "Set EnableSlowEndpoints = true"

    # Build
    Write-Info "Building..."
    dotnet publish -c Release -o ./publish-bad --nologo -v q
    if ($LASTEXITCODE -ne 0) { throw "Build failed" }

    # Create zip
    if (Test-Path "./bad-app.zip") { Remove-Item "./bad-app.zip" -Force }
    Compress-Archive -Path "./publish-bad/*" -DestinationPath "./bad-app.zip" -Force

    # Deploy to staging
    Write-Info "Deploying to staging..."
    az webapp deploy --resource-group $ResourceGroupName --name $AppServiceName --slot staging --src-path "./bad-app.zip" --type zip --output none 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Deployment failed" }

    Write-Success "BAD version deployed to staging"

    # Revert local code back to good version
    $content = Get-Content $ControllerPath -Raw
    $content = $content -replace 'private const bool EnableSlowEndpoints = true;.*', 'private const bool EnableSlowEndpoints = false;  // GOOD: Fast version'
    Set-Content $ControllerPath -Value $content
    Write-Info "Reverted local code to good version"

} finally {
    Pop-Location
}

# ============================================================
# STEP 5: Wait for apps to start and verify
# ============================================================
Write-Step "Waiting for apps to start (30 seconds)..."
Start-Sleep -Seconds 30

Write-Step "Verifying deployments"

# Test production
Write-Info "Testing production..."
try {
    $prodHealth = Invoke-RestMethod -Uri "$prodUrl/health" -TimeoutSec 30
    Write-Success "Production: $($prodHealth.status)"
} catch {
    Write-Warn "Production health check failed (may need more time to start)"
}

# Test staging
Write-Info "Testing staging..."
try {
    $stagingHealth = Invoke-RestMethod -Uri "$stagingUrl/health" -TimeoutSec 30
    Write-Success "Staging: $($stagingHealth.status)"
} catch {
    Write-Warn "Staging health check failed (may need more time to start)"
}

# ============================================================
# STEP 6: Save configuration
# ============================================================
$config = @{
    SubscriptionId = $SubscriptionId
    ResourceGroupName = $ResourceGroupName
    AppServiceName = $AppServiceName
    Location = $Location
    ProductionUrl = $prodUrl
    StagingUrl = $stagingUrl
    AppInsightsName = $appInsightsName
    SetupTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
} | ConvertTo-Json -Depth 2

$config | Set-Content "$ProjectRoot\demo-config.json"
Write-Info "Configuration saved to demo-config.json"

# ============================================================
# DONE
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  SETUP COMPLETE!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Production (GOOD): $prodUrl" -ForegroundColor White
Write-Host "  Staging (BAD):     $stagingUrl" -ForegroundColor White
Write-Host ""
Write-Host "  Next step: Run .\2-run-demo.ps1 to start the demo" -ForegroundColor Yellow
Write-Host ""
