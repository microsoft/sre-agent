variable "resource_group_name" {
  description = "Name of the resource group created for the lab."
  type        = string
  default     = "rg-private-splunk-lab"

  validation {
    condition     = length(trimspace(var.resource_group_name)) > 0
    error_message = "resource_group_name must not be empty."
  }
}

variable "name_prefix" {
  description = "Prefix used for lab resource names."
  type        = string
  default     = "sre-splunk"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,22}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-24 lowercase letters, numbers, or hyphens and must start and end with a letter or number."
  }
}

variable "agent_location" {
  description = "Azure region for the SRE Agent VNet and delegated subnet."
  type        = string
  default     = "eastus2"

  validation {
    condition     = length(trimspace(var.agent_location)) > 0
    error_message = "agent_location must not be empty."
  }
}

variable "splunk_location" {
  description = "Azure region for the private Splunk VNet and VM."
  type        = string
  default     = "centralus"

  validation {
    condition     = length(trimspace(var.splunk_location)) > 0
    error_message = "splunk_location must not be empty."
  }
}

variable "agent_vnet_address_prefix" {
  description = "IPv4 /16 address space for the SRE Agent VNet."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.agent_vnet_address_prefix, 0)) && can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/16$", var.agent_vnet_address_prefix))
    error_message = "agent_vnet_address_prefix must be a valid IPv4 /16 CIDR."
  }
}

variable "agent_subnet_prefix" {
  description = "Dedicated IPv4 /27 subnet delegated to Microsoft.App/environments."
  type        = string
  default     = "10.20.0.0/27"

  validation {
    condition     = can(cidrhost(var.agent_subnet_prefix, 0)) && can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/27$", var.agent_subnet_prefix))
    error_message = "agent_subnet_prefix must be a valid IPv4 /27 CIDR."
  }
}

variable "splunk_vnet_address_prefix" {
  description = "IPv4 /16 address space for the private Splunk VNet."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrhost(var.splunk_vnet_address_prefix, 0)) && can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/16$", var.splunk_vnet_address_prefix))
    error_message = "splunk_vnet_address_prefix must be a valid IPv4 /16 CIDR."
  }
}

variable "splunk_subnet_prefix" {
  description = "IPv4 /24 subnet used by the private Splunk VM."
  type        = string
  default     = "10.40.1.0/24"

  validation {
    condition     = can(cidrhost(var.splunk_subnet_prefix, 0)) && can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/24$", var.splunk_subnet_prefix))
    error_message = "splunk_subnet_prefix must be a valid IPv4 /24 CIDR."
  }
}

variable "splunk_private_ip" {
  description = "Static private IPv4 address assigned to the Splunk VM and private DNS record."
  type        = string
  default     = "10.40.1.4"

  validation {
    condition     = can(cidrhost("${var.splunk_private_ip}/32", 0)) && can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.splunk_private_ip))
    error_message = "splunk_private_ip must be a valid IPv4 address."
  }
}

variable "private_dns_zone_name" {
  description = "Private DNS zone used by the lab."
  type        = string
  default     = "lab.internal"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.private_dns_zone_name))
    error_message = "private_dns_zone_name must be a valid lowercase DNS zone name."
  }
}

variable "splunk_dns_record_name" {
  description = "A record name for the private Splunk MCP host."
  type        = string
  default     = "splunk-mcp"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.splunk_dns_record_name))
    error_message = "splunk_dns_record_name must be a valid lowercase DNS label."
  }
}

variable "vm_size" {
  description = "Azure VM size for the private Ubuntu VM."
  type        = string
  default     = "Standard_D4as_v5"
}

variable "admin_username" {
  description = "Administrator username for the private Ubuntu VM."
  type        = string
  default     = "azureuser"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,30}$", var.admin_username))
    error_message = "admin_username must be a valid Linux username with at most 31 characters."
  }
}

variable "admin_ssh_public_key" {
  description = "SSH public key for the VM. The VM has no public IP."
  type        = string

  validation {
    condition     = can(regex("^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,3}( .*)?$", trimspace(var.admin_ssh_public_key)))
    error_message = "admin_ssh_public_key must be a valid OpenSSH public key."
  }
}

variable "tags" {
  description = "Optional tags applied to lab resources."
  type        = map(string)
  default     = {}
}
