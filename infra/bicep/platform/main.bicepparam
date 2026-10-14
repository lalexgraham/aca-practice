using './main.bicep'

// "inspire-bcp", not the Terraform stack's "inspire-app1": the Bicep stack
// is a separate set of resources (see main.bicep). Kept short because the
// environment layer's Key Vault name is built from it and capped at 24 chars.
param project = 'inspire-bcp'
param location = 'uksouth'
