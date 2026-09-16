#Requires -Version 7.4
<#
.SYNOPSIS
    Configures the Zava SRE Agent after `azd provision`.
.DESCRIPTION
    Bicep deploys the agent, identity, networking, mode, and Azure Monitor
    incident binding. After authenticated API readiness, this script applies:
      - Supported connectors through the staged Bicep template
      - Custom skills
      - Named evidence agents with child-specific read-only hooks
      - Incident filters / response plans
      - Knowledge file upload (Builder UI > Knowledge sources)
      - Global Microsoft Learn MCP tool enablement through the configuration API
        after connector tools are registered.
      - Agent-global custom instructions
.EXAMPLE
    .\scripts\setup-sre-agent.ps1
.EXAMPLE
    .\scripts\setup-sre-agent.ps1 -ResourceGroup rg-example -RenderOnly
    Render and validate locally, without Azure sign-in or network calls.
.EXAMPLE
    .\scripts\setup-sre-agent.ps1 -UpdateExisting
    After reviewing drift, snapshot existing managed definitions and update them.
#>
param(
    [string]$ResourceGroup = "",
    [string]$AgentName = "",
    [string]$SubscriptionId = "",
    [switch]$RenderOnly,
    [switch]$UpdateExisting,
    [string]$SnapshotDirectory = "",
    [ValidateRange(1, 3600)][int]$ReadinessTimeoutSeconds = 900,
    [ValidateRange(1, 3600)][int]$ConnectorTimeoutSeconds = 600,
    [ValidateSet('SkillOwned', 'ExplicitAgent')]
    [string]$EvidenceToolMode = 'SkillOwned',
    [string]$PostgresHost = '',
    [string]$PostgresDatabase = '',
    [string]$SreAgentClientId = '',
    [string]$SreAgentPrincipalName = ''
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot '_sre-config.ps1')
. (Join-Path $PSScriptRoot '_sre-connectors.ps1')
$configRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\sre-config'))

function Get-ZavaSinglePostgresHost {
    param([Parameter(Mandatory)][string]$ResourceGroup)

    $json = az postgres flexible-server list -g $ResourceGroup --query '[].fullyQualifiedDomainName' -o json 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list PostgreSQL Flexible Servers in resource group '$ResourceGroup'."
    }
    $hosts = @($json | ConvertFrom-Json) | Where-Object { $_ -and "$_".Trim() }
    if ($hosts.Count -ne 1) {
        throw "Expected exactly one PostgreSQL Flexible Server in resource group '$ResourceGroup' when DB_HOST discovery is required; found $($hosts.Count)."
    }
    return [string]($hosts -join '')
}

