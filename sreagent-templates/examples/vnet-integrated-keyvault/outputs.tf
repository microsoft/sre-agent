output "resource_group" {
  value = local.rg_name
}

output "vnet_id" {
  value = azurerm_virtual_network.vnet.id
}

output "agent_subnet_id" {
  description = "Delegated subnet the agent is injected into."
  value       = azurerm_subnet.agent.id
}

output "pe_subnet_id" {
  value = azurerm_subnet.pe.id
}

output "key_vault_id" {
  value = azurerm_key_vault.kv.id
}

output "key_vault_uri" {
  value = azurerm_key_vault.kv.vault_uri
}

output "private_endpoint_ip" {
  description = "Private endpoint IP the vault FQDN should resolve to inside the VNet."
  value       = azurerm_private_endpoint.kv.private_service_connection[0].private_ip_address
}

output "private_dns_zone_id" {
  value = azurerm_private_dns_zone.kv.id
}

output "agent_id" {
  value = azapi_resource.sre_agent.id
}

output "agent_identity_principal_id" {
  value = azurerm_user_assigned_identity.agent.principal_id
}
