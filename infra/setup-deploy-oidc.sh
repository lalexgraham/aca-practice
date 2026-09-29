#!/usr/bin/env zsh
# Creates the deploy-pipeline Entra app registration and its federated
# credential, for .github/workflows/deploy.yml (push to main).
#
# This is a separate, lower-privilege app registration to the Terraform one
# (setup-terraform-oidc.sh), deliberately: deploy.yml only ever needs to
# push an image to ACR and point the container app at it, never to create,
# destroy, or manage IAM on infrastructure. Giving it its own identity means
# a compromised/broken deploy workflow can't touch anything Terraform owns.
#
# What this script does, in order:
#   1. Looks up your GitHub owner/repo IDs (needed for the federated
#      credential's subject - see the OIDC note below).
#   2. Creates an Entra "app registration": an identity Azure AD can
#      recognise, roughly analogous to a service account.
#   3. Creates a "service principal" for that app: the actual security
#      principal Azure RBAC grants roles to (the app registration and the
#      service principal are two different objects; you need both).
#   4. Creates a "federated credential" on the app: a trust rule that says
#      "accept OIDC tokens from GitHub Actions, but only for this exact
#      repo and branch". This is what lets deploy.yml authenticate with
#      no stored password/secret - GitHub mints a short-lived token per
#      run, Azure checks it against this rule instead of a stored secret.
#
# Run from anywhere, requires: az login already done, curl.

set -euo pipefail

# --- edit these if your repo/resource names differ ---
GITHUB_USERNAME="lalexgraham"
REPO_NAME="aca-practice"
APP_DISPLAY_NAME="github-aca-practice-deploy"
RESOURCE_GROUP="rg-inspire-app1-dev"
ACR_NAME="acrinspireapp1dev"
CONTAINER_APP_NAME="ca-inspire-app1-dev"
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

# deploy.yml has no `environment:` block and only triggers on push to main,
# so unlike terraform-apply.yml (which needed both a ref subject and an
# environment subject, see setup-terraform-oidc.sh) this only ever needs
# the one subject below. GitHub's "immutable subject" format embeds the
# permanent owner/repo IDs rather than their current names, so it's this
# @<id> form or authentication fails with AADSTS700213.
DEPLOY_SUBJECT="repo:${GITHUB_USERNAME}@${OWNER_ID}/${REPO_NAME}@${REPO_ID}:ref:refs/heads/main"

echo "Creating federated credential for deploy.yml (push to main)..."
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters "{
    \"name\": \"github-deploy-main\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${DEPLOY_SUBJECT}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"

echo ""
echo "Done. Next steps (not automated by this script, deliberately, since they're one-time and worth doing by hand):"
echo "  1. Grant just enough RBAC to do what deploy.yml actually does - push an image"
echo "     and update the running revision - rather than a blanket Contributor grant:"
echo "     az role assignment create --assignee $APP_ID --role AcrPush --scope \"\$(az acr show -n $ACR_NAME -g $RESOURCE_GROUP --query id -o tsv)\""
echo "     az role assignment create --assignee $APP_ID --role \"Container Apps Contributor\" --scope \"\$(az containerapp show -n $CONTAINER_APP_NAME -g $RESOURCE_GROUP --query id -o tsv)\""
echo "  2. Add AZURE_CLIENT_ID = $APP_ID as a GitHub repo secret (this is a *different*"
echo "     secret to AZURE_CLIENT_ID_TERRAFORM - deploy.yml and the Terraform workflows"
echo "     each authenticate as their own app registration)."
echo "  3. AZURE_TENANT_ID and AZURE_SUBSCRIPTION_ID should already exist as repo secrets"
echo "     (same tenant/subscription as the Terraform app) - confirm under Settings >"
echo "     Secrets and variables > Actions rather than assuming, add them if missing."
echo ""

# UNDO
# # get the appId if you don't have it noted
# APP_ID=$(az ad app list --display-name "$APP_DISPLAY_NAME" --query "[0].appId" -o tsv)
#
# # remove the scoped role assignments explicitly first
# # (deleting the app orphans these rather than reliably cleaning them up)
# az role assignment delete --assignee "$APP_ID" --role AcrPush \
#   --scope "$(az acr show -n acrinspireapp1dev -g rg-inspire-app1-dev --query id -o tsv)"
# az role assignment delete --assignee "$APP_ID" --role "Container Apps Contributor" \
#   --scope "$(az containerapp show -n ca-inspire-app1-dev -g rg-inspire-app1-dev --query id -o tsv)"
#
# # this removes the app registration, its service principal, and the
# # federated credential in one go
# az ad app delete --id "$APP_ID"
