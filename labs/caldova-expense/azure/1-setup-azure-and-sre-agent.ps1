<#
.SYNOPSIS
    Step 1 (Azure Side): Provisions the complete Azure monitoring plane AND creates an Azure SRE Agent
    for the Caldova Expense hybrid on-premises lab.

.DESCRIPTION
    Idempotent and re-entrant. Performs:
      1. Registers Azure Resource Providers (HybridCompute, Insights, OperationalInsights, Microsoft.App, ...).
      2. Creates rg-hybrid-connectivity (Arc + monitoring) and rg-caldova-sre-agent (SRE Agent).
      3. Creates law-caldova-central, custom table CaldovaExpenseApp_CL, Data Collection Endpoint
         dce-caldova-central, and Windows DCRs for Perf + Windows Event Logs ('CaldovaExpense') +
         IIS W3C Logs (W3CIISLog) + structured app logs (CaldovaExpenseApp_CL).
      4. Creates an Azure SRE Agent (Microsoft.App/agents@2025-05-01-preview) with:
         - User-Assigned + System-Assigned Managed Identity
         - Application Insights for agent telemetry
         - Least-privilege RBAC (Reader, Monitoring Reader, Log Analytics Reader on hybrid/workspace RGs,
           plus SRE Agent Administrator for the signed-in user and UAMI)
         - Log Analytics connector wired to law-caldova-central + Azure Monitor connector
         - Automatic upload of sre-agent/knowledge/caldova-expense-runbook.md to Agent Knowledge Memory
           (when an SRE Agent data-plane token is available)
      5. Automatically attaches AMAWindows + DCR associations if win-caldova-exp01 is already Arc-connected.

.EXAMPLE
    .\azure\1-setup-azure-and-sre-agent.ps1 -SubscriptionId "66a7fcba-dac3-46d8-b509-202f305618c8"

.EXAMPLE
    # Deploy SRE Agent in swedencentral while keeping Arc & Log Analytics in eastus2
    .\azure\1-setup-azure-and-sre-agent.ps1 `
      -SubscriptionId "66a7fcba-dac3-46d8-b509-202f305618c8" `
      -Location "eastus2" `
      -AgentLocation "swedencentral"
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId = "",
    [string] $HybridResourceGroup = "rg-hybrid-connectivity",
    [string] $WorkspaceResourceGroup = "",
    [string] $WorkspaceName = "law-caldova-central",
    [string] $Location = "eastus2",
    [string] $MachineName = "win-caldova-exp01",

    [string] $AgentResourceGroup = "rg-caldova-sre-agent",
    [string] $AgentName = "sre-caldova-expense",
    [string] $AgentLocation = "",

    [ValidateSet("Low", "High")]
    [string] $AccessLevel = "Low",

    [ValidateSet("Review", "Autonomous")]
    [string] $ActionMode = "Review",

    [ValidateSet("MicrosoftFoundry", "Anthropic")]
    [string] $ModelProvider = "MicrosoftFoundry"
)

$ErrorActionPreference = "Stop"
$AgentApiVersion = "2025-05-01-preview"

if (-not $WorkspaceResourceGroup) { $WorkspaceResourceGroup = $HybridResourceGroup }
if (-not $AgentLocation)          { $AgentLocation = $Location }

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]] $ArgsList, [switch] $AllowEmpty)
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $out = & az @ArgsList 2>$errFile
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            $errText = Get-Content -Path $errFile -Raw
            throw "az $($ArgsList -join ' ') failed (exit $code):`n$errText"
        }
        $text = ($out | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            if ($AllowEmpty) { return $null }
            throw "az $($ArgsList -join ' ') returned empty output."
        }
        return $text | ConvertFrom-Json
    }
    finally {
        Remove-Item -Path $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ArmRest {
    param(
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)] $Body
    )
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("caldova-arm-" + [guid]::NewGuid().ToString("N") + ".json")
    try {
        $Body | ConvertTo-Json -Depth 25 | Set-Content -Path $tmp -NoNewline -Encoding utf8
        return Invoke-AzJson -ArgsList @("rest", "--method", $Method, "--url", $Url, "--headers", "Content-Type=application/json", "--body", "@$tmp", "-o", "json") -AllowEmpty
    }
    finally {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-SignedInUserObjectId {
    try {
        $u = Invoke-AzJson -ArgsList @("ad", "signed-in-user", "show", "--query", "{id:id}", "-o", "json")
        if ($u.id) { return $u.id }
    } catch {}

    $tok = (& az account get-access-token --resource "https://management.azure.com/" --query accessToken -o tsv 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($tok -join ""))) {
        $part = (($tok -join "").Trim().Split('.')[1]).Replace('-', '+').Replace('_', '/')
        $part = $part.PadRight($part.Length + ((4 - ($part.Length % 4)) % 4), '=')
        $claims = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
        if ($claims.oid) { return $claims.oid }
    }
    return $null
}