function Get-ZavaAgentIdentityResourceId {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$AgentName
    )

    $json = az resource show -g $ResourceGroup -n $AgentName `
        --resource-type Microsoft.App/agents --api-version 2025-05-01-preview -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        throw "Could not read SRE Agent '$AgentName' in resource group '$ResourceGroup' for identity discovery."
    }
    $agent = $json | ConvertFrom-Json
    $actionConfiguration = $agent.properties.PSObject.Properties['actionConfiguration']
    $actionIdentityProperty = if ($actionConfiguration -and $actionConfiguration.Value) {
        $actionConfiguration.Value.PSObject.Properties['identity']
    } else { $null }
    $actionIdentity = if ($actionIdentityProperty) {
        [string]$actionIdentityProperty.Value
    } else { '' }
    if ($actionIdentity.Trim()) {
        if ($actionIdentity -notmatch '/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[^/]+$') {
            throw "The action identity on SRE Agent '$AgentName' is not a user-assigned managed identity resource ID."
        }
        return $actionIdentity.Trim()
    }

    $agentIdentity = $agent.PSObject.Properties['identity']
    $identityProperty = if ($agentIdentity -and $agentIdentity.Value) {
        $agentIdentity.Value.PSObject.Properties['userAssignedIdentities']
    } else { $null }
    $identityIds = if ($identityProperty -and $identityProperty.Value) {
        @($identityProperty.Value.PSObject.Properties.Name | Where-Object { $_ -and "$_".Trim() })
    } else { @() }
    if ($identityIds.Count -ne 1) {
        throw "Expected exactly one attached user-assigned identity on SRE Agent '$AgentName' when no action identity is configured; found $($identityIds.Count)."
    }
    return [string]($identityIds -join '')
}

function Get-ZavaManagedIdentityPair {
    param([Parameter(Mandatory)][string]$IdentityResourceId)

    $json = az identity show --ids $IdentityResourceId -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        throw "Could not read attached user-assigned identity '$IdentityResourceId'."
    }
    $identity = $json | ConvertFrom-Json
    $name = [string]$identity.name
    $clientId = [string]$identity.clientId
    if (-not $name.Trim() -or -not $clientId.Trim()) {
        throw "Attached user-assigned identity '$IdentityResourceId' is missing its name or clientId."
    }
    return @{
        Name = $name.Trim()
        ClientId = $clientId.Trim()
    }
}

function Resolve-ZavaPostgresConfiguration {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$AgentName,
        [string]$PostgresHost = '',
        [string]$PostgresDatabase = '',
        [string]$SreAgentClientId = '',
        [string]$SreAgentPrincipalName = '',
        [hashtable]$AzdEnvironment = @{}
    )

    $resolvedHost = if ($PostgresHost.Trim()) {
        $PostgresHost.Trim()
    } elseif ($AzdEnvironment['DB_HOST'] -and "$($AzdEnvironment['DB_HOST'])".Trim()) {
        "$($AzdEnvironment['DB_HOST'])".Trim()
    } else {
        Get-ZavaSinglePostgresHost -ResourceGroup $ResourceGroup
    }
    $resolvedDatabase = if ($PostgresDatabase.Trim()) {
        $PostgresDatabase.Trim()
    } elseif ($AzdEnvironment['DB_NAME'] -and "$($AzdEnvironment['DB_NAME'])".Trim()) {
        "$($AzdEnvironment['DB_NAME'])".Trim()
    } else {
        'zava_store'
    }

    $suppliedClientId = if ($SreAgentClientId.Trim()) {
        $SreAgentClientId.Trim()
    } elseif ($AzdEnvironment['SRE_AGENT_CLIENT_ID'] -and "$($AzdEnvironment['SRE_AGENT_CLIENT_ID'])".Trim()) {
        "$($AzdEnvironment['SRE_AGENT_CLIENT_ID'])".Trim()
    } else { '' }
    $suppliedPrincipalName = if ($SreAgentPrincipalName.Trim()) {
        $SreAgentPrincipalName.Trim()
    } elseif ($AzdEnvironment['SRE_AGENT_IDENTITY_NAME'] -and "$($AzdEnvironment['SRE_AGENT_IDENTITY_NAME'])".Trim()) {
        "$($AzdEnvironment['SRE_AGENT_IDENTITY_NAME'])".Trim()
    } else { '' }

    $identityResourceId = Get-ZavaAgentIdentityResourceId -ResourceGroup $ResourceGroup -AgentName $AgentName
    $identity = Get-ZavaManagedIdentityPair -IdentityResourceId $identityResourceId
    if ($suppliedClientId -and $suppliedClientId -ne $identity.ClientId) {
        throw "The supplied SRE Agent identity client ID does not match the attached user-assigned identity '$($identity.Name)'."
    }
    if ($suppliedPrincipalName -and $suppliedPrincipalName -ne $identity.Name) {
        throw "The supplied SRE Agent identity principal name does not match the attached user-assigned identity selected by client ID '$($identity.ClientId)'."
    }

    return @{
        DB_HOST = $resolvedHost
        DB_NAME = $resolvedDatabase
        SRE_AGENT_CLIENT_ID = $identity.ClientId
        SRE_AGENT_PRINCIPAL_NAME = $identity.Name
    }
}

if ($RenderOnly) {
    if (-not $ResourceGroup) { throw '-RenderOnly requires -ResourceGroup for local token substitution.' }
    if (-not $PostgresHost) { $PostgresHost = 'zava-pg-offline.postgres.database.azure.com' }
    if (-not $PostgresDatabase) { $PostgresDatabase = 'zava_store' }
    if (-not $SreAgentClientId) { $SreAgentClientId = 'offline-client-id' }
    if (-not $SreAgentPrincipalName) { $SreAgentPrincipalName = 'sre-agent-zava' }
    $offlinePostgres = @{
        DB_HOST = $PostgresHost
        DB_NAME = $PostgresDatabase
        SRE_AGENT_CLIENT_ID = $SreAgentClientId
        SRE_AGENT_PRINCIPAL_NAME = $SreAgentPrincipalName
    }
    Get-ZavaConfiguration $configRoot $ResourceGroup $EvidenceToolMode $offlinePostgres | ConvertTo-Json -Depth 30
    return
}

# Load azd env once, then use it for values that were not provided explicitly.
$azdEnv = @{}
try {
    $envText = azd env get-values 2>$null
    if ($envText) {
        $envText | ForEach-Object {
            if ($_ -match '^([^=]+)="?([^"]*)"?$') {
                $azdEnv[$Matches[1]] = $Matches[2]
            }
        }
    }
} catch {}
if (-not $ResourceGroup) { $ResourceGroup = $azdEnv['RESOURCE_GROUP'] }
if (-not $AgentName) { $AgentName = $azdEnv['SRE_AGENT_NAME'] }
if (-not $ResourceGroup -or -not $AgentName) {
    Write-Host "ERROR: Provide -ResourceGroup and -AgentName, or run from an azd environment." -ForegroundColor Red
    exit 1
}

$postgresConfiguration = Resolve-ZavaPostgresConfiguration `
    -ResourceGroup $ResourceGroup `
    -AgentName $AgentName `
    -PostgresHost $PostgresHost `
    -PostgresDatabase $PostgresDatabase `
    -SreAgentClientId $SreAgentClientId `
    -SreAgentPrincipalName $SreAgentPrincipalName `
    -AzdEnvironment $azdEnv
$configuration = Get-ZavaConfiguration $configRoot $ResourceGroup $EvidenceToolMode $postgresConfiguration

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Zava SRE Agent Configuration" -ForegroundColor Cyan
Write-Host "  (infrastructure + agent configuration)" -ForegroundColor DarkGray
Write-Host "========================================`n" -ForegroundColor Cyan

if (-not $SubscriptionId) {
    $SubscriptionId = az account show --query id -o tsv
}
$agentArmId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/agents/$AgentName"
$apiVersion = "2025-05-01-preview"

# --- Step 0: Verify agent exists -------------------------------------------
Write-Host "Step 0: Verifying agent exists..." -ForegroundColor Yellow
try {
    $agent = az rest --method GET --url "${agentArmId}?api-version=$apiVersion" 2>&1 | ConvertFrom-Json
    $agentEndpoint = $agent.properties.agentEndpoint
    Write-Host "  Agent: $AgentName" -ForegroundColor Green
    Write-Host "  Endpoint: $agentEndpoint" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: Agent '$AgentName' not found in $ResourceGroup." -ForegroundColor Red
    Write-Host "  Run 'azd provision' first." -ForegroundColor Red
    exit 1
}

