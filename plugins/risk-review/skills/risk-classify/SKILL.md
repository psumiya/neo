---
name: risk-classify
description: Classify a PR GREEN/YELLOW/RED and run an AI code review, then post the verdict and (for GREEN) approve. Use in the ai-review workflow or when asked to review/approve a PR.
---

# risk-classify

Decide whether a PR can auto-merge. Two layers: a deterministic blast-radius tier, then an AI code
review that can only *downgrade* GREEN, never upgrade it.

## Steps
1. Get the diff stats vs base:
   `git fetch origin main && git diff --numstat origin/main...HEAD > /tmp/numstat`
2. Deterministic tier:
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/classify.py" --policy .agent/risk-policy.yml --numstat /tmp/numstat`
   Capture `tier` and `reasons`.
3. AI review: dispatch the `risk-reviewer` subagent on the diff. It returns
   `{blocking: bool, findings: [...]}`. Blocking findings are correctness/security bugs only —
   not style nits.
4. Decide the final verdict:
   - deterministic `RED` -> **RED** (needs human + protected env approval).
   - deterministic `YELLOW`, or any blocking AI finding -> **YELLOW** (needs human review).
   - deterministic `GREEN` **and** no blocking AI findings -> **GREEN** (auto-merge).
5. Post the review on the PR:
   - `gh pr comment <n>` with the tier, the deterministic reasons, and the AI findings.
   - Apply a label: `gh pr edit <n> --add-label risk:green|risk:yellow|risk:red`.
   - If **GREEN**: `gh pr review <n> --approve` and enable auto-merge
     (`gh pr merge <n> --squash --auto`). The workflow's branch protection still requires all checks.
   - If **YELLOW/RED**: `gh pr edit <n> --add-assignee <owner>` and request changes/leave a comment;
     do **not** approve.

## Hard rules
- Never approve a PR the deterministic classifier marked YELLOW/RED.
- The AI reviewer's job is to catch real bugs and security issues, not to bikeshed.
- If `.agent/risk-policy.yml` is missing, fall back to the conservative built-in defaults and label
  the PR YELLOW (never auto-merge without an explicit policy).
