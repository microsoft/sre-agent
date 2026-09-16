#Requires -Version 7.4
<#
.SYNOPSIS
    Post-provision script for Zava SRE Agent Demo.
    Builds container images, deploys to AKS, configures identity and DB access.
.DESCRIPTION
    Run after 'azd provision' to complete the deployment:
    1. Build and push container images to ACR
    2. Configure PostgreSQL Entra authentication
    3. Set up AKS workload identity federation
    4. Install NGINX ingress controller
    5. Deploy K8s manifests with environment substitution
    6. Wait for pods and ingress IP assignment, then print endpoints
    7. Configure and verify the SRE Agent
.NOTES
    Requires: az CLI, azd. (kubectl is NOT required — all in-cluster ops run through `az aks command invoke`.)
    Run from the project root directory.
#>
param(
    [switch]$SkipImageBuild,
    [switch]$SkipIngressInstall,
    [string]$Namespace = "zava-demo",
    [ValidateRange(1, 3600)][int]$IngressTimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Zava Demo Post-Provision (PowerShell)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Ensure we're in the repo root (script lives in scripts/)
$repoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $repoRoot

# ── Step 0: Load azd environment values ──────────────────────────────────────
Write-Host "Loading azd environment values..." -ForegroundColor Yellow

# Resolve the target resource group early — the Azure-discovery fallback below
# needs it. RESOURCE_GROUP is an azd OUTPUT (only present after a successful
# provision); ZAVA_RG_NAME is an optional override. Fresh environments default
# to rg-$AZURE_ENV_NAME, matching infra/main.bicepparam.
function Get-TargetRg {
    foreach ($k in 'RESOURCE_GROUP', 'ZAVA_RG_NAME') {
        $v = [Environment]::GetEnvironmentVariable($k)
        if (-not $v) {
            $v = azd env get-value $k 2>$null
            if ($LASTEXITCODE -ne 0) { $v = $null }
        }
        if ($v -and "$v".Trim() -and "$v" -notmatch '^ERROR') { return "$v".Trim() }
    }
    $environmentName = [Environment]::GetEnvironmentVariable('AZURE_ENV_NAME')
    if ($environmentName) { return "rg-$environmentName" }
    return $null
}
$script:TargetRg = Get-TargetRg
$script:DiscoveredPostgresServer = $null

function Get-AzdEnvironmentValue([string]$key) {
    $val = [Environment]::GetEnvironmentVariable($key)
    if (-not $val) {
        $val = azd env get-value $key 2>$null
        if ($LASTEXITCODE -ne 0) { $val = $null }
    }
    if ($val -and "$val".Trim() -and "$val" -notmatch '^ERROR') {
        return "$val".Trim()
    }
    return $null
}

function Get-DiscoveredPostgresServer {
    if ($script:DiscoveredPostgresServer) { return $script:DiscoveredPostgresServer }
    $json = az postgres flexible-server list -g $script:TargetRg -o json 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list PostgreSQL Flexible Servers in resource group '$($script:TargetRg)'."
    }
    $servers = @($json | ConvertFrom-Json)
    if ($servers.Count -ne 1) {
        throw "Expected exactly one PostgreSQL Flexible Server in resource group '$($script:TargetRg)'; found $($servers.Count)."
    }
    foreach ($server in $servers) { $script:DiscoveredPostgresServer = $server }
    return $script:DiscoveredPostgresServer
}