function Ensure-RoleAssignment {
    param(
        [Parameter(Mandatory)][string] $PrincipalId,
        [Parameter(Mandatory)][string] $PrincipalType,
        [Parameter(Mandatory)][string] $RoleDefinitionId,
        [Parameter(Mandatory)][string] $Scope,
        [Parameter(Mandatory)][string] $Label
    )
    $listUrl = "https://management.azure.com$Scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"
    $resp = Invoke-AzJson -ArgsList @("rest", "--method", "GET", "--url", $listUrl, "-o", "json") -AllowEmpty
    $existing = if ($resp -and $resp.value) {
        @($resp.value | Where-Object {
            $_.properties.principalId -eq $PrincipalId -and
            $_.properties.roleDefinitionId -like "*/$RoleDefinitionId"
        })
    } else { @() }

    if ($existing.Count -gt 0) {
        Write-Host "  RBAC already assigned: $Label" -ForegroundColor DarkGray
        return
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$Scope|$PrincipalId|$RoleDefinitionId"))
        $guidBytes = [byte[]]::new(16)
        [Array]::Copy($hash, $guidBytes, 16)
        $assignmentName = ([guid]::new($guidBytes)).ToString()
    }
    finally {
        $sha.Dispose()
    }

    $fullRoleId = "/subscriptions/$subId/providers/Microsoft.Authorization/roleDefinitions/$RoleDefinitionId"
    $putUrl = "https://management.azure.com$Scope/providers/Microsoft.Authorization/roleAssignments/$assignmentName`?api-version=2022-04-01"
    $body = @{
        properties = @{
            roleDefinitionId = $fullRoleId
            principalId      = $PrincipalId
            principalType    = $PrincipalType
        }
    }

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            [void](Invoke-ArmRest -Method "PUT" -Url $putUrl -Body $body)
            Write-Host "  Assigned RBAC: $Label" -ForegroundColor Green
            return
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match "RoleAssignmentExists") {
                Write-Host "  RBAC already assigned: $Label" -ForegroundColor DarkGray
                return
            }
            if ($msg -match "PrincipalNotFound" -and $attempt -lt 6) {
                Start-Sleep -Seconds 5
                continue
            }
            throw
        }
    }
}

# ── Step 0: Subscription & CLI check ────────────────────────────────────────
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is required. Install Azure CLI or run in Azure Cloud Shell (PowerShell)."
}

if ($SubscriptionId) {
    [void](Invoke-AzJson -ArgsList @("account", "set", "--subscription", $SubscriptionId) -AllowEmpty)
}
$account = Invoke-AzJson -ArgsList @("account", "show", "-o", "json")
$subId   = $account.id
Write-Host "=== Caldova Expense — Azure Monitoring + SRE Agent Setup ===" -ForegroundColor Cyan
Write-Host "Subscription          : $($account.name) ($subId)"
Write-Host "Hybrid Resource Group : $HybridResourceGroup ($Location)"
Write-Host "Log Analytics         : $WorkspaceName ($WorkspaceResourceGroup)"
Write-Host "SRE Agent             : $AgentName ($AgentResourceGroup in $AgentLocation)"

