#!/usr/bin/env bash
# One-shot onboarding for a target app repo: copy the harness footprint, install the plugins,
# create the labels the pipeline uses, enable auto-merge, and (optionally) set secrets.
# Idempotent and safe to re-run. Use --dry-run to preview every action first.
#
# Usage:
#   init-target-repo.sh --dir <path-to-app-checkout> [--repo owner/name]
#       [--aws-role <iam-role-arn>] [--anthropic-key <key>]
#       [--no-plugins] [--force] [--dry-run]
#
# --dir    local checkout of the app repo to scaffold (required)
# --repo   owner/name on GitHub for label/secret/auto-merge setup; inferred from the dir's
#          origin remote if omitted
# --force  overwrite footprint files that already exist (default: skip existing)
#
# Requires: git, gh (authenticated). `claude` CLI optional (for local plugin install).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$HARNESS_ROOT/templates/target-repo"
MARKETPLACE_URL="https://github.com/psumiya/agent-harness.git"
PLUGINS=(core-workflow risk-review evals deploy-aws)

DIR="" ; REPO="" ; AWS_ROLE="" ; ANTHROPIC_KEY="" ; INSTALL_PLUGINS=true ; FORCE=false ; DRYRUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --aws-role) AWS_ROLE="$2"; shift 2 ;;
    --anthropic-key) ANTHROPIC_KEY="$2"; shift 2 ;;
    --no-plugins) INSTALL_PLUGINS=false; shift ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRYRUN=true; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '  %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
run()  { if $DRYRUN; then printf '  [dry-run] %s\n' "$*"; else eval "$*"; fi; }

[[ -n "$DIR" ]] || { echo "usage: init-target-repo.sh --dir <path> [...]; see --help" >&2; exit 2; }
[[ -d "$DIR" ]] || { echo "target dir not found: $DIR" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 1; }

DIR="$(cd "$DIR" && pwd)"

# Infer repo from the dir's origin remote if not given.
if [[ -z "$REPO" ]]; then
  origin="$(git -C "$DIR" remote get-url origin 2>/dev/null || true)"
  if [[ "$origin" =~ github.com[:/]+([^/]+/[^/.]+) ]]; then
    REPO="${BASH_REMATCH[1]}"
  fi
fi

step "Plan"
say "Footprint source : $TEMPLATE"
say "Target dir       : $DIR"
say "GitHub repo      : ${REPO:-<none — label/secret/auto-merge setup will be skipped>}"
say "Install plugins  : $INSTALL_PLUGINS    Force overwrite: $FORCE    Dry-run: $DRYRUN"

# 1. Copy the footprint (skip existing unless --force).
step "1. Copy harness footprint"
copyflag="-Rn"; $FORCE && copyflag="-R"
for item in CLAUDE.md .claude .agent .github deploy evals; do
  src="$TEMPLATE/$item"
  [[ -e "$src" ]] || continue
  if [[ -e "$DIR/$item" && "$FORCE" == false ]]; then
    say "exists, merging non-clobbering: $item"
  else
    say "copy: $item"
  fi
  run "cp $copyflag \"$src\" \"$DIR/\""
done

# 2. Install plugins locally (optional; CI installs headlessly regardless).
step "2. Plugins"
if $INSTALL_PLUGINS && command -v claude >/dev/null; then
  run "claude plugin marketplace add \"$MARKETPLACE_URL\" || true"
  for p in "${PLUGINS[@]}"; do
    run "claude plugin install ${p}@agent-harness --scope project || true"
  done
else
  say "skipping local plugin install (claude CLI absent or --no-plugins); CI installs them via the action"
fi

if [[ -z "$REPO" ]]; then
  step "Done (local-only)"
  say "No GitHub repo resolved; skipped labels/secrets/auto-merge. Re-run with --repo owner/name for those."
  say "Next: edit $DIR/CLAUDE.md and $DIR/.agent/risk-policy.yml, commit, push."
  exit 0
fi

# 3. Create the labels the pipeline relies on (idempotent).
step "3. Labels on $REPO"
create_label() { run "gh label create \"$1\" --repo \"$REPO\" --color \"$2\" --description \"$3\" --force"; }
create_label "agent:build"    "1d76db" "Hand this issue to the agent to build"
create_label "agent:pr"       "5319e7" "PR opened by the agent"
create_label "risk:green"     "0e8a16" "Auto-mergeable (low blast radius)"
create_label "risk:yellow"    "fbca04" "Needs human review"
create_label "risk:red"       "d93f0b" "Needs human review + protected approval"
create_label "harness-gap"    "c2e0c6" "Agent got stuck; harness improvement needed"
create_label "harness-report" "bfd4f2" "Automated weekly report"
create_label "incident"       "b60205" "Production incident"
create_label "rollback"       "e99695" "Automated rollback occurred"

# 4. Enable auto-merge so GREEN PRs can merge themselves once checks pass.
step "4. Enable auto-merge on $REPO"
run "gh repo edit \"$REPO\" --enable-auto-merge"

# 5. Secrets (only if provided; otherwise remind).
step "5. Secrets"
if [[ -n "$ANTHROPIC_KEY" ]]; then
  run "gh secret set ANTHROPIC_API_KEY --repo \"$REPO\" --body \"$ANTHROPIC_KEY\""
else
  say "ANTHROPIC_API_KEY not provided — set it with: gh secret set ANTHROPIC_API_KEY --repo $REPO"
fi
if [[ -n "$AWS_ROLE" ]]; then
  run "gh secret set AWS_ROLE_TO_ASSUME --repo \"$REPO\" --body \"$AWS_ROLE\""
else
  say "AWS_ROLE_TO_ASSUME not provided — set it (OIDC role ARN) with: gh secret set AWS_ROLE_TO_ASSUME --repo $REPO"
fi

step "Done"
say "Next steps:"
say "  1. Edit $DIR/CLAUDE.md (deploy target, heartbeat metric) and .agent/risk-policy.yml."
say "  2. Fill deploy/ placeholders if this is an AWS target; commit and push the footprint."
say "  3. After the first PR runs, lock the gates:"
say "       $SCRIPT_DIR/set-branch-protection.sh --repo $REPO --dry-run"
say "  4. Open an issue, add the 'agent:build' label, and watch the PR appear."
