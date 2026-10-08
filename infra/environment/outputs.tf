output "container_app_name" {
  value = azurerm_container_app.this.name
}

output "container_app_fqdn" {
  description = "Stable ingress FQDN of the Container App. Not latest_revision_fqdn, which changes on every deploy and showed up as drift in every plan."
  value       = azurerm_container_app.this.ingress[0].fqdn
}

output "container_app_identity_client_id" {
  description = "Client ID of the user-assigned identity this environment's Container App uses to pull from ACR."
  value       = azurerm_user_assigned_identity.aca.client_id
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}
