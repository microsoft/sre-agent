# ---------------------------------------------------------------
# Outputs — values you'll need in later steps
# After running `terraform apply`, Terraform prints these values.
# ---------------------------------------------------------------

output "resource_group_name" {
  description = "The name of the resource group"
  value       = azurerm_resource_group.demo.name
}

output "app_service_url" {
  description = "URL of the demo web app — open this in a browser to verify it's running"
  value       = "https://${azurerm_linux_web_app.demo.default_hostname}"
}

output "app_service_name" {
  description = "Name of the App Service (used in drift scripts)"
  value       = azurerm_linux_web_app.demo.name
}

output "plan_name" {
  description = "Name of the App Service Plan (used in drift scripts)"
  value       = azurerm_service_plan.demo.name
}

output "logic_app_callback_url" {
  description = "The webhook URL for the Logic App — this is where TFC (or the simulation script) sends notifications"
  value       = azurerm_logic_app_trigger_http_request.tfc_webhook.callback_url
  sensitive   = true
}

output "logic_app_identity_principal_id" {
  description = "The Managed Identity of the Logic App — you need to give this the 'SRE Agent Admin' role"
  value       = azurerm_logic_app_workflow.tfc_bridge.identity[0].principal_id
}
