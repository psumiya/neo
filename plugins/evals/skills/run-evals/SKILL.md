---
name: run-evals
description: Author and run eval cases (golden assertions + LLM-judge) as a merge gate, especially for RAG/behavioral changes. Use when adding behavior that needs a regression guard or when the eval gate is red.
---

# run-evals

Behavioral and RAG changes must ship with evals so they are gateable and protected from regression.

## Authoring a case
Add a YAML file under `.neo/evals/cases/` in the target repo:

- **golden** — deterministic command output assertion (`exact` / `contains` / `regex` /
  `json_equals`). Use for CLIs, parsers, API shapes.
- **judge** — LLM-judge scores an output against a rubric and must clear a `threshold`. Use for
  RAG answers, summaries, classifications where exact match is too brittle.

See the header of `scripts/run_evals.py` for the exact schema.

## Running
`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/run_evals.py"` (run from the repo root). Exit 0 = gate green.

## When adding a feature
1. Write at least one case capturing the intended behavior **before/while** implementing.
2. Confirm it fails on the old behavior and passes on the new (a case that never fails is worthless).
3. Keep judge thresholds honest — start at 0.8 and tune from observed scores, don't lower a threshold
   just to make a flaky case pass.

## Hard rules
- Never weaken or delete an existing eval to get a PR green; fix the regression instead.
- A behavioral/RAG PR with no eval case should not be GREEN — flag it for human review.