function Get-PostProvisionSreIdentityPair([string]$AgentName) {
    $agentJson = az resource show -g $script:TargetRg -n $AgentName `
        --resource-type Microsoft.App/agents --api-version 2025-05-01-preview -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $agentJson) {
        throw "Could not read SRE Agent '$AgentName' in resource group '$($script:TargetRg)' for identity discovery."
    }
    $agent = $agentJson | ConvertFrom-Json
    $actionConfiguration = $agent.properties.PSObject.Properties['actionConfiguration']
    $actionIdentityProperty = if ($actionConfiguration -and $actionConfiguration.Value) {
        $actionConfiguration.Value.PSObject.Properties['identity']
    } else { $null }
    $identityId = if ($actionIdentityProperty) {
        [string]$actionIdentityProperty.Value
    } else { '' }
    if (-not $identityId.Trim()) {
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
        $identityId = [string]($identityIds -join '')
    }
    if ($identityId -notmatch '/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[^/]+$') {
        throw "The selected identity on SRE Agent '$AgentName' is not a user-assigned managed identity resource ID."
    }

    $identityJson = az identity show --ids $identityId -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $identityJson) {
        throw "Could not read attached user-assigned identity '$identityId'."
    }
    $identity = $identityJson | ConvertFrom-Json
    $name = [string]$identity.name
    $clientId = [string]$identity.clientId
    if (-not $name.Trim() -or -not $clientId.Trim()) {
        throw "Attached user-assigned identity '$identityId' is missing its name or clientId."
    }

    $suppliedName = Get-AzdEnvironmentValue 'SRE_AGENT_IDENTITY_NAME'
    $suppliedClientId = Get-AzdEnvironmentValue 'SRE_AGENT_CLIENT_ID'
    if ($suppliedName -and $suppliedName -ne $name.Trim()) {
        throw "SRE_AGENT_IDENTITY_NAME does not match the attached user-assigned identity selected for '$AgentName'."
    }
    if ($suppliedClientId -and $suppliedClientId -ne $clientId.Trim()) {
        throw "SRE_AGENT_CLIENT_ID does not match the attached user-assigned identity selected for '$AgentName'."
    }
    return @{
        Name = $name.Trim()
        ClientId = $clientId.Trim()
    }
}

function Enable-ZavaPgStatStatements {
    param(
        [Parameter(Mandatory)] [string]$ResourceGroup,
        [Parameter(Mandatory)] [string]$ClusterName,
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')]
        [string]$Namespace
    )

    $createSql = 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements'
    $createCommand = "kubectl exec -n $Namespace deploy/zava-api -- node bin/run-sql.js '$createSql'"
    $result = Invoke-AksCommand -ResourceGroup $ResourceGroup -ClusterName $ClusterName `
        -Command $createCommand -Quiet
    Assert-AksCommandSucceeded $result 'pg_stat_statements extension creation'

    $verificationSql = 'SELECT extname FROM pg_extension ORDER BY extname'
    $verificationCommand = "kubectl exec -n $Namespace deploy/zava-api -- node bin/run-sql.js '$verificationSql'"
    $result = Invoke-AksCommand -ResourceGroup $ResourceGroup -ClusterName $ClusterName `
        -Command $verificationCommand -Quiet
    Assert-AksCommandSucceeded $result 'pg_stat_statements extension verification'

    try {
        $readback = ([string]$result.logs).Trim() | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $readback -or $readback -isnot [pscustomobject]) {
            throw [FormatException]::new()
        }
    } catch {
        throw 'pg_stat_statements extension verification did not return the expected JSON envelope.'
    }
    $commandProperty = $readback.PSObject.Properties['command']
    $rowCountProperty = $readback.PSObject.Properties['rowCount']
    $rowsProperty = $readback.PSObject.Properties['rows']
    if (-not $commandProperty -or -not $rowCountProperty -or -not $rowsProperty) {
        throw 'pg_stat_statements extension verification must include command, rowCount, and rows properties.'
    }
    if ([string]$commandProperty.Value -cne 'SELECT') {
        throw 'pg_stat_statements extension verification command must be SELECT.'
    }

    $numericTypes = @(
        [TypeCode]::Byte,
        [TypeCode]::SByte,
        [TypeCode]::Int16,
        [TypeCode]::UInt16,
        [TypeCode]::Int32,
        [TypeCode]::UInt32,
        [TypeCode]::Int64,
        [TypeCode]::UInt64,
        [TypeCode]::Single,
        [TypeCode]::Double,
        [TypeCode]::Decimal
    )
    $rowCount = $rowCountProperty.Value
    $rowsValue = $rowsProperty.Value
    if ($rowsValue -isnot [Collections.IList]) {
        throw 'pg_stat_statements extension verification must return a numeric rowCount matching rows.'
    }
    $rows = @($rowsValue)
    if (
        $null -eq $rowCount -or
        [Type]::GetTypeCode($rowCount.GetType()) -notin $numericTypes -or
        $rowCount -ne $rows.Count
    ) {
        throw 'pg_stat_statements extension verification must return a numeric rowCount matching rows.'
    }

    $matchingRows = @($rows | Where-Object {
        $null -ne $_ -and
        $_.PSObject.Properties['extname'] -and
        [string]$_.extname -ceq 'pg_stat_statements'
    })
    if ($matchingRows.Count -ne 1) {
        throw 'pg_stat_statements extension verification must return exactly one pg_stat_statements row.'
    }
}

# Azure-discovery fallback: derive a value straight from the deployed resources
# when azd has not captured outputs. azd only persists Bicep outputs on a FULLY
# successful `azd provision`, so a partial/transient failure (e.g. the AMPLS
# private endpoint's occasional InternalServerError) leaves the outputs unset and
# strands this hook. Discovering from the resource group makes post-provision
# RESUMABLE after such a failure AND runnable standalone (e.g. after a raw
# `az deployment sub create`, outside azd). PostgreSQL and SRE identity recovery
# enforce exact cardinality because those values form an authentication pair.
function Get-DiscoveredValue([string]$key) {
    $rg = $script:TargetRg
    if (-not $rg) { return $null }
    switch ($key) {
        'RESOURCE_GROUP'   { $rg }
        'AZURE_LOCATION'   { az group show -n $rg --query location -o tsv 2>$null }
        'AKS_CLUSTER_NAME' { az aks list -g $rg --query "[0].name" -o tsv 2>$null }
        'AKS_OIDC_ISSUER'  { $a = az aks list -g $rg --query "[0].name" -o tsv 2>$null; if ($a) { az aks show -g $rg -n $a --query oidcIssuerProfile.issuerUrl -o tsv 2>$null } }
        'ACR_NAME'         { az acr list -g $rg --query "[0].name" -o tsv 2>$null }
        'ACR_LOGIN_SERVER' { az acr list -g $rg --query "[0].loginServer" -o tsv 2>$null }
        'PG_SERVER_NAME'   { (Get-DiscoveredPostgresServer).name }
        'DB_HOST'          { (Get-DiscoveredPostgresServer).fullyQualifiedDomainName }
        'DB_NAME'          { 'zava_store' }
        'APPINSIGHTS_CONNECTION_STRING' { $aiId = az resource list -g $rg --resource-type 'microsoft.insights/components' --query "[0].id" -o tsv 2>$null; if ($aiId) { az resource show --ids $aiId --query properties.ConnectionString -o tsv 2>$null } }
        'APP_IDENTITY_NAME'         { az identity list -g $rg --query "[?contains(name,'Zava-app')].name | [0]" -o tsv 2>$null }
        'APP_IDENTITY_CLIENT_ID'    { az identity list -g $rg --query "[?contains(name,'Zava-app')].clientId | [0]" -o tsv 2>$null }
        'APP_IDENTITY_PRINCIPAL_ID' { az identity list -g $rg --query "[?contains(name,'Zava-app')].principalId | [0]" -o tsv 2>$null }
        'SRE_AGENT_NAME'          {
            $agents = @(az resource list -g $rg --resource-type 'Microsoft.App/agents' -o json 2>$null | ConvertFrom-Json)
            if ($agents.Count -ne 1) {
                throw "Expected exactly one SRE Agent in resource group '$rg'; found $($agents.Count)."
            }
            [string]$agents.name
        }
        default                   { $null }
    }
}

function Get-AzdValue([string]$key) {
    # 1) azd injects Bicep outputs as env vars in hook subprocesses; 2) fall back
    # to the persisted env; 3) discover from Azure (resumable + standalone).
    $val = Get-AzdEnvironmentValue $key
    if (-not $val -or -not "$val".Trim() -or "$val" -match '^ERROR') {
        $val = Get-DiscoveredValue $key
        if ($val -and "$val".Trim()) { Write-Host "  (discovered $key from Azure resources)" -ForegroundColor DarkGray }
    }
    if (-not $val -or -not "$val".Trim()) {
        throw "Missing value '$key' — not in azd env and not discoverable in resource group '$($script:TargetRg)'. Run 'azd provision' or set ZAVA_RG_NAME."
    }
    return "$val".Trim()
}

$RG              = Get-AzdValue "RESOURCE_GROUP"
$AKS_NAME        = Get-AzdValue "AKS_CLUSTER_NAME"
$ACR_NAME        = Get-AzdValue "ACR_NAME"
$ACR_LOGIN       = Get-AzdValue "ACR_LOGIN_SERVER"
$DB_HOST         = Get-AzdValue "DB_HOST"
$DB_NAME         = Get-AzdValue "DB_NAME"
$PG_SERVER       = Get-AzdValue "PG_SERVER_NAME"
$AI_CONN         = Get-AzdValue "APPINSIGHTS_CONNECTION_STRING"
$APP_ID_NAME     = Get-AzdValue "APP_IDENTITY_NAME"
$APP_CLIENT_ID   = Get-AzdValue "APP_IDENTITY_CLIENT_ID"
$APP_PRINCIPAL_ID = Get-AzdValue "APP_IDENTITY_PRINCIPAL_ID"
$OIDC_ISSUER     = Get-AzdValue "AKS_OIDC_ISSUER"
$AZURE_LOCATION  = Get-AzdValue "AZURE_LOCATION"
$SRE_AGENT_NAME  = Get-AzdValue "SRE_AGENT_NAME"
$sreIdentity     = Get-PostProvisionSreIdentityPair -AgentName $SRE_AGENT_NAME
$SRE_AGENT_CLIENT_ID = $sreIdentity.ClientId
$SRE_AGENT_PRINCIPAL_NAME = $sreIdentity.Name

Write-Host "  Resource Group:  $RG"
Write-Host "  AKS Cluster:     $AKS_NAME"
Write-Host "  ACR:             $ACR_NAME ($ACR_LOGIN)"
Write-Host "  PostgreSQL:      $DB_HOST"
Write-Host "  App Identity:    $APP_ID_NAME ($APP_CLIENT_ID)"
Write-Host ""

# ── Step 1: Build and push container images ──────────────────────────────────
if (-not $SkipImageBuild) {
    Write-Host "=== Step 1: Building container images ===" -ForegroundColor Green
    Write-Host "Building API image..."
    az acr build --registry $ACR_NAME --image zava-api:latest ./src/api --no-logs -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        az acr build --registry $ACR_NAME --image zava-api:latest ./src/api
        if ($LASTEXITCODE -ne 0) { throw 'API image build failed.' }
    }

    Write-Host "Building Storefront image..."
    az acr build --registry $ACR_NAME --image zava-storefront:latest ./src/storefront --no-logs -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        az acr build --registry $ACR_NAME --image zava-storefront:latest ./src/storefront
        if ($LASTEXITCODE -ne 0) { throw 'Storefront image build failed.' }
    }
    Write-Host "  Images built and pushed to $ACR_LOGIN" -ForegroundColor Green
} else {
    Write-Host "=== Step 1: SKIPPED (image build) ===" -ForegroundColor DarkGray
}
Write-Host ""

# ── Step 2: Configure PostgreSQL Entra admin (signed-in operator only) ───────
# UMI/SMI/app-identity PG admin grants are declared in Bicep (identity.bicep +
# sre-agent.bicep). The signed-in operator grant lives here because it depends
# on `az ad signed-in-user show`, which has no Bicep equivalent.
Write-Host "=== Step 2: PostgreSQL Entra admin (operator) ===" -ForegroundColor Green

$accountInfo = az account show --query "{type:user.type, name:user.name}" | ConvertFrom-Json
$isInteractiveUser = ($accountInfo.type -eq 'user')

if ($isInteractiveUser) {
    $currentUserOid  = az ad signed-in-user show --query id -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $currentUserOid) { throw 'Could not resolve the signed-in operator.' }
    $currentUserName = az ad signed-in-user show --query userPrincipalName -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $currentUserName) { throw 'Could not resolve the operator name.' }
    Write-Host "  Setting Entra admin: $currentUserName ($currentUserOid)"

    az postgres flexible-server microsoft-entra-admin create `
        -g $RG -s $PG_SERVER `
        --object-id $currentUserOid `
        --display-name $currentUserName `
        --type User -o none
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not configure the PostgreSQL operator administrator.'
    }
} else {
    Write-Host "  Skipping signed-in-user PostgreSQL Entra admin step (running as $($accountInfo.type): $($accountInfo.name))" -ForegroundColor Yellow
}
Write-Host ""

# ── Step 3: Set up AKS workload identity federation ─────────────────────────
Write-Host "=== Step 3: Workload identity federation ===" -ForegroundColor Green
Write-Host "  Creating federated credential for namespace: $Namespace"

az identity federated-credential create `
    --name "zava-fed-$Namespace" `
    --identity-name $APP_ID_NAME `
    -g $RG `
    --issuer $OIDC_ISSUER `
    --subject "system:serviceaccount:${Namespace}:zava-workload-identity" `
    --audiences "api://AzureADTokenExchange" -o none
if ($LASTEXITCODE -ne 0) {
    throw 'Could not configure the application federated credential.'
}

# Attach ACR to AKS (ensures kubelet can pull images)
Write-Host "  Attaching ACR to AKS..."
az aks update -g $RG -n $AKS_NAME --attach-acr $ACR_NAME -o none
if ($LASTEXITCODE -ne 0) { throw 'Could not attach the container registry to AKS.' }
Write-Host ""

# ── Step 4: Configure AKS RBAC (operator only) ───────────────────────────────
# SRE Agent UMI + SMI AKS RBAC Cluster Admin grants are declared in Bicep
# (identity.bicep + sre-agent.bicep). The signed-in operator grant lives here
# because it depends on `az ad signed-in-user show`, which has no Bicep equivalent.
#
# NOTE: AKS is a PRIVATE cluster — its API server is not reachable from the
# public internet. We do NOT install kubectl or fetch credentials here; every
# kubectl operation runs through `az aks command invoke` (the same path the
# SRE Agent uses). Operators who want kubectl from a VPN/jumpbox can still run
# `az aks get-credentials` themselves.
Write-Host "=== Step 4: AKS RBAC (operator) ===" -ForegroundColor Green
. "$PSScriptRoot\_aks-helpers.ps1"

# Grant deployer AKS RBAC Cluster Admin (required when Azure RBAC for K8s is enabled)
$aksScope = az aks show -g $RG -n $AKS_NAME --query id -o tsv
if ($LASTEXITCODE -ne 0 -or -not $aksScope) { throw 'Could not resolve the AKS resource ID.' }
if ($isInteractiveUser) {
    az role assignment create --assignee-object-id $currentUserOid --assignee-principal-type User `
        --role "Azure Kubernetes Service RBAC Cluster Admin" `
        --scope $aksScope -o none
    if ($LASTEXITCODE -ne 0) { throw 'Could not assign AKS operator access.' }
} else {
    Write-Host "  Skipping signed-in-user AKS RBAC step (running as $($accountInfo.type))" -ForegroundColor Yellow
}

# Wait for command-invoke availability + RBAC propagation
Write-Host "  Waiting for AKS operator access..."
Wait-AksOperatorAccess -ResourceGroup $RG -ClusterName $AKS_NAME -Namespace $Namespace
Write-Host ""

# ── Step 4b: Link AKS private DNS zone to the agent VNet ─────────────────────
# AKS creates its private DNS
# zone (<guid>.privatelink.<region>.azmk8s.io) in the node resource group with a
# name not known until the cluster exists, so the virtual-network link to the
# agent spoke can't be a static Bicep resource. Idempotent.
Write-Host "=== Step 4b: Linking AKS private DNS zone to agent VNet ===" -ForegroundColor Green
$mcRg = az aks show -g $RG -n $AKS_NAME --query nodeResourceGroup -o tsv 2>$null
$aksDnsZone = az network private-dns zone list -g $mcRg --query "[?contains(name,'azmk8s.io')].name | [0]" -o tsv 2>$null
$agentVnetId = az network vnet list -g $RG --query "[?contains(name,'agent')].id | [0]" -o tsv 2>$null
if ($mcRg -and $aksDnsZone -and $agentVnetId) {
    $existing = az network private-dns link vnet show -g $mcRg -z $aksDnsZone -n agent-link --query name -o tsv 2>$null
    if ($existing) {
        Write-Host "  Link 'agent-link' already present on $aksDnsZone" -ForegroundColor DarkGray
    } else {
        az network private-dns link vnet create -g $mcRg -z $aksDnsZone -n agent-link `
            --virtual-network $agentVnetId --registration-enabled false -o none 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Linked AKS private DNS zone -> agent VNet" -ForegroundColor Green
        } else {
            Write-Host "  (warning: could not link AKS DNS zone to agent VNet)" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  (skipped: could not resolve AKS node RG / DNS zone / agent VNet)" -ForegroundColor Yellow
}
Write-Host ""

