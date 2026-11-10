[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string]$SubscriptionId,[string]$ResourceGroup="rg-sre-onprem-lab")
az account set --subscription $SubscriptionId
if ($PSCmdlet.ShouldProcess($ResourceGroup,"Delete the complete lab resource group")) {
  az group delete -n $ResourceGroup --yes --no-wait
  Write-Host "Deletion started. This does not remove the local Docker project or disconnect the Arc agent immediately."
}
