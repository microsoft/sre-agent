<#
.SYNOPSIS
    Creates the final SRE Agent that deploys its own Onboarding Lab environment.

.DESCRIPTION
    Run this in Azure Cloud Shell (PowerShell). It is self-contained: it uses only
    the Azure CLI, needs no local tooling, and does NOT need a clone of this
    repository. Every Azure resource is created through az, so there is no Bicep
    to compile here.

    The script creates the final onboarding agent with temporary Owner access on
    the lab resource group. The agent clones your fork through Code Access and
    deploys the workload and its durable configuration through Bicep.

    Steps:
      0. Preflight: check az, resolve the subscription, resolve the lab RG name.
      1. Register the Microsoft.App resource provider.
      2. Create the lab resource group.
      3. Create Log Analytics, Application Insights, a managed identity and the final agent.
      4. Append the egress hosts the agent needs to reach while deploying.
      5. Grant the agent identity temporary Owner and grant agent-scoped
         SRE Agent Administrator to the identity and signed-in user.
      6. Acquire an interactive data-plane token when Cloud Shell requires one,
         then pause while you connect your fork as a code repository.
      7. Start a thread asking the agent to deploy the lab.

    The script is re-entrant, because a portal session can die at any point. Run it
    again and it picks up where it stopped. Use -Reset to start over. After the
    deployment thread completes, run with -Finalize to remove temporary Owner
    and set the agent to Low access.

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

.PARAMETER AgentName
    Name of the final SRE Agent.

.PARAMETER StateFile
    Where progress is recorded so the script can resume.

.PARAMETER Finalize
    Remove the agent identity's temporary Owner assignment and set the agent to
    Low access after the deployment thread has completed successfully.

.PARAMETER Reset
    Discard saved progress and start from the beginning.

.PARAMETER NewThread
    Start another deployment thread even if one was started already.

.EXAMPLE
    ./bootstrap-agent.ps1

.EXAMPLE
    ./bootstrap-agent.ps1 -LabResourceGroup MyLabRG -Location swedencentral

.EXAMPLE
    ./bootstrap-agent.ps1 -LabResourceGroup MyLabRG -Finalize
#>

[CmdletBinding()]
param(
    [string] $Subscription,

    [string] $LabResourceGroup,

    [string] $Location = 'swedencentral',

    [string] $AgentName = 'onboardinglab-agent',

    # Progress is recorded here so the script can resume after a dropped session.
    # In Azure Cloud Shell this persists only when a storage account is mounted; an
    # ephemeral session loses it. Losing it is safe: every step re-checks Azure itself
    # rather than trusting this file, and the thread start asks before running twice.
    [string] $StateFile = (Join-Path $HOME '.onboardinglab-agent-bootstrap.json'),

    [switch] $Reset,

    [switch] $Finalize,

    # Start another deployment thread even if one was started already.
    [switch] $NewThread
)

$ErrorActionPreference = 'Stop'

# PS 7.3+ mangles native arguments containing '='; Legacy passing keeps az parameters intact.
if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSVersionTable.PSVersion.Minor -ge 3) {
    $PSNativeCommandArgumentPassing = 'Legacy'
}

$AgentApiVersion = '2025-05-01-preview'

# Hosts the onboarding agent must reach while it deploys the lab.
#   *.bicep.azure.com     - download the Bicep compiler for --template-file *.bicep
#   *.azurewebsites.net   - smoke-test the deployed checkout app
#   *.azuresre.ai         - push skills/knowledge to the agent's data plane
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

function Get-StableGuid {
    param([Parameter(Mandatory)][string] $Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
        $bytes = [byte[]]::new(16)
        [Array]::Copy($hash, $bytes, 16)
        return [guid]::new($bytes).ToString()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-KnowledgeResourceName {
    param([Parameter(Mandatory)][string] $FileName)

    $sanitized = ($FileName.ToLowerInvariant() -replace '[^a-z0-9-]', '-') -replace '-+', '-' -replace '^-|-$', ''
    if ($sanitized.Length -le 32) {
        return $sanitized
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sanitized)) |
            ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 7)
        return "$($sanitized.Substring(0, 24))-$hash"
    }
    finally {
        $sha.Dispose()
    }
}

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

