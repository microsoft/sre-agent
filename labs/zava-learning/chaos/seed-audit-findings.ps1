<#
.SYNOPSIS
  Seed STANDING network-governance "loopholes" for the weekly NSG audit to find.
  Unlike the break-* scenarios (a single transient incident), these are permanent,
  benign misconfigurations: over-permissive rules on the reporting-VM NSG (which has
  no public route) plus an ORPHANED, unattached NSG carrying duplicate/shadowed/stale
  rules. They give the weekly NSG audit real SEV1/SEV2/SEV3 findings to report.

  Mirrors the chaos pattern: flip the IaC param (seedAuditFindings=true) + git push,
  then apply the same rules LIVE via targeted az calls (no full redeploy). Idempotent.
.NOTES
  Reverse with chaos/reset-audit-findings.ps1.
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo"
)
. "$PSScriptRoot\_common.ps1"

function Set-NsgRule {
  param(
    [Parameter(Mandatory)][string]$Nsg,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][int]$Priority,
    [Parameter(Mandatory)][string]$Access,
    [Parameter(Mandatory)][string]$Protocol,
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$DestPort,
    [string]$Description = ""
  )
  $exists = az network nsg rule show -g $ResourceGroup --nsg-name $Nsg -n $Name -o tsv --query name 2>$null
  $verb = if ($exists) { "update" } else { "create" }
  az network nsg rule $verb `
    --resource-group $ResourceGroup `
    --nsg-name $Nsg `
    --name $Name `
    --priority $Priority `
    --direction Inbound `
    --access $Access `
    --protocol $Protocol `
    --source-address-prefixes $Source `
    --source-port-ranges "*" `
    --destination-address-prefixes "*" `
    --destination-port-ranges $DestPort `
    --description $Description -o none
  Write-Host "    [$verb] $Nsg / $Name" -ForegroundColor DarkGray
}

Write-Host "[seed-audit-findings] Seeding standing NSG audit loopholes from IaC..." -ForegroundColor Yellow

Write-Host "  1/3 Committing IaC desired-state (seedAuditFindings=true) to GitHub..." -ForegroundColor Gray
$changed = Set-ParamLine -Pattern '"seedAuditFindings"\s*:\s*\{\s*"value"\s*:\s*false\s*\}' `
                         -Replacement '"seedAuditFindings": { "value": true }'
if ($changed) { Invoke-GitPush -Message "Seed standing NSG audit findings (VM NSG + orphaned NSG)" }
else { Write-Host "  (seedAuditFindings already true in source)" -ForegroundColor DarkGray }

$token = Get-ResourceToken -ResourceGroup $ResourceGroup
$vmNsg = "nsg-vm-$token"
$orphanNsg = "nsg-legacy-unused-$token"

Write-Host "  2/3 Applying over-permissive rules to the live reporting-VM NSG ($vmNsg)..." -ForegroundColor Gray
Set-NsgRule -Nsg $vmNsg -Name "temp-ssh-from-internet" -Priority 200 -Access Allow -Protocol Tcp `
  -Source "Internet" -DestPort "22" -Description "TEMP break-glass INC-4471 2025-08-14 - REMOVE after troubleshooting"
Set-NsgRule -Nsg $vmNsg -Name "allow-rdp-any" -Priority 210 -Access Allow -Protocol Tcp `
  -Source "*" -DestPort "3389" -Description "Remote desktop access."
Set-NsgRule -Nsg $vmNsg -Name "allow-postgres-broad" -Priority 220 -Access Allow -Protocol Tcp `
  -Source "10.0.0.0/8" -DestPort "5432" -Description "Database access for reporting."
Set-NsgRule -Nsg $vmNsg -Name "allow-any-any-legacy" -Priority 4000 -Access Allow -Protocol "*" `
  -Source "*" -DestPort "*" -Description "Legacy catch-all - migrated from on-prem firewall."

Write-Host "  3/3 Creating the orphaned, unattached NSG ($orphanNsg) with stale rules..." -ForegroundColor Gray
$loc = Get-RgLocation -ResourceGroup $ResourceGroup
$orphanExists = az network nsg show -g $ResourceGroup -n $orphanNsg -o tsv --query name 2>$null
if (-not $orphanExists) {
  az network nsg create -g $ResourceGroup -n $orphanNsg --location $loc -o none
}
Set-NsgRule -Nsg $orphanNsg -Name "allow-http-dup" -Priority 100 -Access Allow -Protocol Tcp `
  -Source "Internet" -DestPort "80" -Description "Duplicate web rule (overlaps allow-http-dup2)."
Set-NsgRule -Nsg $orphanNsg -Name "allow-http-dup2" -Priority 110 -Access Allow -Protocol Tcp `
  -Source "Internet" -DestPort "80" -Description "Overlapping duplicate of allow-http-dup."
Set-NsgRule -Nsg $orphanNsg -Name "deny-all-legacy" -Priority 200 -Access Deny -Protocol "*" `
  -Source "10.250.0.0/16" -DestPort "*" -Description "Legacy deny for a decommissioned subnet (never matches)."
Set-NsgRule -Nsg $orphanNsg -Name "shadowed-allow-8080" -Priority 300 -Access Allow -Protocol Tcp `
  -Source "*" -DestPort "8080" -Description "Shadowed by deny-all-legacy at priority 200."

Write-Host "[seed-audit-findings] Done. Standing loopholes are live + in source." -ForegroundColor Green
Write-Host "  These are benign (no public route reaches the VM subnet; the orphaned NSG is unattached)" -ForegroundColor DarkGray
Write-Host "  but give the weekly NSG audit real SEV1/SEV2/SEV3 findings. Reverse with reset-audit-findings.ps1." -ForegroundColor DarkGray
