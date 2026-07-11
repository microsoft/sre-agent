variable "subscription_id" {
  description = "Target Azure subscription ID."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy into. Created when create_resource_group = true."
  type        = string
  default     = "sre-agent-vnet-kv"
}

variable "create_resource_group" {
  description = "Create the resource group (true) or use an existing one (false)."
  type        = bool
  default     = true
}

variable "location" {
  description = "Azure region. The agent subnet must be in the same region as the agent (VNet injection is regional)."
  type        = string
  default     = "uksouth"
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "sreagent"
}

variable "key_vault_name" {
  description = "Globally-unique Key Vault name (3-24 chars, alphanumeric and hyphens)."
  type        = string
}

variable "tenant_id" {
  description = "AAD tenant ID for the Key Vault. Leave empty to use the current CLI context."
  type        = string
  default     = ""
}

# --- Address space ---

variable "vnet_address_space" {
  description = "VNet CIDR."
  type        = string
  default     = "10.30.0.0/24"
}

variable "agent_subnet_prefix" {
  description = "Delegated subnet the SRE Agent is injected into (Microsoft.App/environments)."
  type        = string
  default     = "10.30.0.0/27"
}

variable "pe_subnet_prefix" {
  description = "Subnet that holds the Key Vault private endpoint."
  type        = string
  default     = "10.30.0.32/27"
}
