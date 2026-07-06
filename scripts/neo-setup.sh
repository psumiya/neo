#!/usr/bin/env bash
# Guided, staged onboarding for a target app repo. Interactive by default; --non-interactive for CI.
# Setup happens in consent phases so you always see what changes before it does:
#   0. preflight        — tooling + resolve the GitHub repo
#   1. files            — the minimal footprint (tracked in git, easy to revert)
#   2. GitHub state     — labels, auto-merge, secrets (each confirmed; recorded in a receipt)
#   3. branch protection— deferred; run set-branch-protection.sh after the first pipeline pass
#
# Usage:
#   neo-setup.sh --dir <path> [--repo owner/name] [--deploy none|aws]
#       [--anthropic-key-file <f>] [--aws-role-file <f>]
#       [--non-interactive] [--force] [--dry-run] [--uninstall]
#
# Secrets are read from a file or an interactive prompt — never passed on the command line.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/neo-common.sh
source "$SCRIPT_DIR/lib/neo-common.sh"
TEMPLATE="$(cd "$SCRIPT_DIR/.." && pwd)/templates/target-repo"

DIR="" REPO="" DEPLOY="" AKEY_FILE="" AWSROLE_FILE="" NEOVER=""
INTERACTIVE=true FORCE=false UNINSTALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --deploy) DEPLOY="$2"; shift 2 ;;
    --neo-version) NEOVER="$2"; shift 2 ;;
    --anthropic-key-file) AKEY_FILE="$2"; shift 2 ;;
    --aws-role-file) AWSROLE_FILE="$2"; shift 2 ;;
    --non-interactive) INTERACTIVE=false; shift ;;
    --force) FORCE=true; shift ;;
    --dry-run) NEO_DRYRUN=true; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
export NEO_DRYRUN="${NEO_DRYRUN:-false}"

[[ -n "$DIR" ]] || { echo "usage: neo-setup.sh --dir <path> [...]; see --help" >&2; exit 2; }
[[ -d "$DIR" ]] || { echo "target dir not found: $DIR" >&2; exit 1; }
DIR="$(cd "$DIR" && pwd)"

confirm() { # confirm "question" -> 0/1. Auto-yes when non-interactive.
  [[ "$INTERACTIVE" == false ]] && return 0
  local reply; read -r -p "  $1 [y/N] " reply; [[ "$reply" =~ ^[Yy]$ ]]
}
ask() { # ask "prompt" "default" -> echoes answer (default when non-interactive/empty)
  local reply; [[ "$INTERACTIVE" == false ]] && { printf '%s' "$2"; return; }
  read -r -p "  $1 [$2] " reply; printf '%s' "${reply:-$2}"
}

# ---- phase 0: preflight ----------------------------------------------------------------------
neo_step "0. Preflight"
resolved="$(neo_preflight "$DIR")" || exit 1
REPO="${REPO:-$resolved}"
neo_say "Target dir : $DIR"
neo_say "GitHub repo: ${REPO:-<none — GitHub steps will be skipped>}"
neo_say "Dry-run    : $NEO_DRYRUN"

# ---- uninstall path --------------------------------------------------------------------------
if [[ "$UNINSTALL" == true ]]; then
  if confirm "Uninstall neo from $DIR${REPO:+ and $REPO}?"; then
    neo_uninstall "$DIR" "$REPO"
    neo_step "Uninstalled"
  fi
  exit 0
fi

# ---- deploy target ---------------------------------------------------------------------------
if [[ -z "$DEPLOY" ]]; then
  DEPLOY="$(ask "Deploy target? none|aws" "none")"
fi
[[ "$DEPLOY" == none || "$DEPLOY" == aws ]] || { echo "--deploy must be none or aws" >&2; exit 2; }

# ---- phase 1: files --------------------------------------------------------------------------
neo_step "1. Footprint (deploy: $DEPLOY)"
# Preview first, but only when a human is there to review it before the confirm.
[[ "$NEO_DRYRUN" != true && "$INTERACTIVE" == true ]] && ( NEO_DRYRUN=true neo_copy_footprint "$TEMPLATE" "$DIR" "$DEPLOY" "$FORCE" )
if confirm "Write these files into $DIR?"; then
  neo_copy_footprint "$TEMPLATE" "$DIR" "$DEPLOY" "$FORCE"
  # Pin the copied footprint to the current neo release (or --neo-version) so the install tracks a
  # real tag, not whatever ref the template happened to ship with.
  neo_stamp_version "$DIR" "$(neo_resolve_version "$NEOVER")"
else
  neo_say "skipped file copy"
fi

if [[ -z "$REPO" ]]; then
  neo_step "Done (local-only)"
  neo_say "No GitHub repo resolved; skipped GitHub state. Re-run with --repo owner/name for it."
  neo_say "Next: edit $DIR/.neo/config.yml, commit, push."
  exit 0
fi

# ---- phase 2: GitHub state -------------------------------------------------------------------
automerge=false
neo_step "2. GitHub state on $REPO (each step confirmed)"
if confirm "Create the neo labels?"; then neo_ensure_labels "$REPO"; fi
if confirm "Enable repo-wide auto-merge (needed for GREEN PRs to self-merge)?"; then
  neo_enable_automerge "$REPO" && automerge=true   # record only if it actually took
fi
# set_secret <NAME> <file>: from file if given; else prompt only when interactive; else note + skip.
set_secret() {
  local name="$1" file="$2"
  if [[ -n "$file" ]]; then neo_set_secret "$REPO" "$name" <"$file"
  elif [[ "$INTERACTIVE" == true ]]; then neo_say "paste $name (hidden):"; neo_set_secret "$REPO" "$name"
  else neo_say "$name not provided — set later: gh secret set $name --repo $REPO"; fi
}
if confirm "Set the ANTHROPIC_API_KEY secret now?"; then set_secret ANTHROPIC_API_KEY "$AKEY_FILE"; fi
if [[ "$DEPLOY" == aws ]] && confirm "Set the AWS_ROLE_TO_ASSUME secret now?"; then
  set_secret AWS_ROLE_TO_ASSUME "$AWSROLE_FILE"
fi

neo_write_receipt "$DIR" "$REPO" "$DEPLOY" "$automerge"

# ---- next steps ------------------------------------------------------------------------------
neo_step "Done"
neo_say "1. Edit $DIR/.neo/config.yml (app build/test cmds, risk policy${DEPLOY:+, deploy})."
neo_say "2. Commit and push the footprint."
neo_say "3. Open an issue, add the 'neo:build' label, and watch the PR appear."
neo_say "4. After the first PR runs, lock the gates:"
neo_say "     $SCRIPT_DIR/set-branch-protection.sh --repo $REPO --dry-run"
