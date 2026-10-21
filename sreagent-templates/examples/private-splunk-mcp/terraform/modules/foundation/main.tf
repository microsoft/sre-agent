variable "name_prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "agent_subnet_prefix" { type = string }
variable "private_dns_zone_name" { type = string }
variable "tags" { type = map(string) }

resource "azurerm_network_security_group" "splunk" {
  name                = "${var.name_prefix}-splunk-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "AllowAgentToPrivateTestAndMcp"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "8089"]
    source_address_prefix      = var.agent_subnet_prefix
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyOtherVirtualNetworkInbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyInternetInbound"
    priority                   = 4010
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_public_ip" "nat" {
  name                = "${var.name_prefix}-splunk-nat-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "splunk" {
  name                    = "${var.name_prefix}-splunk-nat"
  location                = var.location
  resource_group_name     = var.resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "splunk" {
  nat_gateway_id       = azurerm_nat_gateway.splunk.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_private_dns_zone" "lab" {
  name                = var.private_dns_zone_name
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

output "splunk_nsg_id" { value = azurerm_network_security_group.splunk.id }
output "nat_gateway_id" { value = azurerm_nat_gateway.splunk.id }
output "private_dns_zone_name" { value = azurerm_private_dns_zone.lab.name }
