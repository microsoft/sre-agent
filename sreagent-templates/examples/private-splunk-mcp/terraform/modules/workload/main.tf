variable "name_prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "splunk_subnet_id" { type = string }
variable "splunk_private_ip" { type = string }
variable "private_dns_zone_name" { type = string }
variable "splunk_dns_record_name" { type = string }
variable "vm_size" { type = string }
variable "admin_username" { type = string }
variable "admin_ssh_public_key" { type = string }
variable "tags" { type = map(string) }

locals {
  vm_name             = "${var.name_prefix}-vm"
  splunk_private_fqdn = "${var.splunk_dns_record_name}.${var.private_dns_zone_name}"
}

resource "azurerm_private_dns_a_record" "splunk_mcp" {
  name                = var.splunk_dns_record_name
  zone_name           = var.private_dns_zone_name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [var.splunk_private_ip]
  tags                = var.tags
}

resource "azurerm_network_interface" "splunk" {
  name                = "${local.vm_name}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.splunk_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.splunk_private_ip
  }
}

resource "azurerm_linux_virtual_machine" "splunk" {
  name                            = local.vm_name
  location                        = var.location
  resource_group_name             = var.resource_group_name
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

output "splunk_vm_id" { value = azurerm_linux_virtual_machine.splunk.id }
output "splunk_vm_name" { value = azurerm_linux_virtual_machine.splunk.name }
output "splunk_private_ip" { value = azurerm_network_interface.splunk.private_ip_address }
output "splunk_hostname" { value = local.splunk_private_fqdn }
output "splunk_endpoint_candidates" {
  value = {
    private_test_http = "http://${local.splunk_private_fqdn}:8080"
    mcp_https         = "https://${local.splunk_private_fqdn}:8089/services/mcp"
    mcp_http_lab_only = "http://${local.splunk_private_fqdn}:8089/services/mcp"
  }
}
