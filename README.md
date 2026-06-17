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

1. `cp -r templates/target-repo/{CLAUDE.md,.claude,.agent,.github} <your-repo>/` and edit
   `CLAUDE.md` + `.agent/risk-policy.yml` for that app.
2. Add this marketplace and install the plugins (CI does this headlessly; locally run once):
   ```
   /plugin marketplace add <path-or-git-url-to-agent-harness>
   /plugin install core-workflow@agent-harness
   /plugin install risk-review@agent-harness
   /plugin install evals@agent-harness
   /plugin install deploy-aws@agent-harness   # only for AWS targets
   ```
3. Set repo secrets: `ANTHROPIC_API_KEY` (or Bedrock vars) and configure AWS OIDC role.
4. Open an issue, add the `agent:build` label, and watch the PR appear.

See `templates/target-repo/CLAUDE.md` for the per-repo contract (deploy target, heartbeat metric,
risk policy).
