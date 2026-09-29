output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "container_app_fqdn" {
  value = azurerm_container_app.this.latest_revision_fqdn
}

output "container_app_identity_client_id" {
  description = "Federate this identity's client ID against GitHub OIDC for the app deploy pipeline's ACR push/ACA update steps."
  value       = azurerm_user_assigned_identity.aca.client_id
}
