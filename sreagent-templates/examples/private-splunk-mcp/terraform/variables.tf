variable "topology" {
  description = "Network topology: same-region or cross-region."
  type        = string
  validation {
    condition     = contains(["same-region", "cross-region"], var.topology)
    error_message = "topology must be same-region or cross-region."
  }
}

variable "resource_group_name" {
  type    = string
  default = "rg-private-splunk-lab"
  validation {
    condition     = length(trimspace(var.resource_group_name)) > 0
    error_message = "resource_group_name must not be empty."
  }
}

variable "name_prefix" {
  type    = string
  default = "sre-splunk"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,22}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-24 lowercase letters, numbers, or hyphens and must start and end with a letter or number."
  }
}

variable "agent_location" {
  type    = string
  default = "eastus2"
  validation {
    condition     = length(trimspace(var.agent_location)) > 0
    error_message = "agent_location must not be empty."
  }
}

variable "splunk_location" {
  type     = string
  default  = null
  nullable = true
  validation {
    condition     = var.splunk_location == null || length(trimspace(var.splunk_location)) > 0
    error_message = "splunk_location must be null or a non-empty Azure region."
  }
}

variable "agent_vnet_address_prefix" {
  type    = string
  default = "10.100.0.0/16"
  validation {
    condition     = can(cidrhost(var.agent_vnet_address_prefix, 0)) && can(regex("/16$", var.agent_vnet_address_prefix))
    error_message = "agent_vnet_address_prefix must be a valid IPv4 /16 CIDR."
  }
}

variable "splunk_vnet_address_prefix" {
  type     = string
  default  = null
  nullable = true
  validation {
    condition     = var.splunk_vnet_address_prefix == null || (can(cidrhost(var.splunk_vnet_address_prefix, 0)) && can(regex("/16$", var.splunk_vnet_address_prefix)))
    error_message = "splunk_vnet_address_prefix must be null or a valid IPv4 /16 CIDR."
  }
}

variable "agent_subnet_prefix" {
  type    = string
  default = "10.100.0.0/27"
  validation {
    condition     = can(cidrhost(var.agent_subnet_prefix, 0)) && can(regex("/27$", var.agent_subnet_prefix))
    error_message = "agent_subnet_prefix must be a valid IPv4 /27 CIDR."
  }
}

variable "splunk_subnet_prefix" {
  type    = string
  default = "10.100.1.0/24"
  validation {
    condition     = can(cidrhost(var.splunk_subnet_prefix, 0)) && can(regex("/24$", var.splunk_subnet_prefix))
    error_message = "splunk_subnet_prefix must be a valid IPv4 /24 CIDR."
  }
}

variable "splunk_private_ip" {
  type    = string
  default = "10.100.1.4"
  validation {
    condition     = can(cidrhost("${var.splunk_private_ip}/32", 0))
    error_message = "splunk_private_ip must be a valid IPv4 address."
  }
}

variable "private_dns_zone_name" {
  type    = string
  default = "lab.internal"
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.private_dns_zone_name))
    error_message = "private_dns_zone_name must be a valid lowercase DNS zone name."
  }
}

variable "splunk_dns_record_name" {
  type    = string
  default = "splunk-mcp"
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.splunk_dns_record_name))
    error_message = "splunk_dns_record_name must be a valid lowercase DNS label."
  }
}

variable "vm_size" {
  type    = string
  default = "Standard_D4as_v5"
}

variable "admin_username" {
  type    = string
  default = "azureuser"
  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,30}$", var.admin_username))
    error_message = "admin_username must be a valid Linux username with at most 31 characters."
  }
}

variable "admin_ssh_public_key" {
  type = string
  validation {
    condition     = can(regex("^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,3}( .*)?$", trimspace(var.admin_ssh_public_key)))
    error_message = "admin_ssh_public_key must be a valid OpenSSH public key."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
