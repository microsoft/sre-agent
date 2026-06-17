# ═══════════════════════════════════════════════════════════════
# Azure SRE Agent — Terraform module
#
# Uses azapi for the SRE Agent (Microsoft.App/agents) which is
# not yet in the azurerm provider, and azurerm for standard
# resources (RG, UAMI, LAW, App Insights, RBAC).
# ═══════════════════════════════════════════════════════════════

provider "azapi" {}
provider "azurerm" {
  features {}
}

# ── Data sources ──

data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}

locals {
  suffix                = substr(sha256("${data.azurerm_subscription.current.subscription_id}-${var.resource_group_name}-${var.agent_name}"), 0, 13)
  create_identity       = var.existing_managed_identity_id == ""
  effective_identity_id = local.create_identity ? azurerm_user_assigned_identity.agent[0].id : var.existing_managed_identity_id
  effective_principal_id = local.create_identity ? azurerm_user_assigned_identity.agent[0].principal_id : data.azurerm_user_assigned_identity.existing[0].principal_id

  create_app_insights        = var.existing_agent_app_insights_id == ""
  effective_ai_app_id        = local.create_app_insights ? azurerm_application_insights.ai[0].app_id : data.azurerm_application_insights.existing_ai[0].app_id
  effective_ai_conn_str      = local.create_app_insights ? azurerm_application_insights.ai[0].connection_string : data.azurerm_application_insights.existing_ai[0].connection_string

  # Well-known role definition IDs
  reader_role_id             = "acdd72a7-3385-48ef-bd42-f606fba81ae7"
  log_analytics_reader_id    = "73c42c96-874c-492b-b04d-ab87d138a893"
  monitoring_reader_id       = "43d0d8ad-25c7-4714-9337-8ba259a9fe05"
  contributor_role_id        = "b24988ac-6180-42a0-ab88-20f7382dd24c"
  sre_agent_admin_role_id    = "e79298df-d852-4c6d-84f9-5d13249d1e55"

  # Merge toggle-generated connectors with caller-supplied array
  toggle_connectors = concat(
    var.enable_app_insights_connector ? [{
      name = "app-insights"
      properties = {
        dataConnectorType  = "AppInsights"
        dataSource         = var.app_insights_resource_id
        extendedProperties = {
          armResourceId = var.app_insights_resource_id
          resource      = { name = var.app_insights_resource_id != "" ? element(split("/", var.app_insights_resource_id), length(split("/", var.app_insights_resource_id)) - 1) : "" }
          appId         = var.app_insights_app_id
        }
        identity = "system"
      }
    }] : [],
    var.enable_log_analytics_connector ? [{
      name = "log-analytics"
      properties = {
        dataConnectorType  = "LogAnalytics"
        dataSource         = var.law_resource_id
        extendedProperties = {
          armResourceId = var.law_resource_id
          resource      = { name = var.law_resource_id != "" ? element(split("/", var.law_resource_id), length(split("/", var.law_resource_id)) - 1) : "" }
        }
        identity = "system"
      }
    }] : [],
    var.enable_azure_monitor_connector ? [{
      name = "azure-monitor"
      properties = {
        dataConnectorType  = "AzureMonitor"
        dataSource         = data.azurerm_subscription.current.id
        extendedProperties = {
          armResourceId = data.azurerm_subscription.current.id
          lookbackDays  = var.azure_monitor_lookback_days
        }
        identity = "system"
      }
    }] : [],
  )

  all_connectors = concat(local.toggle_connectors, var.connectors)
}

# ═══════════════════════════ RESOURCE GROUP ═══════════════════

resource "azurerm_resource_group" "agent" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ═══════════════════════════ IDENTITY ═════════════════════════

resource "azurerm_user_assigned_identity" "agent" {
  count               = local.create_identity ? 1 : 0
  name                = "${var.agent_name}-id-${local.suffix}"
  resource_group_name = azurerm_resource_group.agent.name
  location            = var.location
  tags                = var.tags
}

