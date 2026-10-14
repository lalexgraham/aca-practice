#!/usr/bin/env bash
# Lists the resources a deployment stack would DELETE on its next update:
# ones the stack currently manages that the new template no longer contains.
# Prints one lowercased resource ID per line, nothing if there are none.
#
# `az stack ... create` deletes unmanaged resources (--action-on-unmanage
# deleteResources) but, unlike `az deployment ... what-if`, there is no
# preview for it. This fills that gap: what-if lists every resource the
# template resolves to (including NoChange ones), the stack lists every
# resource it has deployed, and the difference is what would be deleted.
#
# Usage: stack-deletions.sh <sub|group> <stack-name> <whatif.json> [resource-group]
#   whatif.json is the output of `az deployment ... what-if --no-pretty-print`.
# A stack that doesn't exist yet has nothing to delete.

set -euo pipefail

scope="${1:?sub|group}"
stack="${2:?stack name}"
whatif="${3:?what-if json}"
rg="${4:-}"

err=$(mktemp)
trap 'rm -f "$err"' EXIT

if [ "$scope" = "sub" ]; then
  show=(az stack sub show --name "$stack")
else
  show=("az" stack group show --name "$stack" --resource-group "$rg")
fi

if ! current=$("${show[@]}" --query "resources[].id" -o tsv 2>"$err"); then
  # First deployment: no stack yet, so nothing can be deleted. Anything else
  # (auth, permissions) is a real failure and must not read as "no deletions".
  if grep -qiE "notfound|not found|could not be found" "$err"; then
    exit 0
  fi
  cat "$err" >&2
  exit 1
fi

[ -z "$current" ] && exit 0

# Azure doesn't keep resource ID casing consistent (resourceGroups vs
# resourcegroups), so compare lowercased.
wanted=$(jq -r '.changes[].resourceId | ascii_downcase' "$whatif" | sort -u)
comm -23 <(tr '[:upper:]' '[:lower:]' <<< "$current" | sort -u) <(printf '%s\n' "$wanted")
