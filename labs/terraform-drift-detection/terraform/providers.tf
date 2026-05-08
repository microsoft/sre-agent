# ---------------------------------------------------------------
# Provider configuration
# ---------------------------------------------------------------
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # For the blog demo, we use local state (a file on your machine).
  # In production, you'd store state remotely (Azure Storage, Terraform Cloud, etc.)
  # so your whole team shares the same state.
}

provider "azurerm" {
  features {}
  subscription_id                = var.subscription_id
  resource_provider_registrations = "none"
}
