<#
.SYNOPSIS
  Restores the nsg-lane connectivity path and healthy IaC parameter.
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo"
)
. "$PSScriptRoot\_common.ps1"

Write-Host "[fix-nsg] Restoring the nsg-lane connectivity baseline..." -ForegroundColor Yellow

Write-Host "  1/2 Committing healthy release (injectLegacyDenyNsgLane=false) to GitHub..." -ForegroundColor Gray
$changed = Set-ParamLine -Pattern '"injectLegacyDenyNsgLane"\s*:\s*\{\s*"value"\s*:\s*true\s*\}' `
                         -Replacement '"injectLegacyDenyNsgLane": { "value": false }'
if ($changed) { Invoke-GitPush -Message "Restore nsg lane connectivity baseline" }
else { Write-Host "  (injectLegacyDenyNsgLane already false in source)" -ForegroundColor DarkGray }

Write-Host "  2/2 Removing legacy-cross-subnet-deny from the live nsg-lane NSG..." -ForegroundColor Gray
$token = Get-ResourceToken -ResourceGroup $ResourceGroup
$nsgName = "nsg-nsglane-$token"
az network nsg rule delete --resource-group $ResourceGroup --nsg-name $nsgName --name "legacy-cross-subnet-deny" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "  (legacy-cross-subnet-deny was already absent)" -ForegroundColor DarkGray }

Write-Host "[fix-nsg] Connectivity restored. Port 8081 quiz launches should recover." -ForegroundColor Green
