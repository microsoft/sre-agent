#Requires -Version 7.4
# Break Network: Block AKS pods → PostgreSQL using Kubernetes NetworkPolicy
#
# Why a K8s NetworkPolicy, not an NSG rule?
# Azure Database for PostgreSQL Flexible Server with private access lives in a
# *delegated* subnet. Per the docs, services injected into a delegated subnet
# manage their own subnet routing/policy and don't honor user-defined NSG rules
# the way a regular subnet would; the platform also auto-adds a default-deny
# inbound rule on the delegated subnet's NSG. So an NSG-level deny on the AKS
# side won't reliably partition pod-to-PG traffic.
#   - https://learn.microsoft.com/azure/virtual-network/subnet-delegation-overview
#   - https://learn.microsoft.com/azure/postgresql/network/concepts-networking-private
# The reliable place to block this traffic is at the pod egress: a K8s
# NetworkPolicy in the zava-demo namespace.
#
# The script also adds an NSG deny rule as a deliberate *red herring*. The KB
# entry on delegated-subnet networking gives the SRE Agent enough to discount
# the NSG and look for an in-cluster cause instead of stopping at the first
# config that looks suspicious.
#
# Resource names are chosen to look like a security architect's work
# (database-tier-isolation, restrict-egress-database-tier) rather than the
# obvious "block-postgres" of the old version, so the agent can't pattern-
# match its way to the answer — it has to reason about what's actually
# blocking traffic.
#
# AKS is a PRIVATE cluster — we never use kubectl from the operator's workstation. Every
# K8s op runs through `az aks command invoke` (Azure-proxied control plane),
# the exact same path the SRE Agent uses for remediation.
#
# CIDR discovery: instead of hardcoding 10.0.0.0/16 / 10.1.0.0/24 we ask Azure
# what's actually deployed. Falls back to the vnet.bicep defaults only if the
# discovery fails (e.g., a customer renamed the subnets).
param(
    [string]$ResourceGroup = "",
    [string]$ClusterName = "",
    [string]$Namespace = "zava-demo",
    [string]$AksSubnetName = "aks-subnet",
    [string]$DbSubnetName = "db-subnet"
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\..\..\..\scripts\_aks-helpers.ps1"
$ctx = Resolve-AksContext -ResourceGroup $ResourceGroup -ClusterName $ClusterName

# Discover the VNet and the two subnet CIDRs from the actual deployed resources.
function Get-SubnetCidr {
    param([string]$Rg, [string]$VnetName, [string]$SubnetName, [string]$Fallback)
    $cidr = az network vnet subnet show -g $Rg --vnet-name $VnetName -n $SubnetName --query addressPrefix -o tsv 2>$null
    if (-not $cidr) {
        Write-Host "  Could not read $SubnetName from $VnetName, falling back to $Fallback" -ForegroundColor DarkYellow
        return $Fallback
    }
    return $cidr
}

$vnetName = az network vnet list -g $ctx.ResourceGroup --query "[0].name" -o tsv
if (-not $vnetName) {
    Write-Host "No VNet found in $($ctx.ResourceGroup); using vnet.bicep defaults." -ForegroundColor DarkYellow
    $aksCidr = "10.0.0.0/16"
    $dbCidr  = "10.1.0.0/24"
} else {
    $aksCidr = Get-SubnetCidr -Rg $ctx.ResourceGroup -VnetName $vnetName -SubnetName $AksSubnetName -Fallback "10.0.0.0/16"
    $dbCidr  = Get-SubnetCidr -Rg $ctx.ResourceGroup -VnetName $vnetName -SubnetName $DbSubnetName  -Fallback "10.1.0.0/24"
    Write-Host "Discovered CIDRs from VNet '$vnetName': AKS=$aksCidr, PG=$dbCidr" -ForegroundColor DarkGray
}

# Step 1: Add NSG deny rule as a red herring. With PG flex private access on
# a delegated subnet, this NSG rule isn't the active enforcement point — the
# K8s NetworkPolicy below is. The agent needs to reason past the NSG and find
# the real cause.
$nsgName = az network nsg list -g $ctx.ResourceGroup --query "[0].name" -o tsv
if ($nsgName) {
    Write-Host "Adding NSG deny rule (red herring; the NetworkPolicy below is the actual block)..." -ForegroundColor Yellow
    az network nsg rule create `
        --nsg-name $nsgName -g $ctx.ResourceGroup `
        --name restrict-egress-database-tier `
        --priority 100 --direction Outbound --access Deny `
        --source-address-prefixes $aksCidr `
        --destination-port-ranges 5432 --protocol Tcp `
        -o none 2>$null
}

# Step 2: Stage the NetworkPolicy YAML and apply it via az aks command invoke.
# Name picked to read like a security-architect zero-trust attempt that
# accidentally over-blocks; not a giveaway "block-postgres".
$networkPolicy = @"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: database-tier-isolation
  namespace: $Namespace
spec:
  podSelector:
    matchLabels:
      app: zava-api
  policyTypes:
    - Egress
  egress:
    # Allow all egress EXCEPT to the PostgreSQL delegated subnet
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - $dbCidr
"@

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "database-tier-isolation-$([guid]::NewGuid().ToString('N').Substring(0,8)).yaml"
$networkPolicy | Set-Content $tmp -Encoding UTF8

Write-Host "Applying Kubernetes NetworkPolicy via az aks command invoke..." -ForegroundColor Red
Invoke-AksCommand -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName `
    -Command "kubectl apply -n $Namespace -f $(Split-Path $tmp -Leaf)" -Files @($tmp) | Out-Null
Remove-Item $tmp -Force

# Step 3: Restart the API deployment so existing DB connection pools drop.
# A real NetworkPolicy doesn't reach into pods and reset sockets — `rollout
# restart` is the realistic operator action that surfaces the partition fast.
Write-Host "Rolling api deployment so new pods experience the partition..." -ForegroundColor Yellow
Invoke-AksCommand -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName `
    -Command "kubectl rollout restart deployment/zava-api -n $Namespace" -Quiet | Out-Null

Write-Host "Waiting 20s for new pods to start with blocked connections..." -ForegroundColor Yellow
Start-Sleep -Seconds 20

Write-Host "Network partition active. App will see ETIMEDOUT (not ECONNREFUSED)." -ForegroundColor Yellow
Write-Host "This is harder to diagnose — server appears 'Running' but unreachable." -ForegroundColor Yellow
Write-Host "Fix with: .\.github\skills\running-demo\scripts\fix-network.ps1" -ForegroundColor Cyan
