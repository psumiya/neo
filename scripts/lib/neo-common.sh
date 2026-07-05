#!/usr/bin/env bash
# Shared, idempotent primitives for neo onboarding. Sourced by both front doors:
#   - scripts/neo-setup.sh   (interactive / CI installer)
#   - plugins/neo-setup/      (the /neo-setup slash command shells out to the same functions)
#
# Every mutating function honors NEO_DRYRUN=true (print, don't run) and is safe to re-run.
# Nothing here touches a repo's root CLAUDE.md.

# --- output helpers ---------------------------------------------------------------------------
neo_say()  { printf '  %s\n' "$*"; }
neo_step() { printf '\n==> %s\n' "$*"; }
neo_warn() { printf '  ! %s\n' "$*" >&2; }
neo_run()  { if [[ "${NEO_DRYRUN:-false}" == true ]]; then printf '  [dry-run] %s\n' "$*"; else eval "$*"; fi; }

# The minimal footprint. Deploy files are added only for the aws target (see neo_copy_footprint).
NEO_BASE_ITEMS=(".neo/config.yml" ".neo/evals" ".claude/settings.json"
                ".github/workflows/neo.yml" ".github/ISSUE_TEMPLATE/neo-build.yml")
NEO_AWS_ITEMS=(".github/workflows/neo-deploy.yml" ".neo/deploy")

NEO_LABELS=(
  "neo:build|1d76db|Hand this issue to the agent to build"
  "agent:pr|5319e7|PR opened by the agent"
  "risk:green|0e8a16|Auto-mergeable (low blast radius)"
  "risk:yellow|fbca04|Needs human review"
  "risk:red|d93f0b|Needs human review + protected approval"
  "harness-gap|c2e0c6|Agent got stuck; harness improvement needed"
  "harness-report|bfd4f2|Automated weekly report"
  "incident|b60205|Production incident"
  "rollback|e99695|Automated rollback occurred"
)

# --- preflight --------------------------------------------------------------------------------
# neo_preflight <dir> : verify tooling, resolve the GitHub repo from origin. Echoes owner/name.
neo_preflight() {
  local dir="$1"
  command -v git >/dev/null || { neo_warn "git required"; return 1; }
  command -v gh  >/dev/null || { neo_warn "gh CLI required (brew install gh; gh auth login)"; return 1; }
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || { neo_warn "$dir is not a git repo"; return 1; }
  local origin repo=""
  origin="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
  [[ "$origin" =~ github.com[:/]+([^/]+/[^/.]+) ]] && repo="${BASH_REMATCH[1]}"
  printf '%s' "$repo"
}

# --- phase 1: files (reversible via git) ------------------------------------------------------
# neo_copy_footprint <template-dir> <target-dir> <deploy-target> <force>
neo_copy_footprint() {
  local tmpl="$1" dir="$2" deploy="$3" force="${4:-false}"
  local items=("${NEO_BASE_ITEMS[@]}")
  [[ "$deploy" == aws ]] && items+=("${NEO_AWS_ITEMS[@]}")
  for item in "${items[@]}"; do
    local src="$tmpl/$item" dest="$dir/$item"
    [[ -e "$src" ]] || { neo_warn "missing from template: $item"; continue; }
    # Skip existing outright (BSD cp -n returns nonzero when it skips, which trips set -e). This
    # keeps re-runs idempotent and never clobbers a user's file unless --force.
    if [[ -e "$dest" && "$force" == false ]]; then
      neo_say "keep existing (not clobbered): $item"
      continue
    fi
    neo_say "copy: $item"
    neo_run "mkdir -p \"\$(dirname \"$dest\")\""
    neo_run "cp -R \"$src\" \"$dest\""
  done
  neo_say "root CLAUDE.md: left untouched (neo reads .neo/config.yml + the neo-contract skill)"
}

# --- phase 2: GitHub state (NOT in git — recorded in the receipt) -----------------------------
neo_ensure_labels() {
  local repo="$1" spec name color desc
  for spec in "${NEO_LABELS[@]}"; do
    IFS='|' read -r name color desc <<<"$spec"
    neo_run "gh label create \"$name\" --repo \"$repo\" --color \"$color\" --description \"$desc\" --force"
  done
}

