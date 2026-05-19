<#
.SYNOPSIS
    Clone an SRE Agent to another environment.

.DESCRIPTION
    All-in-one: exports config from a live agent (or reads an exported directory),
    validates, overrides identity fields, and deploys.

.PARAMETER Source
    Export directory containing agent.json. Alternative to -FromAgent.

.PARAMETER FromAgent
    Source agent name to clone from (triggers live export).

.PARAMETER FromResourceGroup
    Source agent resource group (required with -FromAgent).

.PARAMETER FromSubscription
    Source agent subscription (default: current az account).

.PARAMETER AgentName
    New agent name for the clone.

.PARAMETER ResourceGroup
    Resource group for the cloned agent.

.PARAMETER Location
    Target region (default: inherit from source).

.PARAMETER TargetResourceGroups
    Comma-separated RGs the clone should monitor.

.PARAMETER Subscription
    Target subscription (default: current az account).

.PARAMETER ValidateOnly
    Run validation checks without deploying.

.PARAMETER SkipExtras
    Deploy Bicep only, skip data-plane config.

.PARAMETER Backend
    Deploy backend: bicep (default) or terraform.

.PARAMETER Force
    Redeploy even if no changes detected.

.EXAMPLE
    .\Clone-Agent.ps1 -FromAgent my-agent -FromResourceGroup rg-src -AgentName my-clone -ResourceGroup rg-clone
    .\Clone-Agent.ps1 -Source ./exported-config/ -AgentName my-clone -ResourceGroup rg-clone -ValidateOnly
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$FromAgent,
    [string]$FromResourceGroup,
    [Alias('FromSubscriptionId')]
    [string]$FromSubscription,
    [Parameter(Mandatory)][string]$AgentName,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Location,
    [string]$TargetResourceGroups,
    [Alias('SubscriptionId')]
    [string]$Subscription,
    [switch]$ValidateOnly,
    [switch]$SkipExtras,
    [ValidateSet('bicep','terraform')][string]$Backend = 'bicep',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# PS 7.3+ changed how native-command arguments are passed; use Legacy to avoid
# broken arg splitting when args contain '=' (e.g. jq --argjson, terraform -out=).
if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSVersionTable.PSVersion.Minor -ge 3) {
    $PSNativeCommandArgumentPassing = 'Legacy'
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $ScriptDir 'Check-Prerequisites.ps1')
if (Test-Path (Join-Path $ScriptDir 'Telemetry.ps1')) { . (Join-Path $ScriptDir 'Telemetry.ps1') }

if (-not $Source -and -not $FromAgent) {
    Write-Error 'Either -Source or -FromAgent is required.'
    exit 1
}

# ── Step 1: Export from live agent (if -FromAgent) ──
if ($FromAgent) {
    if (-not $FromResourceGroup) { Write-Error '-FromResourceGroup required with -FromAgent'; exit 1 }
    if (-not $FromSubscription) { $FromSubscription = (az account show --query id -o tsv 2>$null) }
    if (-not $FromSubscription) { Write-Error '-FromSubscription required (or az login first)'; exit 1 }

    $ExportDir = Join-Path ([System.IO.Path]::GetTempPath()) "$FromAgent-clone-$(Get-Random)"
    Write-Host "── Exporting from live agent: $FromAgent ──"
    $ExportScript = Join-Path $ScriptDir 'Export-Agent.ps1'
    $exportParams = @{
        Subscription  = $FromSubscription
        ResourceGroup = $FromResourceGroup
        AgentName     = $FromAgent
        Output        = $ExportDir
    }
    & $ExportScript @exportParams
    $Source = $ExportDir
    Write-Host "  Exported to: $Source"
    Write-Host
}

# ── Step 2: Validate source ──
Write-Host "── Validating source: $Source ──"
$pass = 0; $fail = 0

$agentFile = Join-Path $Source 'agent.json'
if (Test-Path $agentFile) {
    try { $null = Get-Content $agentFile -Raw | ConvertFrom-Json; $pass++; Write-Host "  ✅ agent.json valid" }
    catch { $fail++; Write-Host "  ❌ agent.json invalid JSON" }
} else { $fail++; Write-Host "  ❌ agent.json not found" }