# ── Step 1: Resource Providers ──────────────────────────────────────────────
Write-Host "`n=== [1/5] Registering required Azure Resource Providers ===" -ForegroundColor Cyan
$providers = @(
    "Microsoft.HybridCompute",
    "Microsoft.GuestConfiguration",
    "Microsoft.HybridConnectivity",
    "Microsoft.AzureArcData",
    "Microsoft.OperationalInsights",
    "Microsoft.Insights",
    "Microsoft.App",
    "Microsoft.ManagedIdentity",
    "Microsoft.Authorization"
)
$pending = [System.Collections.Generic.List[string]]::new()
foreach ($rp in $providers) {
    $st = Invoke-AzJson -ArgsList @("provider", "show", "-n", $rp, "--query", "{state:registrationState}", "-o", "json")
    if ($st.state -ne "Registered") {
        Write-Host "  Registering $rp (currently $($st.state))..." -ForegroundColor Yellow
        [void](Invoke-AzJson -ArgsList @("provider", "register", "-n", $rp) -AllowEmpty)
        $pending.Add($rp)
    }
}
$rpDeadline = (Get-Date).AddMinutes(10)
while ($pending.Count -gt 0 -and (Get-Date) -lt $rpDeadline) {
    Start-Sleep -Seconds 10
    foreach ($rp in @($pending)) {
        $st = Invoke-AzJson -ArgsList @("provider", "show", "-n", $rp, "--query", "{state:registrationState}", "-o", "json")
        if ($st.state -eq "Registered") {
            Write-Host "  Registered $rp." -ForegroundColor Green
            [void]$pending.Remove($rp)
        }
    }
}
if ($pending.Count -gt 0) {
    Write-Warning "Still registering: $($pending -join ', '). Continuing..."
}
else {
    Write-Host "  All required resource providers are Registered." -ForegroundColor Green
}

# ── Step 2: Resource Groups ─────────────────────────────────────────────────
Write-Host "`n=== [2/5] Ensuring Resource Groups exist ===" -ForegroundColor Cyan
[void](Invoke-AzJson -ArgsList @("group", "create", "-n", $HybridResourceGroup, "-l", $Location, "-o", "json"))
if ($WorkspaceResourceGroup -ne $HybridResourceGroup) {
    [void](Invoke-AzJson -ArgsList @("group", "create", "-n", $WorkspaceResourceGroup, "-l", $Location, "-o", "json"))
}
[void](Invoke-AzJson -ArgsList @("group", "create", "-n", $AgentResourceGroup, "-l", $AgentLocation, "-o", "json"))
Write-Host "  Resource groups ready: $HybridResourceGroup, $AgentResourceGroup" -ForegroundColor Green

# ── Step 3: Log Analytics Workspace + Custom Table + DCE + DCRs ─────────────
Write-Host "`n=== [3/5] Provisioning Log Analytics ($WorkspaceName), DCE, and Windows DCRs ===" -ForegroundColor Cyan
$lawUrl = "https://management.azure.com/subscriptions/$subId/resourceGroups/$WorkspaceResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName`?api-version=2023-09-01"
$law = Invoke-ArmRest -Method "PUT" -Url $lawUrl -Body @{
    location   = $Location
    properties = @{
        sku             = @{ name = "PerGB2018" }
        retentionInDays = 30
    }
}
$workspaceId = $law.id
Write-Host "  Log Analytics Workspace ready: $workspaceId" -ForegroundColor Green

# Custom table CaldovaExpenseApp_CL for structured C:\ProgramData\CaldovaExpense\logs\app.log
$existingTable = & az monitor log-analytics workspace table show -g $WorkspaceResourceGroup --workspace-name $WorkspaceName -n CaldovaExpenseApp_CL -o json 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($existingTable -join ""))) {
    Write-Host "  Creating custom table CaldovaExpenseApp_CL..." -ForegroundColor Cyan
    [void](Invoke-AzJson -ArgsList @(
        "monitor", "log-analytics", "workspace", "table", "create",
        "-g", $WorkspaceResourceGroup,
        "--workspace-name", $WorkspaceName,
        "-n", "CaldovaExpenseApp_CL",
        "--columns", "TimeGenerated=datetime", "RawData=string",
        "-o", "json"
    ))
}
Write-Host "  Custom table CaldovaExpenseApp_CL ready." -ForegroundColor Green

