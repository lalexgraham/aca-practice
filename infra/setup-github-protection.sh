#!/usr/bin/env zsh
# Codifies the repo's GitHub-side protection settings, so this script (not
# the Settings UI) is the source of truth for them.
#
# What this script does, in order:
#   1. For each approval-gate GitHub Environment (infra-apply,
#      infra-apply-production, app-deploy-production), creates it if missing
#      and sets: required reviewer, "Allow administrators to bypass
#      configured protection rules" OFF, and deployment branches limited to
#      "Selected branches and tags".
#   2. Ensures each of those environments has exactly one deployment branch
#      rule, `main` (a branch rule, not a tag rule).
#   3. Sets branch protection on main: the `plan` status check
#      (terraform-plan.yml's final job) must pass before merging.
#
# Safe to re-run: the environment PUT and the branch protection PUT are both
# declarative (they replace the whole setting), and branch rules are only
# added when missing. Re-running after a manual UI tweak puts it back.
#
# Run from anywhere, requires: gh auth login already done, with admin
# rights on the repo.

set -euo pipefail

# --- edit these if your repo/names differ ---
GITHUB_USERNAME="lalexgraham"
REPO_NAME="aca-practice"
REVIEWER="lalexgraham"
ENVIRONMENTS=("infra-apply" "infra-apply-production" "app-deploy-production")
PROTECTED_BRANCH="main"
REQUIRED_CHECK="plan"
# --------------------------------------------

REPO="${GITHUB_USERNAME}/${REPO_NAME}"

REVIEWER_ID=$(gh api "users/${REVIEWER}" --jq .id)
if [[ -z "$REVIEWER_ID" ]]; then
  echo "Could not resolve the user ID for ${REVIEWER}." >&2
  exit 1
fi

for ENV_NAME in "${ENVIRONMENTS[@]}"; do
  echo "Configuring environment: ${ENV_NAME}"

  # PUT creates the environment if it doesn't exist and replaces these
  # settings if it does. can_admins_bypass=false is what makes the required
  # reviewer and the branch rule apply to repo admins too (the repo owner
  # counts as an admin, so left on, the gate could be skipped by its owner).
  # prevent_self_review stays false: the reviewer is the only user here, so
  # turning it on would make every run unapprovable.
  gh api --method PUT "repos/${REPO}/environments/${ENV_NAME}" --input - >/dev/null <<EOF
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "can_admins_bypass": false,
  "reviewers": [{"type": "User", "id": ${REVIEWER_ID}}],
  "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}
}
EOF

  # Make the branch rules exactly [PROTECTED_BRANCH]: add it if missing,
  # remove anything else (e.g. a rule added by hand in the UI).
  POLICIES=$(gh api "repos/${REPO}/environments/${ENV_NAME}/deployment-branch-policies" \
    --jq '.branch_policies[] | "\(.id)\t\(.name)\t\(.type)"')

  HAS_RULE=false
  while IFS=$'\t' read -r POLICY_ID POLICY_NAME POLICY_TYPE; do
    [[ -z "$POLICY_ID" ]] && continue
    if [[ "$POLICY_NAME" == "$PROTECTED_BRANCH" && "$POLICY_TYPE" == "branch" ]]; then
      HAS_RULE=true
    else
      echo "   removing unexpected branch rule: ${POLICY_NAME} (${POLICY_TYPE})"
      gh api --method DELETE "repos/${REPO}/environments/${ENV_NAME}/deployment-branch-policies/${POLICY_ID}"
    fi
  done <<< "$POLICIES"

  if [[ "$HAS_RULE" == false ]]; then
    echo "   adding branch rule: ${PROTECTED_BRANCH}"
    gh api --method POST "repos/${REPO}/environments/${ENV_NAME}/deployment-branch-policies" \
      -f name="$PROTECTED_BRANCH" -f type=branch >/dev/null
  fi
done

# Branch protection. The PUT replaces the whole protection object, so every
# top-level key is spelled out; null means "not enabled".
#   - strict=false: the branch needn't be up to date with main to merge, only
#     the check must pass
#   - enforce_admins=false: matches the current live setting, so as repo
#     owner you can still merge past a failing check in an emergency. Flip
#     to true to close that.
#   - no required PR reviews: sole-developer repo
echo "Configuring branch protection on ${PROTECTED_BRANCH} (required check: ${REQUIRED_CHECK})"
gh api --method PUT "repos/${REPO}/branches/${PROTECTED_BRANCH}/protection" --input - >/dev/null <<EOF
{
  "required_status_checks": {"strict": false, "contexts": ["${REQUIRED_CHECK}"]},
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": false
}
EOF

echo ""
echo "Done."

# VERIFY (prints the live settings, should match the above)
# for e in infra-apply infra-apply-production app-deploy-production; do
#   gh api repos/lalexgraham/aca-practice/environments/$e \
#     --jq '{name, can_admins_bypass, deployment_branch_policy, reviewers: [.protection_rules[].reviewers[]?.reviewer.login]}'
#   gh api repos/lalexgraham/aca-practice/environments/$e/deployment-branch-policies --jq '[.branch_policies[].name]'
# done
# gh api repos/lalexgraham/aca-practice/branches/main/protection \
#   --jq '{checks: .required_status_checks.contexts, enforce_admins: .enforce_admins.enabled}'

# UNDO
# # remove branch protection from main
# gh api --method DELETE repos/lalexgraham/aca-practice/branches/main/protection
#
# # delete the environments (also removes their reviewers and branch rules).
# # The workflows that name them will then auto-create them again, unprotected,
# # on their next run.
# for e in infra-apply infra-apply-production app-deploy-production; do
#   gh api --method DELETE repos/lalexgraham/aca-practice/environments/$e
# done
