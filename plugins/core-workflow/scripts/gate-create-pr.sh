#!/usr/bin/env bash
# PreToolUse(Bash) gate: block raw `gh pr create` so PRs only open through the create-pr skill's
# wrapper (agent-pr-create), which enforces intent/tests/risk structure. Mirrors Intercom's
# "PreToolUse intercepts raw gh pr create and blocks it unless the create-pr skill was activated".
set -euo pipefail

input="$(cat)"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"

# Allow the sanctioned wrapper through (it sets AGENT_PR_WRAPPER=1 internally before calling gh).
if printf '%s' "$command" | grep -Eq '(^|[^a-zA-Z0-9_-])gh[[:space:]]+pr[[:space:]]+create'; then
  if printf '%s' "$command" | grep -q 'AGENT_PR_WRAPPER=1'; then
    exit 0
  fi
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Raw `gh pr create` is blocked. Open the PR via the create-pr skill (run the bundled `agent-pr-create` wrapper), which enforces the Intent/Tests/Risk/Rollback body structure required by the ai-review gate."
    }
  }'
  exit 0
fi

exit 0
