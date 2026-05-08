<#
.SYNOPSIS
    Deploy an SRE Agent via Terraform.

.DESCRIPTION
    Same interface as Deploy-Agent.ps1 but uses Terraform instead of Bicep.
    Accepts a config directory (agent.json + connectors.json + config/*.yaml)
    produced by New-Agent.ps1, Export-Agent.ps1, or Clone-Agent.ps1.

.PARAMETER InputPath
    Config directory containing agent.json + connectors.json + config/*.yaml.

.PARAMETER DryRun
    Terraform plan only, no apply.

.PARAMETER Force
    Redeploy even if no changes. Also passed to Apply-Extras.

.PARAMETER Destroy
    Tear down the agent infrastructure.

.PARAMETER NoTelemetry
    Disable anonymous telemetry.

.EXAMPLE
    .\Deploy-Tf.ps1 -InputPath C:\config\myagent
    .\Deploy-Tf.ps1 -InputPath C:\config\myagent -DryRun
    .\Deploy-Tf.ps1 -InputPath C:\config\myagent -Destroy
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$InputPath,

    [switch]$DryRun,
    [switch]$Force,
    [switch]$Destroy,
    [switch]$NoTelemetry
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Paths ──
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$BinDir    = Split-Path -Parent $ScriptDir          # bin/ps -> bin
$RepoRoot  = Split-Path -Parent $BinDir             # bin -> repo root
$BicepDir  = Join-Path $RepoRoot 'bicep'
$TfDir     = Join-Path $RepoRoot 'terraform'

# ── Prerequisites ──
. (Join-Path $ScriptDir 'Check-Prerequisites.ps1')
if (-not (Test-Prerequisites -IncludePython)) { exit 1 }

foreach ($cmd in @('terraform')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Host "Error: $cmd is required but not found." -ForegroundColor Red
        exit 1
    }
}

# Source telemetry
$TelemetryScript = Join-Path $ScriptDir 'Telemetry.ps1'
if (Test-Path $TelemetryScript) { . $TelemetryScript }

# ── Validate input ──
$InputPath = (Resolve-Path $InputPath -ErrorAction Stop).Path
if (-not (Test-Path $InputPath -PathType Container)) {
    Write-Host "Error: $InputPath is not a directory" -ForegroundColor Red
    exit 1
}
$AgentJson = Join-Path $InputPath 'agent.json'
if (-not (Test-Path $AgentJson)) {
    Write-Host "Error: $AgentJson not found" -ForegroundColor Red
    exit 1
}

# ── Helpers ──
function Write-Header([string]$Text) {
    Write-Host $Text -ForegroundColor Cyan
}

# ── Step 1: Assemble ──
Write-Header "── Assembling from directory: $InputPath/ ──"

$AssembleTmp = Join-Path ([System.IO.Path]::GetTempPath()) "assembled-$(New-Guid)"
$AssembleOut = $AssembleTmp

$AssemblePs = Join-Path $BicepDir 'Assemble-Agent.ps1'
if (Test-Path $AssemblePs) {
    & $AssemblePs -ConfigDir $InputPath -Output $AssembleOut
} else {
    $AssembleSh = Join-Path $BicepDir 'assemble-agent.sh'
    bash $AssembleSh $InputPath --output $AssembleOut
}

$ParamsFile = "${AssembleOut}.parameters.json"
$ExtrasFile = "${AssembleOut}.extras.json"
Write-Host ''

if (-not (Test-Path $ParamsFile)) {
    Write-Host "Error: assemble failed — no parameters file" -ForegroundColor Red
    exit 1
}

# ── Step 2: Convert parameters.json → terraform.tfvars.json ──
Write-Header '── Converting to Terraform variables ──'

$TfVarsFile = Join-Path $TfDir 'terraform.tfvars.json'

$jqFilter = @'
{
  agent_name:                    .parameters.agentName.value,
  resource_group_name:           .parameters.agentResourceGroupName.value,
  location:                      .parameters.location.value,
  target_resource_groups:        .parameters.targetResourceGroups.value,
  access_level:                  .parameters.accessLevel.value,
  action_mode:                   .parameters.actionMode.value,
  upgrade_channel:               (.parameters.upgradeChannel.value // "Preview"),
  monthly_agent_unit_limit:      (.parameters.monthlyAgentUnitLimit.value // 10000),
  default_model_provider:        (.parameters.defaultModelProvider.value // "Anthropic"),
  tags:                          (.parameters.tags.value // {}),
  existing_managed_identity_id:  (.parameters.existingManagedIdentityId.value // ""),
  existing_agent_app_insights_id:(.parameters.existingAgentAppInsightsId.value // ""),

  enable_app_insights_connector: (.parameters.enableAppInsightsConnector.value // false),
  app_insights_resource_id:      (.parameters.appInsightsResourceId.value // ""),
  app_insights_app_id:           (.parameters.appInsightsAppId.value // ""),
  enable_log_analytics_connector:(.parameters.enableLogAnalyticsConnector.value // false),
  law_resource_id:               (.parameters.lawResourceId.value // ""),
  enable_azure_monitor_connector:(.parameters.enableAzureMonitorConnector.value // false),
  azure_monitor_lookback_days:   (.parameters.azureMonitorLookbackDays.value // 7),

  enable_webhook_bridge:         (.parameters.enableWebhookBridge.value // false),
  webhook_bridge_trigger_url:    (.parameters.webhookBridgeTriggerUrl.value // ""),

  connectors: [(.parameters.connectors.value // [])[] | {
    name: .name,
    properties: .properties
  }],

  skills: [(.parameters.skills.value // [])[] | {
    name: .metadata.name,
    spec: {
      name:            .metadata.name,
      description:     (.metadata.description // ""),
      tools:           (.metadata.spec.tools // []),
      skillContent:    (.skillContent // ""),
      additionalFiles: (.additionalFiles // [])
    }
  }],

  subagents: [(.parameters.subagents.value // [])[] | {
    name: .metadata.name,
    spec: .spec
  }],

  tools: [(.parameters.tools.value // [])[] | {
    name: .metadata.name,
    spec: .spec
  }],

  common_prompts: [(.parameters.commonPrompts.value // [])[] | {
    name: .name,
    properties: (.properties // .spec // {})
  }]
}
'@

jq $jqFilter $ParamsFile | Set-Content -Path $TfVarsFile -Encoding utf8
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: jq conversion failed" -ForegroundColor Red
    exit 1
}

$AG  = (jq -r '.agent_name' $TfVarsFile).Trim()
$RG  = (jq -r '.resource_group_name' $TfVarsFile).Trim()
$LOC = (jq -r '.location' $TfVarsFile).Trim()

Write-Host "  Agent:       $AG"
Write-Host "  RG:          $RG"
Write-Host "  Location:    $LOC"
Write-Host "  Connectors:  $(jq '.connectors | length' $TfVarsFile) custom + toggles"
Write-Host "  Skills:      $(jq '.skills | length' $TfVarsFile)"
Write-Host "  Subagents:   $(jq '.subagents | length' $TfVarsFile)"
Write-Host "  Tools:       $(jq '.tools | length' $TfVarsFile)"
Write-Host "  Prompts:     $(jq '.common_prompts | length' $TfVarsFile)"
Write-Host "  Wrote:       $TfVarsFile"
Write-Host ''

# ── Step 3: Terraform init + workspace ──
Write-Header '── Terraform init ──'
Push-Location $TfDir
try {
    terraform init -input=false -no-color 2>&1 | Select-Object -Last 3 | ForEach-Object { Write-Host $_ }

    $Workspace = $AG
    $workspaceList = terraform workspace list 2>$null
    if ($workspaceList -match "\b$([regex]::Escape($Workspace))\b") {
        terraform workspace select $Workspace -no-color 2>$null | Out-Null
    } else {
        terraform workspace new $Workspace -no-color 2>$null | Out-Null
    }
    Write-Host "  Workspace: $Workspace"
    Write-Host ''

    # ── Step 4: Destroy path ──
    if ($Destroy) {
        Write-Header '── Terraform destroy ──'
        terraform destroy -input=false -auto-approve -no-color
        Remove-Item -Path $TfVarsFile -Force -ErrorAction SilentlyContinue
        terraform workspace select default -no-color 2>$null | Out-Null
        terraform workspace delete $Workspace -no-color 2>$null | Out-Null
        Remove-Item -Path (Split-Path $AssembleTmp) -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host '✅ Destroyed.' -ForegroundColor Green
        return
    }

    # ── Step 5: Plan ──
    Write-Header '── Terraform plan ──'
    terraform plan -input=false -no-color -out=tf.plan 2>&1 | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }
    Write-Host ''

    if ($DryRun) {
        Write-Header '── DRY RUN — no deployment performed ──'
        Write-Host "  Plan saved to: $TfDir/tf.plan"
        Write-Host "  To apply: cd $TfDir && terraform apply tf.plan"
        Remove-Item -Path (Split-Path $AssembleTmp) -Recurse -Force -ErrorAction SilentlyContinue
        return
    }

    # ── Step 6: Apply ──
    Write-Header '── Terraform apply ──'
    terraform apply -input=false -no-color tf.plan
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: terraform apply failed" -ForegroundColor Red
        exit 1
    }
    Remove-Item -Path (Join-Path $TfDir 'tf.plan') -Force -ErrorAction SilentlyContinue

    $SubscriptionId = (az account show --query id -o tsv).Trim()

    Write-Host ''
    Write-Header '─────────────── Deployment Succeeded ───────────────'
    Write-Host "  Agent (portal):  https://sre.azure.com/#/agent/$SubscriptionId/$RG/$AG"
    Write-Host "  Data plane:      https://${AG}.${LOC}.azuresre.ai"
    Write-Host ''

    # ── Step 7: Apply extras ──
    if ((Test-Path $ExtrasFile -ErrorAction SilentlyContinue)) {
        $extrasSize = jq 'del(._exported_from) | to_entries | map(select(.value | if type == "array" then length > 0 elif type == "object" then length > 0 else false end)) | length' $ExtrasFile 2>$null
        if ($extrasSize -and [int]$extrasSize -gt 0) {
            Write-Header '── Applying data-plane config (extras) ──'
            $ApplyExtrasPs = Join-Path $BicepDir 'Apply-Extras.ps1'
            if (Test-Path $ApplyExtrasPs) {
                $applyParams = @{
                    Subscription  = $SubscriptionId
                    ResourceGroup = $RG
                    AgentName     = $AG
                    ExtrasFile    = $ExtrasFile
                }
                if ($Force) { $applyParams['Force'] = $true }
                & $ApplyExtrasPs @applyParams
            } else {
                $ApplyExtrasSh = Join-Path $BicepDir 'apply-extras.sh'
                if (Test-Path $ApplyExtrasSh) {
                    $env:INPUT = $InputPath
                    $forceArg = if ($Force) { '--force' } else { '' }
                    bash $ApplyExtrasSh $SubscriptionId $RG $AG $ExtrasFile $forceArg
                } else {
                    Write-Host "  ⚠ Apply-Extras script not found. Run manually:" -ForegroundColor Yellow
                    Write-Host "    Apply-Extras.ps1 -Subscription $SubscriptionId -ResourceGroup $RG -AgentName $AG -ExtrasFile $ExtrasFile"
                }
            }
        } else {
            Write-Host 'No data-plane extras to apply.'
        }
    }

    # Telemetry
    if (-not $NoTelemetry -and (Get-Command Send-Telemetry -ErrorAction SilentlyContinue)) {
        $RecipeName = 'unknown'
        try {
            $agentCfg = Get-Content $AgentJson -Raw | ConvertFrom-Json
            if ($agentCfg.PSObject.Properties['_scenario']) { $RecipeName = $agentCfg._scenario }
            else { $RecipeName = 'custom' }
        } catch { }
        Send-Telemetry -Action 'deploy-tf' -Recipe $RecipeName -Region $LOC
    }

} finally {
    Pop-Location
    Remove-Item -Path (Split-Path $AssembleTmp) -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Header '─────────────────────────────────────────────────────'
