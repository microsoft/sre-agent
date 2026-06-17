# ═══════════════════════════════════════════════════════════════
# Azure SRE Agent — Terraform variables
# ═══════════════════════════════════════════════════════════════

# ── Required ──

variable "agent_name" {
  description = "Agent name (lowercase, no spaces)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$", var.agent_name))
    error_message = "agent_name must be lowercase alphanumeric with hyphens, 2-63 chars."
  }
}

variable "resource_group_name" {
  description = "Resource group that holds the agent, identity, LAW, and App Insights."
  type        = string
}

variable "location" {
  description = "Azure region. Only regions supported by the SRE Agent RP."
  type        = string
  default     = "eastus2"

  validation {
    condition     = contains(["swedencentral", "uksouth", "eastus2", "australiaeast"], var.location)
    error_message = "location must be one of: swedencentral, uksouth, eastus2, australiaeast."
  }
}

variable "target_resource_groups" {
  description = "Resource group names the agent is granted access to."
  type        = list(string)
  default     = []
}

# ── Agent behaviour ──

variable "access_level" {
  description = "Low = read-only investigation. High = can take actions."
  type        = string
  default     = "Low"

  validation {
    condition     = contains(["High", "Low"], var.access_level)
    error_message = "access_level must be High or Low."
  }
}

variable "action_mode" {
  description = "Review = human approval. Automatic = agent acts independently."
  type        = string
  default     = "Review"

  validation {
    condition     = contains(["Review", "Automatic"], var.action_mode)
    error_message = "action_mode must be Review or Automatic."
  }
}

variable "upgrade_channel" {
  description = "Upgrade channel for the agent runtime."
  type        = string
  default     = "Preview"

  validation {
    condition     = contains(["Stable", "Preview"], var.upgrade_channel)
    error_message = "upgrade_channel must be Stable or Preview."
  }
}

variable "monthly_agent_unit_limit" {
  description = "Monthly agent unit consumption limit."
  type        = number
  default     = 10000
}

variable "default_model_provider" {
  description = "Default LLM provider (MicrosoftFoundry, Anthropic)."
  type        = string
  default     = "Anthropic"
}

variable "default_model_name" {
  description = "Default LLM model name."
  type        = string
  default     = "Automatic"
}

variable "tags" {
  description = "Azure resource tags applied to the agent and supporting resources."
  type        = map(string)
  default     = {}
}

# ── Identity ──

variable "existing_managed_identity_id" {
  description = "Resource ID of an existing UAMI. If provided, skips creating a new one."
  type        = string
  default     = ""
}

variable "existing_agent_app_insights_id" {
  description = "Resource ID of an existing Application Insights for agent telemetry. If provided, skips creating a new one."
  type        = string
  default     = ""
}

# ── RBAC ──

variable "skip_role_assignments" {
  description = "Skip all role assignments. Set to true when RBAC is pre-configured or on redeploy to avoid RoleAssignmentExists errors."
  type        = bool
  default     = false
}

# ── Network / VNet ──

variable "vnet_subnet_id" {
  description = "Full ARM resource ID of a delegated subnet (Microsoft.App/environments) for VNet integration. Leave empty for no VNet."
  type        = string
  default     = ""
}

variable "egress_mode" {
  description = "Sandbox egress mode: Unrestricted (default), Limited, or AzureVNet."
  type        = string
  default     = "Unrestricted"

  validation {
    condition     = contains(["Unrestricted", "Limited", "AzureVNet"], var.egress_mode)
    error_message = "egress_mode must be Unrestricted, Limited, or AzureVNet."
  }
}

variable "allowed_hosts" {
  description = "Additional hosts the sandbox may reach (e.g. *.contoso.com). Only used in Limited/AzureVNet modes."
  type        = list(string)
  default     = []
}

variable "allowed_registries" {
  description = "Registry catalog IDs (pypi, npmjs, nuget-org) whose hosts are allowed. Only used in Limited/AzureVNet modes."
  type        = list(string)
  default     = []
}

variable "allowed_code_repositories" {
  description = "Code-repo providers (Github, AzureDevOps) whose hosts are allowed. Only used in Limited/AzureVNet modes."
  type        = list(string)
  default     = []
}

variable "allow_http_mcp_server_network_access" {
  description = "Allow remote HTTP MCP server endpoints in sandbox egress."
  type        = bool
  default     = true
}

variable "use_private_dns_resolution" {
  description = "Use VNet private DNS resolver instead of platform default. Only for AzureVNet mode."
  type        = bool
  default     = false
}

# ── Connector toggles ──

variable "enable_app_insights_connector" {
  description = "Enable an Application Insights connector."
  type        = bool
  default     = false
}

variable "app_insights_resource_id" {
  description = "Full Azure resource ID of the App Insights component."
  type        = string
  default     = ""
}

variable "app_insights_app_id" {
  description = "App Insights Application ID (GUID from the Overview blade)."
  type        = string
  default     = ""
}

variable "enable_log_analytics_connector" {
  description = "Enable a Log Analytics connector."
  type        = bool
  default     = false
}

variable "law_resource_id" {
  description = "Full Azure resource ID of the LAW workspace."
  type        = string
  default     = ""
}

variable "enable_azure_monitor_connector" {
  description = "Enable an Azure Monitor connector (subscription-scoped alerts)."
  type        = bool
  default     = false
}

variable "azure_monitor_lookback_days" {
  description = "Lookback window in days for the Azure Monitor connector."
  type        = number
  default     = 7
}

# ── Extension arrays (advanced) ──

variable "skills" {
  description = "Skill definitions. Each entry: { name, spec = { ... } }."
  type = list(object({
    name = string
    spec = any
  }))
  default = []
}

variable "subagents" {
  description = "Subagent definitions. Each entry: { name, spec = { ... } }."
  type = list(object({
    name = string
    spec = any
  }))
  default = []
}

variable "connectors" {
  description = "Additional connector definitions (beyond toggle-generated ones). Each entry: { name, properties = { dataConnectorType, dataSource, extendedProperties, identity } }."
  type    = any
  default = []
}

variable "common_prompts" {
  description = "Common prompt definitions. Each entry: { name, properties = { prompt } }."
  type = list(object({
    name       = string
    properties = any
  }))
  default = []
}

variable "tools" {
  description = "Tool definitions. Each entry: { name, spec = { ... } }."
  type = list(object({
    name = string
    spec = any
  }))
  default = []
}

variable "enable_webhook_bridge" {
  description = "Deploy a Logic App webhook bridge for HTTP trigger ingestion."
  type        = bool
  default     = false
}

variable "webhook_bridge_trigger_url" {
  description = "Pre-existing webhook trigger URL (skip Logic App creation if set)."
  type        = string
  default     = ""
}
