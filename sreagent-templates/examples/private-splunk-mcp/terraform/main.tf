locals {
  splunk_location            = coalesce(var.splunk_location, var.agent_location)
  splunk_vnet_address_prefix = coalesce(var.splunk_vnet_address_prefix, var.agent_vnet_address_prefix)
  agent_vnet_key             = try(join(".", slice(split(".", cidrhost(var.agent_vnet_address_prefix, 0)), 0, 2)), "")
  splunk_vnet_key            = try(join(".", slice(split(".", cidrhost(local.splunk_vnet_address_prefix, 0)), 0, 2)), "")
  agent_subnet_vnet_key      = try(join(".", slice(split(".", cidrhost(var.agent_subnet_prefix, 0)), 0, 2)), "")
  splunk_subnet_vnet_key     = try(join(".", slice(split(".", cidrhost(var.splunk_subnet_prefix, 0)), 0, 2)), "")
  agent_subnet_key           = try(join(".", slice(split(".", cidrhost(var.agent_subnet_prefix, 0)), 0, 3)), "")
  splunk_subnet_key          = try(join(".", slice(split(".", cidrhost(var.splunk_subnet_prefix, 0)), 0, 3)), "")
  splunk_private_ip_key      = try(join(".", slice(split(".", var.splunk_private_ip), 0, 3)), "")
  azure_reserved_ips         = try([for offset in range(4) : cidrhost(var.splunk_subnet_prefix, offset)], [])
  splunk_subnet_last_ip      = try(cidrhost(var.splunk_subnet_prefix, -1), "")

  agent_subnet_id  = var.topology == "same-region" ? module.same_region_network[0].agent_subnet_id : module.cross_region_network[0].agent_subnet_id
  splunk_subnet_id = var.topology == "same-region" ? module.same_region_network[0].splunk_subnet_id : module.cross_region_network[0].splunk_subnet_id
  agent_vnet_id    = var.topology == "same-region" ? module.same_region_network[0].agent_vnet_id : module.cross_region_network[0].agent_vnet_id
  splunk_vnet_id   = var.topology == "same-region" ? module.same_region_network[0].splunk_vnet_id : module.cross_region_network[0].splunk_vnet_id
}

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.agent_location
  tags     = var.tags

  lifecycle {
    precondition {
      condition     = var.topology == "same-region" ? lower(var.agent_location) == lower(local.splunk_location) : lower(var.agent_location) != lower(local.splunk_location)
      error_message = "same-region requires equal locations; cross-region requires different locations."
    }
    precondition {
      condition     = local.agent_vnet_key == local.agent_subnet_vnet_key
      error_message = "agent_subnet_prefix must be contained in agent_vnet_address_prefix."
    }
    precondition {
      condition     = local.splunk_vnet_key == local.splunk_subnet_vnet_key
      error_message = "splunk_subnet_prefix must be contained in the selected Splunk VNet prefix."
    }
    precondition {
      condition     = var.topology == "same-region" ? var.agent_vnet_address_prefix == local.splunk_vnet_address_prefix && local.agent_subnet_key != local.splunk_subnet_key : local.agent_vnet_key != local.splunk_vnet_key
      error_message = "same-region requires one VNet with distinct subnets; cross-region requires non-overlapping VNets."
    }
    precondition {
      condition = (
        local.splunk_subnet_key == local.splunk_private_ip_key &&
        !contains(local.azure_reserved_ips, var.splunk_private_ip) &&
        var.splunk_private_ip != local.splunk_subnet_last_ip
      )
      error_message = "splunk_private_ip must be a usable host address in splunk_subnet_prefix."
    }
  }
}

module "foundation" {
  source                = "./modules/foundation"
  name_prefix           = var.name_prefix
  location              = local.splunk_location
  resource_group_name   = azurerm_resource_group.lab.name
  agent_subnet_prefix   = var.agent_subnet_prefix
  private_dns_zone_name = var.private_dns_zone_name
  tags                  = var.tags
}

module "same_region_network" {
  count                 = var.topology == "same-region" ? 1 : 0
  source                = "./modules/same-region-network"
  name_prefix           = var.name_prefix
  location              = var.agent_location
  resource_group_name   = azurerm_resource_group.lab.name
  vnet_address_prefix   = var.agent_vnet_address_prefix
  agent_subnet_prefix   = var.agent_subnet_prefix
  splunk_subnet_prefix  = var.splunk_subnet_prefix
  splunk_nsg_id         = module.foundation.splunk_nsg_id
  nat_gateway_id        = module.foundation.nat_gateway_id
  private_dns_zone_name = module.foundation.private_dns_zone_name
  tags                  = var.tags
}

module "cross_region_network" {
  count                      = var.topology == "cross-region" ? 1 : 0
  source                     = "./modules/cross-region-network"
  name_prefix                = var.name_prefix
  agent_location             = var.agent_location
  splunk_location            = local.splunk_location
  resource_group_name        = azurerm_resource_group.lab.name
  agent_vnet_address_prefix  = var.agent_vnet_address_prefix
  splunk_vnet_address_prefix = local.splunk_vnet_address_prefix
  agent_subnet_prefix        = var.agent_subnet_prefix
  splunk_subnet_prefix       = var.splunk_subnet_prefix
  splunk_nsg_id              = module.foundation.splunk_nsg_id
  nat_gateway_id             = module.foundation.nat_gateway_id
  private_dns_zone_name      = module.foundation.private_dns_zone_name
  tags                       = var.tags
}

module "workload" {
  source                 = "./modules/workload"
  name_prefix            = var.name_prefix
  location               = local.splunk_location
  resource_group_name    = azurerm_resource_group.lab.name
  splunk_subnet_id       = local.splunk_subnet_id
  splunk_private_ip      = var.splunk_private_ip
  private_dns_zone_name  = module.foundation.private_dns_zone_name
  splunk_dns_record_name = var.splunk_dns_record_name
  vm_size                = var.vm_size
  admin_username         = var.admin_username
  admin_ssh_public_key   = var.admin_ssh_public_key
  tags                   = var.tags
  depends_on             = [module.same_region_network, module.cross_region_network]
}