# Data Collection Endpoint (required by AMA for IIS and custom text log DCRs)
$dceName = "dce-caldova-central"
$dceUrl  = "https://management.azure.com/subscriptions/$subId/resourceGroups/$HybridResourceGroup/providers/Microsoft.Insights/dataCollectionEndpoints/$dceName`?api-version=2022-06-01"
$dce = Invoke-ArmRest -Method "PUT" -Url $dceUrl -Body @{
    location   = $Location
    kind       = "Windows"
    properties = @{
        networkAcls = @{ publicNetworkAccess = "Enabled" }
    }
}
Write-Host "  Data Collection Endpoint ready: $($dce.name)" -ForegroundColor Green

# DCR 1: Windows Performance Counters + Windows Event Logs ('CaldovaExpense' + System/App) + IIS W3C Logs
$winDcrName = "dcr-caldova-win-telemetry"
$winDcrUrl  = "https://management.azure.com/subscriptions/$subId/resourceGroups/$HybridResourceGroup/providers/Microsoft.Insights/dataCollectionRules/$winDcrName`?api-version=2022-06-01"
$winDcrBody = @{
    location   = $Location
    kind       = "Windows"
    properties = @{
        description              = "Caldova Expense Windows Server Perf, Event Logs, and IIS W3C Logs"
        dataCollectionEndpointId = $dce.id
        dataSources              = @{
            performanceCounters = @(
                @{
                    name                       = "winPerfCounters"
                    streams                    = @("Microsoft-Perf")
                    samplingFrequencyInSeconds = 60
                    counterSpecifiers          = @(
                        "\Processor(_Total)\% Processor Time",
                        "\Memory\Available MBytes",
                        "\Memory\% Committed Bytes In Use",
                        "\LogicalDisk(_Total)\% Free Space",
                        "\Web Service(_Total)\Current Connections",
                        "\Web Service(_Total)\Total Method Requests/sec",
                        "\Web Service(_Total)\Total Internal Server Errors",
                        "\SQLServer:General Statistics\User Connections",
                        "\SQLServer:SQL Statistics\Batch Requests/sec",
                        "\SQLServer:Locks(_Total)\Number of Deadlocks/sec",
                        "\SQLServer:Locks(_Total)\Lock Wait Time (ms)",
                        "\MSSQL`$SQLEXPRESS:General Statistics\User Connections",
                        "\MSSQL`$SQLEXPRESS:SQL Statistics\Batch Requests/sec",
                        "\MSSQL`$SQLEXPRESS:Locks(_Total)\Lock Wait Time (ms)"
                    )
                }
            )
            windowsEventLogs = @(
                @{
                    name         = "caldovaEventLogs"
                    streams      = @("Microsoft-Event")
                    xPathQueries = @(
                        "Application!*[System[(Level=1 or Level=2 or Level=3 or Level=4) and Provider[@Name='CaldovaExpense']]]",
                        "Application!*[System[(Level=1 or Level=2 or Level=3)]]",
                        "System!*[System[(Level=1 or Level=2 or Level=3)]]"
                    )
                }
            )
            iisLogs = @(
                @{
                    name    = "iisW3cLogs"
                    streams = @("Microsoft-W3CIISLog")
                }
            )
        }
        destinations = @{
            logAnalytics = @(
                @{
                    name                = "caldovaLaw"
                    workspaceResourceId = $workspaceId
                }
            )
        }
        dataFlows = @(
            @{
                streams      = @("Microsoft-Perf", "Microsoft-Event", "Microsoft-W3CIISLog")
                destinations = @("caldovaLaw")
            }
        )
    }
}
[void](Invoke-ArmRest -Method "PUT" -Url $winDcrUrl -Body $winDcrBody)
Write-Host "  Windows Telemetry DCR ready: $winDcrName (Perf, Event, W3CIISLog)" -ForegroundColor Green

