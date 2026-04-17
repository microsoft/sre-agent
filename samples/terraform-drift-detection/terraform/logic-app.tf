# ---------------------------------------------------------------
# Logic App: Auth Bridge
#
# WHY DO WE NEED THIS?
# Terraform Cloud (or any external tool) sends a plain HTTP webhook.
# But SRE Agent's HTTP Trigger requires an Azure AD token for security.
# The Logic App sits in between: it receives the webhook, automatically
# acquires an Azure AD token using its Managed Identity, and forwards
# the request to SRE Agent with proper authentication.
#
# External Tool → Logic App (adds auth) → SRE Agent HTTP Trigger
# ---------------------------------------------------------------

resource "azurerm_logic_app_workflow" "tfc_bridge" {
  name                = "${var.prefix}-tfc-bridge"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name

  # Managed Identity = the Logic App gets its own Azure AD identity.
  # No passwords or secrets to manage — Azure handles the auth automatically.
  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# ---------------------------------------------------------------
# Logic App HTTP Trigger
# This creates a public URL that can receive webhook POSTs.
# Terraform Cloud (or our simulation script) will call this URL.
# ---------------------------------------------------------------
resource "azurerm_logic_app_trigger_http_request" "tfc_webhook" {
  name         = "on-tfc-run-notification"
  logic_app_id = azurerm_logic_app_workflow.tfc_bridge.id

  # This schema describes what the incoming JSON looks like.
  # It's based on Terraform Cloud's run notification format.
  schema = jsonencode({
    type = "object"
    properties = {
      payload_version = { type = "integer" }
      notification_configuration_id = { type = "string" }
      run_url         = { type = "string" }
      run_id          = { type = "string" }
      run_message     = { type = "string" }
      run_created_at  = { type = "string" }
      run_created_by  = { type = "string" }
      workspace_id    = { type = "string" }
      workspace_name  = { type = "string" }
      organization_name = { type = "string" }
      notifications = {
        type = "array"
        items = {
          type = "object"
          properties = {
            message      = { type = "string" }
            trigger      = { type = "string" }
            run_status   = { type = "string" }
            run_updated_at = { type = "string" }
            run_updated_by = { type = "string" }
          }
        }
      }
    }
  })
}

# ---------------------------------------------------------------
# Logic App HTTP Action: Forward to SRE Agent
# This takes the Terraform Cloud payload, reshapes it into the
# format our HTTP Trigger prompt expects, and sends it to SRE Agent
# with a proper Azure AD token attached.
# ---------------------------------------------------------------
resource "azurerm_logic_app_action_custom" "call_sre_agent" {
  name         = "forward-to-sre-agent"
  logic_app_id = azurerm_logic_app_workflow.tfc_bridge.id

  body = jsonencode({
    type = "Http"
    inputs = {
      method = "POST"
      uri    = var.sre_agent_trigger_url
      headers = {
        "Content-Type" = "application/json"
      }
      body = {
        workspace_name = "@{triggerBody()?['workspace_name']}"
        organization   = "@{triggerBody()?['organization_name']}"
        run_id         = "@{triggerBody()?['run_id']}"
        run_url        = "@{triggerBody()?['run_url']}"
        run_message    = "@{triggerBody()?['run_message']}"
        run_status     = "@{triggerBody()?['notifications']?[0]?['run_status']}"
        trigger_type   = "@{triggerBody()?['notifications']?[0]?['trigger']}"
        run_created_by = "@{triggerBody()?['run_created_by']}"
        run_created_at = "@{triggerBody()?['run_created_at']}"
        resource_group = azurerm_resource_group.demo.name
        app_name       = azurerm_linux_web_app.demo.name
      }
      authentication = {
        type     = "ManagedServiceIdentity"
        audience = var.sre_agent_audience
      }
    }
    runAfter = {}
  })
}
