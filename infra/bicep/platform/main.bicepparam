using './main.bicep'

// "inspire-bcp", not the Terraform stack's "inspire-app1": the Bicep stack
// is a separate set of resources (see main.bicep). Kept short because the
// environment layer's Key Vault name is built from it and capped at 24 chars.
param project = 'inspire-bcp'
// UK West, not the Terraform stack's UK South: this subscription allows one
// Container Apps environment per region, and Terraform's already has UK South.
// Everything in the environment layer takes its region from the resource group.
param location = 'ukwest'