# DCR 2: Structured App Text Log -> CaldovaExpenseApp_CL
$appDcrName = "dcr-caldova-expense-applog"
$appDcrUrl  = "https://management.azure.com/subscriptions/$subId/resourceGroups/$HybridResourceGroup/providers/Microsoft.Insights/dataCollectionRules/$appDcrName`?api-version=2022-06-01"
$appDcrBody = @{
    location   = $Location
    kind       = "Windows"
    properties = @{
        dataCollectionEndpointId = $dce.id
        streamDeclarations       = @{
            "Custom-CaldovaExpenseApp_CL" = @{
                columns = @(
                    @{ name = "TimeGenerated"; type = "datetime" },
                    @{ name = "RawData";       type = "string" }
                )
            }
        }
        dataSources = @{
            logFiles = @(
                @{
                    name         = "caldovaAppTextLog"
                    streams      = @("Custom-CaldovaExpenseApp_CL")
                    filePatterns = @("C:\ProgramData\CaldovaExpense\logs\app.log")
                    format       = "text"
                    settings     = @{
                        text = @{ recordStartTimestampFormat = "ISO 8601" }
                    }
                }
            )
        }
        destinations = @{
            logAnalytics = @(
                @{
                    name                = "caldovaLaw"
                    workspaceResourceId = $workspaceId
                }
            )
        }
        dataFlows = @(
            @{
                streams      = @("Custom-CaldovaExpenseApp_CL")
                destinations = @("caldovaLaw")
                transformKql = "source"
                outputStream = "Custom-CaldovaExpenseApp_CL"
            }
        )
    }
}
[void](Invoke-ArmRest -Method "PUT" -Url $appDcrUrl -Body $appDcrBody)
Write-Host "  Structured App Log DCR ready: $appDcrName (CaldovaExpenseApp_CL)" -ForegroundColor Green

# ── Step 4: Create Azure SRE Agent + UAMI + App Insights + Connectors + RBAC ─
Write-Host "`n=== [4/5] Creating and configuring Azure SRE Agent ($AgentName) ===" -ForegroundColor Cyan

$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $bytes  = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$subId|$AgentResourceGroup|$AgentName"))
    $suffix = (([System.BitConverter]::ToString($bytes)) -replace '-', '').ToLowerInvariant().Substring(0, 10)
}
finally { $sha.Dispose() }

$agentRgBase = "https://management.azure.com/subscriptions/$subId/resourceGroups/$AgentResourceGroup/providers"

# If AgentLocation differs from Workspace Location, create a regional LAW for the agent's own App Insights
$agentBackingLawId = $workspaceId
if ($AgentLocation -ne $Location) {
    $agentLawName = "law-agent-$suffix"
    $agentLaw = Invoke-ArmRest -Method "PUT" `
        -Url "$agentRgBase/Microsoft.OperationalInsights/workspaces/$agentLawName`?api-version=2023-09-01" `
        -Body @{ location = $AgentLocation; properties = @{ sku = @{ name = "PerGB2018" }; retentionInDays = 30 } }
    $agentBackingLawId = $agentLaw.id
}

$aiName = "ai-$suffix"
[void](Invoke-ArmRest -Method "PUT" `
    -Url "$agentRgBase/Microsoft.Insights/components/$aiName`?api-version=2020-02-02" `
    -Body @{
        location   = $AgentLocation
        kind       = "web"
        properties = @{
            Application_Type    = "web"
            Request_Source      = "SreAgent"
            WorkspaceResourceId = $agentBackingLawId
        }
    })
$appInsights = Invoke-AzJson -ArgsList @(
    "resource", "show", "-g", $AgentResourceGroup, "-n", $aiName,
    "--resource-type", "Microsoft.Insights/components", "--api-version", "2020-02-02", "-o", "json"
)
Write-Host "  Agent Application Insights ready: $aiName" -ForegroundColor Green

$identityName = "$AgentName-id-$suffix"
$uami = Invoke-AzJson -ArgsList @(
    "identity", "create", "-g", $AgentResourceGroup, "-n", $identityName, "-l", $AgentLocation, "-o", "json"
)
Write-Host "  User-Assigned Managed Identity ready: $($uami.name) ($($uami.principalId))" -ForegroundColor Green

# Target scopes monitored by the SRE Agent
$targetScopes = [System.Collections.Generic.List[string]]::new()
$targetScopes.Add("/subscriptions/$subId/resourceGroups/$HybridResourceGroup")
if ($WorkspaceResourceGroup -ne $HybridResourceGroup) {
    $targetScopes.Add("/subscriptions/$subId/resourceGroups/$WorkspaceResourceGroup")
}

