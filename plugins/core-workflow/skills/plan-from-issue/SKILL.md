---
name: plan-from-issue
description: Turn a GitHub issue into an implementation plan and a working branch. Use at the start of any autonomous "issue -> PR" run, before writing code.
---

# plan-from-issue

You are starting an autonomous change from a GitHub issue. Produce a small, reviewable plan and set
up the branch. Do **not** start editing code until the plan comment is posted.

## Inputs
- `ISSUE_NUMBER` (env or argument). If absent, ask which issue.
- The repo's `CLAUDE.md` (conventions, deploy target, heartbeat metric) and `.agent/risk-policy.yml`.

## Steps
1. Read the issue: `gh issue view "$ISSUE_NUMBER" --json title,body,labels,comments`.
2. Extract the **business intent** in one or two sentences: what outcome the user wants, not the
   mechanics. This becomes the PR title/summary later.
3. Inspect the repo for existing functions, utilities, and patterns to reuse. Prefer reuse over new
   code. Note the specific files you will touch.
4. Decide scope against `.agent/risk-policy.yml`. If the change clearly must touch
   schema/auth/billing/infra paths, note that it will be YELLOW/RED (human review expected).
5. Create a branch: `git switch -c agent/issue-<ISSUE_NUMBER>-<slug>`.
6. Post the plan as an issue comment with `gh issue comment "$ISSUE_NUMBER" --body-file -`:
   - **Intent:** one or two sentences.
   - **Files to change:** bullet list with one sentence each.
   - **Reuse:** existing utilities you will build on (path + name).
   - **Tests/evals:** what you will add or update to make the change gateable.
   - **Risk read:** expected GREEN/YELLOW/RED and why.

## Definition of done
A plan comment exists on the issue and a branch is checked out. Hand off to implementation, then to
the `create-pr` skill.

## Hard rules
- Never skip writing/updating tests "to save time" — an ungateable PR cannot auto-merge.
- Keep the diff as small as the intent allows; smaller diffs classify GREEN and ship faster.