# ── Step 5: Install NGINX Ingress Controller (via command invoke) ────────────
if (-not $SkipIngressInstall) {
    Write-Host "=== Step 5: Installing NGINX Ingress (via az aks command invoke) ===" -ForegroundColor Green
    $ingressUrl = "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/cloud/deploy.yaml"
    $r = Invoke-AksCommand -ResourceGroup $RG -ClusterName $AKS_NAME `
        -Command "kubectl apply -f $ingressUrl"
    Assert-AksCommandSucceeded $r 'Ingress installation'
    Write-Host "  Waiting for ingress controller pods..."
    $r = Invoke-AksCommand -ResourceGroup $RG -ClusterName $AKS_NAME `
        -Command "kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=180s"
    Assert-AksCommandSucceeded $r 'Ingress readiness'
} else {
    Write-Host "=== Step 5: SKIPPED (ingress install) ===" -ForegroundColor DarkGray
}
Write-Host ""

# ── Step 6: Render manifests + apply via command invoke ──────────────────────
Write-Host "=== Step 6: Deploying to AKS (namespace: $Namespace) ===" -ForegroundColor Green

# Substitute env vars into each manifest and stage in a temp dir for upload
$stageDir = Join-Path ([System.IO.Path]::GetTempPath()) "zava-k8s-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

