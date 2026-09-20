<#
.SYNOPSIS
    Creates the "lab creator" SRE Agent that deploys the Onboarding Lab for you.

.DESCRIPTION
    Run this in Azure Cloud Shell (PowerShell). It is self-contained: it uses only
    the Azure CLI, needs no local tooling, and does NOT need a clone of this
    repository. Every Azure resource is created through az, so there is no Bicep
    to compile here.

    The agent this script creates is the thing that deploys the lab. It clones
    your fork through Code Access and runs the Bicep templates itself.

    Steps:
      0. Preflight: check az, resolve the subscription, resolve the lab RG name.
      1. Register the Microsoft.App resource provider.
      2. Create the lab-creator and lab resource groups.
      3. Create Log Analytics, Application Insights, a managed identity and the agent.
      4. Append the egress hosts the agent needs to reach while deploying.
      5. Grant the agent's identity Owner on the lab resource group.
      6. Pause while you connect your fork as a code repository.
      7. Start a thread asking the agent to deploy the lab.

    The script is re-entrant, because a portal session can die at any point. Run it
    again and it picks up where it stopped. Use -Reset to start over.

    Re-entrancy is mostly not based on the state file: each step asks Azure what
    already exists and skips accordingly, so it behaves correctly even if the state
    file is gone. That matters in Cloud Shell, which only persists $HOME when a
    storage account is mounted.

      Step 1  provider show before register
      Step 2  group show before group create
      Step 3  Log Analytics / App Insights / agent are PUT upserts and az identity
              create is idempotent; the agent is read first, and if it is still
              provisioning the script waits instead of PUTting over it
      Step 4  reads the current allowlist and appends only what is missing
      Step 5  role assignment list before role assignment create
      Step 6  state file only (re-prompting just costs you an extra Enter)
      Step 7  the one step that must not repeat: every POST starts another thread,
              and two threads means two agents deploying the same lab at once, so
              it is skipped when a thread is recorded and asks when it is not

.PARAMETER Subscription
    Subscription to deploy into. Defaults to the current az subscription.

.PARAMETER LabResourceGroup
    Resource group the lab workload is deployed into. Prompted for if not supplied.

.PARAMETER Location
    Region for the agent and the lab. Must support both Azure SRE Agent and, on
    your subscription, PostgreSQL Flexible Server 16 / Standard_B1ms.

.PARAMETER StateFile
    Where progress is recorded so the script can resume.

.PARAMETER Reset
    Discard saved progress and start from the beginning.

.PARAMETER NewThread
    Start another deployment thread even if one was started already.

.EXAMPLE
    ./bootstrap-labcreator.ps1

.EXAMPLE
    ./bootstrap-labcreator.ps1 -LabResourceGroup MyLabRG -Location swedencentral
#>

[CmdletBinding()]
param(
    [string] $Subscription,

    [string] $LabResourceGroup,

    [string] $Location = 'swedencentral',

    [string] $LabCreatorResourceGroup = 'SreAgentLabCreatorRG',

    [string] $LabCreatorAgentName = 'labcreator-sreagent',

    # Progress is recorded here so the script can resume after a dropped session.
    # In Azure Cloud Shell this persists only when a storage account is mounted; an
    # ephemeral session loses it. Losing it is safe: every step re-checks Azure itself
    # rather than trusting this file, and the thread start asks before running twice.
    [string] $StateFile = (Join-Path $HOME '.onboardinglab-bootstrap.json'),

    [switch] $Reset,

    # Start another deployment thread even if one was started already.
    [switch] $NewThread
)

$ErrorActionPreference = 'Stop'

# PS 7.3+ mangles native arguments containing '='; Legacy passing keeps az parameters intact.
if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSVersionTable.PSVersion.Minor -ge 3) {
    $PSNativeCommandArgumentPassing = 'Legacy'
}

$AgentApiVersion = '2025-05-01-preview'

