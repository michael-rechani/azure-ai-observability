terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.68"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}
