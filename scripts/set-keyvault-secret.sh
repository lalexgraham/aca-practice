#!/usr/bin/env zsh
# Prompts for a secret value and stores it in an environment's Azure Key
# Vault, for the Django app to read at /secret/ (core/keyvault.py).
#
# Usage: bash scripts/set-keyvault-secret.sh <staging|production>
# Run it from the repo root. It prompts for the value so it never lands in shell history.
#
# The vault itself is created by Terraform (infra/environment/keyvault.tf);
# this script only writes the secret VALUE, deliberately outside Terraform so
# the value never lands in the state file.
#
# What this script does, in order:
#   1. Finds the environment's vault by its `environment` tag.
#   2. Makes sure you hold "Key Vault Secrets Officer" on it. Being Owner of
#      the subscription is NOT enough, the vault uses Azure RBAC for its data
#      plane, so management and data access are separate permissions.
#   3. Asks for the value with no echo, and again to confirm. It is never
#      taken as an argument (shell history, `ps`) or printed.
#   4. Stores it with an expiry date and a content type. Writing to an
#      existing name creates a new version, the old one is kept, which is how
#      you rotate.
#
# Run from anywhere, requires: az login already done.

set -euo pipefail

# --- edit these if your names differ ---
RESOURCE_GROUP="rg-inspire-app1"
SECRET_NAME="demo-secret"     # must match var.key_vault_secret_name
EXPIRY_DAYS=90
# ---------------------------------------

ENVIRONMENT="${1:-}"
if [[ "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "production" ]]; then
  echo "Usage: $0 <staging|production>" >&2
  exit 1
fi

VAULT_NAME=$(az keyvault list -g "$RESOURCE_GROUP" \
  --query "[?tags.environment=='${ENVIRONMENT}'].name | [0]" -o tsv)
if [[ -z "$VAULT_NAME" ]]; then
  echo "No Key Vault tagged environment=${ENVIRONMENT} in ${RESOURCE_GROUP}. Has terraform apply run for ${ENVIRONMENT}?" >&2
  exit 1
fi
echo "Vault: $VAULT_NAME"

VAULT_ID=$(az keyvault show -n "$VAULT_NAME" -g "$RESOURCE_GROUP" --query id -o tsv)
MY_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

# Least privilege for the human too: Secrets Officer (read/write secrets) on
# this one vault, not a subscription-wide role.
if [[ -z "$(az role assignment list --assignee "$MY_OBJECT_ID" --scope "$VAULT_ID" \
      --role "Key Vault Secrets Officer" --query "[0].id" -o tsv)" ]]; then
  echo "Granting you Key Vault Secrets Officer on ${VAULT_NAME}..."
  az role assignment create \
    --assignee-object-id "$MY_OBJECT_ID" \
    --assignee-principal-type User \
    --role "Key Vault Secrets Officer" \
    --scope "$VAULT_ID" >/dev/null
fi

echo "Use a dummy value for this demo: the app prints it on a public page."
# Prompt with printf and a plain `read -rs` so this works under both bash and
# zsh (zsh's `read "?prompt" var` form is a syntax error in bash).
printf 'Secret value for %s: ' "$SECRET_NAME"; read -rs SECRET_VALUE; echo
printf 'Confirm: '; read -rs SECRET_CONFIRM; echo
if [[ -z "$SECRET_VALUE" || "$SECRET_VALUE" != "$SECRET_CONFIRM" ]]; then
  echo "Empty, or the two values didn't match. Nothing stored." >&2
  exit 1
fi
unset SECRET_CONFIRM

# macOS date first, GNU date as the fallback
EXPIRES=$(date -u -v+${EXPIRY_DAYS}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "+${EXPIRY_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)

# The value goes in on stdin (--file /dev/stdin), not --value, so it never
# appears in the process list. A new role assignment can take a few minutes
# to reach the vault's data plane, hence the retry.
for attempt in 1 2 3 4 5 6 7 8; do
  if SECRET_ID=$(printf '%s' "$SECRET_VALUE" | az keyvault secret set \
      --vault-name "$VAULT_NAME" --name "$SECRET_NAME" \
      --file /dev/stdin --encoding utf-8 \
      --content-type "text/plain" --expires "$EXPIRES" \
      --query id -o tsv 2>/dev/null); then
    unset SECRET_VALUE
    echo "Stored ${SECRET_NAME} in ${VAULT_NAME}, expires ${EXPIRES}"
    echo "Version: ${SECRET_ID}"
    echo ""
    echo "Done. The app picks up the new value within a minute (see CACHE_SECONDS in core/keyvault.py)."
    exit 0
  fi
  echo "   not permitted yet (role assignments take a few minutes to propagate), retrying in 20s... (${attempt}/8)"
  sleep 20
done

unset SECRET_VALUE
echo "Could not write the secret. Check the Key Vault Secrets Officer assignment and your network access to the vault." >&2
exit 1

# VERIFY (metadata only, this prints no value)
# az keyvault secret show --vault-name <vault> --name demo-secret \
#   --query "{id:id, enabled:attributes.enabled, expires:attributes.expires}" -o json
# # then browse to https://<container-app-fqdn>/secret/

# ROTATE
# # run the script again with the new value: it adds a new version, and the
# # app picks it up within CACHE_SECONDS. The old version stays available.

# UNDO
# # soft-deletes the secret (recoverable for 90 days)
# az keyvault secret delete --vault-name <vault> --name demo-secret
# # recover it
# az keyvault secret recover --vault-name <vault> --name demo-secret