# Hosts the lab-creator agent must reach to deploy the lab.
#   *.bicep.azure.com     - download the Bicep compiler for --template-file *.bicep
#   *.azurewebsites.net   - smoke-test the deployed checkout app
#   *.azuresre.ai         - push skills/knowledge to the new lab agent's data plane
$RequiredEgressHosts = @(
    '*.bicep.azure.com'
    '*.azurewebsites.net'
    '*.azuresre.ai'
)

$RunbookPath = 'labs/onboardinglab/agent-deploy-runbook.md'

# ── Output helpers ──────────────────────────────────────────────────────────

function Write-Step { param([string] $Message) Write-Host "`n== $Message ==" -ForegroundColor Cyan }
function Write-Ok { param([string] $Message) Write-Host "   $Message" -ForegroundColor Green }
function Write-Note { param([string] $Message) Write-Host "   $Message" }

# ── State (re-entrancy) ─────────────────────────────────────────────────────

function Get-State {
    if ($Reset -or -not (Test-Path $StateFile)) { return [ordered]@{} }
    try {
        $raw = Get-Content -Path $StateFile -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return [ordered]@{} }
        $obj = $raw | ConvertFrom-Json
        $table = [ordered]@{}
        foreach ($p in $obj.PSObject.Properties) { $table[$p.Name] = $p.Value }
        return $table
    }
    catch {
        Write-Warning "State file $StateFile is unreadable, starting fresh."
        return [ordered]@{}
    }
}

function Save-State {
    param([Parameter(Mandatory)] $State)
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $StateFile -NoNewline
}

function Test-StepDone {
    param([Parameter(Mandatory)] $State, [Parameter(Mandatory)][string] $Name)
    return ($State.Contains($Name) -and $State[$Name] -eq $true)
}

function Set-StepDone {
    param([Parameter(Mandatory)] $State, [Parameter(Mandatory)][string] $Name)
    $State[$Name] = $true
    Save-State -State $State
}

# ── az helpers ──────────────────────────────────────────────────────────────

function Invoke-Az {
    <#
        Runs az and returns parsed JSON. Throws with az's own stderr on failure so the
        caller sees the real Azure error rather than a generic message.
    #>
    param([Parameter(Mandatory)][string[]] $Arguments, [switch] $AllowEmpty)

    $stdErrFile = [System.IO.Path]::GetTempFileName()
    try {
        $output = & az @Arguments 2> $stdErrFile
        $exit = $LASTEXITCODE
        if ($exit -ne 0) {
            $err = (Get-Content -Path $stdErrFile -Raw)
            throw "az $($Arguments -join ' ') failed (exit $exit).`n$err"
        }
        $joined = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($joined)) {
            if ($AllowEmpty) { return $null }
            throw "az $($Arguments -join ' ') returned no output."
        }
        return $joined | ConvertFrom-Json
    }
    finally {
        Remove-Item -Path $stdErrFile -ErrorAction SilentlyContinue
    }
}

function Invoke-ArmRequest {
    <#
        PUT or PATCH an ARM resource through 'az rest'. Used instead of
        'az resource create' because the agent needs a top-level identity block,
        and App Insights needs a top-level kind, neither of which that command sets.
        Going through az rest also avoids depending on any az extension.
    #>
    param(
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)] $Body
    )

    $file = Join-Path ([System.IO.Path]::GetTempPath()) ("arm-" + [guid]::NewGuid().ToString('n') + '.json')
    try {
        $Body | ConvertTo-Json -Depth 20 | Set-Content -Path $file -NoNewline
        return Invoke-Az @(
            'rest', '--method', $Method, '--url', $Url,
            '--headers', 'Content-Type=application/json',
            '--body', "@$file"
        ) -AllowEmpty
    }
    finally {
        Remove-Item -Path $file -ErrorAction SilentlyContinue
    }
}

function Get-AgentResource {
    param([Parameter(Mandatory)][string] $ResourceGroup, [Parameter(Mandatory)][string] $Name)
    try {
        return Invoke-Az @(
            'resource', 'show', '-g', $ResourceGroup, '-n', $Name,
            '--resource-type', 'Microsoft.App/agents', '--api-version', $AgentApiVersion, '-o', 'json'
        )
    }
    catch { return $null }
}