# --- Step 1: Authenticate --------------------------------------------------
Write-Host "`nStep 1: Authenticating..." -ForegroundColor Yellow
$tokenOutput = az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv 2>&1
$tokenText = ($tokenOutput | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $tokenText) {
    throw "Could not authenticate with the SRE Agent. Sign in to Azure CLI with an account that can configure this agent, then rerun the script."
}
$token = $tokenText
$client = [System.Net.Http.HttpClient]::new()
$client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $token)
$client.Timeout = [TimeSpan]::FromSeconds(30)
Write-Host "  Authentication succeeded" -ForegroundColor Green

# --- Helpers ---------------------------------------------------------------
function Invoke-DataPlaneWrite {
    param(
        [string]$Path,
        [object]$Body,
        [string]$Label,
        [int]$MaxAttempts = 1,
        [int]$RetryDelaySeconds = 15,
        [ValidateSet('Put', 'Patch')][string]$Method = 'Put',
        [ValidateSet('application/json', 'application/x-yaml')][string]$ContentType = 'application/json'
    )

    $json = $Body | ConvertTo-Json -Depth 20 -Compress
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        # JSON is valid YAML 1.2, so the portal's YAML apply endpoint can receive
        # this exact object without adding a YAML serializer dependency.
        $content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, $ContentType)
        $response = $null
        try {
            $response = if ($Method -eq 'Patch') {
                $client.PatchAsync("$agentEndpoint$Path", $content).Result
            } else {
                $client.PutAsync("$agentEndpoint$Path", $content).Result
            }
            $responseBody = $response.Content.ReadAsStringAsync().Result
            if ($response.IsSuccessStatusCode) {
                Write-Host "  [ok] $Label" -ForegroundColor Green
                return $true
            }

            if ($attempt -eq $MaxAttempts) {
                Write-Host "  [failed] $Label returned HTTP $([int]$response.StatusCode): $responseBody" -ForegroundColor Red
                return $false
            }
        } catch {
            if ($attempt -eq $MaxAttempts) {
                Write-Host "  [failed] ${Label}: $($_.Exception.Message)" -ForegroundColor Red
                return $false
            }
        } finally {
            if ($response) { $response.Dispose() }
            $content.Dispose()
        }

        Write-Host "  [retry] $Label attempt $attempt/$MaxAttempts; waiting ${RetryDelaySeconds}s for platform initialization" -ForegroundColor Yellow
        Start-Sleep -Seconds $RetryDelaySeconds
    }
}

function Get-DataPlaneJson {
    param([string]$Path)

    $response = $client.GetAsync("$agentEndpoint$Path").Result
    try {
        $responseBody = $response.Content.ReadAsStringAsync().Result
        if (-not $response.IsSuccessStatusCode) {
            throw "GET $Path returned HTTP $([int]$response.StatusCode): $responseBody"
        }
        return ConvertFrom-Json -InputObject $responseBody -NoEnumerate
    } finally {
        $response.Dispose()
    }
}

function Get-DataPlaneCollection {
    param([string]$Path)
    $parsed = Get-DataPlaneJson $Path
    $nextLink = $parsed.PSObject.Properties['nextLink']
    if ($nextLink -and $nextLink.Value) { throw "GET $Path returned a paginated collection; refusing a partial configuration comparison." }
    if ($parsed -is [array]) { return @($parsed) }
    if ($parsed.PSObject.Properties['value'] -and $parsed.value -is [array]) { return @($parsed.value) }
    if ($parsed.PSObject.Properties['data'] -and
        $parsed.data.PSObject.Properties['tools'] -and
        $parsed.data.tools.PSObject.Properties['data'] -and
        $parsed.data.tools.data -is [array]) {
        return @($parsed.data.tools.data)
    }
    throw "GET $Path did not return a resource collection."
}

$armToken = az account get-access-token --resource 'https://management.azure.com/' --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $armToken) { throw 'Could not authenticate for connector provisioning.' }
$armClient = [Net.Http.HttpClient]::new()
$armClient.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $armToken.Trim())
$armClient.Timeout = [TimeSpan]::FromSeconds(30)

function Invoke-ZavaArmRequest {
    param(
        [string]$Path,
        [ValidateSet('Get', 'Put', 'Post')][string]$Method = 'Get',
        [object]$Body,
        [ValidateRange(0.000001, 30)][double]$TimeoutSeconds = 30
    )
    if (-not $Path.StartsWith('/subscriptions/')) { throw 'Expected a subscription-scoped ARM path.' }
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), "https://management.azure.com$Path")
    $response = $null
    $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        if ($null -ne $Body) {
            $request.Content = [Net.Http.StringContent]::new(
                (ConvertTo-Json -InputObject $Body -Depth 100 -Compress), [Text.Encoding]::UTF8, 'application/json')
        }
        $response = $armClient.SendAsync($request, $cancellation.Token).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $parsed = if ($text.TrimStart().StartsWith('{')) { ConvertFrom-Json -InputObject $text -ErrorAction Stop } else { $null }
        return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Body = $parsed; Text = $text }
    } finally {
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $cancellation.Dispose()
    }
}

Write-Host "`nWaiting for the agent configuration API..." -ForegroundColor Yellow
Wait-ZavaDataPlane -Client $client -Endpoint $agentEndpoint -TimeoutSeconds $ReadinessTimeoutSeconds