$k8sFiles = @(
    "k8s/service-account.yaml",
    "k8s/configmap.yaml",
    "k8s/secret.yaml",
    "k8s/api-deployment.yaml",
    "k8s/api-service.yaml",
    "k8s/storefront-deployment.yaml",
    "k8s/storefront-service.yaml",
    "k8s/ingress.yaml"
)

$stagedFiles = @()
foreach ($f in $k8sFiles) {
    if (-not (Test-Path $f)) {
        throw "Missing Kubernetes manifest: $f"
    }
    $content = Get-Content $f -Raw
    $content = $content -replace '\$\{ACR_NAME\}', $ACR_NAME
    $content = $content -replace '\$\{DB_HOST\}', $DB_HOST
    $content = $content -replace '\$\{APP_IDENTITY_CLIENT_ID\}', $APP_CLIENT_ID
    $content = $content -replace '\$\{APP_IDENTITY_NAME\}', $APP_ID_NAME
    $content = $content -replace '\$\{APPINSIGHTS_CONNECTION_STRING\}', $AI_CONN
    $content = $content -replace '\$\{AZURE_LOCATION\}', $AZURE_LOCATION

    if ($content -notmatch 'namespace:') {
        $content = $content -replace '(metadata:\s*\n\s+name:)', "metadata:`n  namespace: $Namespace`n  name:"
    }

    $outFile = Join-Path $stageDir (Split-Path $f -Leaf)
    $content | Set-Content $outFile -Encoding UTF8
    $stagedFiles += $outFile
    Write-Host "  Staged: $f" -ForegroundColor DarkGray
}