function Get-SignedInUserObjectId {
    try {
        $user = Invoke-Az @('ad', 'signed-in-user', 'show', '--query', '{id:id}', '-o', 'json')
        if (-not [string]::IsNullOrWhiteSpace($user.id)) {
            return $user.id
        }
    }
    catch {
        Write-Note 'Microsoft Graph did not return the signed-in user. Reading the object ID from the ARM token instead.'
    }

    $token = (& az account get-access-token --resource 'https://management.azure.com/' `
        --query accessToken --only-show-errors -o tsv 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($token -join ''))) {
        throw 'Could not determine the signed-in user object ID.'
    }

    try {
        $payload = (($token -join '').Trim().Split('.')[1]).Replace('-', '+').Replace('_', '/')
        $payload = $payload.PadRight($payload.Length + ((4 - ($payload.Length % 4)) % 4), '=')
        $claims = [System.Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($payload)
        ) | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($claims.oid)) {
            throw 'The ARM token has no oid claim.'
        }
        return $claims.oid
    }
    catch {
        throw "Could not determine the signed-in user object ID: $($_.Exception.Message)"
    }
}

$script:DataPlaneToken = $null
$script:SelectedSubscriptionId = $null
$script:SignedInUserObjectId = $null

function Get-DataPlaneToken {
    if (-not [string]::IsNullOrWhiteSpace($script:DataPlaneToken)) {
        return $script:DataPlaneToken
    }

    $token = (& az account get-access-token --scope 'https://azuresre.dev/.default' `
        --query accessToken --only-show-errors -o tsv 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($token -join ''))) {
        Write-Warning 'Cloud Shell could not issue an SRE Agent data-plane token with its built-in credential.'
        Write-Host '   An interactive Azure CLI sign-in is required for Code Access and agent data-plane calls.' -ForegroundColor Yellow
        $reply = Read-Host '   Start device-code sign-in now? [Y/n]'
        if ($reply -match '^\s*[Nn]') {
            throw 'SRE Agent sign-in is required. Run az login --use-device-code --scope "https://azuresre.dev/.default", then rerun this script.'
        }

        & az login --use-device-code --scope 'https://azuresre.dev/.default' --output none
        if ($LASTEXITCODE -ne 0) {
            throw 'Interactive Azure CLI sign-in failed. Rerun the script to try again.'
        }
        if (-not [string]::IsNullOrWhiteSpace($script:SelectedSubscriptionId)) {
            $null = Invoke-Az @('account', 'set', '--subscription', $script:SelectedSubscriptionId) -AllowEmpty
        }
        $interactiveUserObjectId = Get-SignedInUserObjectId
        if (-not [string]::IsNullOrWhiteSpace($script:SignedInUserObjectId) -and
            $interactiveUserObjectId -ne $script:SignedInUserObjectId) {
            throw 'Interactive sign-in used a different account. Sign in with the same user that started the bootstrap script.'
        }

        $token = (& az account get-access-token --scope 'https://azuresre.dev/.default' `
            --query accessToken --only-show-errors -o tsv 2>$null)
    }

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($token -join ''))) {
        throw 'Could not get an SRE Agent data-plane token after interactive sign-in.'
    }

    $script:DataPlaneToken = ($token -join '').Trim()
    return $script:DataPlaneToken
}

function Invoke-DataPlaneGet {
    param([Parameter(Mandatory)][string] $Url)

    $token = Get-DataPlaneToken
    try {
        for ($attempt = 1; $attempt -le 7; $attempt++) {
            try {
                return Invoke-RestMethod -Uri $Url -Method Get `
                    -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 60
            }
            catch {
                $statusCode = [int]$_.Exception.Response.StatusCode
                if ($statusCode -eq 403 -and $attempt -lt 7) {
                    if ($attempt -eq 1) {
                        Write-Note 'Waiting for the SRE Agent Administrator assignment to propagate...'
                    }
                    Start-Sleep -Seconds 10
                    continue
                }
                if ($statusCode -eq 403) {
                    throw 'SRE Agent data-plane access was denied after waiting for RBAC propagation. Wait another minute, sign out and back in if using the portal, then rerun this script.'
                }
                throw "SRE Agent data-plane request failed for $Url`: $($_.Exception.Message)"
            }
        }
    }
    finally {
        $token = $null
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

function Get-ConnectedRepositories {
    param([Parameter(Mandatory)][string] $Endpoint)

    $response = Invoke-DataPlaneGet -Url "$($Endpoint.TrimEnd('/'))/api/v2/repos"
    if ($response.PSObject.Properties['value']) {
        return @($response.value)
    }
    return @($response)
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
if (-not $Finalize -and -not $Reset -and $state.Contains('finalized') -and $state['finalized'] -eq $true) {
    throw 'This environment is finalized. Use -Reset only when you intentionally want to start a new deployment lifecycle.'
}

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
$script:SelectedSubscriptionId = $subId
$state['subscriptionId'] = $subId
Save-State -State $state

Write-Ok "Subscription: $($account.name) ($subId)"
Write-Ok "Signed in as: $($account.user.name)"

if ($account.user.type -ne 'user') {
    throw 'This bootstrap flow requires an interactive human Azure CLI sign-in so it can grant agent data-plane access for Code Access.'
}
$signedInUserObjectId = Get-SignedInUserObjectId
$script:SignedInUserObjectId = $signedInUserObjectId

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
if (-not $PSBoundParameters.ContainsKey('Location') -and $state.Contains('location')) {
    $Location = $state['location']
}
if (-not $PSBoundParameters.ContainsKey('AgentName') -and $state.Contains('agentName')) {
    $AgentName = $state['agentName']
}
$state['labResourceGroup'] = $LabResourceGroup
$state['location'] = $Location
$state['agentName'] = $AgentName
Save-State -State $state

Write-Ok "Lab resource group: $LabResourceGroup"
Write-Ok "Location: $Location"
Write-Ok "Agent: $AgentName"

if ($Finalize) {
    Write-Step 'Finalize - Remove temporary deployment access'

    $agent = Get-AgentResource -ResourceGroup $LabResourceGroup -Name $AgentName
    if (-not $agent) {
        throw "Agent $AgentName was not found in $LabResourceGroup."
    }

    $identityId = @($agent.identity.userAssignedIdentities.PSObject.Properties.Name)[0]
    $identityPrincipalId = @($agent.identity.userAssignedIdentities.PSObject.Properties.Value.principalId)[0]
    $systemPrincipalId = $agent.identity.principalId
    if ([string]::IsNullOrWhiteSpace($identityId) -or
        [string]::IsNullOrWhiteSpace($identityPrincipalId) -or
        [string]::IsNullOrWhiteSpace($systemPrincipalId)) {
        throw "Agent $AgentName does not have the expected managed identities."
    }

    $labScope = "/subscriptions/$subId/resourceGroups/$LabResourceGroup"
    $ownerAssignmentName = Get-StableGuid "$labScope|$identityPrincipalId|onboardinglab-temporary-owner"
    $ownerAssignmentId = "$labScope/providers/Microsoft.Authorization/roleAssignments/$ownerAssignmentName"
    $requiredRoles = @('Reader', 'Monitoring Reader', 'Log Analytics Reader')
    $assignments = @(Invoke-Az @(
        'role', 'assignment', 'list',
        '--assignee', $identityPrincipalId,
        '--scope', $labScope,
        '--query', '[].{id:id,role:roleDefinitionName,scope:scope}',
        '-o', 'json'
    ) -AllowEmpty)

    $missingRoles = @($requiredRoles | Where-Object { $role = $_; -not ($assignments | Where-Object { $_.role -eq $role -and $_.scope -eq $labScope }) })
    if ($missingRoles.Count -gt 0) {
        throw "Cannot finalize because permanent role assignments are missing: $($missingRoles -join ', '). Complete the deployment thread first."
    }

    $systemAssignments = @(Invoke-Az @(
        'role', 'assignment', 'list',
        '--assignee', $systemPrincipalId,
        '--scope', $labScope,
        '--query', '[].{role:roleDefinitionName,scope:scope}',
        '-o', 'json'
    ) -AllowEmpty)
    $missingSystemRoles = @(@('Reader', 'Log Analytics Reader') | Where-Object {
        $role = $_
        -not ($systemAssignments | Where-Object { $_.role -eq $role -and $_.scope -eq $labScope })
    })
    if ($missingSystemRoles.Count -gt 0) {
        throw "Cannot finalize because system identity roles are missing: $($missingSystemRoles -join ', '). Complete the deployment thread first."
    }

    $connectorUrl = "https://management.azure.com/subscriptions/$subId/resourceGroups/$LabResourceGroup/providers/Microsoft.App/agents/$AgentName/connectors/app-insights?api-version=$AgentApiVersion"
    $connector = Invoke-Az @('rest', '--method', 'get', '--url', $connectorUrl, '-o', 'json')
    if ($connector.properties.provisioningState -notin @('Succeeded', 'Running')) {
        throw "Cannot finalize because the app-insights connector is not ready (state: $($connector.properties.provisioningState))."
    }

    if ($agent.properties.incidentManagementConfiguration.type -ne 'AzMonitor') {
        throw 'Cannot finalize because the Azure Monitor incident platform is not configured.'
    }

    $endpoint = $agent.properties.agentEndpoint.TrimEnd('/')
    $requiredDataPlaneObjects = @(
        @{ Kind = 'skills'; Name = 'sre-agent-self-configure' }
        @{ Kind = 'skills'; Name = 'onboarding-lab-guide' }
        @{ Kind = 'skills'; Name = 'onboarding-health-check' }
        @{ Kind = 'hooks'; Name = 'evidence-checklist' }
        @{ Kind = 'commonprompts'; Name = 'onboardinglab-safety' }
    )
    foreach ($fileName in @('onboardinglab-architecture.md', 'onboardinglab-incident-runbook.md')) {
        $requiredDataPlaneObjects += @{
            Kind = 'connectors'
            Name = (Get-KnowledgeResourceName -FileName $fileName)
        }
    }
    foreach ($item in $requiredDataPlaneObjects) {
        $encodedName = [uri]::EscapeDataString($item.Name)
        $installed = Invoke-DataPlaneGet -Url "$endpoint/api/v2/extendedAgent/$($item.Kind)/$encodedName"
        if ($installed.name -ne $item.Name) {
            throw "Cannot finalize because $($item.Kind)/$($item.Name) could not be verified."
        }
    }

    $globalSettings = Invoke-DataPlaneGet -Url "$endpoint/api/v2/agent/settings/global"
    if ('RunAzCliWriteCommands' -notin @($globalSettings.permissions.ask) -or
        'RunInTerminal' -notin @($globalSettings.permissions.deny) -or
        'Terminal' -notin @($globalSettings.permissions.deny)) {
        throw 'Cannot finalize because the expected Review-mode tool policy is not installed.'
    }

    $temporaryOwner = @($assignments | Where-Object {
        $_.role -eq 'Owner' -and $_.scope -eq $labScope -and $_.id -eq $ownerAssignmentId
    })
    if ($temporaryOwner.Count -ne 1) {
        throw 'Cannot finalize because the temporary Owner assignment created by this script was not found.'
    }
    $null = Invoke-Az @('role', 'assignment', 'delete', '--ids', $ownerAssignmentId) -AllowEmpty

    $agentUrl = "https://management.azure.com/subscriptions/$subId/resourceGroups/$LabResourceGroup/providers/Microsoft.App/agents/$AgentName`?api-version=$AgentApiVersion"
    $null = Invoke-ArmRequest -Method 'patch' -Url $agentUrl -Body @{
        properties = @{
            actionConfiguration = @{
                accessLevel = 'Low'
                identity = $identityId
                mode = 'Review'
            }
        }
    }
    $agent = Wait-ForAgent -ResourceGroup $LabResourceGroup -Name $AgentName

    $remainingOwner = @(Invoke-Az @(
        'role', 'assignment', 'list',
        '--scope', $labScope,
        '--query', "[?name=='$ownerAssignmentName']",
        '-o', 'json'
    ) -AllowEmpty)
    if ($remainingOwner.Count -gt 0) {
        throw "Temporary Owner could not be removed from $LabResourceGroup."
    }
    if ($agent.properties.actionConfiguration.accessLevel -ne 'Low' -or
        $agent.properties.actionConfiguration.mode -ne 'Review') {
        throw 'Agent access did not converge to Low/Review.'
    }

    $state['finalized'] = $true
    Save-State -State $state
    Write-Ok 'Temporary Owner removed.'
    Write-Ok 'Permanent read-only roles verified.'
    Write-Ok 'Agent access is Low/Review.'
    return
}

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

$existing = $null
try { $existing = Invoke-Az @('group', 'show', '-n', $LabResourceGroup, '-o', 'json') } catch { $existing = $null }

if ($existing) {
    Write-Ok "$LabResourceGroup already exists in $($existing.location)."
}
else {
    $created = Invoke-Az @('group', 'create', '-n', $LabResourceGroup, '-l', $Location, '-o', 'json')
    Write-Ok "Created $LabResourceGroup in $($created.location)."
}

# ── Step 3: create the final onboarding agent ───────────────────────────────

Write-Step 'Step 3 - Create the final onboarding agent'

$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$subId|$LabResourceGroup|$AgentName"))
    $suffix = (([System.BitConverter]::ToString($bytes)) -replace '-', '').ToLowerInvariant().Substring(0, 10)
}
finally { $sha.Dispose() }

$lawName = "law-$suffix"
$aiName = "ai-$suffix"
$identityName = "$AgentName-id-$suffix"
$rgBase = "https://management.azure.com/subscriptions/$subId/resourceGroups/$LabResourceGroup/providers"

$agent = Get-AgentResource -ResourceGroup $LabResourceGroup -Name $AgentName
$agentState = if ($agent) { $agent.properties.provisioningState } else { $null }

if ($agentState -eq 'Succeeded') {
    # Tracked so Step 7 can distinguish "first run" from "state file was lost".
    $agentAlreadyExisted = $true
    Write-Ok "Agent $AgentName already exists."
}
elseif ($agent -and $agentState -notin @('Failed', 'Canceled')) {
    # A previous run created it and the session died while it was still provisioning.
    # Wait for it rather than PUTting over a resource that is mid-creation.
    $agentAlreadyExisted = $true
    Write-Note "Agent $AgentName is still provisioning ($agentState). Waiting..."
    $agent = Wait-ForAgent -ResourceGroup $LabResourceGroup -Name $AgentName
    Write-Ok "Agent $AgentName is ready."
}
else {
    if ($agentState -in @('Failed', 'Canceled')) {
        Write-Note "Agent $AgentName is in state $agentState. Recreating it."
    }
    $agentAlreadyExisted = $false

    # Log Analytics workspace — backs Application Insights.
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
        'resource', 'show', '-g', $LabResourceGroup, '-n', $aiName,
        '--resource-type', 'Microsoft.Insights/components', '--api-version', '2020-02-02', '-o', 'json'
    )
    $aiAppId = $appInsights.properties.AppId
    $aiConnectionString = $appInsights.properties.ConnectionString
    if ([string]::IsNullOrWhiteSpace($aiAppId) -or [string]::IsNullOrWhiteSpace($aiConnectionString)) {
        throw "Application Insights $aiName has no AppId/ConnectionString yet. Re-run this script."
    }
    Write-Ok "Application Insights $aiName ready."

    # Managed identity the agent acts as.
    Write-Note "Creating managed identity $identityName..."
    $identity = Invoke-Az @(
        'identity', 'create', '-g', $LabResourceGroup, '-n', $identityName, '-l', $Location, '-o', 'json'
    )
    if (-not $identity.principalId) { throw "Could not create managed identity $identityName." }
    Write-Ok "Identity $identityName ready."

    $labScope = "/subscriptions/$subId/resourceGroups/$LabResourceGroup"

    # The agent itself.
    #   accessLevel High  - it needs to create resources to deploy the lab
    #   actionMode Review - you approve every write it proposes
    $agentBody = [ordered]@{
        location   = $Location
        tags       = @{ workload = 'onboardinglab' }
        identity   = [ordered]@{
            type                   = 'SystemAssigned, UserAssigned'
            userAssignedIdentities = @{ "$($identity.id)" = @{} }
        }
        properties = [ordered]@{
            knowledgeGraphConfiguration = [ordered]@{
                identity         = $identity.id
                managedResources = @($labScope)
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

    Write-Note "Creating agent $AgentName (this takes a few minutes)..."
    $null = Invoke-ArmRequest -Method 'put' `
        -Url "$rgBase/Microsoft.App/agents/$AgentName`?api-version=$AgentApiVersion" `
        -Body $agentBody

    $agent = Wait-ForAgent -ResourceGroup $LabResourceGroup -Name $AgentName
    Write-Ok "Agent $AgentName created."
}

# Always read the agent back: the data-plane hostname contains service-assigned segments and
# cannot be composed from the agent name and region.
$agent = Get-AgentResource -ResourceGroup $LabResourceGroup -Name $AgentName
if (-not $agent) { throw "Agent $AgentName could not be read back." }

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
$state['agentIdentityName'] = (($agent.identity.userAssignedIdentities.PSObject.Properties.Name | Select-Object -First 1) -split '/')[-1]
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

        $armUrl = "https://management.azure.com/subscriptions/$subId/resourceGroups/$LabResourceGroup/providers/Microsoft.App/agents/$AgentName" + "?api-version=$AgentApiVersion"
        $null = Invoke-ArmRequest -Method 'patch' -Url $armUrl `
            -Body @{ properties = @{ sandboxConfiguration = @{ egress = $egressBody } } }

        # The PATCH briefly moves the agent to InProgress; wait for it to settle.
        $deadline = (Get-Date).AddMinutes(5)
        do {
            Start-Sleep -Seconds 10
            $check = Invoke-Az @(
                'resource', 'show', '-g', $LabResourceGroup, '-n', $AgentName,
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

# ── Step 5: grant temporary deployment access ───────────────────────────────

Write-Step 'Step 5 - Grant temporary Owner on the lab resource group'

$labScope = "/subscriptions/$subId/resourceGroups/$LabResourceGroup"
$ownerAssignmentName = Get-StableGuid "$labScope|$agentUamiPrincipalId|onboardinglab-temporary-owner"

# Owner is temporary. The Bicep deployment creates the permanent read-only roles,
# which Contributor alone cannot do. -Finalize removes Owner after verification.
$existingAssignments = Invoke-Az @(
    'role', 'assignment', 'list',
    '--assignee', $agentUamiPrincipalId,
    '--scope', $labScope,
    '--query', "[?roleDefinitionName=='Owner'].{id:id,name:name}",
    '-o', 'json'
) -AllowEmpty

if ($existingAssignments -and @($existingAssignments | Where-Object { $_.name -eq $ownerAssignmentName }).Count -gt 0) {
    Write-Ok 'Temporary Owner already assigned.'
}
elseif ($existingAssignments -and @($existingAssignments).Count -gt 0) {
    throw 'The agent identity already has an Owner assignment that this script did not create. Refusing to adopt or later remove it.'
}
else {
    $null = Invoke-Az @(
        'role', 'assignment', 'create',
        '--name', $ownerAssignmentName,
        '--assignee-object-id', $agentUamiPrincipalId,
        '--assignee-principal-type', 'ServicePrincipal',
        '--role', 'Owner',
        '--scope', $labScope,
        '-o', 'json'
    ) -AllowEmpty
    Write-Ok "Temporary Owner granted on $LabResourceGroup."
}

$agentAdminAssignments = Invoke-Az @(
    'role', 'assignment', 'list',
    '--assignee', $agentUamiPrincipalId,
    '--scope', $agent.id,
    '--query', "[?roleDefinitionName=='SRE Agent Administrator']",
    '-o', 'json'
) -AllowEmpty
if (-not ($agentAdminAssignments -and @($agentAdminAssignments).Count -gt 0)) {
    $null = Invoke-Az @(
        'role', 'assignment', 'create',
        '--assignee-object-id', $agentUamiPrincipalId,
        '--assignee-principal-type', 'ServicePrincipal',
        '--role', 'SRE Agent Administrator',
        '--scope', $agent.id,
        '-o', 'json'
    ) -AllowEmpty
}
Write-Ok 'Agent identity can configure its own agent data plane.'

$userAdminAssignments = Invoke-Az @(
    'role', 'assignment', 'list',
    '--assignee', $signedInUserObjectId,
    '--scope', $agent.id,
    '--query', "[?roleDefinitionName=='SRE Agent Administrator']",
    '-o', 'json'
) -AllowEmpty
if (-not ($userAdminAssignments -and @($userAdminAssignments).Count -gt 0)) {
    $null = Invoke-Az @(
        'role', 'assignment', 'create',
        '--assignee-object-id', $signedInUserObjectId,
        '--assignee-principal-type', 'User',
        '--role', 'SRE Agent Administrator',
        '--scope', $agent.id,
        '-o', 'json'
    ) -AllowEmpty
}
Write-Ok 'Signed-in user can administer the agent and configure Code Access.'

# ── Step 6: connect the code repository ─────────────────────────────────────

Write-Step 'Step 6 - Connect your fork as a code repository'

$connectedRepositories = @(Get-ConnectedRepositories -Endpoint $agentEndpoint)
if ($connectedRepositories.Count -gt 0) {
    $repositoryNames = @($connectedRepositories | ForEach-Object { $_.name } | Where-Object { $_ })
    Set-StepDone -State $state -Name 'codeAccessConfirmed'
    Write-Ok "Code access verified: $($repositoryNames -join ', ')"
}
else {
    $portalUrl = "https://sre.azure.com/#/agent/$subId/$LabResourceGroup/$AgentName"

    Write-Host ''
    Write-Host '   The final onboarding agent clones your fork and deploys its workload' -ForegroundColor Yellow
    Write-Host "   and durable configuration from $RunbookPath and the lab templates." -ForegroundColor Yellow
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
    $connectedRepositories = @(Get-ConnectedRepositories -Endpoint $agentEndpoint)
    if ($connectedRepositories.Count -eq 0) {
        $state['codeAccessConfirmed'] = $false
        Save-State -State $state
        throw 'No connected repository was found. Complete Code Access and rerun this script; no deployment thread was started.'
    }
    Set-StepDone -State $state -Name 'codeAccessConfirmed'
    $repositoryNames = @($connectedRepositories | ForEach-Object { $_.name } | Where-Object { $_ })
    Write-Ok "Code access verified: $($repositoryNames -join ', ')"
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
    Write-Host "   https://sre.azure.com/#/agent/$subId/$LabResourceGroup/$AgentName"
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
- AGENT_NAME: $AgentName
- AGENT_IDENTITY_NAME: $($state['agentIdentityName'])

You are the final lab agent. The resource group already exists and your action identity has
temporary Owner on it. Deploy the workload and converge your durable configuration through
Bicep. Do not create another SRE Agent or managed identity. Leave the database fault off.
Do not modify anything outside $LabResourceGroup. Report when external finalization is safe.
"@

if ($startThread) {
    $dpToken = Get-DataPlaneToken

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
Write-Host "  Onboarding agent  : $AgentName"
Write-Host "  Lab resource group: $LabResourceGroup"
Write-Host "  Region            : $Location"
if ($threadId) { Write-Host "  Thread            : $threadId" }
Write-Host ''
Write-Host '  Watch progress at:'
Write-Host "  https://sre.azure.com/#/agent/$subId/$LabResourceGroup/$AgentName"
Write-Host ''
Write-Host '  The agent runs in Review mode, so approve each action as it is proposed.' -ForegroundColor Yellow
Write-Host '  Read commands run without prompting; only writes need your approval.' -ForegroundColor DarkGray
Write-Host "  After successful verification, run: ./bootstrap-agent.ps1 -LabResourceGroup '$LabResourceGroup' -AgentName '$AgentName' -Finalize" -ForegroundColor Yellow
Write-Host ''