# Resolve the lab's linked telemetry resources, not the operator's default environment.
$appInsightsProperty = if ($agent.PSObject.Properties['tags'] -and $agent.tags) {
    $agent.tags.PSObject.Properties['hidden-link: /app-insights-resource-id']
} else { $null }
$appInsightsId = if ($appInsightsProperty) { [string]$appInsightsProperty.Value } else { '' }
$scopePattern = '^' + [regex]::Escape("/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup")
if ($appInsightsId -notmatch "$scopePattern/providers/Microsoft.Insights/components/[^/]+$") {
    throw 'The agent must have a linked Application Insights resource in this lab resource group.'
}
$appInsights = Invoke-ZavaArmRequest -Path "$appInsightsId`?api-version=2020-02-02"
if ($appInsights.StatusCode -ne 200) { throw "Could not read linked Application Insights (HTTP $($appInsights.StatusCode))." }
$workspaceProperty = $appInsights.Body.properties.PSObject.Properties['WorkspaceResourceId']
$workspaceId = if ($workspaceProperty) { [string]$workspaceProperty.Value } else { '' }
if ($workspaceId -notmatch "$scopePattern/providers/Microsoft.OperationalInsights/workspaces/[^/]+$") {
    throw 'The linked Application Insights resource must use a Log Analytics workspace in this lab resource group.'
}
$connectorPlan = Get-ZavaConnectorPlan -ConfigRoot $configRoot `
    -Existing @(Get-ZavaArmConnectors $agentArmId) -UpdateExisting:$UpdateExisting

# Preflight every managed name before the first write. Do not overwrite manually
# created specialists (or other managed drift) merely because their names match.
$collections = @{}
foreach ($kind in @('tools', 'skills', 'agents', 'incidentFilters')) {
    $collections[$kind] = @(Get-DataPlaneCollection (Get-ZavaCollectionPath $kind))
}
$currentInstructions = Get-DataPlaneJson '/api/v2/agent/customInstructions'
if (-not $currentInstructions.PSObject.Properties['instructions']) {
    throw 'Custom-instruction readback is missing instructions; refusing to overwrite unknown state.'
}
$syncPlan = New-ZavaSyncPlan $configuration $collections $currentInstructions.instructions
Assert-ZavaUpdateApproved $syncPlan -UpdateExisting:$UpdateExisting
$snapshotItems = @($syncPlan.Items) + @($connectorPlan.Definitions | ForEach-Object {
    [pscustomobject]@{
        Resource = @{ Path = "$agentArmId/connectors/$($_.name)?api-version=$apiVersion" }
        Previous = $connectorPlan.Existing | Where-Object name -ceq $_.name | Select-Object -First 1
        Action = 'apply'
    }
})
$snapshotPlan = [pscustomobject]@{ Items = $snapshotItems; PreviousInstructions = $syncPlan.PreviousInstructions }
$null = Save-ZavaSnapshot $snapshotPlan $SnapshotDirectory $agentArmId
Write-Host "  Evidence tool mode: $EvidenceToolMode" -ForegroundColor Yellow

Write-Host "`nApplying connector infrastructure after API readiness..." -ForegroundColor Yellow
Sync-ZavaConnectors -Plan $connectorPlan -TemplatePath (Join-Path $PSScriptRoot '..\infra\modules\sre-agent-connectors.bicep') `
    -AgentArmId $agentArmId -AppInsightsId $appInsightsId -LogAnalyticsId $workspaceId -TimeoutSeconds $ConnectorTimeoutSeconds

# Check registration, not global enablement: skill-gated tools need not be global.
$requiredEvidenceTools = @($configuration.Resources |
    Where-Object { $_.Kind -eq 'skills' -and $_.Name -like 'zava-*-evidence' } |
    ForEach-Object { $_.Body.properties.tools } |
    Where-Object { $_ -like 'system-mcp-*' } | Sort-Object -Unique)
$deadline = (Get-Date).AddMinutes(3)
do {
    $toolCatalog = Get-DataPlaneJson '/api/v2/agent/tools'
    if ($toolCatalog.data -isnot [array]) { throw 'Tool catalog is missing its data array.' }
    $missing = @($requiredEvidenceTools | Where-Object { $_ -cnotin $toolCatalog.data.name })
    if ($missing.Count -eq 0) { break }
    if ((Get-Date) -ge $deadline) { throw "Evidence tool dependencies are not registered: $($missing -join ', '). No tool permissions were changed." }
    Start-Sleep -Seconds 15
} while ($true)

# --- Step 2: Sync tools, skills, then agents and their hooks ---------------
Write-Host "`nStep 2: Syncing native tools, skills, and named evidence agents..." -ForegroundColor Yellow
Sync-ZavaResources $syncPlan 'tools'
Sync-ZavaResources $syncPlan 'skills'
Sync-ZavaResources $syncPlan 'agents'

# --- Step 3: Sync response plans -------------------------------------------
Write-Host "`nStep 3: Syncing incident response plans..." -ForegroundColor Yellow
Sync-ZavaResources $syncPlan 'incidentFilters'

$expectedSkillProperties = @{}
$expectedFilterProperties = @{}
foreach ($resource in $configuration.Resources) {
    if ($resource.Kind -eq 'skills') { $expectedSkillProperties[$resource.Name] = $resource.Body.properties }
    if ($resource.Kind -eq 'incidentFilters') { $expectedFilterProperties[$resource.Name] = $resource.Body.properties }
}

