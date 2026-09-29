#!/usr/bin/env zsh
# Creates the Terraform-specific Entra app registration and its two
# federated credentials (plan on PR, apply on push to main).
# Run from anywhere, requires: az login already done, curl.

set -euo pipefail

# --- edit these three ---
GITHUB_USERNAME="lalexgraham"
REPO_NAME="aca-practice"
APP_DISPLAY_NAME="github-aca-practice-terraform"
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

echo ""
echo "Done. Next steps (not automated by this script, deliberately, since they're one-time and worth doing by hand):"
echo "  1. Grant Contributor at subscription scope (Terraform creates the resource group itself):"
echo "     az role assignment create --assignee $APP_ID --role Contributor --scope \"/subscriptions/\$(az account show --query id -o tsv)\""
echo "  2. Add AZURE_CLIENT_ID_TERRAFORM = $APP_ID as a GitHub repo secret."
echo "  3. AZURE_TENANT_ID and AZURE_SUBSCRIPTION_ID are already set from the deploy pipeline, no change needed."
echo "  4. Grant User Access Administrator on the ACR so Terraform can create the AcrPull role assignment"
echo "     (azurerm_role_assignment.acr_pull in main.tf). The ACR doesn't exist yet at this point, so this"
echo "     can't be run until after the first terraform apply creates it - run it then, or if apply fails"
echo "     with 'AuthorizationFailed ... roleAssignments/write':"
echo "     az role assignment create --assignee $APP_ID --role \"User Access Administrator\" --scope \"\$(az acr show -n <acr-name> -g <resource-group> --query id -o tsv)\""
echo ""
echo "Granting Storage Blob Data Contributor role to the app registration for the tfstate storage account"
echo "az role assignment create --assignee 9ee70454-efd4-45c0-85ed-305f146937b2 --role "Storage Blob Data Contributor" --scope "$(az storage account show -g rg-tfstate -n tfstate19271 --query id -o tsv)"

# UNDO
# # get the appId if you don't have it noted
# APP_ID=$(az ad app list --display-name "github-aca-practice-terraform" --query "[0].appId" -o tsv)

# # remove the subscription-scope role assignment explicitly first
# # (deleting the app orphans this rather than reliably cleaning it up)
# az role assignment delete \
#   --assignee "$APP_ID" \
#   --role Contributor \
#   --scope "/subscriptions/$(az account show --query id -o tsv)"

# # this removes the app registration, its service principal, and both
# # federated credentials in one go
# az ad app delete --id "$APP_ID"