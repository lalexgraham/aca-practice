// Platform layer (Bicep): provisioned once, shared by every environment.
// The Bicep counterpart of infra/platform (Terraform).
//
// Subscription scope, because this layer creates the resource group itself
// (Terraform's azurerm_resource_group). Everything inside the group is in
// platform.bicep, deployed as a module scoped to it.
//
// This is a separate, parallel stack to the Terraform one, with its own
// names (project "inspire-bcp"), not a second description of the same
// resources. Bicep keeps no state, so two tools owning one resource would
// just overwrite each other.

targetScope = 'subscription'

@description('Short project/app name used in resource naming. Must match the environment layer\'s project param, which looks the platform resources up by name.')
param project string

@description('Azure region.')
param location string

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${project}'
  location: location
  tags: {
    purpose: 'pipeline-test'
  }
}

module platform 'platform.bicep' = {
  name: 'platform-resources'
  scope: rg
  params: {
    project: project
    location: rg.location
  }
}

output resource_group_name string = rg.name
output acr_login_server string = platform.outputs.acr_login_server
output container_app_environment_name string = platform.outputs.container_app_environment_name
