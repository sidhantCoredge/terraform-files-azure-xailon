terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tokenfactory"
    storage_account_name = "sttokenfactorytfstate001"
    container_name       = "tfstate"
    key                  = "tokenfactory.tfstate"
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azapi" {
  # picks up the same az-cli / service-principal auth as azurerm — no separate config needed
}
