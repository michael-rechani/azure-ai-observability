terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    # Cost Management exports need a managed identity, which azurerm cannot set on them.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.4"
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {
    storage {
      # Storage is managed through ARM only. The cost account disables shared keys, and tenants
      # that force public network access off make the data plane unreachable from the deployer.
      data_plane_available = false
    }
  }
}
