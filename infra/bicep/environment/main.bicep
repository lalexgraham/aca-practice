// Environment layer (Bicep): one Container App, its identity, AcrPull role
// assignment and Key Vault, deployed once per environment into the shared
// platform. The Bicep counterpart of infra/environment (Terraform).
// Parameter files: staging.bicepparam, production.bicepparam
//
// Deployed at resource group scope into the platform layer's group, whose
// resources are looked up by name with `existing` (Terraform's data sources),
// so the platform layer (../platform) has to be deployed first.

@description('Short project/app name. Must match the platform layer\'s project param, it\'s how this layer finds the shared ACR, Log Analytics workspace and Container Apps Environment.')
param project string

@description('Which Container App this deployment manages. Not to be confused with the GitHub Environments (infra-apply, infra-apply-production), which are approval gates only.')
@allowed([
  'staging'
  'production'
])
param environment string

// Bicep has no lifecycle ignore_changes, so every deployment sets the image.
// The workflows pass the image the app is currently running (from
// `az containerapp show`), so a deploy never resets it. This default is only
// used when the app doesn't exist yet.
@description('Container image to run. Pass the currently running image on redeploys.')
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Name of the demo secret the app reads from this environment\'s Key Vault. Must match the name scripts/set-keyvault-secret.sh writes.')
param keyVaultSecretName string = 'demo-secret'

var location = resourceGroup().location

// Built-in role definition IDs (the same in every tenant).
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

// --- platform resources, looked up by name ---

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: replace('acr${project}', '-', '')
}

resource cae 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: 'cae-${project}'
}

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: 'log-${project}'
}

// --- identity and registry access ---

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${project}-${environment}-aca'
  location: location
}

// Role assignment names must be GUIDs, and deterministic so redeploys update
// the same assignment rather than failing on a duplicate.
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, identity.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: identity.properties.principalId
    // Set explicitly so the assignment doesn't fail while the new identity
    // is still replicating in Entra.
    principalType: 'ServicePrincipal'
  }
}

// --- Key Vault (keyvault.tf) ---
// One vault per environment, so staging's identity can never read
// production's secrets (and vice versa). This template owns the vault and who
// can read it, never a secret VALUE: values are set out of band with
// scripts/set-keyvault-secret.sh.

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  // 3-24 chars, globally unique. uniqueString() of the subscription stands in
  // for Terraform's md5 hash, so the names differ from the Terraform stack's.
  name: 'kv-${replace(project, '-', '')}-${take(environment, 4)}-${take(uniqueString(subscription().id), 4)}'
  location: location
  tags: {
    purpose: 'pipeline-test'
    environment: environment // set-keyvault-secret.sh finds the vault by this tag
  }
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    // Azure RBAC for access, not legacy access policies.
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    // Production only, as in Terraform. ARM refuses an explicit false here
    // (purge protection can't be turned off), so staging leaves it unset.
    enablePurgeProtection: environment == 'production' ? true : null
  }
}

// Read-only at the data plane, scoped to this one vault, granted to this
// environment's own identity only.
resource kvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, identity.id, keyVaultSecretsUserRoleId)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Audit trail: every secret read/write/delete lands in the platform's Log
// Analytics workspace.
resource kvAudit 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'audit-to-log-analytics'
  scope: kv
  properties: {
    workspaceId: law.id
    logs: [
      {
        category: 'AuditEvent'
        enabled: true
      }
    ]
  }
}

// --- the Container App ---

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'aca-app-${environment}'
  location: location
  tags: {
    purpose: 'pipeline-test'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    environmentId: cae.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8000
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: identity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: project
          image: containerImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            {
              name: 'DJANGO_ALLOWED_HOSTS'
              value: '*' // tighten to the real hostname once DNS cutover happens
            }
            // Key Vault access: addresses and an identity pointer, not
            // secrets. AZURE_CLIENT_ID tells DefaultAzureCredential which
            // user-assigned identity to use (core/keyvault.py).
            {
              name: 'KEY_VAULT_URL'
              value: kv.properties.vaultUri
            }
            {
              name: 'KEY_VAULT_SECRET_NAME'
              value: keyVaultSecretName
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: identity.properties.clientId
            }
          ]
        }
      ]
    }
  }
  // The registry block needs the identity to already hold AcrPull. Nothing
  // in the app references the role assignments, so the order is explicit.
  dependsOn: [
    acrPull
    kvSecretsUser
  ]
}

output container_app_name string = app.name

@description('Stable ingress FQDN of the Container App, not the per-revision one.')
output container_app_fqdn string = app.properties.configuration.ingress.fqdn

@description('Client ID of the user-assigned identity this environment\'s Container App uses to pull from ACR.')
output container_app_identity_client_id string = identity.properties.clientId

output key_vault_name string = kv.name
output key_vault_uri string = kv.properties.vaultUri
