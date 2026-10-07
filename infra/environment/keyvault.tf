# One Key Vault per environment, so staging's identity can never read
# production's secrets (and vice versa). Terraform owns the vault and who can
# read it; it deliberately never owns a secret VALUE, because anything set
# through Terraform ends up in plaintext in the state file. Values are set
# out of band with infra/set-keyvault-secret.sh.

data "azurerm_client_config" "current" {}

data "azurerm_log_analytics_workspace" "platform" {
  name                = "log-${var.project}"
  resource_group_name = data.azurerm_resource_group.platform.name
}

resource "azurerm_key_vault" "this" {
  # 3-24 chars, globally unique, alphanumerics and hyphens. The short hash of
  # the subscription ID makes a name collision with someone else's vault
  # unlikely without a random provider.
  name                = "kv-${replace(var.project, "-", "")}-${substr(var.environment, 0, 4)}-${substr(md5(data.azurerm_client_config.current.subscription_id), 0, 4)}"
  resource_group_name = data.azurerm_resource_group.platform.name
  location            = data.azurerm_resource_group.platform.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Azure RBAC for access, not legacy access policies: one permission model
  # shared with the rest of Azure, auditable, and assignable per secret.
  rbac_authorization_enabled = true

  # Soft delete is always on (90 days). Purge protection blocks anyone,
  # including an admin, from permanently deleting a vault or secret inside
  # that window. It can't be switched off once on, and it means a destroyed
  # vault's name is locked for 90 days, so it's production only; staging can
  # be destroyed and rebuilt freely (README section 9).
  soft_delete_retention_days = 90
  purge_protection_enabled   = var.environment == "production"

  tags = {
    purpose     = "pipeline-test"
    environment = var.environment # set-keyvault-secret.sh finds the vault by this tag
  }
}

# Read-only at the data plane: the app can get a secret's value but can't
# list-and-rewrite, delete or create. Scoped to this one vault, granted to
# the environment's own identity only.
resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.aca.principal_id
}

# Audit trail: every secret read/write/delete, with the caller's identity,
# lands in the platform's Log Analytics workspace.
resource "azurerm_monitor_diagnostic_setting" "kv_audit" {
  name                       = "audit-to-log-analytics"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.platform.id

  enabled_log {
    category = "AuditEvent"
  }
}
