# ═══════════════════════════════════════════════════════════════
# Azure SRE Agent — Terraform outputs
# ═══════════════════════════════════════════════════════════════

output "agent_id" {
  description = "Full ARM resource ID of the SRE Agent."
  value       = azapi_resource.sre_agent.id
}

output "agent_portal_url" {
  description = "Direct link to the agent in the SRE Agent portal."
  value       = "https://sre.azure.com/#/agent/${data.azurerm_subscription.current.subscription_id}/${azurerm_resource_group.agent.name}/${var.agent_name}"
}

output "agent_data_plane_url" {
  description = "Agent data plane endpoint."
  value       = "https://${var.agent_name}.${var.location}.azuresre.ai"
}

output "managed_identity_id" {
  description = "Resource ID of the User-Assigned Managed Identity used by the agent."
  value       = local.effective_identity_id
}

output "law_id" {
  description = "Resource ID of the Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.law.id
}

output "resource_group_portal_url" {
  description = "Link to the agent resource group in the Azure portal."
  value       = "https://portal.azure.com/#@/resource/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${azurerm_resource_group.agent.name}/overview"
}