function Wait-ForAgent {
    <#
        Agent create and update are long-running: ARM returns before the resource is
        ready, so poll until it settles.
    #>
    param(
        [Parameter(Mandatory)][string] $ResourceGroup,
        [Parameter(Mandatory)][string] $Name,
        [int] $TimeoutMinutes = 20
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $state = $null
    do {
        Start-Sleep -Seconds 15
        $agent = Get-AgentResource -ResourceGroup $ResourceGroup -Name $Name
        $state = if ($agent) { $agent.properties.provisioningState } else { 'NotFound' }
        Write-Note "  ... $state"
        if ($state -in @('Failed', 'Canceled')) {
            throw "Agent provisioning ended in state $state. Check the deployment in the portal."
        }
    } while ($state -ne 'Succeeded' -and (Get-Date) -lt $deadline)

    if ($state -ne 'Succeeded') {
        throw "Agent did not reach Succeeded within $TimeoutMinutes minutes (last state: $state)."
    }
    return $agent
}

# ════════════════════════════════════════════════════════════════════════════

Write-Host 'Azure SRE Agent - Onboarding Lab bootstrap' -ForegroundColor White
Write-Host "State file: $StateFile"
if ($Reset) { Write-Warning 'Reset requested - previous progress is being discarded.' }

$state = Get-State

# ── Step 0: preflight ───────────────────────────────────────────────────────

Write-Step 'Preflight'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'The Azure CLI (az) was not found. Run this from Azure Cloud Shell (PowerShell).'
}

$account = Invoke-Az @('account', 'show', '-o', 'json')

if ($Subscription) {
    if ($account.id -ne $Subscription) {
        Write-Note "Switching to subscription $Subscription"
        $null = Invoke-Az @('account', 'set', '--subscription', $Subscription) -AllowEmpty
        $account = Invoke-Az @('account', 'show', '-o', 'json')
    }
}
elseif ($state.Contains('subscriptionId') -and $account.id -ne $state['subscriptionId']) {
    Write-Note "Restoring subscription $($state['subscriptionId']) from saved state"
    $null = Invoke-Az @('account', 'set', '--subscription', $state['subscriptionId']) -AllowEmpty
    $account = Invoke-Az @('account', 'show', '-o', 'json')
}

$subId = $account.id
$state['subscriptionId'] = $subId
Save-State -State $state

Write-Ok "Subscription: $($account.name) ($subId)"
Write-Ok "Signed in as: $($account.user.name)"

# Resolve the lab resource group name up front. The agent is created with both resource
# groups in scope, so the name has to be known before the agent is created.
if (-not $LabResourceGroup) {
    if ($state.Contains('labResourceGroup')) {
        $LabResourceGroup = $state['labResourceGroup']
        Write-Note "Using saved lab resource group: $LabResourceGroup"
    }
    else {
        $answer = Read-Host 'Resource group for the lab [SreAgentOnboardingLabRG]'
        $LabResourceGroup = if ([string]::IsNullOrWhiteSpace($answer)) { 'SreAgentOnboardingLabRG' } else { $answer.Trim() }
    }
}
$state['labResourceGroup'] = $LabResourceGroup
$state['location'] = $Location
Save-State -State $state

Write-Ok "Lab resource group: $LabResourceGroup"
Write-Ok "Location: $Location"

# ── Step 1: register the resource provider ──────────────────────────────────

Write-Step 'Step 1 - Register Microsoft.App'

