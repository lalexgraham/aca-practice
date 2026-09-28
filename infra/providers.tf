terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # Values supplied at init time: -backend-config="..." locally (or a
  # gitignored backend.hcl), and via workflow inputs/vars in CI.
  # Never commit real values here.
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  # No auth block here on purpose. Locally this picks up your `az login`
  # session. In CI, ARM_USE_OIDC/ARM_CLIENT_ID/ARM_TENANT_ID/
  # ARM_SUBSCRIPTION_ID env vars (set by azure/login + the workflow) are
  # picked up automatically, so this file doesn't change between contexts.
}
