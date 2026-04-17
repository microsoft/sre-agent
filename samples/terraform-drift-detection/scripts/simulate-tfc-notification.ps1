<#
.SYNOPSIS
    Simulates a Terraform Cloud run notification webhook.
    Sends a POST request to your Logic App's webhook URL (the auth bridge),
    which then forwards it (with Azure AD auth) to the SRE Agent HTTP Trigger.

.DESCRIPTION
    You don't need an actual Terraform Cloud account for this demo.
    This script sends the same JSON payload that TFC would send when a
    speculative plan completes and detects drift.

.PARAMETER LogicAppCallbackUrl
    The Logic App's webhook URL (from terraform output logic_app_callback_url)

.PARAMETER WorkspaceName
    Simulated TFC workspace name (default: iacdemo-production)

.EXAMPLE
    # Get the Logic App URL first:
    #   cd terraform
    #   $url = terraform output -raw logic_app_callback_url
    #
    # Then run this script:
    .\simulate-tfc-notification.ps1 -LogicAppCallbackUrl $url
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$LogicAppCallbackUrl,

    [string]$WorkspaceName = "iacdemo-production",
    [string]$OrgName = "contoso-sre",
    [string]$ResourceGroup = "iacdemo-rg",
    [string]$AppName = "iacdemo-webapp"
)

$ErrorActionPreference = "Stop"

# Build a payload that looks exactly like what Terraform Cloud sends
# when a run completes. See: https://developer.hashicorp.com/terraform/cloud-docs/api-docs/notification-configurations
$runId = "run-" + [guid]::NewGuid().ToString().Substring(0, 8)

$payload = @{
    payload_version                = 1
    notification_configuration_id  = "nc-demo-" + [guid]::NewGuid().ToString().Substring(0, 8)
    run_url                        = "https://app.terraform.io/app/$OrgName/workspaces/$WorkspaceName/runs/$runId"
    run_id                         = $runId
    run_message                    = "Nightly speculative plan detected drift on $AppName in $ResourceGroup"
    run_created_at                 = (Get-Date).AddMinutes(-5).ToString("o")
    run_created_by                 = "scheduled-drift-check"
    workspace_id                   = "ws-demo-" + [guid]::NewGuid().ToString().Substring(0, 8)
    workspace_name                 = $WorkspaceName
    organization_name              = $OrgName
    notifications                  = @(
        @{
            message        = "3 resources have changed: 1 tag drift (benign), 1 TLS downgrade (risky), 1 SKU change (critical)"
            trigger        = "run:completed"
            run_status     = "planned_and_finished"
            run_updated_at = (Get-Date).ToString("o")
            run_updated_by = "system"
        }
    )
} | ConvertTo-Json -Depth 5

Write-Host "`n=== Simulating Terraform Cloud Run Notification ===" -ForegroundColor Cyan
Write-Host "Workspace:  $WorkspaceName"
Write-Host "Run ID:     $runId"
Write-Host "Target URL: $LogicAppCallbackUrl"
Write-Host ""

Write-Host "Payload:" -ForegroundColor DarkGray
Write-Host $payload -ForegroundColor DarkGray
Write-Host ""

Write-Host "Sending webhook to Logic App..." -ForegroundColor Yellow

try {
    $response = Invoke-RestMethod -Uri $LogicAppCallbackUrl `
        -Method POST `
        -ContentType "application/json" `
        -Body $payload

    Write-Host "[SUCCESS] Logic App accepted the webhook." -ForegroundColor Green
    Write-Host ""
    Write-Host "What happens next:" -ForegroundColor Cyan
    Write-Host "  1. Logic App receives this payload"
    Write-Host "  2. Logic App acquires an Azure AD token using its Managed Identity"
    Write-Host "  3. Logic App forwards the payload to SRE Agent's HTTP Trigger"
    Write-Host "  4. SRE Agent creates a new investigation thread"
    Write-Host "  5. Agent uses the drift analysis skill to classify the drift"
    Write-Host ""
    Write-Host "Go to SRE Agent to see the new investigation thread!"
}
catch {
    Write-Host "[ERROR] Failed to call Logic App: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "  - Is the Logic App deployed? Run: terraform apply"
    Write-Host "  - Is the URL correct? Run: terraform output logic_app_callback_url"
    Write-Host "  - Check Logic App Run History in the Azure Portal"
}
