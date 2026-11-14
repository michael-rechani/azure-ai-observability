terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
    # The Grafana Infinity plugin is enabled through an azapi update, which azurerm cannot do.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.4"
    }
    # Creates the optional Infinity cost-query app registration, service principal and client secret.
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    # Schedules that client secret's rotation.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
}

provider "azuread" {}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}