# Upload all manifests in one invoke and apply them inside the cluster
Write-Host "  Applying all manifests via az aks command invoke..."
$applyCmd = "kubectl create namespace $Namespace 2>/dev/null; kubectl apply -n $Namespace -f ."
$r = Invoke-AksCommand -ResourceGroup $RG -ClusterName $AKS_NAME `
    -Command $applyCmd -Files $stagedFiles
Remove-Item -Recurse -Force $stageDir
Assert-AksCommandSucceeded $r 'Application manifest deployment'
Write-Host ""

# ── Step 7: Wait for deployments to be ready ─────────────────────────────────
Write-Host "=== Step 7: Waiting for pods ===" -ForegroundColor Green
$r = Invoke-AksCommand -ResourceGroup $RG -ClusterName $AKS_NAME `
    -Command "kubectl rollout status deployment/zava-api -n $Namespace --timeout=180s && kubectl rollout status deployment/zava-storefront -n $Namespace --timeout=180s"
Assert-AksCommandSucceeded $r 'Application rollout'
Write-Host ""

# ── Step 7b: Ensure required PostgreSQL extension ────────────────────────────
Write-Host "=== Step 7b: Ensuring pg_stat_statements ===" -ForegroundColor Green
Enable-ZavaPgStatStatements -ResourceGroup $RG -ClusterName $AKS_NAME -Namespace $Namespace
Write-Host "  pg_stat_statements is installed and verified in $DB_NAME" -ForegroundColor Green
Write-Host ""