$roleReader            = "acdd72a7-3385-48ef-bd42-f606fba81ae7"
$roleLogAnalyticsRead  = "73c42c96-874c-492b-b04d-ab87d138a893"
$roleMonitoringReader  = "43d0d8ad-25c7-4714-9337-8ba259a9fe05"
$roleContributor       = "b24988ac-6180-42a0-ab88-20f7382dd24c"
$roleArcAdmin          = "cd570a14-e51a-42ad-bac8-bafd67325302"
$roleSreAgentAdmin     = "e79298df-d852-4c6d-84f9-5d13249d1e55"

Ensure-RoleAssignment -PrincipalId $uami.principalId -PrincipalType "ServicePrincipal" `
    -RoleDefinitionId $roleMonitoringReader -Scope "/subscriptions/$subId/resourceGroups/$AgentResourceGroup" `
    -Label "UAMI -> Monitoring Reader on $AgentResourceGroup"

foreach ($scope in $targetScopes) {
    Ensure-RoleAssignment -PrincipalId $uami.principalId -PrincipalType "ServicePrincipal" -RoleDefinitionId $roleReader           -Scope $scope -Label "UAMI -> Reader on $($scope.Split('/')[-1])"
    Ensure-RoleAssignment -PrincipalId $uami.principalId -PrincipalType "ServicePrincipal" -RoleDefinitionId $roleLogAnalyticsRead -Scope $scope -Label "UAMI -> Log Analytics Reader on $($scope.Split('/')[-1])"
    Ensure-RoleAssignment -PrincipalId $uami.principalId -PrincipalType "ServicePrincipal" -RoleDefinitionId $roleMonitoringReader -Scope $scope -Label "UAMI -> Monitoring Reader on $($scope.Split('/')[-1])"
    if ($AccessLevel -eq "High") {
        Ensure-RoleAssignment -PrincipalId $uami.principalId -PrincipalType "ServicePrincipal" -RoleDefinitionId $roleContributor -Scope $scope -Label "UAMI -> Contributor on $($scope.Split('/')[-1])"
        Ensure-RoleAssignment -PrincipalId $uami.principalId -PrincipalType "ServicePrincipal" -RoleDefinitionId $roleArcAdmin    -Scope $scope -Label "UAMI -> Azure Connected Machine Resource Administrator on $($scope.Split('/')[-1])"
    }
}

# Create or read SRE Agent resource
$agentArmUrl = "$agentRgBase/Microsoft.App/agents/$AgentName`?api-version=$AgentApiVersion"
$existingAgent = $null
try {
    $existingAgent = Invoke-AzJson -ArgsList @(
        "resource", "show", "-g", $AgentResourceGroup, "-n", $AgentName,
        "--resource-type", "Microsoft.App/agents", "--api-version", $AgentApiVersion, "-o", "json"
    )
} catch { $existingAgent = $null }

if (-not $existingAgent -or $existingAgent.properties.provisioningState -in @("Failed", "Canceled")) {
    Write-Host "  Provisioning SRE Agent '$AgentName' in '$AgentLocation' (takes ~2-4 minutes)..." -ForegroundColor Cyan
    $agentBody = @{
        location = $AgentLocation
        tags     = @{ workload = "CaldovaExpense"; environment = "HybridOnPremLab" }
        identity = @{
            type                   = "SystemAssigned, UserAssigned"
            userAssignedIdentities = @{ "$($uami.id)" = @{} }
        }
        properties = @{
            knowledgeGraphConfiguration = @{
                identity         = $uami.id
                managedResources = @($targetScopes)
            }
            actionConfiguration = @{
                accessLevel = $AccessLevel
                identity    = $uami.id
                mode        = $ActionMode
            }
            incidentManagementConfiguration = @{
                type           = "AzMonitor"
                connectionName = "azmonitor"
            }
            logConfiguration = @{
                applicationInsightsConfiguration = @{
                    appId                          = $appInsights.properties.AppId
                    connectionString               = $appInsights.properties.ConnectionString
                    applicationInsightsResourceId  = $appInsights.id
                }
            }
            upgradeChannel        = "Preview"
            monthlyAgentUnitLimit = 10000
            defaultModel          = @{
                provider = $ModelProvider
                name     = "Automatic"
            }
            experimentalSettings  = @{
                EnableWorkspaceTools = $true
                EnableHttpTriggers   = $true
                EnableV2AgentLoop    = $true
            }
        }
    }
    [void](Invoke-ArmRest -Method "PUT" -Url $agentArmUrl -Body $agentBody)
}

