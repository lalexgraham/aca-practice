#!/usr/bin/env zsh
# Creates the Terraform-specific Entra app registration and its three
# federated credentials (1 for plan on PR, 2 for apply on push to main).
#
# What this script does, in order:
#   1. Looks up your GitHub owner/repo IDs (needed for the federated
#      credentials' subjects, which use GitHub's immutable @<id> format).
#   2. Creates an Entra "app registration": an identity Azure AD can
#      recognise, roughly analogous to a service account.
#   3. Creates a "service principal" for that app: the actual security
#      principal Azure RBAC grants roles to (the app registration and the
#      service principal are two different objects; you need both).
#   4. Creates three "federated credentials" on the app: trust rules that
#      say "accept OIDC tokens from GitHub Actions, but only for this exact
#      repo and trigger". One for terraform-plan.yml on pull requests, and
#      two for terraform-apply.yml (push to main, and the infra-apply
#      environment). No stored password/secret - GitHub mints a short-lived
#      token per run, Azure checks it against these rules instead.
#   5. Grants Contributor at subscription scope, since Terraform creates the
#      resource group itself and so needs rights above it.
#   6. Grants Storage Blob Data Contributor on the tfstate storage account,
#      so Terraform can read, write and lease-lock the state file.
#   7. Sets the AZURE_CLIENT_ID_TERRAFORM GitHub repo secret used by the
#      Terraform workflows (AZURE_TENANT_ID and AZURE_SUBSCRIPTION_ID are
#      set by setup-deploy-oidc.sh).
#   8. Grants User Access Administrator on the ACR, so Terraform can create
#      the AcrPull role assignment (azurerm_role_assignment.acr_pull in
#      main.tf). Skipped with a reminder if the ACR doesn't exist yet, which
#      it won't until the first terraform apply.
#
# Run from anywhere, requires: az login and gh auth login already done, curl.

set -euo pipefail

# --- edit these three ---
GITHUB_USERNAME="lalexgraham"
REPO_NAME="aca-practice"
APP_DISPLAY_NAME="github-aca-practice-terraform"

TF_ENVIRONMENT="dev"                      # must match -var="environment=..."
TFSTATE_RG="rg-tfstate"
TFSTATE_SA="tfstate19271"
PROJECT="inspire-app1"                    # must match var.project default
APP_RG="rg-${PROJECT}-${TF_ENVIRONMENT}"
ACR_NAME="acr${PROJECT//-/}${TF_ENVIRONMENT}"

# -------------------------

echo "Fetching GitHub owner and repo IDs (public API, no auth needed)..."
OWNER_ID=$(curl -s "https://api.github.com/users/${GITHUB_USERNAME}" | grep '"id"' | head -1 | grep -o '[0-9]\+')
REPO_ID=$(curl -s "https://api.github.com/repos/${GITHUB_USERNAME}/${REPO_NAME}" | grep '"id"' | head -1 | grep -o '[0-9]\+')

if [[ -z "$OWNER_ID" || -z "$REPO_ID" ]]; then
  echo "Could not resolve owner/repo IDs, check GITHUB_USERNAME and REPO_NAME." >&2
  exit 1
fi

echo "Owner ID: $OWNER_ID"
echo "Repo ID:  $REPO_ID"

echo "Creating app registration: $APP_DISPLAY_NAME"
APP_ID=$(az ad app create --display-name "$APP_DISPLAY_NAME" --query appId -o tsv)
echo "App (client) ID: $APP_ID"

echo "Creating service principal..."
az ad sp create --id "$APP_ID" >/dev/null

APPLY_SUBJECT="repo:${GITHUB_USERNAME}@${OWNER_ID}/${REPO_NAME}@${REPO_ID}:ref:refs/heads/main"
APPLY_ENV_SUBJECT="repo:${GITHUB_USERNAME}@${OWNER_ID}/${REPO_NAME}@${REPO_ID}:environment:infra-apply"
PLAN_SUBJECT="repo:${GITHUB_USERNAME}@${OWNER_ID}/${REPO_NAME}@${REPO_ID}:pull_request"

