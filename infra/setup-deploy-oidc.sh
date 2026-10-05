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
#   5. Grants AcrPush on the ACR and Container Apps Contributor on both
#      container apps, staging and production (each skipped with a reminder
#      if Terraform hasn't created it yet).
#   6. Sets the AZURE_CLIENT_ID, AZURE_TENANT_ID and AZURE_SUBSCRIPTION_ID
#      GitHub repo secrets used by deploy.yml.
#
# Run from anywhere, requires: az login and gh auth login already done, curl.

set -euo pipefail

# --- edit these if your repo/resource names differ ---
GITHUB_USERNAME="lalexgraham"
REPO_NAME="aca-practice"
APP_DISPLAY_NAME="github-aca-practice-deploy"
RESOURCE_GROUP="rg-inspire-app1"
ACR_NAME="acrinspireapp1"
CONTAINER_APP_NAMES=("aca-app-staging" "aca-app-production")
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

# deploy.yml only triggers on push to main, and none of its jobs that log
# in to Azure has an `environment:` block (the production approval gate is
# its own job, approve-production, which never touches Azure), so unlike
# terraform-apply.yml (which needed both a ref subject and an environment
# subject, see setup-terraform-oidc.sh) this only ever needs the one
# subject below. GitHub's "immutable subject" format embeds the
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

echo "Done creating app registration and federated credential. Granting roles and setting GitHub secrets..."

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

# Use the SP object ID + principal type so role assignments don't fail
# while the new service principal is still replicating in Entra.
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

# Just enough RBAC for what deploy.yml actually does - push an image and
# update the running revision - rather than a blanket Contributor grant.
# Both resources are created by Terraform, so skip with a reminder if this
# runs before the first terraform apply.
echo "Granting AcrPush on the ACR..."
if ACR_ID=$(az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" --query id -o tsv 2>/dev/null); then
  az role assignment create \
    --assignee-object-id "$SP_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role AcrPush \
    --scope "$ACR_ID"
else
  echo "   ACR ${ACR_NAME} doesn't exist yet. After the first terraform apply, run:"
  echo "   az role assignment create --assignee-object-id $SP_OBJECT_ID --assignee-principal-type ServicePrincipal --role AcrPush --scope \"\$(az acr show -n $ACR_NAME -g $RESOURCE_GROUP --query id -o tsv)\""
fi

# One identity covers both apps: the staging/production separation is
# enforced by the approval gate in deploy.yml, not by Azure RBAC.
for CONTAINER_APP_NAME in "${CONTAINER_APP_NAMES[@]}"; do
  echo "Granting Container Apps Contributor on ${CONTAINER_APP_NAME}..."
  if CONTAINER_APP_ID=$(az containerapp show -n "$CONTAINER_APP_NAME" -g "$RESOURCE_GROUP" --query id -o tsv 2>/dev/null); then
    az role assignment create \
      --assignee-object-id "$SP_OBJECT_ID" \
      --assignee-principal-type ServicePrincipal \
      --role "Container Apps Contributor" \
      --scope "$CONTAINER_APP_ID"
  else
    echo "   Container app ${CONTAINER_APP_NAME} doesn't exist yet. After the first terraform apply, run:"
    echo "   az role assignment create --assignee-object-id $SP_OBJECT_ID --assignee-principal-type ServicePrincipal --role \"Container Apps Contributor\" --scope \"\$(az containerapp show -n $CONTAINER_APP_NAME -g $RESOURCE_GROUP --query id -o tsv)\""
  fi
done

# AZURE_CLIENT_ID is a *different* secret to AZURE_CLIENT_ID_TERRAFORM -
# deploy.yml and the Terraform workflows each authenticate as their own app
# registration. Tenant and subscription are shared by both, setting them
# again is harmless (gh overwrites with the same value).
echo "Setting AZURE_CLIENT_ID, AZURE_TENANT_ID and AZURE_SUBSCRIPTION_ID GitHub secrets..."
gh secret set AZURE_CLIENT_ID --repo "${GITHUB_USERNAME}/${REPO_NAME}" --body "$APP_ID"
gh secret set AZURE_TENANT_ID --repo "${GITHUB_USERNAME}/${REPO_NAME}" --body "$TENANT_ID"
gh secret set AZURE_SUBSCRIPTION_ID --repo "${GITHUB_USERNAME}/${REPO_NAME}" --body "$SUBSCRIPTION_ID"

echo ""
echo "Done."

# UNDO
# # get the appId if you don't have it noted
# APP_ID=$(az ad app list --display-name "github-aca-practice-deploy" --query "[0].appId" -o tsv)

# # remove the scoped role assignments first, while the SP still exists to
# # resolve them (deleting the app orphans these rather than reliably
# # cleaning them up). Only needed if the ACR / container apps still exist -
# # terraform destroy removes their role assignments with them.
# az role assignment delete \
#   --assignee "$APP_ID" \
#   --role AcrPush \
#   --scope "$(az acr show -n acrinspireapp1 -g rg-inspire-app1 --query id -o tsv)"

# for app in aca-app-staging aca-app-production; do
#   az role assignment delete \
#     --assignee "$APP_ID" \
#     --role "Container Apps Contributor" \
#     --scope "$(az containerapp show -n "$app" -g rg-inspire-app1 --query id -o tsv)"
# done

# # confirm nothing is left (should print an empty table)
# az role assignment list --assignee "$APP_ID" --all -o table

# # this removes the app registration, its service principal, and the
# # federated credential in one go
# az ad app delete --id "$APP_ID"

# # remove the GitHub secret that pointed at the deleted app
# gh secret delete AZURE_CLIENT_ID --repo lalexgraham/aca-practice

# # AZURE_TENANT_ID and AZURE_SUBSCRIPTION_ID are shared with the Terraform
# # workflows - only delete these if you're also undoing setup-terraform-oidc.sh
# gh secret delete AZURE_TENANT_ID --repo lalexgraham/aca-practice
# gh secret delete AZURE_SUBSCRIPTION_ID --repo lalexgraham/aca-practice