# --- Step 4: Sync knowledge files (data-plane only — no ARM equivalent) ----
# Knowledge files are stored as data-plane connectors of type KnowledgeFile.
# PUT to /connectors/{filename} creates or replaces the named file.
#
# Sync semantics: for every local *.md file in sre-config/knowledge-base/, we
# compute a SHA256 of the bytes and compare to a local hash cache. If the
# cached hash matches AND the named file is already present in the agent, we
# skip. Otherwise we PUT the file (which replaces any existing copy with the
# same name) and update the cache. The agent KB API does not surface a content
# hash on its file list, so a local sidecar cache is the simplest robust signal.
Write-Host "`nStep 4: Syncing knowledge files..." -ForegroundColor Yellow
$kbDir = Resolve-Path "$PSScriptRoot\..\sre-config\knowledge-base"
$kbLocalFiles = @(Get-ChildItem -Path $kbDir -Filter "*.md" -File)
$hashCachePath = Join-Path $kbDir ".upload-hashes.json"
$hashCache = @{}
if (Test-Path $hashCachePath) {
    try {
        $raw = Get-Content -Raw -Path $hashCachePath | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $hashCache[$p.Name] = $p.Value }
    } catch {
        Write-Host "  (hash cache unreadable, treating as empty)" -ForegroundColor DarkGray
    }
}

# Fetch the current set of remote KB files once. The /connectors endpoint
# returns all connector kinds; filter to dataConnectorType == "KnowledgeFile".
$remoteByName = @{}
$existingResp = $client.GetAsync("$agentEndpoint/api/v2/extendedAgent/connectors").Result
if ($existingResp.IsSuccessStatusCode) {
    $items = ($existingResp.Content.ReadAsStringAsync().Result | ConvertFrom-Json).value
    foreach ($f in @($items)) {
        if ($f.properties.dataConnectorType -eq "KnowledgeFile") { $remoteByName[$f.name] = $f }
    }
} else {
    Write-Host "  WARNING: could not list existing connectors ($($existingResp.StatusCode)); will attempt uploads anyway" -ForegroundColor Yellow
}

$sha256 = [System.Security.Cryptography.SHA256]::Create()
$uploaded = 0; $replaced = 0; $skipped = 0; $failed = 0

foreach ($localFile in $kbLocalFiles) {
    $kbFileName = $localFile.Name
    # Substitute placeholders so the agent KB reflects this deployment's resource group.
    # Convention matches Bicep skills (@@RG@@ -> actual resource group name).
    $kbText = [System.IO.File]::ReadAllText($localFile.FullName)
    $kbText = $kbText.Replace('@@RG@@', $ResourceGroup)
    $kbBytes = [System.Text.Encoding]::UTF8.GetBytes($kbText)
    $localHash = [System.BitConverter]::ToString($sha256.ComputeHash($kbBytes)).Replace("-", "").ToLowerInvariant()
    $remote = $remoteByName[$kbFileName]
    $cachedHash = $hashCache[$kbFileName]

    if ($remote -and $cachedHash -and ($cachedHash -eq $localHash)) {
        Write-Host "  [skip] $kbFileName unchanged (sha256=$($localHash.Substring(0,12))...)" -ForegroundColor DarkGray
        $skipped++
        continue
    }

    $isReplace = [bool]$remote
    $body = @{
        name = $kbFileName
        type = "KnowledgeItem"
        properties = @{
            dataConnectorType = "KnowledgeFile"
            dataSource = $kbFileName
            extendedProperties = @{
                displayName = $kbFileName
                fileContent = [System.Convert]::ToBase64String($kbBytes)
            }
        }
    } | ConvertTo-Json -Depth 6 -Compress
    $jsonContent = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, "application/json")
    $kbResp = $client.PutAsync("$agentEndpoint/api/v2/extendedAgent/connectors/$kbFileName", $jsonContent).Result
    if ($kbResp.IsSuccessStatusCode) {
        if ($isReplace) {
            Write-Host "  [replace] $kbFileName re-uploaded (sha256=$($localHash.Substring(0,12))...)" -ForegroundColor Cyan
            $replaced++
        } else {
            Write-Host "  [upload] $kbFileName uploaded (sha256=$($localHash.Substring(0,12))...)" -ForegroundColor Green
            $uploaded++
        }
        $hashCache[$kbFileName] = $localHash
    } else {
        Write-Host "  WARNING: upload of $kbFileName returned $($kbResp.StatusCode): $($kbResp.Content.ReadAsStringAsync().Result)" -ForegroundColor Yellow
        $failed++
    }
    $jsonContent.Dispose()
}
$sha256.Dispose()

# Persist updated hash cache.
try {
    ($hashCache | ConvertTo-Json) | Set-Content -Path $hashCachePath -Encoding UTF8
} catch {
    Write-Host "  (could not write hash cache to ${hashCachePath}: $($_.Exception.Message))" -ForegroundColor DarkGray
}

Write-Host ("  Summary: {0} uploaded, {1} replaced, {2} skipped, {3} failed (of {4} local files)" -f $uploaded, $replaced, $skipped, $failed, $kbLocalFiles.Count) -ForegroundColor Yellow
if ($failed -gt 0) {
    $client.Dispose()
    $armClient.Dispose()
    throw "$failed knowledge file upload(s) failed. The remote content may be stale."
}

