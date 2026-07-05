---
name: create-pr
description: Open a pull request the harness-approved way, with structured intent, test/eval evidence, and the issue link. REQUIRED before any `gh pr create`; a PreToolUse hook blocks raw `gh pr create` until this skill has run.
---

# create-pr

This skill is the only sanctioned path to open a PR. A `PreToolUse` hook blocks a raw `gh pr create`
unless this skill has been activated in the session, so always run through here.

## Preconditions (verify, do not assume)
1. All new/changed code has tests; run them and confirm green locally/in-CI.
2. Eval cases exist for behavioral/RAG changes (see the `evals` plugin) and pass.
3. The branch is pushed: `git push -u origin HEAD`.

## Build the PR body
Use this exact structure so `risk-review` and the human reader get what they need:

```
## Intent
<one or two sentences — the business outcome, lifted from the plan>

Closes #<ISSUE_NUMBER>

## What changed
- <file>: <one line>

## Tests & evals
- <command(s) run> — <result>
- evals: <pass/fail summary>

## Risk
Self-assessed: GREEN | YELLOW | RED — <why, referencing the risk block in .neo/config.yml>
Feature flag: <flag name, default-off> | none

## Rollback
<heartbeat metric this should not regress; how to disable via flag>
```

## Create it
```
gh pr create --title "<intent as title>" --body-file <body> \
  --base main --head "$(git branch --show-current)" --label agent:pr
```

## After creation
Hand off to the `ci-monitor` skill to watch checks. Do **not** merge manually — merge is decided by
the `ai-review` workflow (GREEN auto-merges; YELLOW/RED wait for the human).

## Hard rules
- Never open a PR with failing or absent tests.
- Never include secrets, `.env`, or generated credentials in the diff.
- One issue per PR; keep the diff scoped to the plan.
