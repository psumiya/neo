# agent-harness

An Intercom/Fin-inspired **autonomous coding harness** for Claude Code. You feed a requirement in as a
GitHub issue; the harness produces a PR, gates it on tests + evals + risk classification,
auto-merges the low-risk ones, deploys on merge, and auto-rolls-back on bad outcome signals — so you
write ~no code and review little.

Modeled on:
- [2x: Nine Months Later](https://ideas.fin.ai/p/2x-nine-months-later)
- [How we use Claude Code today at Intercom](https://ideas.fin.ai/p/how-we-use-claude-code-today-at-intercom)
- [The safety of speed: shipping code at Intercom](https://www.intercom.com/blog/the-safety-of-speed-shipping-code-at-intercom/)

## Layout

```
agent-harness/
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

## How the pieces map to the pipeline

| Stage | Where it lives |
|---|---|
| Intake | `templates/target-repo/.github/ISSUE_TEMPLATE/agent-build.yml` + `agent:build` label |
| Issue -> PR | `.github/workflows/agent-build.yml` (cloud) / `local/worktree-driver.sh` (local) |
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
2. Open an issue, add the `agent:build` label, and watch the PR appear.
3. After the first PR runs, lock the gates so they can't be skipped:
   `scripts/set-branch-protection.sh --repo owner/name --dry-run`.

See `templates/target-repo/CLAUDE.md` for the per-repo contract (deploy target, heartbeat metric,
risk policy).
