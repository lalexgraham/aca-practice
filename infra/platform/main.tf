# Platform layer: provisioned once, shared by every environment.
# State key: aca-practice-platform.tfstate
#
# Nothing here is parameterised by var.environment on purpose - staging and
# production both run inside this one resource group / Container Apps
# Environment. The per-environment Container Apps live in ../environment,
# which looks these resources up by name.

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.project}"
  location = var.location
  tags = {
    purpose = "pipeline-test"
  }
}

resource "azurerm_container_registry" "this" {
  name                = replace("acr${var.project}", "-", "")
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"
  admin_enabled       = false # pull via managed identity, not admin creds
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.project}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${var.project}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}