# ── Step 8: Get public endpoint ──────────────────────────────────────────────
Write-Host "=== Step 8: Getting public endpoint ===" -ForegroundColor Green
$ingressIP = Wait-AksIngressAddress -ResourceGroup $RG -ClusterName $AKS_NAME -TimeoutSeconds $IngressTimeoutSeconds

Write-Host ""
Write-Host "  Storefront:   http://$ingressIP/" -ForegroundColor White
Write-Host "  API Health:   http://$ingressIP/api/health" -ForegroundColor White
Write-Host "  API Products: http://$ingressIP/api/products" -ForegroundColor White
Write-Host "  Diagnostics:  http://$ingressIP/api/diagnostics" -ForegroundColor White
Write-Host ""
Write-Host "  SRE Agent:" -ForegroundColor Yellow
Write-Host "  - Agent + identity + networking + mode + incident binding = core Bicep" -ForegroundColor DarkGray
Write-Host "  - Readiness + staged connectors + runtime configuration = setup-sre-agent.ps1 (next)" -ForegroundColor DarkGray
Write-Host "========================================" -ForegroundColor Cyan

# === Agent configuration + verification ===
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Configuring + verifying agent" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

if ($SRE_AGENT_NAME) {
    Write-Host "Running setup-sre-agent.ps1..." -ForegroundColor Yellow
    & "$PSScriptRoot\setup-sre-agent.ps1" `
        -ResourceGroup $RG `
        -AgentName $SRE_AGENT_NAME `
        -PostgresHost $DB_HOST `
        -PostgresDatabase $DB_NAME `
        -SreAgentClientId $SRE_AGENT_CLIENT_ID `
        -SreAgentPrincipalName $SRE_AGENT_PRINCIPAL_NAME
    if (-not $?) { throw 'SRE Agent configuration failed. Inspect the setup output before retrying post-provision.' }
} else {
    Write-Host "SRE_AGENT_NAME not set - skipping agent configuration." -ForegroundColor Yellow
    Write-Host "Run scripts\setup-sre-agent.ps1 manually after creating the agent." -ForegroundColor Yellow
}

if ($SRE_AGENT_NAME) {
    Write-Host "`nZava Demo Deployed Successfully!" -ForegroundColor Cyan
    Write-Host "Auth: Managed Identity (no passwords)" -ForegroundColor Cyan
}
