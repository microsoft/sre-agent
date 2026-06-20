<#
.SYNOPSIS
    Deploys the demo Node.js app to the Azure App Service created by Terraform.

.DESCRIPTION
    Zips the app files (server.js + package.json) and deploys them to the
    App Service using az webapp deploy. Verifies the deployment by calling
    the /health endpoint.

.PARAMETER ResourceGroup
    Azure resource group name (default: iacdemo-rg)

.PARAMETER AppName
    App Service name (default: iacdemo-webapp)

.EXAMPLE
    .\deploy-app.ps1
    .\deploy-app.ps1 -ResourceGroup "mygroup-rg" -AppName "myapp-webapp"
#>

param(
    [string]$ResourceGroup = "iacdemo-rg",
    [string]$AppName = "iacdemo-webapp"
)

$ErrorActionPreference = "Stop"

$appDir = Join-Path $PSScriptRoot ".." "app"
$zipPath = Join-Path $appDir "app.zip"

Write-Host "`n=== Deploying Demo App ===" -ForegroundColor Cyan
Write-Host "Resource Group: $ResourceGroup"
Write-Host "App Service:    $AppName"
Write-Host ""

# Create zip
Write-Host "Creating deployment package..." -ForegroundColor Yellow
Push-Location $appDir
Compress-Archive -Path server.js, package.json -DestinationPath app.zip -Force
Pop-Location
Write-Host "Created: $zipPath"

# Deploy
Write-Host "Deploying to Azure App Service..." -ForegroundColor Yellow
az webapp deploy `
    --resource-group $ResourceGroup `
    --name $AppName `
    --src-path $zipPath `
    --type zip `
    --output none

Write-Host "Deployment complete." -ForegroundColor Green
Write-Host ""

# Verify
$url = "https://$AppName.azurewebsites.net/health"
Write-Host "Verifying deployment at $url ..." -ForegroundColor Yellow

# Wait a moment for the app to start
Start-Sleep -Seconds 5

try {
    $response = Invoke-RestMethod -Uri $url -TimeoutSec 30
    Write-Host "[SUCCESS] App is healthy!" -ForegroundColor Green
    Write-Host "  Status:    $($response.status)"
    Write-Host "  Timestamp: $($response.timestamp)"
}
catch {
    Write-Host "[WARNING] Health check failed: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  The app may still be starting up. Try again in 30 seconds:"
    Write-Host "  Invoke-RestMethod -Uri '$url'"
}

Write-Host ""
Write-Host "App endpoints:" -ForegroundColor Cyan
Write-Host "  /health             — Health check (200)"
Write-Host "  /api/data?size=100  — Data processing (has latency bug with large sizes)"
Write-Host "  /api/crash          — Simulated 500 error"
Write-Host "  /api/slow?delay=3000 — Delayed response"
Write-Host ""
