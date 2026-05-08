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
    6. Wait for pods and print endpoints
.NOTES
    Requires: az CLI, azd. (kubectl is NOT required — all in-cluster ops run through `az aks command invoke`.)
    Run from the project root directory.
#>
param(
    [switch]$SkipImageBuild,
    [switch]$SkipIngressInstall,
    [string]$Namespace = "zava-demo"
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

function Get-AzdValue([string]$key) {
    # azd injects Bicep outputs as env vars in hook subprocesses
    $val = [Environment]::GetEnvironmentVariable($key)
    if (-not $val) {
        $val = azd env get-value $key 2>$null
    }
    if (-not $val) { throw "Missing azd env value: $key — run 'azd provision' first." }
    return $val.Trim()
}

$RG              = Get-AzdValue "RESOURCE_GROUP"
$AKS_NAME        = Get-AzdValue "AKS_CLUSTER_NAME"
$ACR_NAME        = Get-AzdValue "ACR_NAME"
$ACR_LOGIN       = Get-AzdValue "ACR_LOGIN_SERVER"
$DB_HOST         = Get-AzdValue "DB_HOST"
$PG_SERVER       = Get-AzdValue "PG_SERVER_NAME"
$AI_CONN         = Get-AzdValue "APPINSIGHTS_CONNECTION_STRING"
$APP_ID_NAME     = Get-AzdValue "APP_IDENTITY_NAME"
$APP_CLIENT_ID   = Get-AzdValue "APP_IDENTITY_CLIENT_ID"
$APP_PRINCIPAL_ID = Get-AzdValue "APP_IDENTITY_PRINCIPAL_ID"
$OIDC_ISSUER     = Get-AzdValue "AKS_OIDC_ISSUER"
$AZURE_LOCATION  = Get-AzdValue "AZURE_LOCATION"

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
    az acr build --registry $ACR_NAME --image zava-api:latest ./src/api --no-logs 2>$null
    if ($LASTEXITCODE -ne 0) {
        az acr build --registry $ACR_NAME --image zava-api:latest ./src/api
    }

    Write-Host "Building Storefront image..."
    az acr build --registry $ACR_NAME --image zava-storefront:latest ./src/storefront --no-logs 2>$null
    if ($LASTEXITCODE -ne 0) {
        az acr build --registry $ACR_NAME --image zava-storefront:latest ./src/storefront
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
    $currentUserName = az ad signed-in-user show --query userPrincipalName -o tsv
    Write-Host "  Setting Entra admin: $currentUserName ($currentUserOid)"

    az postgres flexible-server microsoft-entra-admin create `
        -g $RG -s $PG_SERVER `
        --object-id $currentUserOid `
        --display-name $currentUserName `
        --type User 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  (Entra admin may already be configured)" -ForegroundColor DarkGray
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
    --audiences "api://AzureADTokenExchange" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  (Federated credential may already exist)" -ForegroundColor DarkGray
}

# Attach ACR to AKS (ensures kubelet can pull images)
Write-Host "  Attaching ACR to AKS..."
az aks update -g $RG -n $AKS_NAME --attach-acr $ACR_NAME 2>$null
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
if ($isInteractiveUser) {
    $currentUserOid = az ad signed-in-user show --query id -o tsv
    az role assignment create --assignee $currentUserOid `
        --role "Azure Kubernetes Service RBAC Cluster Admin" `
        --scope $aksScope 2>$null
} else {
    Write-Host "  Skipping signed-in-user AKS RBAC step (running as $($accountInfo.type))" -ForegroundColor Yellow
}

# Wait for command-invoke availability + RBAC propagation
Write-Host "  Waiting for control-plane proxy to be ready..."
$proxyReady = $false
for ($i = 1; $i -le 12; $i++) {
    $ping = Invoke-AksCommand -ResourceGroup $RG -ClusterName $AKS_NAME `
        -Command "kubectl version --short=true 2>/dev/null || kubectl version" -Quiet
    if ($ping -and $ping.exitCode -eq 0) { Write-Host "  Control-plane proxy live" -ForegroundColor Green; $proxyReady = $true; break }
    Write-Host "  Attempt $i/12: waiting 10s..." -ForegroundColor DarkGray
    Start-Sleep 10
}
if (-not $proxyReady) {
    Write-Host "ERROR: az aks command invoke did not become ready after 2 minutes." -ForegroundColor Red
    Write-Host "  Possible causes: RBAC propagation delay, Azure Policy blocking aks-command pod, cluster not fully provisioned." -ForegroundColor Red
    Write-Host "  Try: az aks command invoke -g $RG -n $AKS_NAME --command 'kubectl version'" -ForegroundColor Yellow
    exit 1
}
Write-Host ""

# ── Step 5: Install NGINX Ingress Controller (via command invoke) ────────────
if (-not $SkipIngressInstall) {
    Write-Host "=== Step 5: Installing NGINX Ingress (via az aks command invoke) ===" -ForegroundColor Green
    $ingressUrl = "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/cloud/deploy.yaml"
    $r = Invoke-AksCommand -ResourceGroup $RG -ClusterName $AKS_NAME `
        -Command "kubectl apply -f $ingressUrl"
    if ($r.exitCode -ne 0) { Write-Host "  Ingress apply returned $($r.exitCode); continuing..." -ForegroundColor Yellow }
    Write-Host "  Waiting for ingress controller pods..."
    $r = Invoke-AksCommand -ResourceGroup $RG -ClusterName $AKS_NAME `
        -Command "kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=180s"
    if ($r.exitCode -ne 0) {
        Write-Host "  Ingress controller still starting — will continue..." -ForegroundColor Yellow
    }
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
        Write-Host "  MISSING: $f" -ForegroundColor Red
        continue
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
if ($r.exitCode -ne 0) {
    Write-Host "  Manifest apply returned $($r.exitCode) — see logs above." -ForegroundColor Yellow
}
Remove-Item -Recurse -Force $stageDir
Write-Host ""

# ── Step 7: Wait for deployments to be ready ─────────────────────────────────
Write-Host "=== Step 7: Waiting for pods ===" -ForegroundColor Green
Invoke-AksCommand -ResourceGroup $RG -ClusterName $AKS_NAME `
    -Command "kubectl rollout status deployment/zava-api -n $Namespace --timeout=180s; kubectl rollout status deployment/zava-storefront -n $Namespace --timeout=180s" | Out-Null
Write-Host ""

# ── Step 8: Get public endpoint ──────────────────────────────────────────────
Write-Host "=== Step 8: Getting public endpoint ===" -ForegroundColor Green
Start-Sleep -Seconds 10
$ipResult = Invoke-AksCommand -ResourceGroup $RG -ClusterName $AKS_NAME `
    -Command "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" -Quiet
$ingressIP = if ($ipResult -and $ipResult.exitCode -eq 0) { ($ipResult.logs -replace "[^\d\.]","").Trim() } else { "" }
if (-not $ingressIP) {
    $ingressIP = "pending (re-run: az aks command invoke -g $RG -n $AKS_NAME --command 'kubectl get svc -n ingress-nginx ingress-nginx-controller')"
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Zava Demo Deployed Successfully!" -ForegroundColor Cyan
Write-Host "  Auth: Managed Identity (no passwords)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Storefront:   http://$ingressIP/" -ForegroundColor White
Write-Host "  API Health:   http://$ingressIP/api/health" -ForegroundColor White
Write-Host "  API Products: http://$ingressIP/api/products" -ForegroundColor White
Write-Host "  Diagnostics:  http://$ingressIP/api/diagnostics" -ForegroundColor White
Write-Host ""
Write-Host "  SRE Agent (already provisioned by Bicep above):" -ForegroundColor Yellow
Write-Host "  - Agent + connectors + custom skills + response plans = Bicep" -ForegroundColor DarkGray
Write-Host "  - Knowledge file upload + verification = setup-sre-agent.ps1 (next)" -ForegroundColor DarkGray
Write-Host "========================================" -ForegroundColor Cyan

# === Knowledge file sync + verification ===
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Syncing knowledge + verifying agent" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$agentName = try { Get-AzdValue "SRE_AGENT_NAME" } catch { "" }
if ($agentName) {
    Write-Host "Running setup-sre-agent.ps1..." -ForegroundColor Yellow
    & "$PSScriptRoot\setup-sre-agent.ps1" -ResourceGroup $RG -AgentName $agentName
} else {
    Write-Host "SRE_AGENT_NAME not set - skipping agent configuration." -ForegroundColor Yellow
    Write-Host "Run scripts\setup-sre-agent.ps1 manually after creating the agent." -ForegroundColor Yellow
}