# Poll until provisioningState == Succeeded
$deadline = (Get-Date).AddMinutes(20)
$agent = $null
do {
    $agent = Invoke-AzJson -ArgsList @(
        "resource", "show", "-g", $AgentResourceGroup, "-n", $AgentName,
        "--resource-type", "Microsoft.App/agents", "--api-version", $AgentApiVersion, "-o", "json"
    )
    $state = $agent.properties.provisioningState
    if ($state -eq "Succeeded") { break }
    if ($state -in @("Failed", "Canceled")) {
        throw "SRE Agent '$AgentName' provisioning ended in state '$state'."
    }
    Write-Host "    ... SRE Agent provisioningState = $state" -ForegroundColor DarkGray
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $deadline)

if ($agent.properties.provisioningState -ne "Succeeded") {
    throw "Timed out waiting for SRE Agent '$AgentName' to reach Succeeded."
}
Write-Host "  SRE Agent '$AgentName' is Succeeded!" -ForegroundColor Green

# Grant System-Assigned MI Reader + Log Analytics Reader + Monitoring Reader on target scopes (used by connectors!)
$systemMiPrincipalId = $agent.identity.principalId
foreach ($scope in $targetScopes) {
    Ensure-RoleAssignment -PrincipalId $systemMiPrincipalId -PrincipalType "ServicePrincipal" -RoleDefinitionId $roleReader           -Scope $scope -Label "SystemMI -> Reader on $($scope.Split('/')[-1])"
    Ensure-RoleAssignment -PrincipalId $systemMiPrincipalId -PrincipalType "ServicePrincipal" -RoleDefinitionId $roleLogAnalyticsRead -Scope $scope -Label "SystemMI -> Log Analytics Reader on $($scope.Split('/')[-1])"
    Ensure-RoleAssignment -PrincipalId $systemMiPrincipalId -PrincipalType "ServicePrincipal" -RoleDefinitionId $roleMonitoringReader -Scope $scope -Label "SystemMI -> Monitoring Reader on $($scope.Split('/')[-1])"
}

# Grant SRE Agent Administrator on agent scope to signed-in user and UAMI
$signedInOid = Get-SignedInUserObjectId
if ($signedInOid) {
    Ensure-RoleAssignment -PrincipalId $signedInOid -PrincipalType "User" -RoleDefinitionId $roleSreAgentAdmin -Scope $agent.id -Label "Current User -> SRE Agent Administrator"
}
Ensure-RoleAssignment -PrincipalId $uami.principalId -PrincipalType "ServicePrincipal" -RoleDefinitionId $roleSreAgentAdmin -Scope $agent.id -Label "UAMI -> SRE Agent Administrator"

# Wire Log Analytics connector (law-caldova-central) + Azure Monitor connector on the SRE Agent
Write-Host "  Configuring Log Analytics ($WorkspaceName) & Azure Monitor connectors on '$AgentName'..." -ForegroundColor Cyan
$connectorsBase = "https://management.azure.com$($agent.id)/connectors"

[void](Invoke-ArmRest -Method "PUT" -Url "$connectorsBase/log-analytics?api-version=$AgentApiVersion" -Body @{
    properties = @{
        dataConnectorType  = "LogAnalytics"
        dataSource         = $workspaceId
        extendedProperties = @{
            armResourceId = $workspaceId
            resource      = @{ name = $WorkspaceName }
        }
        identity           = "system"
    }
})

[void](Invoke-ArmRest -Method "PUT" -Url "$connectorsBase/azure-monitor?api-version=$AgentApiVersion" -Body @{
    properties = @{
        dataConnectorType  = "AzureMonitor"
        dataSource         = "/subscriptions/$subId"
        extendedProperties = @{
            armResourceId = "/subscriptions/$subId"
            lookbackDays  = 7
        }
        identity           = "system"
    }
})
Write-Host "  Connectors configured: log-analytics ($WorkspaceName), azure-monitor" -ForegroundColor Green