# --- Step 5: Enable Microsoft Learn MCP tools globally ---------------------
# Connector provisioning does not enable tools globally. Wait for registration,
# then merge the Learn overrides without changing unrelated tool settings.
Write-Host "`nStep 5: Enabling Microsoft Learn MCP tools globally..." -ForegroundColor Yellow
$learnToolSets = @(
    [pscustomobject]@{
        Connector = 'learn-docs'
        Tools = @(
            'learn-docs_microsoft_docs_search',
            'learn-docs_microsoft_code_sample_search',
            'learn-docs_microsoft_docs_fetch'
        )
    },
    # Preserve compatibility with the previous connector name.
    [pscustomobject]@{
        Connector = 'microsoft-learn'
        Tools = @(
            'microsoft-learn_microsoft_docs_search',
            'microsoft-learn_microsoft_code_sample_search',
            'microsoft-learn_microsoft_docs_fetch'
        )
    }
)
$learnConnectorName = $learnToolSets[0].Connector
$learnTools = $learnToolSets[0].Tools
$catalog = @(); $present = @()
$toolDeadline = (Get-Date).AddMinutes(3)
do {
    try {
        $tr = $client.GetAsync("$agentEndpoint/api/v2/agent/tools").Result
        if ($tr.IsSuccessStatusCode) { $catalog = @(($tr.Content.ReadAsStringAsync().Result | ConvertFrom-Json).data) }
    } catch {}

    foreach ($toolSet in $learnToolSets) {
        $candidatePresent = @($toolSet.Tools | Where-Object { $_ -in $catalog.name })
        if ($candidatePresent.Count -gt $present.Count) {
            $learnConnectorName = $toolSet.Connector
            $learnTools = $toolSet.Tools
            $present = $candidatePresent
        }
    }
    if ($present.Count -eq $learnTools.Count) { break }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $toolDeadline)

if ($present.Count -lt $learnTools.Count) {
    Write-Host "  [WARN] Only $($present.Count)/$($learnTools.Count) Learn MCP tools visible in the catalog yet — the" -ForegroundColor Yellow
    Write-Host "         $learnConnectorName connection is still warming up (it fetches its server bits from" -ForegroundColor Yellow
    Write-Host "         raw.githubusercontent.com; confirm the allow-github-raw-mcp-bits firewall rule exists)." -ForegroundColor Yellow
    Write-Host "         Re-run this script shortly to finish enabling them." -ForegroundColor Yellow
}
if ($present.Count -gt 0) {
    $alreadyEnabled = @($catalog | Where-Object { ($_.name -in $present) -and $_.enabled } | ForEach-Object { $_.name })
    if ($alreadyEnabled.Count -eq $present.Count) {
        Write-Host "  [skip] $($present.Count) Learn MCP tool(s) already enabled globally" -ForegroundColor DarkGray
    } else {
        $payload = @{ overrides = @($present | ForEach-Object { @{ name = $_; enabled = $true } }) } | ConvertTo-Json -Depth 4 -Compress
        $cfgContent = [System.Net.Http.StringContent]::new($payload, [System.Text.Encoding]::UTF8, "application/json")
        $cfgResp = $client.PostAsync("$agentEndpoint/api/v2/agent/tools/configure", $cfgContent).Result
        if ($cfgResp.IsSuccessStatusCode) {
            Write-Host "  [ok] Enabled $($present.Count) Learn MCP tool(s) globally (docs_search, code_sample_search, docs_fetch)" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: tool enable returned $($cfgResp.StatusCode): $($cfgResp.Content.ReadAsStringAsync().Result)" -ForegroundColor Yellow
        }
        $cfgContent.Dispose()
    }
}

# --- Step 6: Sync custom instructions (data-plane only) ---------------------
# Custom instructions are the agent-scoped, ALWAYS-ON prompt appended to EVERY
# thread — chat, incident, scheduled task — regardless of which response plan or
# skill matched. This is the surface the portal's "Custom instructions" box writes.
#
# Data-plane contract:
#   GET/PUT {agentEndpoint}/api/v2/agent/customInstructions
#   body: { "instructions": "<text>" }
#
# The global instructions cover correlation and bounded parallel investigation.
Write-Host "`nStep 6: Syncing custom instructions..." -ForegroundColor Yellow
$ciText = $configuration.CustomInstructions
$normalizeInstructions = { param($s) if ($null -eq $s) { '' } else { $s.Replace("`r", '').Trim() } }
# Do not publish a routing hint until every referenced skill/agent is read back.
Assert-ZavaResourcesConverged -Resources @($configuration.Resources | Where-Object Kind -in @('skills', 'agents'))
$latestInstructions = Get-DataPlaneJson '/api/v2/agent/customInstructions'
if (-not $latestInstructions.PSObject.Properties['instructions'] -or
    (& $normalizeInstructions $latestInstructions.instructions) -cne (& $normalizeInstructions $syncPlan.PreviousInstructions)) {
    throw 'Custom instructions changed after preflight. Rerun to review the new drift.'
}
if (-not $syncPlan.InstructionsChanged) {
    Write-Host "  [skip] custom instructions unchanged ($($ciText.Length) chars)" -ForegroundColor DarkGray
} elseif (-not (Invoke-DataPlaneWrite -Path '/api/v2/agent/customInstructions' -Body @{ instructions = $ciText } -Label 'custom instructions')) {
    throw 'Failed to synchronize custom instructions.'
}
for ($attempt = 1; $attempt -le 6; $attempt++) {
    $savedInstructions = Get-DataPlaneJson '/api/v2/agent/customInstructions'
    if ((& $normalizeInstructions $savedInstructions.instructions) -ceq (& $normalizeInstructions $ciText)) { break }
    if ($attempt -eq 6) {
        throw 'Custom instructions did not converge after readback.'
    }
    Start-Sleep -Seconds 5
}

