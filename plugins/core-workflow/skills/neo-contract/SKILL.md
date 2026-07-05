---
name: neo-contract
description: The generic working agreement for any neo-managed repo — how GREEN/YELLOW/RED gating, evals, feature flags, and PR structure work. Read this when acting autonomously in a repo that has a .neo/config.yml, so per-repo files only carry app-specific facts.
---

# neo-contract

The rules every neo-managed repo follows. These live here, in the plugin, so a target repo carries
only its own facts in `.neo/config.yml` (and app-specific conventions in its own `CLAUDE.md`), not a
copy of this agreement.

## Where per-repo facts live
- `.neo/config.yml` — `app` (build/test/lint commands), `risk` (policy), `deploy` (target +
  heartbeat), `evals` (case dir). This is the only neo file a human edits.
- The repo's own `CLAUDE.md`, if any — codebase conventions. neo never overwrites it.

## Risk gating (GREEN / YELLOW / RED)
Computed deterministically by `risk-review/scripts/classify.py` from the `risk:` block:
- **GREEN** — total added+removed <= `max_lines_green`, every changed path matches `green_paths`,
  no path matches `blocked_paths`. Auto-merges with no human review, but only if the AI review adds
  no blocking findings. The reviewer may downgrade GREEN, never upgrade past these rules.
- **YELLOW** — anything not GREEN and not blocked. Human review required.
- **RED** — touches any `blocked_paths` entry (auth, billing, schema, migrations, infra, workflows).
  Human review **and** protected-environment approval. Never auto-merges.

## Evals
A behavioral or RAG change must add a case under the `evals.dir` (default `.neo/evals/cases/`). A
behavioral PR with no eval is not eligible for GREEN. Run them with the `run-evals` skill.

## Feature flags
New behavior ships behind a flag, **default-off**. The PR's Rollback section names the flag so a bad
change is disabled without a revert.

## PR structure
Every agent PR body includes: **Intent** (with `Closes #<issue>`), **Tests & evals**, **Risk**, and
**Rollback**. Never weaken tests or evals to make a gate pass — if a gate can't be met, say so in an
issue comment and stop.