if (Test-StepDone -State $state -Name 'rpRegistered') {
    Write-Ok 'Already registered (from saved state).'
}
else {
    $provider = Invoke-Az @('provider', 'show', '-n', 'Microsoft.App', '--query', '{state:registrationState}', '-o', 'json')
    if ($provider.state -ne 'Registered') {
        Write-Note "Current state: $($provider.state). Registering..."
        $null = Invoke-Az @('provider', 'register', '-n', 'Microsoft.App') -AllowEmpty

        $deadline = (Get-Date).AddMinutes(10)
        do {
            Start-Sleep -Seconds 10
            $provider = Invoke-Az @('provider', 'show', '-n', 'Microsoft.App', '--query', '{state:registrationState}', '-o', 'json')
            Write-Note "  ... $($provider.state)"
        } while ($provider.state -ne 'Registered' -and (Get-Date) -lt $deadline)

        if ($provider.state -ne 'Registered') {
            throw "Microsoft.App did not reach Registered within 10 minutes (last state: $($provider.state))."
        }
    }
    Write-Ok 'Microsoft.App is registered.'
    Set-StepDone -State $state -Name 'rpRegistered'
}

# ── Step 2: resource groups ─────────────────────────────────────────────────

Write-Step 'Step 2 - Resource groups'

foreach ($rg in @($LabCreatorResourceGroup, $LabResourceGroup)) {
    $existing = $null
    try { $existing = Invoke-Az @('group', 'show', '-n', $rg, '-o', 'json') } catch { $existing = $null }

    if ($existing) {
        Write-Ok "$rg already exists in $($existing.location)."
    }
    else {
        $created = Invoke-Az @('group', 'create', '-n', $rg, '-l', $Location, '-o', 'json')
        Write-Ok "Created $rg in $($created.location)."
    }
}

# ── Step 3: create the lab-creator agent ────────────────────────────────────

Write-Step 'Step 3 - Create the lab-creator agent'

$agent = Get-AgentResource -ResourceGroup $LabCreatorResourceGroup -Name $LabCreatorAgentName
$agentState = if ($agent) { $agent.properties.provisioningState } else { $null }

