# ---------------------------------------------------------------
# Resource Group
# A container that groups all our Azure resources together.
# ---------------------------------------------------------------
resource "azurerm_resource_group" "demo" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------
# App Service Plan
# Think of this as the "server" that hosts your web app.
# B1 = Basic tier, small size — fine for a demo.
# ---------------------------------------------------------------
resource "azurerm_service_plan" "demo" {
  name                = "${var.prefix}-plan"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  os_type             = "Linux"
  sku_name            = "B1"
  tags                = var.tags
}

# ---------------------------------------------------------------
# App Service (Web App)
# This is the actual web application. It runs Node.js 20 on Linux.
# We set TLS 1.2 as the minimum — this will be one of our "drift" targets.
# ---------------------------------------------------------------
resource "azurerm_linux_web_app" "demo" {
  name                = "${var.prefix}-webapp"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  service_plan_id     = azurerm_service_plan.demo.id

  site_config {
    minimum_tls_version = "1.2"

    application_stack {
      node_version = "20-lts"
    }
  }

  app_settings = {
    "WEBSITE_NODE_DEFAULT_VERSION"  = "~20"
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
  }

  tags = var.tags
}

# ---------------------------------------------------------------
# Log Analytics Workspace
# A place where Azure stores logs. Application Insights sends data here.
# ---------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "demo" {
  name                = "${var.prefix}-law"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# ---------------------------------------------------------------
# Application Insights
# Monitors your web app — tracks requests, errors, response times, etc.
# The SRE Agent can query this when investigating.
# ---------------------------------------------------------------
resource "azurerm_application_insights" "demo" {
  name                = "${var.prefix}-appinsights"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  workspace_id        = azurerm_log_analytics_workspace.demo.id
  application_type    = "web"
  tags                = var.tags
}
