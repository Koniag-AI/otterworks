#!/usr/bin/env bash
# Tech-lead gate for the ALERT workflow: require a code-owner review on the deploy
# branch so a Devin PR cannot reach the merge -> Harness step without a named human.
#
# Needs a token with admin rights on the repository (repo admin or org owner);
# a normal contributor token cannot create rulesets. Run:
#
#   ./scripts/setup-branch-protection.sh              # show what would be created
#   ./scripts/setup-branch-protection.sh --apply
#
# Idempotent: updates the ruleset if it already exists.
set -euo pipefail

REPO="${REPO:-Koniag-AI/otterworks}"
BRANCH="${BRANCH:-main}"
RULESET_NAME="ALERT deploy branch protection"
APPLY=false
[[ "${1:-}" == "--apply" ]] && APPLY=true

payload=$(cat <<JSON
{
  "name": "${RULESET_NAME}",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["refs/heads/${BRANCH}"], "exclude": [] }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "require_code_owner_review": true,
        "dismiss_stale_reviews_on_push": true,
        "require_last_push_approval": true,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["squash", "merge"]
      }
    }
  ]
}
JSON
)

# require_last_push_approval is the rule that stops the author of the last commit
# from being the approver, i.e. Devin cannot approve its own remediation.

if [[ "${APPLY}" != true ]]; then
  echo "Would apply to ${REPO} (${BRANCH}):"
  echo "${payload}"
  echo
  echo "Re-run with --apply. Required status checks are intentionally omitted here;"
  echo "add them once the CI check names are stable and green."
  exit 0
fi

existing=$(gh api "repos/${REPO}/rulesets" --jq \
  ".[] | select(.name == \"${RULESET_NAME}\") | .id" || true)

if [[ -n "${existing}" ]]; then
  echo "${payload}" | gh api --method PUT "repos/${REPO}/rulesets/${existing}" --input -
  echo "updated ruleset ${existing}"
else
  echo "${payload}" | gh api --method POST "repos/${REPO}/rulesets" --input -
  echo "created ruleset"
fi
