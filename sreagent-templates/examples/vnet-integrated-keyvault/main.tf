########################################
# VNet-integrated SRE Agent + private Key Vault
#
# The SRE Agent is injected into a delegated subnet, and a Key Vault with
# public access disabled is reachable only through a private endpoint,
# resolved via a private DNS zone linked to the same VNet. All Key Vault
# traffic stays on the VNet.
########################################

data "azurerm_client_config" "current" {}

locals {
  tenant_id   = var.tenant_id != "" ? var.tenant_id : data.azurerm_client_config.current.tenant_id
  rg_name     = var.create_resource_group ? azurerm_resource_group.this[0].name : var.resource_group_name
  rg_location = var.location
}

resource "azurerm_resource_group" "this" {
  count    = var.create_resource_group ? 1 : 0
  name     = var.resource_group_name
  location = var.location
}

########################################
# Networking: one VNet, two subnets
########################################

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.name_prefix}-vnet"
  location            = local.rg_location
  resource_group_name = local.rg_name
  address_space       = [var.vnet_address_space]
}

# Subnet the agent is injected into. Delegation to Microsoft.App/environments
# is required for SRE Agent VNet injection.
resource "azurerm_subnet" "agent" {
  name                 = "agent-subnet"
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.agent_subnet_prefix]

  delegation {
    name = "app-env-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Subnet that holds the Key Vault private endpoint.
resource "azurerm_subnet" "pe" {
  name                 = "pe-subnet"
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.pe_subnet_prefix]
}

########################################
# Managed identity for the agent
########################################

resource "azurerm_user_assigned_identity" "agent" {
  name                = "${var.name_prefix}-identity"
  location            = local.rg_location
  resource_group_name = local.rg_name
}

########################################
# Key Vault - public access disabled
########################################

resource "azurerm_key_vault" "kv" {
  name                = var.key_vault_name
  location            = local.rg_location
  resource_group_name = local.rg_name
  tenant_id           = local.tenant_id
  sku_name            = "standard"

  # RBAC authorization (not access policies).
  rbac_authorization_enabled = true

  # No public network access. The only way in is the private endpoint below.
  public_network_access_enabled = false

  network_acls {
    default_action = "Deny"
    bypass         = "None"
  }
}

# Agent identity can use (sign with) keys in the vault. Crypto User is the
# least privilege needed to use a GitHub App private key stored as a KV Key.
resource "azurerm_role_assignment" "agent_crypto_user" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.agent.principal_id
}

# The deployer can import the key (e.g. the GitHub App .pem as a KV Key).
resource "azurerm_role_assignment" "deployer_crypto_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

########################################
# Private endpoint + private DNS
########################################

resource "azurerm_private_dns_zone" "kv" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = local.rg_name
}

# Link the private DNS zone to the VNet. This makes <vault>.vault.azure.net
# resolve to the private endpoint IP (10.x) from inside the agent's VNet.
# Without this link the FQDN resolves to a public IP.
resource "azurerm_private_dns_zone_virtual_network_link" "kv" {
  name                  = "kv-dns-link"
  resource_group_name   = local.rg_name
  private_dns_zone_name = azurerm_private_dns_zone.kv.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
}

resource "azurerm_private_endpoint" "kv" {
  name                = "pe-kv"
  location            = local.rg_location
  resource_group_name = local.rg_name
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "pe-kv"
    private_connection_resource_id = azurerm_key_vault.kv.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.kv.id]
  }
}

########################################
# SRE Agent (Microsoft.App/agents)
# Deployed via azapi. The networking knob that matters is
# properties.vnetConfiguration.subnetResourceId pointing at the
# delegated agent subnet above.
########################################

resource "azapi_resource" "sre_agent" {
  type      = "Microsoft.App/agents@2026-01-01"
  name      = "${var.name_prefix}-agent"
  location  = local.rg_location
  parent_id = var.create_resource_group ? azurerm_resource_group.this[0].id : "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}"

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.agent.id]
  }

  body = {
    properties = {
      # VNet injection: puts the agent (and its sandbox) on the VNet so it
      # resolves and reaches Key Vault via the private endpoint.
      vnetConfiguration = {
        subnetResourceId = azurerm_subnet.agent.id
      }

      actionConfiguration = {
        mode        = "review"
        accessLevel = "Low"
        identity    = azurerm_user_assigned_identity.agent.id
      }

      defaultModel = {
        name     = "Automatic"
        provider = "MicrosoftFoundry"
      }
    }
  }

  schema_validation_enabled = false

  depends_on = [
    azurerm_subnet.agent,
    azurerm_private_dns_zone_virtual_network_link.kv,
  ]
}