# --- Step 7: Verify the combined configuration -----------------------------
Write-Host "`nStep 7: Verifying ARM + data-plane configuration..." -ForegroundColor Yellow
$allGood = $true
$armToken = (az account get-access-token --resource "https://management.azure.com/" --query accessToken -o tsv 2>$null).Trim()
if (-not $armToken) {
    throw "Could not acquire an Azure Resource Manager token for post-provision verification."
}
$armHeaders = @{ Authorization = "Bearer $armToken"; Accept = "application/json" }

function Get-AgentChildren {
    param([string]$Kind)

    $url = "https://management.azure.com${agentArmId}/${Kind}?api-version=$apiVersion"
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $response = Invoke-RestMethod -Method Get -Uri $url -Headers $armHeaders
            $valueProperty = $response.PSObject.Properties['value']
            if ($valueProperty) {
                return @($valueProperty.Value)
            }
        } catch {
            if ($attempt -eq 6) {
                throw "Could not list agent $Kind after $attempt attempts: $($_.Exception.Message)"
            }
        }

        if ($attempt -lt 6) { Start-Sleep -Seconds 5 }
    }

    throw "Agent $Kind list response did not contain a value collection after 6 attempts."
}

$connectors = @(Get-AgentChildren -Kind "connectors")
$expectedConnectors = @("app-insights","log-analytics","azure-monitor")
$missingConnectors = $expectedConnectors | Where-Object { $_ -notin $connectors.name }
$learnConnector = $connectors | Where-Object { $_.name -in @("learn-docs", "microsoft-learn") } | Select-Object -First 1
if (-not $learnConnector) { $missingConnectors += "learn-docs" }
else { $learnConnectorName = $learnConnector.name }
if (-not $missingConnectors) { Write-Host "  [OK] Connectors: $($connectors.Count) (app-insights, log-analytics, azure-monitor, $($learnConnector.name))" -ForegroundColor Green }
else { Write-Host "  [MISSING] Connectors: $($missingConnectors -join ', ') — re-run azd provision" -ForegroundColor Red; $allGood = $false }

$skills = @(Get-DataPlaneCollection -Path "/api/v2/extendedAgent/skills")
$skillDifferences = [System.Collections.Generic.List[string]]::new()
foreach ($skillName in @($expectedSkillProperties.Keys)) {
    $deployedSkill = $skills | Where-Object { $_.name -eq $skillName } | Select-Object -First 1
    if (-not $deployedSkill) {
        $skillDifferences.Add("$skillName is missing")
        continue
    }
    Compare-ExpectedProperties -Expected ($expectedSkillProperties[$skillName]) -Actual $deployedSkill.properties -Path $skillName -Differences $skillDifferences
}
if ($skillDifferences.Count -eq 0) {
    Write-Host "  [OK] Custom skills: $($expectedSkillProperties.Count) match source" -ForegroundColor Green
} else {
    Write-Host "  [MISMATCH] Skills: $($skillDifferences -join '; ')" -ForegroundColor Red
    $allGood = $false
}

$filters = @(Get-DataPlaneCollection -Path "/api/v2/extendedAgent/incidentFilters")
$filterDifferences = [System.Collections.Generic.List[string]]::new()
foreach ($filterName in @($expectedFilterProperties.Keys)) {
    $deployedFilter = $filters | Where-Object { $_.name -eq $filterName } | Select-Object -First 1
    if (-not $deployedFilter) {
        $filterDifferences.Add("$filterName is missing")
        continue
    }
    Compare-ExpectedProperties -Expected ($expectedFilterProperties[$filterName]) -Actual $deployedFilter.properties -Path $filterName -Differences $filterDifferences
}
if ($filterDifferences.Count -eq 0) {
    Write-Host "  [OK] Response plans: $($expectedFilterProperties.Count) match source" -ForegroundColor Green
} else {
    Write-Host "  [MISMATCH] Response plans: $($filterDifferences -join '; ')" -ForegroundColor Red
    $allGood = $false
}

Assert-ZavaResourcesConverged -Resources @($configuration.Resources | Where-Object Kind -eq 'agents')
Write-Host "  [OK] Named evidence agents and hooks match source" -ForegroundColor Green

$kbResp = $client.GetAsync("$agentEndpoint/api/v2/extendedAgent/connectors").Result
$knowledgeFiles = @()
if ($kbResp.IsSuccessStatusCode) {
    $knowledgeFiles = @(($kbResp.Content.ReadAsStringAsync().Result | ConvertFrom-Json).value | Where-Object { $_.properties.dataConnectorType -eq "KnowledgeFile" })
}
# Match against the actual local KB filenames so a partial sync (some files
# uploaded, others missing) doesn't pass verification just because the count
# is non-zero. The data-plane API stores files under their original name
# (no prefix) — see Step 2.
$expectedKb = @(Get-ChildItem -Path $kbDir -Filter '*.md' -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Name })
$uploadedKbNames = @($knowledgeFiles | ForEach-Object { $_.name })
$missingKb = $expectedKb | Where-Object { $_ -notin $uploadedKbNames }
if ($expectedKb.Count -eq 0) {
    Write-Host "  [WARN] No local knowledge files found under sre-config/knowledge-base/" -ForegroundColor Yellow
} elseif (-not $missingKb) {
    Write-Host "  [OK] Knowledge files: $($knowledgeFiles.Count) (all $($expectedKb.Count) expected files present)" -ForegroundColor Green
} else {
    Write-Host "  [MISSING] Knowledge files: $($missingKb -join ', ') — re-run Step 2 (upload) above" -ForegroundColor Red; $allGood = $false
}

