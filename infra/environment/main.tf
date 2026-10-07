# Environment layer: one Container App (plus its identity and AcrPull role
# assignment), applied once per environment into the shared platform.
# State keys: aca-practice-staging.tfstate, aca-practice-production.tfstate
#
# The platform resources are looked up by name rather than created here, so
# the platform layer (../platform) has to be applied first.

data "azurerm_resource_group" "platform" {
  name = "rg-${var.project}"
}

data "azurerm_container_registry" "platform" {
  name                = replace("acr${var.project}", "-", "")
  resource_group_name = data.azurerm_resource_group.platform.name
}

data "azurerm_container_app_environment" "platform" {
  name                = "cae-${var.project}"
  resource_group_name = data.azurerm_resource_group.platform.name
}

resource "azurerm_user_assigned_identity" "aca" {
  name                = "id-${var.project}-${var.environment}-aca"
  resource_group_name = data.azurerm_resource_group.platform.name
  location            = data.azurerm_resource_group.platform.location
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = data.azurerm_container_registry.platform.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aca.principal_id
}

resource "azurerm_container_app" "this" {
  name                         = "aca-app-${var.environment}"
  resource_group_name          = data.azurerm_resource_group.platform.name
  container_app_environment_id = data.azurerm_container_app_environment.platform.id
  # Azure sets this on every app in a workload-profile environment. Left
  # undeclared, Terraform plans to null it on every run (a permanent diff).
  workload_profile_name = "Consumption"
  revision_mode         = "Single"

  tags = {
    purpose = "pipeline-test"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aca.id]
  }

  registry {
    server   = data.azurerm_container_registry.platform.login_server
    identity = azurerm_user_assigned_identity.aca.id
  }

  template {
    container {
      name   = var.project
      image  = var.container_image
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        # Wire this via settings.py os.environ.get(...), not a hardcoded
        # list, per the DisallowedHost gotcha from the practice build.
        name  = "DJANGO_ALLOWED_HOSTS"
        value = "*" # tighten to the real hostname once DNS cutover happens
      }

      # Key Vault access: the app reads the secret at runtime with
      # DefaultAzureCredential (see core/keyvault.py). These are addresses and
      # an identity pointer, not secrets. AZURE_CLIENT_ID is what tells the
      # credential which user-assigned identity to use.
      env {
        name  = "KEY_VAULT_URL"
        value = azurerm_key_vault.this.vault_uri
      }

      env {
        name  = "KEY_VAULT_SECRET_NAME"
        value = var.key_vault_secret_name
      }

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.aca.client_id
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8000

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  lifecycle {
    ignore_changes = [
      # App deploy pipeline (separate workflow) owns the running image tag
      # after the first apply. Terraform shouldn't fight it on every plan.
      template[0].container[0].image,
    ]
  }

  # The registry block needs the identity to already hold AcrPull.
  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets_user,
  ]
}
