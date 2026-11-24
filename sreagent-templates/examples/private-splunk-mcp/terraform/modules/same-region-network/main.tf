variable "name_prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "vnet_address_prefix" { type = string }
variable "agent_subnet_prefix" { type = string }
variable "splunk_subnet_prefix" { type = string }
variable "splunk_nsg_id" { type = string }
variable "nat_gateway_id" { type = string }
variable "private_dns_zone_name" { type = string }
variable "tags" { type = map(string) }

resource "azurerm_virtual_network" "lab" {
  name                = "${var.name_prefix}-vnet"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.vnet_address_prefix]
  tags                = var.tags
}

resource "azurerm_subnet" "agent" {
  name                 = "agent-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.agent_subnet_prefix]

  delegation {
    name = "sre-agent-environment"
    service_delegation {
      name = "Microsoft.App/environments"
    }
  }
}

resource "azurerm_subnet" "splunk" {
  name                 = "splunk-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.splunk_subnet_prefix]
  depends_on           = [azurerm_subnet.agent]
}

resource "azurerm_subnet_network_security_group_association" "splunk" {
  subnet_id                 = azurerm_subnet.splunk.id
  network_security_group_id = var.splunk_nsg_id
}

resource "azurerm_subnet_nat_gateway_association" "splunk" {
  subnet_id      = azurerm_subnet.splunk.id
  nat_gateway_id = var.nat_gateway_id
}

resource "azurerm_private_dns_zone_virtual_network_link" "lab" {
  name                  = "lab-vnet-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = var.private_dns_zone_name
  virtual_network_id    = azurerm_virtual_network.lab.id
  registration_enabled  = false
  tags                  = var.tags
}

output "agent_subnet_id" { value = azurerm_subnet.agent.id }
output "splunk_subnet_id" { value = azurerm_subnet.splunk.id }
output "agent_vnet_id" { value = azurerm_virtual_network.lab.id }
output "splunk_vnet_id" { value = azurerm_virtual_network.lab.id }
