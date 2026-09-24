output "resource_group_name" {
  description = "Name of the lab resource group."
  value       = azurerm_resource_group.lab.name
}

output "resource_group_id" {
  description = "Resource ID of the lab resource group."
  value       = azurerm_resource_group.lab.id
}

output "agent_subnet_id" {
  description = "Resource ID of the delegated subnet to attach to the SRE Agent."
  value       = azurerm_subnet.agent.id
}

output "lab_vnet_id" {
  description = "Resource ID of the shared same-region VNet."
  value       = azurerm_virtual_network.lab.id
}

output "splunk_vm_id" {
  description = "Resource ID of the private Splunk VM."
  value       = azurerm_linux_virtual_machine.splunk.id
}

output "splunk_vm_name" {
  description = "Name of the private Splunk VM."
  value       = azurerm_linux_virtual_machine.splunk.name
}

output "splunk_private_ip" {
  description = "Static private IP address of the Splunk VM."
  value       = azurerm_network_interface.splunk.private_ip_address
}

output "splunk_hostname" {
  description = "Private DNS hostname resolvable from the shared lab VNet."
  value       = local.splunk_private_fqdn
}

output "splunk_endpoint_candidates" {
  description = "Private endpoint candidates for lab connectivity tests and the Splunk MCP connector."
  value = {
    private_test_http = "http://${local.splunk_private_fqdn}:8080"
    mcp_https         = "https://${local.splunk_private_fqdn}:8089/services/mcp"
    mcp_http_lab_only = "http://${local.splunk_private_fqdn}:8089/services/mcp"
  }
}
