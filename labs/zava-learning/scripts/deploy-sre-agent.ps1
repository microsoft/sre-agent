<#
.SYNOPSIS
  Provisions the Zava Learning SRE Agent against an existing lab resource group.
  Run this AFTER the main infra deployment. Discovers the App Insights / Log
  Analytics / managed-identity resources in the RG and deploys infra/modules/sre-agent.bicep.

.NOTES
  The lab infra is provisioned without the SRE Agent so the operator can provision
  it themselves (different access / cost considerations). This wrapper makes that a
  one-liner.
#>
param(
  [string]$ResourceGroup,
  [string]$Location,
  [string]$AgentName,
  [ValidateSet('PagerDuty','AzMonitor')]
  [string]$IncidentPlatform = "PagerDuty",
  [ValidateSet('Anthropic','MicrosoftFoundry')]
  [string]$ModelProvider,
  [string]$ModelName = "Automatic"
)
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

# Prompt for the core values (rg / model / region) if not supplied.
if (-not $ResourceGroup) { $ResourceGroup = Read-Host "Resource group (e.g. rg-zava-learning-demo)" }
if (-not $ModelProvider) {
  $mp = Read-Host "Model provider [Anthropic / MicrosoftFoundry] (default Anthropic)"
  $ModelProvider = if ($mp) { $mp } else { "Anthropic" }
}

if (-not $AgentName) {
  $envName = ($ResourceGroup -replace '^rg-zava-learning-', '')
  $AgentName = "sre-zava-$envName"
}

Write-Host "Discovering lab resources in $ResourceGroup..." -ForegroundColor Cyan
$identityId   = az identity list -g $ResourceGroup --query "[0].id" -o tsv
$aiName       = az resource list -g $ResourceGroup --resource-type "Microsoft.Insights/components" --query "[0].name" -o tsv
$aiId         = az resource show -g $ResourceGroup -n $aiName --resource-type "Microsoft.Insights/components" --query id -o tsv
$aiAppId      = az resource show -g $ResourceGroup -n $aiName --resource-type "Microsoft.Insights/components" --query properties.AppId -o tsv
$aiConn       = az resource show -g $ResourceGroup -n $aiName --resource-type "Microsoft.Insights/components" --query properties.ConnectionString -o tsv
$rgId         = az group show -n $ResourceGroup --query id -o tsv
if (-not $Location) { $Location = az group show -n $ResourceGroup --query location -o tsv }

if (-not ($identityId -and $aiId)) { throw "Could not discover required resources in $ResourceGroup." }

Write-Host "Deploying SRE Agent '$AgentName' (platform: $IncidentPlatform)..." -ForegroundColor Cyan
az deployment group create `
  --resource-group $ResourceGroup `
  --name "sre-agent-$(Get-Date -Format 'yyyyMMddHHmmss')" `
  --template-file (Join-Path $repoRoot "infra/modules/sre-agent.bicep") `
  --parameters `
      location=$Location `
      agentName=$AgentName `
      identityId=$identityId `
      appInsightsAppId=$aiAppId `
      appInsightsConnectionString=$aiConn `
      appInsightsId=$aiId `
      managedResourceGroupId=$rgId `
      incidentPlatform=$IncidentPlatform `
      modelProvider=$ModelProvider `
      modelName=$ModelName `
  --query "properties.outputs" -o json

Write-Host "SRE Agent provisioned (deployment only)." -ForegroundColor Green
Write-Host "Next: apply agent CONFIG (connectors/skills/incident filter/KB/tools) via Azure MCP -" -ForegroundColor Yellow
Write-Host "      see sre-config/agent-config/README.md" -ForegroundColor Yellow