echo "Creating federated credential for terraform-apply.yml (push to main)..."
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters "{
    \"name\": \"github-tf-apply-main\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${APPLY_SUBJECT}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"

echo "Creating federated credential for terraform-apply.yml (infra-apply environment)..."
# terraform-apply.yml's job sets `environment: infra-apply`, which changes
# the OIDC subject GitHub issues from ref:refs/heads/main to
# environment:infra-apply. Both credentials are needed: this one for the
# environment-scoped subject, the ref one above is harmless to keep.
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters "{
    \"name\": \"github-tf-apply-env-infra-apply\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${APPLY_ENV_SUBJECT}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"

echo "Creating federated credential for terraform-plan.yml (pull request)..."
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters "{
    \"name\": \"github-tf-plan-pr\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${PLAN_SUBJECT}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"

echo "Done creating app registration and federated credentials. Now grant the app registration the necessary roles on the subscription and storage account. And push secrets to GitHub"

SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Use the SP object ID + principal type so role assignments don't fail
# while the new service principal is still replicating in Entra.

SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

echo "Granting Contributor at subscription scope..."

az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role Contributor \
  --scope "/subscriptions/${SUBSCRIPTION_ID}"

echo "Granting Storage Blob Data Contributor on the tfstate storage account..."

az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$(az storage account show -g "$TFSTATE_RG" -n "$TFSTATE_SA" --query id -o tsv)"

echo "Setting AZURE_CLIENT_ID_TERRAFORM GitHub secret..."

gh secret set AZURE_CLIENT_ID_TERRAFORM \
  --repo "${GITHUB_USERNAME}/${REPO_NAME}" \
  --body "$APP_ID"

# AZURE_TENANT_ID and AZURE_SUBSCRIPTION_ID are already set by the deploy pipeline setup.

echo "Granting User Access Administrator on the ACR (for azurerm_role_assignment.acr_pull)..."

if ACR_ID=$(az acr show -n "$ACR_NAME" -g "$APP_RG" --query id -o tsv 2>/dev/null); then
  az role assignment create \
    --assignee-object-id "$SP_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "User Access Administrator" \
    --scope "$ACR_ID"
else
  echo "   ACR ${ACR_NAME} doesn't exist yet. After the first terraform apply, run:"
  echo "   az role assignment create --assignee-object-id $SP_OBJECT_ID --assignee-principal-type ServicePrincipal --role \"User Access Administrator\" --scope \"\$(az acr show -n $ACR_NAME -g $APP_RG --query id -o tsv)\""
fi

echo ""
echo "Done."

# UNDO
# # get the appId if you don't have it noted
# APP_ID=$(az ad app list --display-name "github-aca-practice-terraform" --query "[0].appId" -o tsv)
# SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# # remove role assignments first, while the SP still exists to resolve them
# # (deleting the app orphans these rather than reliably cleaning them up)
# az role assignment delete \
#   --assignee "$APP_ID" \
#   --role Contributor \
#   --scope "/subscriptions/${SUBSCRIPTION_ID}"

# az role assignment delete \
#   --assignee "$APP_ID" \
#   --role "Storage Blob Data Contributor" \
#   --scope "$(az storage account show -g rg-tfstate -n tfstate19271 --query id -o tsv)"

# # only needed if the ACR still exists (terraform destroy removes the ACR
# # and its role assignments with it)
# az role assignment delete \
#   --assignee "$APP_ID" \
#   --role "User Access Administrator" \
#   --scope "$(az acr show -n acrinspireapp1dev -g rg-inspire-app1-dev --query id -o tsv)"

# # this removes the app registration, its service principal, and all three
# # federated credentials in one go
# az ad app delete --id "$APP_ID"

# # remove the GitHub secret that pointed at the deleted app
# gh secret delete AZURE_CLIENT_ID_TERRAFORM --repo lalexgraham/aca-practice