$connFile = Join-Path $Source 'connectors.json'
if (Test-Path $connFile) { $pass++; Write-Host "  ✅ connectors.json exists" }
else { $fail++; Write-Host "  ❌ connectors.json not found" }

# Check for leftover placeholders
$placeholders = (Get-ChildItem $Source -Recurse -Include '*.json','*.yaml','*.yml' | ForEach-Object {
    $content = Get-Content $_ -Raw -ErrorAction SilentlyContinue
    if ($content -match '\{\{[^}]+\}\}') { $_.FullName }
})
if ($placeholders) { $fail++; Write-Host "  ❌ Leftover {{placeholders}} in: $($placeholders -join ', ')" }
else { $pass++; Write-Host "  ✅ No {{placeholders}}" }

# Skills >50 chars
$skillDir = Join-Path $Source 'config/skills'
if (Test-Path $skillDir) {
    Get-ChildItem $skillDir -Filter '*.md' | ForEach-Object {
        $len = (Get-Content $_.FullName -Raw).Length
        if ($len -gt 50) { $pass++; Write-Host "  ✅ skill $($_.BaseName): $len chars" }
        else { $fail++; Write-Host "  ❌ skill $($_.BaseName): $len chars (<50)" }
    }
}

# Subagent instructions >50 chars
$saDir = Join-Path $Source 'config/subagents'
if (Test-Path $saDir) {
    Get-ChildItem $saDir -Filter '*.md' | ForEach-Object {
        $len = (Get-Content $_.FullName -Raw).Length
        if ($len -gt 50) { $pass++; Write-Host "  ✅ subagent $($_.BaseName): $len chars" }
        else { $fail++; Write-Host "  ❌ subagent $($_.BaseName): $len chars (<50)" }
    }
}

Write-Host
Write-Host "  Validation: $pass passed, $fail failed"

if ($fail -gt 0 -and -not $Force) {
    Write-Error "Validation failed ($fail errors). Use -Force to override."
    exit 1
}

# ── Step 3: Override agent.json fields ──
Write-Host "── Overriding agent identity ──"
$agentJson = Get-Content $agentFile -Raw | ConvertFrom-Json
$agentJson.identity.agentName = $AgentName
$agentJson.identity.resourceGroup = $ResourceGroup
if ($Location) { $agentJson.identity.location = $Location }
if ($TargetResourceGroups) { $agentJson.identity.targetResourceGroups = $TargetResourceGroups }
$agentJson | ConvertTo-Json -Depth 20 | Set-Content $agentFile -Encoding utf8
Write-Host "  Agent: $AgentName → $ResourceGroup"
Write-Host

if ($ValidateOnly) {
    Write-Host "── VALIDATE ONLY — no deployment ──"
    exit 0
}

# ── Step 4: Deploy ──
Write-Host "── Deploying clone ──"
if ($Backend -eq 'terraform') {
    $DeployTfScript = Join-Path $ScriptDir 'Deploy-Tf.ps1'
    if (-not (Test-Path $DeployTfScript)) {
        Write-Error "Deploy-Tf.ps1 not found at $DeployTfScript"
    }
    if (-not (Test-Path $Source -PathType Container)) {
        Write-Error "-Backend terraform requires a directory source (-FromAgent or directory -Source)"
    }
    $deployParams = @{ InputPath = $Source }
    if ($Force) { $deployParams['Force'] = $true }
    & $DeployTfScript @deployParams
} else {
    $DeployScript = Join-Path $ScriptDir 'Deploy-Agent.ps1'
    $deployParams = @{ InputPath = $Source }
    if ($Force) { $deployParams['Force'] = $true }
    if ($SkipExtras) { $deployParams['SkipExtras'] = $true }
    if ($Subscription) { $deployParams['Subscription'] = $Subscription }
    & $DeployScript @deployParams
}
