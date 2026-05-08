#Requires -Version 7.4
# Fix Network: Remove the K8s NetworkPolicy and NSG deny rule that
# break-network.ps1 installs. Names match the realistic-sounding ones the
# break script uses (database-tier-isolation / restrict-egress-database-tier),
# not the old "block-postgres" giveaway.
# Uses `az aks command invoke` against the PRIVATE AKS cluster — no kubectl required.
param(
    [string]$ResourceGroup = "",
    [string]$ClusterName = "",
    [string]$Namespace = "zava-demo"
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\..\..\..\scripts\_aks-helpers.ps1"
$ctx = Resolve-AksContext -ResourceGroup $ResourceGroup -ClusterName $ClusterName

# Remove K8s NetworkPolicy (the actual traffic block)
Write-Host "Removing Kubernetes NetworkPolicy via az aks command invoke..." -ForegroundColor Green
Invoke-AksCommand -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName `
    -Command "kubectl delete networkpolicy database-tier-isolation -n $Namespace --ignore-not-found" -Quiet | Out-Null

# Remove the NSG red herring (it never actually blocked anything — delegated
# subnets bypass NSGs — but leaving it would be configuration drift).
$nsgName = az network nsg list -g $ctx.ResourceGroup --query "[0].name" -o tsv
if ($nsgName) {
    Write-Host "Removing NSG deny rule: $nsgName → restrict-egress-database-tier..." -ForegroundColor Green
    az network nsg rule delete --nsg-name $nsgName -g $ctx.ResourceGroup --name restrict-egress-database-tier 2>$null
}

Write-Host "Network restored. AKS can reach PostgreSQL on port 5432." -ForegroundColor Green
