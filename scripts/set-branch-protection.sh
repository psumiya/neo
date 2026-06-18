#!/usr/bin/env bash
# Make the harness gates unskippable on a repo's main branch: require a PR, require the
# ai-review status checks to pass before merge. Converts "did the workflow run?" (audit) into
# "it cannot not run" (enforcement).
#
# Usage:
#   set-branch-protection.sh --repo owner/app [--branch main] \
#       [--checks "review / evals,review / review"] [--reviews 0] [--no-strict] [--dry-run]
#
# Notes on check names: for a CALLED (reusable) workflow, the status-check context is
# "<caller-job> / <reusable-job>". The template caller job is `review`, and ai-review.yml's jobs
# are `evals` and `review`, so the defaults are "review / evals" and "review / review". Run the
# pipeline once and copy the exact names from `gh pr checks <n>` if yours differ.
#
# Requires `gh` (admin on the repo) and `jq`.
set -euo pipefail

REPO=""
BRANCH="main"
CHECKS="review / evals,review / review"
REVIEWS=0
STRICT=true
DRYRUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --checks) CHECKS="$2"; shift 2 ;;
    --reviews) REVIEWS="$2"; shift 2 ;;
    --no-strict) STRICT=false; shift ;;
    --dry-run) DRYRUN=true; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$REPO" ]] || { echo "usage: set-branch-protection.sh --repo owner/app [...]" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

# Build the contexts JSON array from the comma-separated --checks.
contexts_json="$(printf '%s' "$CHECKS" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";""))')"

body="$(jq -n \
  --argjson contexts "$contexts_json" \
  --argjson strict "$STRICT" \
  --argjson reviews "$REVIEWS" \
  '{
    required_status_checks: { strict: $strict, contexts: $contexts },
    enforce_admins: false,
    required_pull_request_reviews: {
      required_approving_review_count: $reviews,
      dismiss_stale_reviews: true,
      require_code_owner_reviews: false
    },
    restrictions: null,
    allow_force_pushes: false,
    allow_deletions: false,
    required_linear_history: true
  }')"

echo "Repo:    $REPO"
echo "Branch:  $BRANCH"
echo "Checks:  $(printf '%s' "$contexts_json" | jq -c .)"
echo "Reviews required: $REVIEWS   strict(up-to-date): $STRICT"

if [[ "$DRYRUN" == "true" ]]; then
  echo "--- dry-run, body that would be PUT ---"
  printf '%s\n' "$body"
  exit 0
fi

printf '%s' "$body" | gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  "repos/${REPO}/branches/${BRANCH}/protection" \
  --input - >/dev/null

echo "Branch protection applied. Verify:"
echo "  gh api repos/${REPO}/branches/${BRANCH}/protection --jq '{checks: .required_status_checks.contexts, reviews: .required_pull_request_reviews.required_approving_review_count}'"