# Optional: Upload Caldova Expense Runbook to SRE Agent Knowledge Memory if data-plane token is available
$runbookPath = Join-Path (Split-Path -Parent $PSScriptRoot) "sre-agent\knowledge\caldova-expense-runbook.md"
$agentEndpoint = $agent.properties.agentEndpoint
if ($agentEndpoint -and (Test-Path $runbookPath)) {
    $dpToken = (& az account get-access-token --scope "https://azuresre.dev/.default" --query accessToken -o tsv 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($dpToken -join ""))) {
        try {
            $tok = ($dpToken -join "").Trim()
            $fileBytes = [System.IO.File]::ReadAllBytes($runbookPath)
            $boundary  = [guid]::NewGuid().ToString()
            $lf        = "`r`n"
            $headerStr = "--$boundary$lf" +
                         "Content-Disposition: form-data; name=`"files`"; filename=`"caldova-expense-runbook.md`"$lf" +
                         "Content-Type: text/markdown$lf$lf"
            $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($headerStr)
            $footerBytes = [System.Text.Encoding]::UTF8.GetBytes("$lf--$boundary--$lf")

            $ms = [System.IO.MemoryStream]::new()
            $ms.Write($headerBytes, 0, $headerBytes.Length)
            $ms.Write($fileBytes, 0, $fileBytes.Length)
            $ms.Write($footerBytes, 0, $footerBytes.Length)
            $bodyBytes = $ms.ToArray()
            $ms.Dispose()

            $uploadUrl = "$($agentEndpoint.TrimEnd('/'))/api/v1/AgentMemory/upload?triggerIndexing=true"
            Invoke-WebRequest -Uri $uploadUrl -Method Post `
                -Headers @{ Authorization = "Bearer $tok" } `
                -ContentType "multipart/form-data; boundary=$boundary" `
                -Body $bodyBytes -UseBasicParsing -TimeoutSec 30 | Out-Null
            Write-Host "  Uploaded knowledge file 'caldova-expense-runbook.md' to SRE Agent memory." -ForegroundColor Green
        }
        catch {
            Write-Host "  Note: Knowledge upload skipped ($($_.Exception.Message)). You can upload sre-agent\knowledge\caldova-expense-runbook.md in the SRE Agent portal (Knowledge -> Files)." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "  Note: Run 'az login --scope `"https://azuresre.dev/.default`"' and re-run (or upload sre-agent\knowledge\caldova-expense-runbook.md via the SRE Agent portal) to index the Caldova runbook." -ForegroundColor Yellow
    }
}

# ── Step 5: Attach AMAWindows + DCRs if Arc Machine is already onboarded ─────
Write-Host "`n=== [5/5] Checking Azure Arc machine '$MachineName' in '$HybridResourceGroup' ===" -ForegroundColor Cyan
$arcCheck = & az resource show -g $HybridResourceGroup -n $MachineName --resource-type "Microsoft.HybridCompute/machines" -o json 2>$null
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($arcCheck -join ""))) {
    & (Join-Path $PSScriptRoot "2-attach-arc-monitoring.ps1") `
        -SubscriptionId $subId `
        -HybridResourceGroup $HybridResourceGroup `
        -Location $Location `
        -MachineName $MachineName
}
else {
    Write-Host "  Arc machine '$MachineName' is not onboarded yet." -ForegroundColor Yellow
    Write-Host "  Once you complete .\onprem\4-connect-azure-arc.ps1, run:" -ForegroundColor Yellow
    Write-Host "    .\azure\2-attach-arc-monitoring.ps1 -SubscriptionId `"$subId`" -HybridResourceGroup `"$HybridResourceGroup`" -MachineName `"$MachineName`"" -ForegroundColor White
}

$portalUrl = "https://sre.azure.com/#/agent/$subId/$AgentResourceGroup/$AgentName"
Write-Host "`n=== Setup Summary ===" -ForegroundColor Green
Write-Host "SRE Agent Portal URL  : $portalUrl"
Write-Host "SRE Agent Endpoint    : $agentEndpoint"
Write-Host "Log Analytics         : $WorkspaceName ($WorkspaceResourceGroup)"
Write-Host "Arc Target Machine    : $MachineName ($HybridResourceGroup)"