$verifiedInstructions = $null
$customInstructionsVerified = $false
if (-not $ciText) {
    Write-Host "  [MISSING] Custom instructions source file — restore sre-config/custom-instructions.md" -ForegroundColor Red
    $allGood = $false
} else {
    try {
        $verifyCiResp = $client.GetAsync("$agentEndpoint/api/v2/agent/customInstructions").Result
        if ($verifyCiResp.IsSuccessStatusCode) {
            $verifiedInstructions = ($verifyCiResp.Content.ReadAsStringAsync().Result | ConvertFrom-Json).instructions
        }
    } catch {}
    if ((& $normalizeInstructions $verifiedInstructions) -eq (& $normalizeInstructions $ciText)) {
        Write-Host "  [OK] Custom instructions match local source ($($ciText.Length) chars)" -ForegroundColor Green
        $customInstructionsVerified = $true
    } else {
        Write-Host "  [MISSING] Custom instructions do not match local source - re-run Step 6" -ForegroundColor Red
        $allGood = $false
    }
}

if ($agent.properties.actionConfiguration.mode -ne "autonomous") {
    Write-Host "  [WARN] Agent mode: $($agent.properties.actionConfiguration.mode) (expected autonomous)" -ForegroundColor Yellow; $allGood = $false
} else { Write-Host "  [OK] Mode: autonomous + access $($agent.properties.actionConfiguration.accessLevel)" -ForegroundColor Green }

if ($agent.properties.incidentManagementConfiguration.type -ne "AzMonitor") {
    Write-Host "  [WARN] Incident platform: $($agent.properties.incidentManagementConfiguration.type) (expected AzMonitor)" -ForegroundColor Yellow; $allGood = $false
} else { Write-Host "  [OK] Incident platform: AzMonitor" -ForegroundColor Green }

$learnEnabled = @()
$vcat = @()
try {
    $vt = $client.GetAsync("$agentEndpoint/api/v2/agent/tools").Result
    if ($vt.IsSuccessStatusCode) {
        $vcat = @(($vt.Content.ReadAsStringAsync().Result | ConvertFrom-Json).data)
        $learnEnabled = @($vcat | Where-Object { ($_.name -in $learnTools) -and $_.enabled } | ForEach-Object { $_.name })
    }
} catch {}
if ($learnEnabled.Count -eq $learnTools.Count) {
    Write-Host "  [OK] Microsoft Learn MCP tools enabled globally: $($learnEnabled.Count)/$($learnTools.Count)" -ForegroundColor Green
} else {
    Write-Host "  [WARN] Learn MCP tools enabled globally: $($learnEnabled.Count)/$($learnTools.Count) (MCP connection may still be warming up)" -ForegroundColor Yellow
}

if (-not $allGood) {
    $client.Dispose()
    $armClient.Dispose()
    throw "Required SRE Agent assets are missing or misconfigured. Review the verification failures above."
}

Write-Host "  All required Bicep + data-plane assets verified." -ForegroundColor Green
$client.Dispose()
$armClient.Dispose()

# --- Summary ---------------------------------------------------------------
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Done" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "  DEPLOYED BY BICEP:" -ForegroundColor DarkGray
Write-Host "  [x] Agent: autonomous mode + High access"
Write-Host "  [x] Incident platform: Azure Monitor"
Write-Host "  [x] Agent firewall and identity configuration"
Write-Host "`n  APPLIED BY SETUP SCRIPT:" -ForegroundColor Cyan
Write-Host "  [x] Staged Bicep connectors: app-insights, log-analytics, azure-monitor, $learnConnectorName"
Write-Host "  [x] Custom skills: $($expectedSkillProperties.Keys -join ', ')"
Write-Host "  [x] Named evidence agents: app-investigator, database-investigator (tool mode: $EvidenceToolMode)"
Write-Host "  [x] Response plans (incident filters): zava-database, zava-performance, zava-application, zava-unknown"
Write-Host ("  [x] Knowledge files synced: {0} local file(s) ({1} uploaded, {2} replaced, {3} skipped, {4} failed)" -f $kbLocalFiles.Count, $uploaded, $replaced, $skipped, $failed)
if ($learnEnabled.Count -eq $learnTools.Count) {
    Write-Host ("  [x] Microsoft Learn MCP tools enabled globally: {0}/{1} (docs_search, code_sample_search, docs_fetch)" -f $learnEnabled.Count, $learnTools.Count)
} else {
    Write-Host ("  [!] Microsoft Learn MCP tools enabled globally: {0}/{1} (connector warm-up/runtime issue; nonfatal)" -f $learnEnabled.Count, $learnTools.Count) -ForegroundColor Yellow
}
if ($customInstructionsVerified) {
    Write-Host ("  [x] Custom instructions synced and verified: {0} chars" -f $ciText.Length)
} else {
    Write-Host "  [ ] Custom instructions not verified" -ForegroundColor Red
}
Write-Host "`n  NEXT STEPS:" -ForegroundColor Cyan
Write-Host "  Run a break scenario:"
Write-Host "    .\.github\skills\running-demo\scripts\break-sql.ps1      # Stop PostgreSQL"
Write-Host "    .\.github\skills\running-demo\scripts\break-network.ps1  # Block DB traffic"
Write-Host "    .\.github\skills\running-demo\scripts\break-db-perf.ps1  # Drop index"
Write-Host "    .\.github\skills\running-demo\scripts\break-bad-deploy.ps1 # Ship a bad rollout"
Write-Host "    .\.github\skills\running-demo\scripts\break-compound.ps1  # Two independent faults"
Write-Host "  Watch the agent: https://sre.azure.com/agents$agentArmId`n"
