locals {
  vnet_name               = "${var.name_prefix}-vnet"
  agent_subnet_name       = "agent-subnet"
  splunk_subnet_name      = "splunk-subnet"
  splunk_nsg_name         = "${var.name_prefix}-splunk-nsg"
  nat_gateway_name        = "${var.name_prefix}-splunk-nat"
  nat_public_ip_name      = "${var.name_prefix}-splunk-nat-pip"
  vm_name                 = "${var.name_prefix}-vm"
  nic_name                = "${local.vm_name}-nic"
  splunk_private_fqdn     = "${var.splunk_dns_record_name}.${var.private_dns_zone_name}"
  vnet_key                = try(join(".", slice(split(".", cidrhost(var.vnet_address_prefix, 0)), 0, 2)), "")
  agent_subnet_vnet_key   = try(join(".", slice(split(".", cidrhost(var.agent_subnet_prefix, 0)), 0, 2)), "")
  splunk_subnet_vnet_key  = try(join(".", slice(split(".", cidrhost(var.splunk_subnet_prefix, 0)), 0, 2)), "")
  agent_subnet_key        = try(join(".", slice(split(".", cidrhost(var.agent_subnet_prefix, 0)), 0, 3)), "")
  splunk_subnet_key       = try(join(".", slice(split(".", cidrhost(var.splunk_subnet_prefix, 0)), 0, 3)), "")
  splunk_private_ip_key   = try(join(".", slice(split(".", var.splunk_private_ip), 0, 3)), "")
  azure_reserved_ips      = try([for offset in range(4) : cidrhost(var.splunk_subnet_prefix, offset)], [])
  splunk_subnet_last_ip   = try(cidrhost(var.splunk_subnet_prefix, -1), "")
}

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags

  lifecycle {
    precondition {
      condition     = local.vnet_key == local.agent_subnet_vnet_key
      error_message = "agent_subnet_prefix must be fully contained in vnet_address_prefix."
    }

    precondition {
      condition     = local.vnet_key == local.splunk_subnet_vnet_key
      error_message = "splunk_subnet_prefix must be fully contained in vnet_address_prefix."
    }

    precondition {
      condition     = local.agent_subnet_key != local.splunk_subnet_key
      error_message = "agent_subnet_prefix and splunk_subnet_prefix must not overlap."
    }

    precondition {
      condition = (
        local.splunk_subnet_key == local.splunk_private_ip_key &&
        !contains(local.azure_reserved_ips, var.splunk_private_ip) &&
        var.splunk_private_ip != local.splunk_subnet_last_ip
      )
      error_message = "splunk_private_ip must be a usable host address in splunk_subnet_prefix and cannot be an Azure-reserved or broadcast address."
    }
  }
}

resource "azurerm_virtual_network" "lab" {
  name                = local.vnet_name
  location            = var.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = [var.vnet_address_prefix]
  tags                = var.tags
}

resource "azurerm_subnet" "agent" {
  name                 = local.agent_subnet_name
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.agent_subnet_prefix]

  delegation {
    name = "sre-agent-environment"

    service_delegation {
      name = "Microsoft.App/environments"
    }
  }
}

resource "azurerm_network_security_group" "splunk" {
  name                = local.splunk_nsg_name
  location            = var.location
  resource_group_name = azurerm_resource_group.lab.name
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
  name                = local.nat_public_ip_name
  location            = var.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "splunk" {
  name                    = local.nat_gateway_name
  location                = var.location
  resource_group_name     = azurerm_resource_group.lab.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "splunk" {
  nat_gateway_id       = azurerm_nat_gateway.splunk.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet" "splunk" {
  name                 = local.splunk_subnet_name
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.splunk_subnet_prefix]

  depends_on = [azurerm_subnet.agent]
}

resource "azurerm_subnet_network_security_group_association" "splunk" {
  subnet_id                 = azurerm_subnet.splunk.id
  network_security_group_id = azurerm_network_security_group.splunk.id
}

resource "azurerm_subnet_nat_gateway_association" "splunk" {
  subnet_id      = azurerm_subnet.splunk.id
  nat_gateway_id = azurerm_nat_gateway.splunk.id
}

resource "azurerm_private_dns_zone" "lab" {
  name                = var.private_dns_zone_name
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "lab" {
  name                  = "lab-vnet-link"
  resource_group_name   = azurerm_resource_group.lab.name
  private_dns_zone_name = azurerm_private_dns_zone.lab.name
  virtual_network_id    = azurerm_virtual_network.lab.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_a_record" "splunk_mcp" {
  name                = var.splunk_dns_record_name
  zone_name           = azurerm_private_dns_zone.lab.name
  resource_group_name = azurerm_resource_group.lab.name
  ttl                 = 300
  records             = [var.splunk_private_ip]
  tags                = var.tags
}

resource "azurerm_network_interface" "splunk" {
  name                = local.nic_name
  location            = var.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.splunk.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.splunk_private_ip
  }

  depends_on = [
    azurerm_subnet_nat_gateway_association.splunk,
    azurerm_subnet_network_security_group_association.splunk,
  ]
}

resource "azurerm_linux_virtual_machine" "splunk" {
  name                            = local.vm_name
  location                        = var.location
  resource_group_name             = azurerm_resource_group.lab.name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.splunk.id]
  tags                            = var.tags

  identity {
    type = "SystemAssigned"
  }

  admin_ssh_key {
    username   = var.admin_username
    public_key = trimspace(var.admin_ssh_public_key)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  secure_boot_enabled = true
  vtpm_enabled        = true
}
