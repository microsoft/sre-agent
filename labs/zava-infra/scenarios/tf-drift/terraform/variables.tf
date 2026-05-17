# ---------------------------------------------------------------
# Input variables — you fill these in via terraform.tfvars
# ---------------------------------------------------------------

variable "subscription_id" {
  description = "Your Azure subscription ID (find it in Azure Portal > Subscriptions)"
  type        = string
}

variable "location" {
  description = "Azure region where resources are created (e.g., eastus2, westus2)"
  type        = string
  default     = "eastus2"
}

variable "prefix" {
  description = "Short prefix for naming all resources (e.g., 'iac-demo')"
  type        = string
  default     = "iacdemo"
}

variable "sre_agent_trigger_url" {
  description = "The HTTP Trigger URL from SRE Agent (you'll create this in Step 4 and come back to fill it in)"
  type        = string
  default     = "https://placeholder-update-after-step4.azuresre.ai"
}

variable "sre_agent_audience" {
  description = "Azure AD audience for the SRE Agent data plane. Leave this as-is."
  type        = string
  default     = "https://azuresre.dev"
}

variable "tags" {
  description = "Tags applied to all resources for organization"
  type        = map(string)
  default = {
    environment = "demo"
    managed_by  = "terraform"
    project     = "sre-agent-iac-blog"
  }
}