# Enable repo-wide auto-merge and confirm it stuck. `gh repo edit --enable-auto-merge` exits 0 even
# when it silently no-ops, so use the REST API and read the value back. Returns non-zero (with a
# warning) if it did not take — commonly a plan/visibility limit on private repos.
neo_enable_automerge() {
  local repo="$1" result
  if [[ "${NEO_DRYRUN:-false}" == true ]]; then
    printf '  [dry-run] gh api repos/%s -X PATCH -F allow_auto_merge=true\n' "$repo"; return 0
  fi
  result="$(gh api "repos/$repo" --method PATCH -F allow_auto_merge=true --jq '.allow_auto_merge' 2>/dev/null || echo error)"
  if [[ "$result" == true ]]; then
    neo_say "auto-merge enabled"
    return 0
  fi
  neo_warn "could not enable auto-merge (allow_auto_merge=$result). Often a plan/visibility limit on"
  neo_warn "private repos. Enable it by hand in Settings, or GREEN PRs will wait for a manual merge."
  return 1
}

neo_disable_automerge() {
  local repo="$1"
  neo_run "gh api \"repos/$repo\" --method PATCH -F allow_auto_merge=false --jq '.allow_auto_merge' >/dev/null"
}

# neo_set_secret <repo> <name> : reads the value from stdin so it never lands in argv/history.
neo_set_secret() {
  local repo="$1" name="$2" value
  IFS= read -rs value || true
  echo
  if [[ -z "$value" ]]; then
    neo_say "$name not provided — set later: gh secret set $name --repo $repo"
    return 0
  fi
  if [[ "${NEO_DRYRUN:-false}" == true ]]; then
    printf '  [dry-run] gh secret set %s --repo %s (value from stdin)\n' "$name" "$repo"
  else
    printf '%s' "$value" | gh secret set "$name" --repo "$repo" --body -
  fi
}

# --- receipt + uninstall ----------------------------------------------------------------------
# neo_write_receipt <dir> <repo> <deploy> <automerge:true|false> : records the non-git changes.
neo_write_receipt() {
  local dir="$1" repo="$2" deploy="$3" automerge="$4"
  local labels="" spec name
  for spec in "${NEO_LABELS[@]}"; do name="${spec%%|*}"; labels+=" $name"; done
  [[ "${NEO_DRYRUN:-false}" == true ]] && { neo_say "[dry-run] write .neo/install-receipt.md"; return 0; }
  mkdir -p "$dir/.neo"
  cat >"$dir/.neo/install-receipt.md" <<EOF
# neo install receipt

Repo: \`$repo\` · Deploy target: \`$deploy\` · Generated by \`neo-setup\`.

Files are tracked in git (revert with \`git rm\`). The changes below are GitHub-side state, **not**
captured in git. To fully uninstall, run \`neo-setup --uninstall --dir . --repo $repo\`, or reverse
them by hand:

## Labels created
\`\`\`
$(for spec in "${NEO_LABELS[@]}"; do echo "gh label delete ${spec%%|*} --repo $repo --yes"; done)
\`\`\`

## Auto-merge
$( [[ "$automerge" == true ]] && echo "Enabled repo-wide. Reverse: \`gh repo edit $repo --enable-auto-merge=false\`" || echo "Not changed by neo." )

## Secrets
\`\`\`
gh secret delete ANTHROPIC_API_KEY --repo $repo
$( [[ "$deploy" == aws ]] && echo "gh secret delete AWS_ROLE_TO_ASSUME --repo $repo" )
\`\`\`

## Branch protection
If you ran \`set-branch-protection.sh\`, remove it with:
\`\`\`
gh api --method DELETE repos/$repo/branches/main/protection
\`\`\`
EOF
  neo_say "wrote .neo/install-receipt.md (reversal steps for the non-git changes)"
}

# neo_uninstall <dir> <repo> : remove the footprint files and reverse the GitHub-side state.
neo_uninstall() {
  local dir="$1" repo="$2" spec name
  neo_step "Remove footprint files"
  neo_run "rm -rf \"$dir/.neo\" \"$dir/.github/workflows/neo.yml\" \"$dir/.github/workflows/neo-deploy.yml\" \"$dir/.github/ISSUE_TEMPLATE/neo-build.yml\""
  neo_say "left .claude/settings.json and root CLAUDE.md in place (edit by hand if desired)"
  if [[ -n "$repo" ]]; then
    neo_step "Reverse GitHub state on $repo"
    for spec in "${NEO_LABELS[@]}"; do name="${spec%%|*}"; neo_run "gh label delete \"$name\" --repo \"$repo\" --yes || true"; done
    neo_disable_automerge "$repo"
    neo_say "secrets left in place — delete with: gh secret delete ANTHROPIC_API_KEY --repo $repo"
  fi
}