data "azurerm_user_assigned_identity" "existing" {
  count               = local.create_identity ? 0 : 1
  name                = element(split("/", var.existing_managed_identity_id), length(split("/", var.existing_managed_identity_id)) - 1)
  resource_group_name = element(split("/", var.existing_managed_identity_id), 4)
}

# ═══════════════════════════ OBSERVABILITY ════════════════════

resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-${local.suffix}"
  resource_group_name = azurerm_resource_group.agent.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "ai" {
  count               = local.create_app_insights ? 1 : 0
  name                = "ai-${local.suffix}"
  resource_group_name = azurerm_resource_group.agent.name
  location            = var.location
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.law.id
  tags                = var.tags
}

data "azurerm_application_insights" "existing_ai" {
  count               = local.create_app_insights ? 0 : 1
  name                = element(split("/", var.existing_agent_app_insights_id), length(split("/", var.existing_agent_app_insights_id)) - 1)
  resource_group_name = element(split("/", var.existing_agent_app_insights_id), 4)
}

# ═══════════════════════════ SRE AGENT ════════════════════════

resource "azapi_resource" "sre_agent" {
  schema_validation_enabled = false
  type                      = "Microsoft.App/agents@2025-05-01-preview"
  name                      = var.agent_name
  location                  = var.location
  parent_id                 = azurerm_resource_group.agent.id
  tags                      = var.tags

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [local.effective_identity_id]
  }

  body = {
    properties = {
      knowledgeGraphConfiguration = {
        identity         = local.effective_identity_id
        managedResources = [for rg in var.target_resource_groups : "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${rg}"]
      }
      actionConfiguration = {
        accessLevel = var.access_level
        identity    = local.effective_identity_id
        mode        = var.action_mode
      }
      logConfiguration = {
        applicationInsightsConfiguration = {
          appId            = local.effective_ai_app_id
          connectionString = local.effective_ai_conn_str
        }
      }
      upgradeChannel         = var.upgrade_channel
      monthlyAgentUnitLimit  = var.monthly_agent_unit_limit
      defaultModel = {
        provider = var.default_model_provider
        name     = var.default_model_name
      }
      experimentalSettings = {
        EnableWorkspaceTools = true
        EnableHttpTriggers   = true
        EnableV2AgentLoop    = true
      }
      vnetConfiguration = var.vnet_subnet_id != "" ? {
        subnetResourceId = var.vnet_subnet_id
      } : null
      sandboxConfiguration = var.egress_mode != "Unrestricted" ? {
        egress = {
          mode                           = var.egress_mode
          allowedHosts                   = var.allowed_hosts
          allowedRegistries              = var.allowed_registries
          allowedCodeRepositories        = var.allowed_code_repositories
          allowHttpMcpServerNetworkAccess = var.allow_http_mcp_server_network_access
          vnetConfiguration = var.egress_mode == "AzureVNet" ? {
            usePrivateDnsResolution = var.use_private_dns_resolution
          } : null
        }
      } : null
    }
  }

  depends_on = [
    azurerm_role_assignment.target_reader,
    azurerm_role_assignment.target_log_reader,
    azurerm_role_assignment.target_contributor,
    azurerm_role_assignment.monitoring_reader,
  ]
}

# ═══════════════════════ CHILD RESOURCES ═════════════════════

# ── Connectors (typed properties — not base64) ──
# Connectors remain on ARM — they work for all tenants (1P and 3P).

resource "azapi_resource" "connector" {
  for_each                  = { for c in local.all_connectors : c.name => c }
  schema_validation_enabled = false
  type                      = "Microsoft.App/agents/connectors@2025-05-01-preview"
  name      = each.key
  parent_id = azapi_resource.sre_agent.id

  body = {
    properties = each.value.properties
  }

  # Connector ARM PUTs trigger a K8s extension install that can take 10-30+ min.
  # Cap the wait so `terraform apply` doesn't hang indefinitely.
  # A timeout error is safe — the connector will finish provisioning in the background;
  # re-running `terraform apply` will reconcile the state.
  timeouts {
    create = "10m"
    update = "10m"
    delete = "10m"
  }
}

