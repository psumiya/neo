#!/usr/bin/env bash
# SessionEnd hook: self-improvement loop. When an autonomous run struggled (repeated tool failures,
# abandoned plan, gate it couldn't satisfy), summarize the transcript with a cheap model and file a
# GitHub "harness gap" issue so the skills/CLAUDE.md can be improved. Mirrors Intercom's SessionEnd
# -> Haiku gap classification -> GitHub issue.
#
# Opt-in: only runs when AGENT_GAP_FILING=1 (set in CI). No-ops otherwise so local sessions are quiet.
set -euo pipefail

[[ "${AGENT_GAP_FILING:-0}" == "1" ]] || exit 0
command -v gh >/dev/null 2>&1 || exit 0
command -v claude >/dev/null 2>&1 || exit 0

input="$(cat)"
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // ""')"
[[ -n "$transcript" && -f "$transcript" ]] || exit 0

# Keep cost bounded: only the tail of the transcript.
tail_text="$(tail -c 60000 "$transcript" 2>/dev/null || true)"
[[ -n "$tail_text" ]] || exit 0

prompt='You are triaging a Claude Code autonomous coding session transcript for harness gaps.
Decide if the agent got materially stuck: repeated identical tool failures, a plan it could not
complete, a gate (tests/evals/risk) it could not satisfy, or a missing skill/permission/tool.
Respond with ONLY minified JSON: {"file_issue":bool,"title":string,"body":string}.
If the run was clean, return {"file_issue":false,"title":"","body":""}.
The body should name the specific friction and a concrete suggested fix (new skill, permission,
CLAUDE.md note, or tooling). Transcript tail follows:
'"$tail_text"

result="$(printf '%s' "$prompt" | claude -p --model claude-haiku-4-5-20251001 --output-format text 2>/dev/null || true)"
json="$(printf '%s' "$result" | grep -o '{.*}' | head -1 || true)"
[[ -n "$json" ]] || exit 0

file_issue="$(printf '%s' "$json" | jq -r '.file_issue // false' 2>/dev/null || echo false)"
[[ "$file_issue" == "true" ]] || exit 0

title="$(printf '%s' "$json" | jq -r '.title // "Harness gap detected"')"
body="$(printf '%s' "$json" | jq -r '.body // ""')"
gh issue create \
  --title "[harness-gap] $title" \
  --body "$body

_Filed automatically by the core-workflow SessionEnd hook._" \
  --label "harness-gap" >/dev/null 2>&1 || true
