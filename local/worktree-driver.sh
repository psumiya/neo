#!/usr/bin/env bash
# Local driver for the hybrid path: run the agent on an issue in an isolated git worktree on your
# Mac, for large tasks you want to babysit. Same plugins/skills/gates as the cloud path; you just
# watch and steer. When it opens the PR, the cloud ai-review workflow takes over (classify/merge).
#
# Usage:
#   worktree-driver.sh <issue-number> [--repo <owner/repo>] [--model claude-sonnet-4-6] [--print]
#
# Requires: git, gh (authenticated), claude (Claude Code CLI) with the agent-harness marketplace
# added and plugins installed at user scope.
set -euo pipefail

ISSUE="${1:?usage: worktree-driver.sh <issue-number> [--repo o/r] [--model m] [--print]}"
shift || true
REPO=""
MODEL="claude-sonnet-4-6"
PRINT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --print) PRINT=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v claude >/dev/null || { echo "claude CLI not found" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }

SLUG="agent/issue-${ISSUE}"
WT_DIR="../$(basename "$PWD")-wt-${ISSUE}"

# Create an isolated worktree off the latest main so the task can't disturb your working tree.
git fetch origin main
git worktree add -B "$SLUG" "$WT_DIR" origin/main
echo "worktree: $WT_DIR  branch: $SLUG"

PROMPT="You are implementing GitHub issue #${ISSUE} for this repo.
1. Run /core-workflow:plan-from-issue for #${ISSUE} and post the plan.
2. Implement it, reusing existing utilities; keep the diff scoped. Add tests + evals/cases for any
   behavioral change.
3. Run tests and the evals runner until green.
4. Open the PR with /core-workflow:create-pr (raw gh pr create is blocked). Body needs Intent
   (Closes #${ISSUE}), Tests & evals, Risk, Rollback. Do not merge."

cd "$WT_DIR"
export AGENT_GAP_FILING=0   # local runs stay quiet; cloud path files gap issues

if [[ "$PRINT" == "1" ]]; then
  # Headless: good for unattended local runs.
  printf '%s' "$PROMPT" | claude -p --model "$MODEL" --permission-mode acceptEdits
else
  # Interactive: you watch and steer. The prompt is seeded; continue the conversation as needed.
  claude --model "$MODEL" --append-system-prompt "Seed task: $PROMPT"
fi

echo
echo "Done. When you're finished, remove the worktree with:"
echo "  git worktree remove \"$WT_DIR\""