if ($agentState -eq 'Succeeded') {
    # Tracked so Step 7 can distinguish "first run" from "state file was lost".
    $agentAlreadyExisted = $true
    Write-Ok "Agent $LabCreatorAgentName already exists."
}
elseif ($agent -and $agentState -notin @('Failed', 'Canceled')) {
    # A previous run created it and the session died while it was still provisioning.
    # Wait for it rather than PUTting over a resource that is mid-creation.
    $agentAlreadyExisted = $true
    Write-Note "Agent $LabCreatorAgentName is still provisioning ($agentState). Waiting..."
    $agent = Wait-ForAgent -ResourceGroup $LabCreatorResourceGroup -Name $LabCreatorAgentName
    Write-Ok "Agent $LabCreatorAgentName is ready."
}
else {
    if ($agentState -in @('Failed', 'Canceled')) {
        Write-Note "Agent $LabCreatorAgentName is in state $agentState. Recreating it."
    }
    $agentAlreadyExisted = $false

    # Deterministic suffix so re-runs address the same Log Analytics / App Insights resources.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$subId|$LabCreatorResourceGroup|$LabCreatorAgentName"))
        $suffix = (([System.BitConverter]::ToString($bytes)) -replace '-', '').ToLowerInvariant().Substring(0, 10)
    }
    finally { $sha.Dispose() }

    $rgBase = "https://management.azure.com/subscriptions/$subId/resourceGroups/$LabCreatorResourceGroup/providers"

    # Log Analytics workspace — backs Application Insights.
    $lawName = "law-$suffix"
    Write-Note "Creating Log Analytics workspace $lawName..."
    $law = Invoke-ArmRequest -Method 'put' `
        -Url "$rgBase/Microsoft.OperationalInsights/workspaces/$lawName`?api-version=2023-09-01" `
        -Body ([ordered]@{
            location   = $Location
            properties = [ordered]@{
                sku             = @{ name = 'PerGB2018' }
                retentionInDays = 30
            }
        })
    if (-not $law.id) { throw "Could not create Log Analytics workspace $lawName." }
    Write-Ok "Workspace $lawName ready."

    # Application Insights — the agent's own telemetry.
    $aiName = "ai-$suffix"
    Write-Note "Creating Application Insights $aiName..."
    $null = Invoke-ArmRequest -Method 'put' `
        -Url "$rgBase/Microsoft.Insights/components/$aiName`?api-version=2020-02-02" `
        -Body ([ordered]@{
            location   = $Location
            kind       = 'web'
            properties = [ordered]@{
                Application_Type    = 'web'
                Request_Source      = 'SreAgent'
                WorkspaceResourceId = $law.id
            }
        })

    # Read it back: AppId and ConnectionString are assigned by the service.
    $appInsights = Invoke-Az @(
        'resource', 'show', '-g', $LabCreatorResourceGroup, '-n', $aiName,
        '--resource-type', 'Microsoft.Insights/components', '--api-version', '2020-02-02', '-o', 'json'
    )
    $aiAppId = $appInsights.properties.AppId
    $aiConnectionString = $appInsights.properties.ConnectionString
    if ([string]::IsNullOrWhiteSpace($aiAppId) -or [string]::IsNullOrWhiteSpace($aiConnectionString)) {
        throw "Application Insights $aiName has no AppId/ConnectionString yet. Re-run this script."
    }
    Write-Ok "Application Insights $aiName ready."

    # Managed identity the agent acts as.
    $identityName = "$LabCreatorAgentName-id-$suffix"
    Write-Note "Creating managed identity $identityName..."
    $identity = Invoke-Az @(
        'identity', 'create', '-g', $LabCreatorResourceGroup, '-n', $identityName, '-l', $Location, '-o', 'json'
    )
    if (-not $identity.principalId) { throw "Could not create managed identity $identityName." }
    Write-Ok "Identity $identityName ready."

    # Monitoring Reader for the identity on the lab-creator group, so the agent can read
    # its own telemetry. Access on the lab group is granted in Step 5.
    $creatorScope = "/subscriptions/$subId/resourceGroups/$LabCreatorResourceGroup"
    $existingMonReader = Invoke-Az @(
        'role', 'assignment', 'list', '--assignee', $identity.principalId,
        '--scope', $creatorScope, '--query', "[?roleDefinitionName=='Monitoring Reader']", '-o', 'json'
    ) -AllowEmpty
    if (-not ($existingMonReader -and @($existingMonReader).Count -gt 0)) {
        $null = Invoke-Az @(
            'role', 'assignment', 'create',
            '--assignee-object-id', $identity.principalId,
            '--assignee-principal-type', 'ServicePrincipal',
            '--role', 'Monitoring Reader',
            '--scope', $creatorScope, '-o', 'json'
        ) -AllowEmpty
    }

    # The agent itself.
    #   accessLevel High  - it needs to create resources to deploy the lab
    #   actionMode Review - you approve every write it proposes
    $agentBody = [ordered]@{
        location   = $Location
        tags       = @{ workload = 'onboardinglab-labcreator' }
        identity   = [ordered]@{
            type                   = 'SystemAssigned, UserAssigned'
            userAssignedIdentities = @{ "$($identity.id)" = @{} }
        }
        properties = [ordered]@{
            knowledgeGraphConfiguration = [ordered]@{
                identity         = $identity.id
                managedResources = @(
                    "/subscriptions/$subId/resourceGroups/$LabCreatorResourceGroup"
                    "/subscriptions/$subId/resourceGroups/$LabResourceGroup"
                )
            }
            actionConfiguration         = [ordered]@{
                accessLevel = 'High'
                identity    = $identity.id
                mode        = 'Review'
            }
            logConfiguration            = [ordered]@{
                applicationInsightsConfiguration = [ordered]@{
                    appId            = $aiAppId
                    connectionString = $aiConnectionString
                }
            }
            upgradeChannel              = 'Preview'
            monthlyAgentUnitLimit       = 10000
            defaultModel                = [ordered]@{
                provider = 'MicrosoftFoundry'
                name     = 'Automatic'
            }
            experimentalSettings        = [ordered]@{
                EnableWorkspaceTools = $true
                EnableHttpTriggers   = $true
                EnableV2AgentLoop    = $true
            }
        }
    }

    Write-Note "Creating agent $LabCreatorAgentName (this takes a few minutes)..."
    $null = Invoke-ArmRequest -Method 'put' `
        -Url "$rgBase/Microsoft.App/agents/$LabCreatorAgentName`?api-version=$AgentApiVersion" `
        -Body $agentBody

    $agent = Wait-ForAgent -ResourceGroup $LabCreatorResourceGroup -Name $LabCreatorAgentName
    Write-Ok "Agent $LabCreatorAgentName created."
}