# Skills, subagents, tools, and common prompts are now deployed via data-plane
# (apply-extras.sh) instead of ARM to avoid tenant restrictions that block 3P tenants.

# ═══════════════════════════ RBAC ═════════════════════════════

# ── Monitoring Reader on agent RG ──

resource "azurerm_role_assignment" "monitoring_reader" {
  count                = var.skip_role_assignments || !local.create_identity ? 0 : 1
  scope                = azurerm_resource_group.agent.id
  role_definition_name = "Monitoring Reader"
  principal_id         = local.effective_principal_id
  principal_type       = "ServicePrincipal"
}

# ── SRE Agent Administrator — deployer on the agent ──

resource "azurerm_role_assignment" "deployer_admin" {
  count              = var.skip_role_assignments ? 0 : 1
  scope              = azapi_resource.sre_agent.id
  role_definition_id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.sre_agent_admin_role_id}"
  principal_id       = data.azurerm_client_config.current.object_id
  principal_type     = "User"
}

# ── SRE Agent Administrator — UAMI on the agent ──

resource "azurerm_role_assignment" "uami_admin" {
  count              = var.skip_role_assignments ? 0 : 1
  scope              = azapi_resource.sre_agent.id
  role_definition_id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.sre_agent_admin_role_id}"
  principal_id       = local.effective_principal_id
  principal_type     = "ServicePrincipal"
}

# ── Target RG: Reader ──

resource "azurerm_role_assignment" "target_reader" {
  for_each             = var.skip_role_assignments || !local.create_identity ? toset([]) : toset(var.target_resource_groups)
  scope                = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${each.value}"
  role_definition_name = "Reader"
  principal_id         = local.effective_principal_id
  principal_type       = "ServicePrincipal"
}

# ── Target RG: Log Analytics Reader ──

resource "azurerm_role_assignment" "target_log_reader" {
  for_each             = var.skip_role_assignments || !local.create_identity ? toset([]) : toset(var.target_resource_groups)
  scope                = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${each.value}"
  role_definition_name = "Log Analytics Reader"
  principal_id         = local.effective_principal_id
  principal_type       = "ServicePrincipal"
}

# ── Target RG: Contributor (High access only) ──

resource "azurerm_role_assignment" "target_contributor" {
  for_each             = !var.skip_role_assignments && local.create_identity && var.access_level == "High" ? toset(var.target_resource_groups) : toset([])
  scope                = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${each.value}"
  role_definition_name = "Contributor"
  principal_id         = local.effective_principal_id
  principal_type       = "ServicePrincipal"
}

# ═══════════ System MI RBAC on target RGs ═════════════
# The agent uses system-assigned MI for connector queries (App Insights, Log Analytics).
# Same roles as UAMI: Reader + Log Analytics Reader + Contributor (if High).

resource "azurerm_role_assignment" "smi_target_reader" {
  for_each             = var.skip_role_assignments ? toset([]) : toset(var.target_resource_groups)
  scope                = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${each.value}"
  role_definition_name = "Reader"
  principal_id         = azapi_resource.sre_agent.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "smi_target_log_reader" {
  for_each             = var.skip_role_assignments ? toset([]) : toset(var.target_resource_groups)
  scope                = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${each.value}"
  role_definition_name = "Log Analytics Reader"
  principal_id         = azapi_resource.sre_agent.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "smi_target_contributor" {
  for_each             = !var.skip_role_assignments && var.access_level == "High" ? toset(var.target_resource_groups) : toset([])
  scope                = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${each.value}"
  role_definition_name = "Contributor"
  principal_id         = azapi_resource.sre_agent.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
