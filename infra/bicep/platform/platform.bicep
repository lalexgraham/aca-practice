// The platform layer's resources, deployed into the resource group main.bicep
// creates. Nothing here is per environment on purpose: staging and production
// both run inside this one Container Apps Environment.

param project string
param location string

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: replace('acr${project}', '-', '')
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false // pull via managed identity, not admin creds
  }
}

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${project}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource cae 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${project}'
  location: location
  properties: {
    // Terraform's log_analytics_workspace_id does this wiring for you; in
    // ARM the environment takes the workspace's ID and key directly.
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

output acr_login_server string = acr.properties.loginServer
output container_app_environment_name string = cae.name