# Always read the agent back: the data-plane hostname contains service-assigned segments and
# cannot be composed from the agent name and region.
$agent = Get-AgentResource -ResourceGroup $LabCreatorResourceGroup -Name $LabCreatorAgentName
if (-not $agent) { throw "Agent $LabCreatorAgentName could not be read back." }

$agentEndpoint = $agent.properties.agentEndpoint
if ([string]::IsNullOrWhiteSpace($agentEndpoint)) {
    throw 'The agent has no agentEndpoint yet. Wait a moment and re-run this script.'
}

$agentUamiPrincipalId = $null
foreach ($uami in $agent.identity.userAssignedIdentities.PSObject.Properties) {
    $agentUamiPrincipalId = $uami.Value.principalId
    break
}
if (-not $agentUamiPrincipalId) {
    throw 'Could not determine the user-assigned managed identity of the agent.'
}

$state['agentEndpoint'] = $agentEndpoint
$state['agentUamiPrincipalId'] = $agentUamiPrincipalId
Save-State -State $state

Write-Ok "Endpoint: $agentEndpoint"
Write-Ok "Agent identity: $agentUamiPrincipalId"

# ── Step 4: egress allowlist ────────────────────────────────────────────────

Write-Step 'Step 4 - Allow the egress hosts the agent needs'

# Read the current egress block and append. Do NOT write a fresh list: the platform seeds
# roughly thirty defaults (management.azure.com, api.github.com, the package registries, ...)
# and replacing them would leave the agent unable to reach Azure at all.
$egress = $agent.properties.sandboxConfiguration.egress

