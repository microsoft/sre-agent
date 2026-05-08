<#
.SYNOPSIS
    Deploy an SRE Agent via Bicep.

.DESCRIPTION
    Accepts either:
      (a) A config directory (agent.json + connectors.json + config/*.yaml)
          → runs Assemble-Agent.ps1 internally, then deploys
      (b) A legacy .parameters.json file → deploys directly

    After deploy, auto-runs Apply-Extras.ps1 for data-plane config (repos, hooks, etc.)

.PARAMETER InputPath
    Config directory or legacy .parameters.json file.

.PARAMETER DeploymentName
    Optional ARM deployment name. Defaults to sre-agent-<timestamp>.

.PARAMETER DryRun
    Assemble only, no ARM call.

.PARAMETER WhatIf
    ARM validation without deploying.

.PARAMETER Force
    Redeploy even if no changes detected.

.PARAMETER NoTelemetry
    Disable anonymous telemetry.

.EXAMPLE
    .\Deploy-Agent.ps1 -InputPath C:\config\myagent
    .\Deploy-Agent.ps1 -InputPath C:\config\myagent -DryRun
    .\Deploy-Agent.ps1 -InputPath .\params.json -Force
#>
[CmdletBinding(SupportsShouldProcess = $false)]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$InputPath,

    [Parameter(Position = 1)]
    [string]$DeploymentName,

    [switch]$DryRun,

    [switch]$WhatIf_,  # renamed to avoid collision with built-in $WhatIfPreference

    [switch]$Force,

    [switch]$NoTelemetry
)

# Also accept -WhatIf as a named alias from the command line
# PowerShell reserves -WhatIf for SupportsShouldProcess, so we use -WhatIf_ internally
# but also check $PSBoundParameters for a raw --WhatIf passed via CLI
if ($args -contains '--WhatIf' -or $args -contains '-WhatIf') {
    $WhatIf_ = $true
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Prereqs ──
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $ScriptDir 'Check-Prerequisites.ps1')
if (-not (Test-Prerequisites -IncludePython)) { exit 1 }

# ── Resolve paths ──
$BinDir = Split-Path -Parent $ScriptDir   # bin/ps -> bin
$BicepDir = Join-Path (Split-Path -Parent $BinDir) 'bicep'
$Template = Join-Path $BicepDir 'main.bicep'

# Source telemetry
$TelemetryScript = Join-Path $ScriptDir 'Telemetry.ps1'
if (Test-Path $TelemetryScript) {
    . $TelemetryScript
}

# ── Helpers ──
function Write-Header([string]$Text) {
    Write-Host $Text -ForegroundColor Cyan
}

function Write-Success([string]$Text) {
    Write-Host $Text -ForegroundColor Green
}

function Write-Fail([string]$Text) {
    Write-Host $Text -ForegroundColor Red
}

function Get-JsonValue {
    param([string]$Json, [string]$Query, [string]$Default = '')
    try {
        $result = $Json | ConvertFrom-Json
        $parts = $Query -split '\.'
        $current = $result
        foreach ($part in $parts) {
            if ($null -eq $current) { return $Default }
            $current = $current.$part
        }
        if ($null -eq $current -or $current -eq '') { return $Default }
        return $current
    } catch {
        return $Default
    }
}

# ── Validate prerequisites ──
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Fail 'Error: Azure CLI (az) is required but not found.'
    exit 1
}
if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    Write-Fail 'Error: jq is required but not found.'
    exit 1
}

# ── Resolve input ──
$resolved = Resolve-Path $InputPath -ErrorAction SilentlyContinue
$InputPath = if ($resolved) { $resolved.Path } else { $InputPath }
if (-not (Test-Path $InputPath)) {
    Write-Fail "Error: input path '$InputPath' not found."
    exit 1
}

if (-not $DeploymentName) {
    $DeploymentName = "sre-agent-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

if (-not (Test-Path $Template)) {
    Write-Fail "Error: Bicep template not found at $Template"
    exit 1
}

# ── Detect input type and resolve to parameters.json ──
$CleanupFiles = @()
$ExtrasFile = ''
$IsDirectory = Test-Path $InputPath -PathType Container

if ($IsDirectory) {
    $AgentJson = Join-Path $InputPath 'agent.json'
    if (-not (Test-Path $AgentJson)) {
        Write-Fail "Error: $AgentJson not found"
        exit 1
    }

    Write-Header "── Assembling from directory: $InputPath/ ──"

    $AssembleScript = Join-Path $ScriptDir 'Assemble-Agent.ps1'
    if (-not (Test-Path $AssembleScript)) {
        # Fallback: try bash assemble
        $AssembleScript = Join-Path $BicepDir 'assemble-agent.sh'
    }

    $AssembleTmp = Join-Path ([System.IO.Path]::GetTempPath()) "assembled-$(New-Guid)"
    $AssembleOut = $AssembleTmp

    if ($AssembleScript -match '\.ps1$') {
        & $AssembleScript -ConfigDir $InputPath -Output $AssembleOut
    } else {
        bash $AssembleScript $InputPath --output $AssembleOut
    }

    $ParametersFile = "${AssembleOut}.parameters.json"
    $ExtrasFile = "${AssembleOut}.extras.json"
    $CleanupFiles += $ParametersFile, $ExtrasFile, (Split-Path $AssembleTmp -Parent)

    Write-Host ''
} elseif (Test-Path $InputPath -PathType Leaf) {
    $ParametersFile = $InputPath
    $ExtrasFile = ''
} else {
    Write-Fail "Error: $InputPath not found (expected directory or .json file)"
    exit 1
}

if (-not (Test-Path $ParametersFile)) {
    Write-Fail "Error: parameters file not found: $ParametersFile"
    exit 1
}

# ── Pre-flight: parse params and show summary ──
$ParamsRaw = Get-Content $ParametersFile -Raw
$Params = $ParamsRaw | ConvertFrom-Json

function Get-Param([string]$Name, $Default = $null) {
    $val = $Params.parameters.$Name.value
    if ($null -eq $val -or $val -eq '') { return $Default }
    return $val
}

$Location    = Get-Param 'location' 'eastus2'
$AgentName   = Get-Param 'agentName'
$ResourceGroup = Get-Param 'agentResourceGroupName'
$TargetRGs   = Get-Param 'targetResourceGroups'
$AccessLevel = Get-Param 'accessLevel' 'Low'
$ActionMode  = Get-Param 'actionMode' 'Review'
$UpgradeChannel = Get-Param 'upgradeChannel' 'Preview'
$ModelProvider  = Get-Param 'defaultModelProvider' 'Anthropic'
$MonthlyLimit   = Get-Param 'monthlyAgentUnitLimit' 10000

$SubInfo = az account show --output json 2>$null | ConvertFrom-Json
$SubscriptionId   = $SubInfo.id
$SubscriptionName = $SubInfo.name

$RgExists = (az group exists -n $ResourceGroup 2>$null) -eq 'true'
$RgStatus = if ($RgExists) { '(exists)' } else { '(will be created)' }
$TargetRGsStr = if ($TargetRGs -is [array]) { $TargetRGs -join ', ' } else { $TargetRGs }
if (-not $TargetRGsStr) { $TargetRGsStr = '<none>' }

Write-Host ''
Write-Header '──────────────── SRE Agent deployment ────────────────'
Write-Host "  Subscription:  $SubscriptionName ($SubscriptionId)"
Write-Host "  Region:        $Location"
Write-Host "  Agent name:    $AgentName"
Write-Host "  Agent RG:      $ResourceGroup  $RgStatus"
Write-Host "  Target RGs:    $TargetRGsStr"
Write-Host "  Access level:  $AccessLevel"
Write-Host "  Action mode:   $ActionMode"
Write-Host "  Upgrade chan:  $UpgradeChannel"
Write-Host "  Model:         $ModelProvider"
Write-Host "  Monthly limit: $MonthlyLimit AU"
Write-Host ''

# Show Bicep resources
Write-Host '  Bicep (ARM) resources:'

$WebhookBridge = Get-Param 'enableWebhookBridge' $false
if ($WebhookBridge -eq $true) {
    Write-Host '    ✓ Webhook bridge (Logic App)'
}

foreach ($toggle in @('enableLogAnalyticsConnector', 'enableAppInsightsConnector', 'enableAzureMonitorConnector')) {
    $val = Get-Param $toggle $false
    if ($val -eq $true) {
        switch ($toggle) {
            'enableLogAnalyticsConnector' { Write-Host '    ✓ Log Analytics connector' }
            'enableAppInsightsConnector'  { Write-Host '    ✓ App Insights connector' }
            'enableAzureMonitorConnector' { Write-Host '    ✓ Azure Monitor connector' }
        }
    }
}

# Array connectors
$Connectors = Get-Param 'connectors'
if (@($Connectors).Count -gt 0) {
    foreach ($c in $Connectors) {
        $cType = $c.properties.dataConnectorType
        Write-Host "    ✓ Connector: $($c.name) ($cType)"
    }
}

# Skills + subagents
foreach ($arr in @('skills', 'subagents')) {
    $items = Get-Param $arr
    if ($items -and $items.Count -gt 0) {
        Write-Host "    ✓ ${arr}: $($items.Count)"
    }
}

Write-Host ''
Write-Host '  Data-plane (apply-extras):'

# Resolve extras file
if (-not $ExtrasFile -or -not (Test-Path $ExtrasFile -ErrorAction SilentlyContinue)) {
    $candidate = $ParametersFile -replace '\.parameters\.json$', '.extras.json'
    if (Test-Path $candidate -ErrorAction SilentlyContinue) {
        $ExtrasFile = $candidate
    } else {
        $candidate2 = Join-Path (Split-Path $ParametersFile) 'assembled.extras.json'
        if (Test-Path $candidate2 -ErrorAction SilentlyContinue) {
            $ExtrasFile = $candidate2
        }
    }
}

if ($ExtrasFile -and (Test-Path $ExtrasFile -ErrorAction SilentlyContinue)) {
    $ExtrasRaw = Get-Content $ExtrasFile -Raw | ConvertFrom-Json
    $ExtrasKeys = @{
        hooks             = 'Hooks'
        commonPrompts     = 'Common prompts'
        incidentPlatforms = 'Incident platforms'
        incidentFilters   = 'Incident filters (response plans)'
        scheduledTasks    = 'Scheduled tasks'
        httpTriggers      = 'HTTP triggers'
        repos             = 'Repos'
        knowledgeItems    = 'Knowledge files'
        knowledge         = 'Knowledge docs'
    }
    foreach ($key in $ExtrasKeys.Keys) {
        $items = $ExtrasRaw.$key
        if ($items -and $items.Count -gt 0) {
            Write-Host "    ✓ $($ExtrasKeys[$key]): $($items.Count)"
        }
    }
} else {
    Write-Host '    (extras file not found — data-plane items shown in change detection below)'
}

Write-Host ''
Write-Host "  Deployment name: $DeploymentName"
Write-Header '─────────────────────────────────────────────────────'
Write-Host ''

# ── Pre-deploy: change detection ──
$ChangesDetected = ''
if ($IsDirectory) {
    Write-Header '── Change detection ──'

    $DiffScript = Join-Path $ScriptDir 'Diff-Agent.ps1'
    if (Test-Path $DiffScript) {
        try {
            & $DiffScript -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -AgentName $AgentName -InputPath $InputPath
            $DiffExit = $LASTEXITCODE
        } catch {
            $DiffExit = 1
        }

        if ($DiffExit -eq 0) {
            Write-Host '  No changes detected.'
            if (-not $Force) {
                Write-Host '  Skipping deployment. Use -Force to redeploy anyway.'
                Write-Host ''

                # Still run verify
                $VerifyScript = Join-Path $ScriptDir 'Verify-Agent.ps1'
                if (Test-Path $VerifyScript) {
                    Write-Header '── Current state verification ──'
                    try {
                        & $VerifyScript -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -AgentName $AgentName -Expected $InputPath
                    } catch { }
                }
                exit 0
            } else {
                Write-Host '  -Force: redeploying anyway.'
            }
        } elseif ($DiffExit -eq 2) {
            $ChangesDetected = 'new'
        } else {
            $ChangesDetected = 'update'
        }
    } else {
        Write-Host '  (Diff-Agent.ps1 not found — skipping change detection)'
    }
    Write-Host ''
}

# ── Dry-run: stop here ──
if ($DryRun) {
    Write-Header '── DRY RUN — no deployment performed ──'
    Write-Host '  Assemble: ✅ (parameters + extras built)'
    Write-Host '  To validate against ARM without deploying: -WhatIf_'
    Write-Host '  To deploy for real: remove -DryRun'
    exit 0
}

# ── What-if: validate against ARM without deploying ──
if ($WhatIf_) {
    Write-Header '── What-if validation (ARM preflight) ──'
    Write-Host ''

    $whatIfResult = az deployment sub what-if `
        --location $Location `
        --name $DeploymentName `
        --template-file $Template `
        --parameters "@$ParametersFile" `
        --no-pretty-print 2>&1

    $whatIfExit = $LASTEXITCODE
    Write-Host ($whatIfResult -join "`n")

    if ($whatIfExit -eq 0) {
        Write-Host ''
        Write-Success '✅ What-if passed — deployment should succeed.'
    } else {
        Write-Host ''
        Write-Fail '❌ What-if found errors — fix before deploying.'
    }
    exit $whatIfExit
}

# ── Run the deployment ──
Write-Host 'Starting deployment (this typically takes 3-5 min)...'
Write-Host "Tip: open another terminal and run 'az deployment operation sub list -n $DeploymentName -o table' to watch progress."
Write-Host ''

# Capture stdout (JSON) cleanly; let stderr (warnings/errors) flow to console
$deployJson = az deployment sub create `
    --location $Location `
    --name $DeploymentName `
    --template-file $Template `
    --parameters "@$ParametersFile" `
    --output json | Out-String

Write-Host $deployJson

# ── Post-deploy: check state ──
$deployResult = $null
try {
    $deployResult = $deployJson | ConvertFrom-Json
} catch { }

$State = 'Failed'
if ($deployResult) {
    $State = if ($deployResult.properties.provisioningState) { $deployResult.properties.provisioningState } else { 'Failed' }
}

if ($State -ne 'Succeeded') {
    Write-Host ''
    Write-Fail '══════════ Deployment FAILED ══════════'

    # Extract error messages
    if ($deployResult) {
        $errMsgs = @()
        function Find-ErrorMessages($obj) {
            if ($null -eq $obj) { return }
            if ($obj -is [PSCustomObject]) {
                if ($obj.PSObject.Properties['message']) {
                    $msg = $obj.message
                    if ($msg -and $msg -notmatch '^At least') {
                        $script:errMsgs += $msg
                    }
                }
                foreach ($prop in $obj.PSObject.Properties) {
                    Find-ErrorMessages $prop.Value
                }
            } elseif ($obj -is [array]) {
                foreach ($item in $obj) {
                    Find-ErrorMessages $item
                }
            }
        }
        Find-ErrorMessages $deployResult
        if ($errMsgs.Count -gt 0) {
            Write-Host ''
            Write-Host '  Root cause:'
            $errMsgs | Select-Object -First 3 | ForEach-Object { Write-Host "    $_" }
        }
    }

    Write-Host ''
    Write-Host "  Debug: az deployment operation sub list -n $DeploymentName -o table"
    Write-Host ''
    exit 1
}

Write-Host ''
Write-Header '─────────────── Deployment Succeeded ───────────────'
$portalUrl       = $deployResult.properties.outputs.agentPortalUrl.value
$rgPortalUrl     = $deployResult.properties.outputs.resourceGroupPortalUrl.value
$dataPlaneUrl    = $deployResult.properties.outputs.agentDataPlaneUrl.value
Write-Host "  Agent (portal):  $portalUrl"
Write-Host "  Resource group:  $rgPortalUrl"
Write-Host "  Data plane:      $dataPlaneUrl"
Write-Host ''

# ── Telemetry ──
$RecipeName = 'unknown'
if ($IsDirectory) {
    $agentJsonPath = Join-Path $InputPath 'agent.json'
    if (Test-Path $agentJsonPath) {
        try {
            $agentCfg = Get-Content $agentJsonPath -Raw | ConvertFrom-Json
            $scenarioVal = if ($agentCfg.PSObject.Properties['_scenario']) { $agentCfg._scenario } else { $null }
            if ($scenarioVal) { $RecipeName = $scenarioVal } else { $RecipeName = 'custom' }
        } catch { }
    }
}

if (-not $NoTelemetry -and (Get-Command Send-Telemetry -ErrorAction SilentlyContinue)) {
    Send-Telemetry -Action 'deploy' -Recipe $RecipeName -Region $Location
}

# ── Auto-run Apply-Extras if extras file exists ──
if ($ExtrasFile -and (Test-Path $ExtrasFile -ErrorAction SilentlyContinue)) {
    $ExtrasContent = Get-Content $ExtrasFile -Raw | ConvertFrom-Json
    # Count non-empty data-plane entries
    $extrasCount = 0
    foreach ($prop in $ExtrasContent.PSObject.Properties) {
        if ($prop.Name -eq '_exported_from') { continue }
        $v = $prop.Value
        if ($null -eq $v) { continue }
        $isNonEmpty = $false
        if ($v -is [System.Array]) {
            $isNonEmpty = ($v.Length -gt 0)
        } elseif ($v -is [System.Collections.IList]) {
            $isNonEmpty = ($v.Count -gt 0)
        } elseif ($v -is [PSCustomObject]) {
            $isNonEmpty = (@($v.PSObject.Properties).Count -gt 0)
        } elseif ($v -is [string]) {
            $isNonEmpty = ($v.Length -gt 0)
        }
        if ($isNonEmpty) { $extrasCount++ }
    }

    if ($extrasCount -gt 0) {
        Write-Header '── Applying data-plane config (extras) ──'
        $ApplyExtrasScript = Join-Path $ScriptDir 'Apply-Extras.ps1'
        if (Test-Path $ApplyExtrasScript) {
            $applyParams = @{
                Subscription  = $SubscriptionId
                ResourceGroup = $ResourceGroup
                AgentName     = $AgentName
                ExtrasFile    = $ExtrasFile
            }
            if ($Force) { $applyParams['Force'] = $true }
            & $ApplyExtrasScript @applyParams
        } else {
            # Fallback to bash
            $applyExtrasBash = Join-Path $BicepDir 'apply-extras.sh'
            if (Test-Path $applyExtrasBash) {
                $env:INPUT = $InputPath
                $forceArg = if ($Force) { '--force' } else { '' }
                bash $applyExtrasBash $SubscriptionId $ResourceGroup $AgentName $ExtrasFile $forceArg
            } else {
                Write-Host "  ⚠ Apply-Extras script not found. Run manually:"
                Write-Host "    Apply-Extras.ps1 -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -AgentName $AgentName -ExtrasFile $ExtrasFile"
            }
        }
    } else {
        Write-Host 'No data-plane extras to apply.'
    }
} else {
    Write-Host 'Next: apply data-plane config (repos, hooks, knowledge, GitHub/ADO auth):'
    Write-Host "  .\Apply-Extras.ps1 -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -AgentName $AgentName -ExtrasFile <extras-file>"
}

Write-Header '─────────────────────────────────────────────────────'

# ── Deployment log ──
$LogDir = if ($IsDirectory) { $InputPath } else { Split-Path $InputPath }
$DeployLog = Join-Path $LogDir "deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$Duration = if ($deployResult.properties.duration) { $deployResult.properties.duration } else { '?' }

try {
    @"
Deployment: $DeploymentName
Timestamp:  $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ' -AsUTC)
Agent:      $AgentName
RG:         $ResourceGroup
Region:     $Location
State:      $State
Duration:   $Duration
Portal:     $portalUrl

"@ | Out-File -FilePath $DeployLog -Encoding utf8
} catch { }

# ── Post-deploy verification ──
if ($IsDirectory) {
    Write-Host ''
    Write-Header '── Post-deploy verification ──'
    $VerifyScript = Join-Path $ScriptDir 'Verify-Agent.ps1'
    $VerifyOutput = ''
    if (Test-Path $VerifyScript) {
        try {
            $VerifyOutput = & $VerifyScript -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -AgentName $AgentName -Expected $InputPath 2>&1 | Out-String
        } catch {
            $VerifyOutput = $_.Exception.Message
        }
    } else {
        # Fallback to bash
        $verifyBash = Join-Path (Split-Path $ScriptDir) 'verify-agent.sh'
        if (Test-Path $verifyBash) {
            try {
                $VerifyOutput = bash $verifyBash $SubscriptionId $ResourceGroup $AgentName --expected $InputPath 2>&1 | Out-String
            } catch {
                $VerifyOutput = $_.Exception.Message
            }
        } else {
            $VerifyOutput = '(Verify-Agent script not found — skipping)'
        }
    }
    Write-Host $VerifyOutput

    # Append verify results to log
    try {
        @"

── Verification Results ──
$VerifyOutput

"@ | Out-File -FilePath $DeployLog -Append -Encoding utf8
    } catch { }

    Write-Host ''
    Write-Host "  Log saved: $DeployLog"
}

# ── Post-deploy: process roles.yaml if present ──
$RolesFile = ''
if ($IsDirectory) {
    $candidate = Join-Path $InputPath 'roles.yaml'
    if (Test-Path $candidate) {
        $RolesFile = $candidate
    } else {
        $candidate2 = Join-Path (Split-Path $InputPath) 'roles.yaml'
        if (Test-Path $candidate2) {
            $RolesFile = $candidate2
        }
    }
}

$UamiId = $null
$UamiPrincipal = ''
try {
    $UamiId = $deployResult.properties.outputs.managedIdentityId.value
    if ($UamiId) {
        $UamiPrincipal = az identity show --ids $UamiId --query principalId -o tsv 2>$null
    }
} catch { }

if ($RolesFile -and (Test-Path $RolesFile)) {
    Write-Host ''
    Write-Header '── Setting up UAMI roles (from roles.yaml) ──'
    if ($UamiPrincipal) {
        Write-Host "  UAMI principal ID: $UamiPrincipal"
    }
    Write-Host ''

    # Use python3 for YAML parsing (same approach as bash version)
    $pyScript = @"
import yaml, sys, os, subprocess

uami = '$UamiPrincipal'
sub = '$SubscriptionId'
rg = '$ResourceGroup'
ag = '$AgentName'
loc = '$Location'

with open(r'$RolesFile') as f:
    data = yaml.safe_load(f)

for role in (data.get('roles') or []):
    rtype = role.get('type', 'manual')
    name = role.get('name', 'unnamed')
    instructions = role.get('instructions', '')

    if rtype == 'azure-role':
        scope = role.get('scope', '')
        role_id = role.get('role_definition_id', '')
        print(f'  Granting Azure role: {name}')
        cmd = f'az role assignment create --assignee-object-id {uami} --assignee-principal-type ServicePrincipal --role "{role_id}" --scope "{scope}"'
        print(f'    Command: {cmd}')
        if uami:
            os.system(cmd)
        else:
            print('    SKIPPED - UAMI principal ID not available')

    elif rtype == 'adx-principal':
        scope = role.get('scope', '')
        adx_role = role.get('role', 'Viewer')
        print(f'  Granting ADX role: {name} ({adx_role})')
        parts = scope.split('/databases/')
        if len(parts) == 2 and uami:
            cluster_url = parts[0]
            db = parts[1]
            cluster_name = cluster_url.split('/')[-1]
            cmd = (
                f'az kusto database-principal-assignment create '
                f'--cluster-name "{cluster_name}" --database-name "{db}" '
                f'--principal-id "{uami}" --principal-type App --role "{adx_role}" '
                f'--principal-assignment-name "sre-agent-{ag}" --subscription "{sub}" 2>NUL '
                f'|| az kusto database add-principal --cluster-name "{cluster_name}" '
                f'--database-name "{db}" --value name="sre-agent-{ag}" type="App" '
                f'app-id="{uami}" role="{adx_role}" 2>NUL'
            )
            if os.system(cmd) == 0:
                print(f'    ADX {adx_role} granted on {db}')
            else:
                print(f'    Could not auto-grant. Run manually:')
                print(f'    az kusto database add-principal --cluster-name "{cluster_name}" --database-name "{db}" --value name="sre-agent-{ag}" type="App" app-id="{uami}" role="{adx_role}"')
        else:
            print(f'    Run manually after deploy - scope: {scope}')

    elif rtype == 'token':
        env_var = role.get('env_var', '')
        print(f'  Token required: {name}')
        if env_var:
            print(f'    Set in connectors.secrets.env: {env_var}=<value>')
        if instructions:
            for line in instructions.strip().split('\n'):
                print(f'    {line}')

    elif rtype == 'manual':
        print(f'  Manual setup required: {name}')
        if instructions:
            for line in instructions.strip().split('\n'):
                print(f'    {line}')
        if uami:
            print(f'    UAMI principal ID: {uami}')

    elif rtype == 'api-connection':
        api_name = role.get('api', '')
        conn_name = f'{ag}-{api_name}'
        print(f'  Creating API connection: {name} ({api_name})')
        create_cmd = (
            f'az resource create '
            f'--resource-group "{rg}" '
            f'--resource-type "Microsoft.Web/connections" '
            f'--name "{conn_name}" '
            f'--location "{loc}" '
            f'--properties \'{{"displayName":"{name}","api":{{"id":"/subscriptions/{sub}/providers/Microsoft.Web/locations/{loc}/managedApis/{api_name}"}}}}\' '
            f'--api-version 2016-06-01'
        )
        print(f'    Creating connection resource...')
        if os.system(create_cmd) == 0:
            consent_cmd = (
                f'az rest --method POST '
                f'--url "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connections/{conn_name}/listConsentLinks?api-version=2016-06-01" '
                f'--body \'{{"parameters":[{{"parameterName":"token","redirectUrl":"https://portal.azure.com"}}]}}\' '
                f'--query "value[0].link" -o tsv 2>NUL'
            )
            result = subprocess.run(consent_cmd, shell=True, capture_output=True, text=True)
            consent_url = result.stdout.strip()
            if consent_url:
                print(f'    Connection created. Open this URL to sign in:')
                print(f'    {consent_url}')
            else:
                print(f'    Connection created. Get consent URL from portal:')
                print(f'    Portal -> Resource Group -> {conn_name} -> Edit API Connection -> Authorize')
        else:
            print(f'    Failed to create connection. Create manually in portal.')

    print()
"@

    try {
        $pyScript | python3 -
    } catch {
        Write-Host '  Could not process roles.yaml (python3 + pyyaml required)'
    }
}

# ── Recipe-specific post-deploy instructions ──
if ($IsDirectory) {
    $agentJsonPath = Join-Path $InputPath 'agent.json'
    if (Test-Path $agentJsonPath) {
        $agentCfg = Get-Content $agentJsonPath -Raw | ConvertFrom-Json
        $Scenario = if ($agentCfg.PSObject.Properties['_scenario']) { $agentCfg._scenario } else { $null }
        $WhEnabled = $false
        if ($agentCfg.PSObject.Properties['toggles'] -and $agentCfg.toggles -and $agentCfg.toggles.PSObject.Properties['enableWebhookBridge']) {
            $WhEnabled = [bool]$agentCfg.toggles.enableWebhookBridge
        }

        switch ($Scenario) {
            'httptrigger-dynatrace' {
                # Try to get the Logic App callback URL
                $WhCallback = ''
                try {
                    $WhCallback = az rest --method POST `
                        --url "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$AgentName-webhook-bridge/triggers/incoming_webhook/listCallbackUrl?api-version=2019-05-01" `
                        --query value -o tsv 2>$null
                } catch { }

                Write-Host ''
                Write-Header '── Dynatrace setup (required to receive alerts) ──'
                Write-Host ''
                if ($WhCallback) {
                    Write-Host '  Webhook bridge URL (use this in Dynatrace):'
                    Write-Host "     $WhCallback"
                } else {
                    Write-Host "  ⚠ Webhook bridge not found. Check Azure portal → $ResourceGroup → $AgentName-webhook-bridge"
                }
                Write-Host ''
                Write-Host '  Option A: Dynatrace Workflow (recommended)'
                Write-Host '  ─────────────────────────────────────────────'
                Write-Host "  1. Go to Dynatrace → Automations → Workflows → + Workflow"
                Write-Host '  2. Add trigger: ''Davis problem'' trigger'
                Write-Host '     - Filter: event.status_transition == "CREATED"'
                Write-Host '       (fires once per problem, not on every status update)'
                Write-Host '  3. Add action: ''Send HTTP request'''
                Write-Host '     - Method: POST'
                if ($WhCallback) {
                    Write-Host "     - URL: $WhCallback"
                } else {
                    Write-Host '     - URL: <webhook bridge URL>'
                }
                Write-Host '     - Headers: Content-Type: application/json'
                Write-Host '     - Payload:'
                Write-Host '       {'
                Write-Host '         "ProblemID": "{{ event()[''event.id''] }}",'
                Write-Host '         "ProblemTitle": "{{ event()[''display_id''] }}: {{ event()[''event.name''] }}",'
                Write-Host '         "State": "{{ event()[''event.status''] }}",'
                Write-Host '         "ProblemSeverity": "{{ event()[''event.category''] }}",'
                Write-Host '         "ProblemURL": "{{ environment().url }}/ui/apps/dynatrace.classic.problems/#problems/problemdetails;pid={{ event()[''event.id''] }}",'
                Write-Host '         "ImpactedEntities": "{{ event()[''affected_entity_ids''] }}",'
                Write-Host '         "ProblemDetailsText": "{{ event()[''event.name''] }}"'
                Write-Host '       }'
                Write-Host '  4. Grant workflow permissions:'
                Write-Host '     Settings → Authorization → Automation Service → grant permissions'
                Write-Host '  5. Activate the workflow'
                Write-Host ''
                Write-Host '  Option B: Classic webhook (simpler but less control)'
                Write-Host '  ────────────────────────────────────────────────────'
                Write-Host '  1. Go to Settings → Integration → Problem notifications'
                Write-Host '  2. Add ''Custom Integration'' webhook'
                if ($WhCallback) {
                    Write-Host "  3. URL: $WhCallback"
                } else {
                    Write-Host '  3. URL: <webhook bridge URL>'
                }
                Write-Host '  4. Send test notification to verify'
                Write-Host ''
                Write-Host '  Test: trigger a problem in Dynatrace (or use the test button)'
                Write-Host '  Then check the agent portal for the incoming investigation:'
                Write-Host "  Portal: https://sre.azure.com/#/agent/$SubscriptionId/$ResourceGroup/$AgentName"
                Write-Host ''
            }
            'pagerduty-law-vmcosmos' {
                Write-Host ''
                Write-Header '── PagerDuty setup ──'
                Write-Host ''
                Write-Host "  1. Open the agent portal: https://sre.azure.com/#/agent/$SubscriptionId/$ResourceGroup/$AgentName"
                Write-Host '  2. Navigate to Incident Platforms → PagerDuty'
                Write-Host '  3. Complete the OAuth flow to connect your PagerDuty account'
                Write-Host '  4. Select which PagerDuty services to monitor'
                Write-Host '  5. The pd-p1p2 response plan routes P1/P2 incidents with customInstructions'
                Write-Host ''
            }
        }
    }
}

# ── Cleanup temp files ──
foreach ($f in $CleanupFiles) {
    if (Test-Path $f -ErrorAction SilentlyContinue) {
        Remove-Item $f -Recurse -Force -ErrorAction SilentlyContinue
    }
}
