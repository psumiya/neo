# neo

**Open a GitHub issue describing a feature. A tested, risk-gated, deployed PR comes back. You write no
code and review only the risky ones.**

## Before / After

**Before:** write the spec → branch → code → write tests → open PR → review → merge → deploy → watch
dashboards → roll back by hand when something breaks.

**After:** open an issue, add the `neo:build` label. The harness produces the PR, runs tests +
evals, classifies risk, auto-merges and deploys the safe ones, and auto-rolls-back on bad signals.
You approve only the YELLOW/RED ones.

A RED-tier change (touches auth, billing, migrations) takes the same path but stops at your review
instead of auto-merging.

## Who it's for

A solo dev or small team shipping a web + backend app (AWS is the first-class deploy target) who
wants to spend their time on specs and judgment, not boilerplate and deploy plumbing.

**Non-goals:** it won't design greenfield architecture for you, and it will never auto-merge a
RED-tier change.

Modeled on:
- [2x: Nine Months Later](https://ideas.fin.ai/p/2x-nine-months-later)
- [How we use Claude Code today at Intercom](https://ideas.fin.ai/p/how-we-use-claude-code-today-at-intercom)
- [The safety of speed: shipping code at Intercom](https://www.intercom.com/blog/the-safety-of-speed-shipping-code-at-intercom/)

## How it works

### Layout

```
neo/
  .claude-plugin/marketplace.json   # the marketplace every target repo installs from
  settings/settings.json            # shared Claude Code settings (telemetry, permissions) to merge into repos
  plugins/
    core-workflow/                  # plan-from-issue, create-pr (gated), ci-monitor + hooks
    risk-review/                    # GREEN/YELLOW/RED PR classifier + reviewer agent
    evals/                          # golden-test + LLM-judge gate
    deploy-aws/                     # reference AWS deploy/rollback adapter
  .github/workflows/                # reusable workflows (workflow_call) called by every target repo
  templates/target-repo/            # drop-in footprint for a new app repo (callers + contract)
  local/                            # local `claude -p` worktree driver for large/babysat tasks
  scripts/                          # shared helper scripts (risk classify, metrics)
```

### How the pieces map to the pipeline

| Stage | Where it lives |
|---|---|
| Intake | `templates/target-repo/.github/ISSUE_TEMPLATE/neo-build.yml` + `neo:build` label |
| Issue -> PR | `.github/workflows/neo-build.yml` (cloud) / `local/worktree-driver.sh` (local) |
| Risk gate + auto-merge | `.github/workflows/ai-review.yml` + `plugins/risk-review` + repo `.agent/risk-policy.yml` |
| Eval gate | `.github/workflows/ai-review.yml` calls `plugins/evals` |
| Deploy | `.github/workflows/deploy.yml` + `plugins/deploy-aws` |
| Rollback | `.github/workflows/rollback.yml` (CloudWatch alarm -> revert) |
| Self-improvement | `core-workflow` SessionEnd hook + `.github/workflows/claudemd-factcheck-weekly.yml` |
| Metrics | `.github/workflows/metrics-weekly.yml` + `scripts/metrics.py` |

## Quick start (per target repo)

One command scaffolds the footprint, installs the plugins, creates the labels, enables auto-merge,
and (optionally) sets secrets. Use `--dry-run` first to preview every action:

```
scripts/init-target-repo.sh --dir <path-to-app-checkout> [--repo owner/name] \
    [--anthropic-key <key>] [--aws-role <iam-role-arn>] [--dry-run]
```

(`--repo` is inferred from the checkout's `origin` remote if omitted. Re-runnable; skips existing
files unless `--force`.)

Then:
1. Edit `CLAUDE.md` (deploy target, heartbeat metric) and `.agent/risk-policy.yml` for the app;
   fill `deploy/` placeholders for AWS targets. Commit and push.
2. Open an issue, add the `neo:build` label, and watch the PR appear.
3. After the first PR runs, lock the gates so they can't be skipped:
   `scripts/set-branch-protection.sh --repo owner/name --dry-run`.

See `templates/target-repo/CLAUDE.md` for the per-repo contract (deploy target, heartbeat metric,
risk policy).