if (-not $egress -or $egress.mode -eq 'Unrestricted') {
    # No restriction in force, so the hosts are already reachable. Writing an allowlist
    # here would *introduce* a restriction rather than relax one.
    Write-Ok 'Sandbox egress is unrestricted; no allowlist needed.'
}
else {
    $currentHosts = @()
    if ($egress.allowedHosts) { $currentHosts = @($egress.allowedHosts) }

    $missing = @($RequiredEgressHosts | Where-Object { $_ -notin $currentHosts })

    if ($missing.Count -eq 0) {
        Write-Ok 'All required hosts are already allowed.'
    }
    else {
        Write-Note "Adding: $($missing -join ', ')"

        $egressBody = [ordered]@{
            mode         = $egress.mode
            allowedHosts = @($currentHosts + $missing)
        }
        # Preserve the other egress settings verbatim.
        if ($null -ne $egress.allowedRegistries) { $egressBody['allowedRegistries'] = @($egress.allowedRegistries) }
        if ($null -ne $egress.allowedCodeRepositories) { $egressBody['allowedCodeRepositories'] = @($egress.allowedCodeRepositories) }
        if ($null -ne $egress.allowHttpMcpServerNetworkAccess) { $egressBody['allowHttpMcpServerNetworkAccess'] = $egress.allowHttpMcpServerNetworkAccess }

        $armUrl = "https://management.azure.com/subscriptions/$subId/resourceGroups/$LabCreatorResourceGroup/providers/Microsoft.App/agents/$LabCreatorAgentName" + "?api-version=$AgentApiVersion"
        $null = Invoke-ArmRequest -Method 'patch' -Url $armUrl `
            -Body @{ properties = @{ sandboxConfiguration = @{ egress = $egressBody } } }

        # The PATCH briefly moves the agent to InProgress; wait for it to settle.
        $deadline = (Get-Date).AddMinutes(5)
        do {
            Start-Sleep -Seconds 10
            $check = Invoke-Az @(
                'resource', 'show', '-g', $LabCreatorResourceGroup, '-n', $LabCreatorAgentName,
                '--resource-type', 'Microsoft.App/agents', '--api-version', $AgentApiVersion,
                '--query', '{state:properties.provisioningState,hosts:properties.sandboxConfiguration.egress.allowedHosts}', '-o', 'json'
            )
        } while ($check.state -eq 'InProgress' -and (Get-Date) -lt $deadline)

        $stillMissing = @($RequiredEgressHosts | Where-Object { $_ -notin @($check.hosts) })
        if ($stillMissing.Count -gt 0) {
            throw "Egress update did not take effect. Still missing: $($stillMissing -join ', ')"
        }
        Write-Ok 'Egress hosts allowed.'
    }
}

# ── Step 5: grant Owner on the lab resource group ───────────────────────────

Write-Step 'Step 5 - Grant the agent Owner on the lab resource group'

$labScope = "/subscriptions/$subId/resourceGroups/$LabResourceGroup"

# Owner is required because deploying the lab agent creates role assignments
# (Reader, Monitoring Reader, Log Analytics Reader), which Contributor cannot do.
$existingAssignments = Invoke-Az @(
    'role', 'assignment', 'list',
    '--assignee', $agentUamiPrincipalId,
    '--scope', $labScope,
    '--query', "[?roleDefinitionName=='Owner']",
    '-o', 'json'
) -AllowEmpty

if ($existingAssignments -and @($existingAssignments).Count -gt 0) {
    Write-Ok 'Owner already assigned.'
}
else {
    $null = Invoke-Az @(
        'role', 'assignment', 'create',
        '--assignee-object-id', $agentUamiPrincipalId,
        '--assignee-principal-type', 'ServicePrincipal',
        '--role', 'Owner',
        '--scope', $labScope,
        '-o', 'json'
    ) -AllowEmpty
    Write-Ok "Owner granted on $LabResourceGroup."
}

# ── Step 6: connect the code repository ─────────────────────────────────────

Write-Step 'Step 6 - Connect your fork as a code repository'

if (Test-StepDone -State $state -Name 'codeAccessConfirmed') {
    Write-Ok 'Already confirmed (from saved state). Use -Reset to redo this step.'
}
else {
    $portalUrl = "https://sre.azure.com/#/agent/$subId/$LabCreatorResourceGroup/$LabCreatorAgentName"

    Write-Host ''
    Write-Host '   The agent clones your fork of the sre-agent repository and deploys the lab' -ForegroundColor Yellow
    Write-Host "   from it, so it needs read access to $RunbookPath and the lab templates." -ForegroundColor Yellow
    Write-Host ''
    Write-Host '   1. Open the agent in the portal:'
    Write-Host "      $portalUrl"
    Write-Host '   2. Go to Manage - Sources (code repositories).'
    Write-Host '   3. Choose Add / Connect, pick GitHub, and complete the sign-in and consent.'
    Write-Host '   4. Select your fork of sre-agent and grant read access.'
    Write-Host '   5. Wait until the repository shows as connected.'
    Write-Host ''
    Write-Host '   This step is manual: it needs an interactive OAuth consent that cannot be' -ForegroundColor DarkGray
    Write-Host '   scripted. If this session dies, re-run the script and it resumes here.' -ForegroundColor DarkGray
    Write-Host ''

    $null = Read-Host '   Press Enter once the repository is connected'
    Set-StepDone -State $state -Name 'codeAccessConfirmed'
    Write-Ok 'Code access confirmed.'
}

# ── Step 7: start the deployment thread ─────────────────────────────────────

Write-Step 'Step 7 - Ask the agent to deploy the lab'

# This is the one step that is not safe to simply repeat: every POST starts another
# thread, and two threads would have two agents deploying the same lab into the same
# resource group at once, each asking for conflicting approvals.
$existingThreadId = if ($state.Contains('threadId')) { $state['threadId'] } else { $null }
$threadId = $existingThreadId
$startThread = $true

if ($existingThreadId -and -not $NewThread) {
    Write-Ok "A deployment thread was already started: $existingThreadId"
    Write-Note 'Re-running does not start another one. Use -NewThread to force a fresh thread.'
    $startThread = $false
}
elseif ($agentAlreadyExisted -and -not $NewThread) {
    # The agent predates this run but nothing recorded a thread, which usually means the
    # state file was lost with an ephemeral Cloud Shell session. A thread may already be
    # running, so confirm rather than silently starting a second one.
    Write-Host ''
    Write-Warning 'The agent already existed, but this run has no record of a deployment thread.'
    Write-Host '   The state file was probably lost with a previous session.' -ForegroundColor DarkGray
    Write-Host '   Check whether a deployment is already running before starting another:' -ForegroundColor DarkGray
    Write-Host "   https://sre.azure.com/#/agent/$subId/$LabCreatorResourceGroup/$LabCreatorAgentName"
    Write-Host ''
    $reply = Read-Host '   Start a new deployment thread? [y/N]'
    if ($reply -notmatch '^\s*[Yy]') {
        Write-Note 'Skipped. Re-run with -NewThread once you are sure no thread is running.'
        $startThread = $false
    }
}

$startMessage = @"
Deploy the Azure SRE Agent Onboarding Lab.

The sre-agent repository you connected through Code Access is already synced into your
workspace. Follow the runbook at $RunbookPath. Work through every step in order and run its
verification before moving on.

Inputs:
- SUBSCRIPTION: $subId
- LAB_RG: $LabResourceGroup
- LOCATION: $Location
- NAME_PREFIX: flu-lab01
- AGENT_NAME: onboardinglab-agent

The resource group already exists and you have Owner on it. Leave the database fault off.
Do not modify anything outside $LabResourceGroup. Report what you created when you are done.
"@

if ($startThread) {
    $dpToken = (& az account get-access-token --resource 'https://azuresre.dev' --query accessToken -o tsv 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($dpToken -join ''))) {
        throw 'Could not get a data-plane token for https://azuresre.dev. Run: az login --scope "https://azuresre.dev/.default" and re-run this script.'
    }
    $dpToken = ($dpToken -join '').Trim()

    $body = @{ StartMessage = $startMessage } | ConvertTo-Json -Depth 5

    try {
        $thread = Invoke-RestMethod -Uri "$agentEndpoint/api/v1/threads" -Method Post `
            -Headers @{ Authorization = "Bearer $dpToken" } `
            -ContentType 'application/json' -Body $body -TimeoutSec 60
    }
    catch {
        throw "Could not start the agent thread: $($_.Exception.Message)"
    }
    finally {
        $dpToken = $null
    }

    $threadId = if ($thread.id) { $thread.id } elseif ($thread.threadId) { $thread.threadId } else { $null }

    # Recorded immediately so a session that dies right after this does not start a second
    # thread on the next run.
    $state['threadId'] = $threadId
    Save-State -State $state

    Write-Ok 'Thread started.'
}

# ── Done ────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host 'Bootstrap complete.' -ForegroundColor Green
Write-Host ''
Write-Host "  Lab-creator agent : $LabCreatorAgentName (in $LabCreatorResourceGroup)"
Write-Host "  Lab resource group: $LabResourceGroup"
Write-Host "  Region            : $Location"
if ($threadId) { Write-Host "  Thread            : $threadId" }
Write-Host ''
Write-Host '  Watch progress at:'
Write-Host "  https://sre.azure.com/#/agent/$subId/$LabCreatorResourceGroup/$LabCreatorAgentName"
Write-Host ''
Write-Host '  The agent runs in Review mode, so approve each action as it is proposed.' -ForegroundColor Yellow
Write-Host '  Read commands run without prompting; only writes need your approval.' -ForegroundColor DarkGray
Write-Host ''
