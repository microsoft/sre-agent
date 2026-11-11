variable "name_prefix" { type = string }
variable "agent_location" { type = string }
variable "splunk_location" { type = string }
variable "resource_group_name" { type = string }
variable "agent_vnet_address_prefix" { type = string }
variable "splunk_vnet_address_prefix" { type = string }
variable "agent_subnet_prefix" { type = string }
variable "splunk_subnet_prefix" { type = string }
variable "splunk_nsg_id" { type = string }
variable "nat_gateway_id" { type = string }
variable "private_dns_zone_name" { type = string }
variable "tags" { type = map(string) }

resource "azurerm_virtual_network" "agent" {
  name                = "${var.name_prefix}-agent-vnet"
  location            = var.agent_location
  resource_group_name = var.resource_group_name
  address_space       = [var.agent_vnet_address_prefix]
  tags                = var.tags
}

resource "azurerm_subnet" "agent" {
  name                 = "agent-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.agent.name
  address_prefixes     = [var.agent_subnet_prefix]

  delegation {
    name = "sre-agent-environment"
    service_delegation {
      name = "Microsoft.App/environments"
    }
  }
}

resource "azurerm_virtual_network" "splunk" {
  name                = "${var.name_prefix}-splunk-vnet"
  location            = var.splunk_location
  resource_group_name = var.resource_group_name
  address_space       = [var.splunk_vnet_address_prefix]
  tags                = var.tags
}

resource "azurerm_subnet" "splunk" {
  name                 = "splunk-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.splunk.name
  address_prefixes     = [var.splunk_subnet_prefix]
}

resource "azurerm_subnet_network_security_group_association" "splunk" {
  subnet_id                 = azurerm_subnet.splunk.id
  network_security_group_id = var.splunk_nsg_id
}

resource "azurerm_subnet_nat_gateway_association" "splunk" {
  subnet_id      = azurerm_subnet.splunk.id
  nat_gateway_id = var.nat_gateway_id
}

resource "azurerm_virtual_network_peering" "agent_to_splunk" {
  name                         = "agent-to-splunk"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.agent.name
  remote_virtual_network_id    = azurerm_virtual_network.splunk.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
  depends_on                   = [azurerm_subnet.agent, azurerm_subnet.splunk]
}

resource "azurerm_virtual_network_peering" "splunk_to_agent" {
  name                         = "splunk-to-agent"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.splunk.name
  remote_virtual_network_id    = azurerm_virtual_network.agent.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
  depends_on                   = [azurerm_subnet.agent, azurerm_subnet.splunk, azurerm_virtual_network_peering.agent_to_splunk]
}

resource "azurerm_private_dns_zone_virtual_network_link" "agent" {
  name                  = "agent-vnet-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = var.private_dns_zone_name
  virtual_network_id    = azurerm_virtual_network.agent.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "splunk" {
  name                  = "splunk-vnet-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = var.private_dns_zone_name
  virtual_network_id    = azurerm_virtual_network.splunk.id
  registration_enabled  = false
  tags                  = var.tags
}

output "agent_subnet_id" { value = azurerm_subnet.agent.id }
output "splunk_subnet_id" { value = azurerm_subnet.splunk.id }
output "agent_vnet_id" { value = azurerm_virtual_network.agent.id }
output "splunk_vnet_id" { value = azurerm_virtual_network.splunk.id }
