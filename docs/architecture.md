# Architecture

How neo is laid out, how a change flows through the pipeline, and where the trust boundaries sit.

## Layout

```
neo/
  .claude-plugin/marketplace.json   # the marketplace every target repo installs from
  settings/settings.json            # shared Claude Code settings (telemetry, permissions) to merge into repos
  plugins/
    core-workflow/                  # plan-from-issue, create-pr (gated), ci-monitor, neo-contract + hooks
    risk-review/                    # GREEN/YELLOW/RED PR classifier + reviewer agent
    evals/                          # golden-test + LLM-judge gate
    deploy-aws/                     # reference AWS deploy/rollback adapter (opt-in)
    neo-setup/                      # /neo-setup + /neo-uninstall guided-onboarding commands
  .github/workflows/                # reusable workflows (workflow_call) called by every target repo
  templates/target-repo/            # the minimal drop-in footprint (see below)
  local/                            # local `claude -p` worktree driver for large/babysat tasks
  scripts/                          # neo-setup.sh (+ lib/neo-common.sh), set-branch-protection.sh, metrics
```

The footprint dropped into a target repo is deliberately minimal — everything else is referenced
from the marketplace, not copied:

```
your-app/
  .neo/config.yml                   # the one file you edit: build/test cmds, risk policy, deploy, heartbeat
  .neo/evals/cases/                 # per-repo eval cases
  .claude/settings.json             # enables the neo marketplace + plugins
  .github/workflows/neo.yml         # single caller: issue->build, PR->review, weekly maintenance
  .github/workflows/neo-deploy.yml  # opt-in; added only when deploy target is aws
  .github/ISSUE_TEMPLATE/neo-build.yml
```

Your repo's own `CLAUDE.md` is never touched; the generic working agreement lives in the
`neo-contract` plugin skill, so per-repo files carry only app-specific facts.

## Pipeline stages

| Stage | Where it lives |
|---|---|
| Intake | `templates/target-repo/.github/ISSUE_TEMPLATE/neo-build.yml` + `neo:build` label |
| Issue -> PR | `.github/workflows/neo-build.yml` (cloud) / `local/worktree-driver.sh` (local) |
| Risk gate + auto-merge | `.github/workflows/ai-review.yml` + `plugins/risk-review` + repo `.neo/config.yml` (`risk:`) |
| Eval gate | `.github/workflows/ai-review.yml` calls `plugins/evals` |
| Deploy | `.github/workflows/deploy.yml` + `plugins/deploy-aws` |
| Rollback | `.github/workflows/rollback.yml` (CloudWatch alarm -> revert) |
| Self-improvement | `core-workflow` SessionEnd hook + `.github/workflows/claudemd-factcheck-weekly.yml` |
| Metrics | `.github/workflows/metrics-weekly.yml` + `scripts/metrics.py` |

The target repo's `neo.yml` is a pure event router: it wires `issues` (labeled `neo:build`),
`pull_request`, and a weekly cron to the reusable workflows above and holds no logic of its own.
One subtlety lives in the router: the review job skips `labeled` events for `risk:*` labels,
because the review agent itself applies a `risk:*` label to the PR — without the guard, that
label would re-trigger a redundant second review.

A PR's path through `ai-review.yml`:

1. **Evals** — a hard, deterministic gate. Golden cases run directly; judge-kind cases shell out
   to `claude -p`. This is a required status check, so merge is impossible if it fails.
2. **Risk classification** — `plugins/risk-review/scripts/classify.py` reads the repo's
   `.neo/config.yml` risk policy and labels the PR GREEN, YELLOW, or RED
   (see [configuration.md](configuration.md) for the exact rules).
3. **AI review** — the reviewer agent comments on the PR.
4. **Auto-merge** — GREEN PRs are squash-merged automatically. YELLOW and RED wait for a human;
   RED additionally requires the protected approval that branch protection enforces.

Deploy is a separate opt-in caller (`neo-deploy.yml`, push to `main`). The AWS reference adapter
does build -> pre-prod -> smoke -> canary (CodeDeploy blue-green) -> heartbeat watch -> promote.
The heartbeat is an outcome metric you name in `.neo/config.yml`, not CPU/memory; if the canary's
ratio against baseline drops below `min_ratio` during the bake window, or the CloudWatch alarm
fires later, `rollback.yml` stops the in-flight deployment with auto-rollback.

## Trust boundaries

neo runs in your CI with merge-capable credentials, so it's worth being precise about who holds
what:

- **`GITHUB_TOKEN`** — each job in the target repo's `neo.yml` carries an explicit job-level
  `permissions:` block (a called reusable workflow can never hold more than its caller grants).
  The build and review jobs get `contents: write` and `pull-requests: write`; that is what lets
  them push branches and merge GREEN PRs.
- **`ANTHROPIC_API_KEY`** — a repo secret, passed to the build/review/maintenance jobs. It is the
  only non-GitHub credential the core pipeline holds.
- **Claude GitHub App** — `anthropics/claude-code-action` exchanges an OIDC token for its GitHub
  App token at startup (hence `id-token: write` on those jobs). PRs are opened with the App's
  identity rather than `GITHUB_TOKEN`, which is what makes GitHub trigger the `pull_request`
  review workflow on them.
- **AWS** — deploy and rollback authenticate via OIDC role assumption
  (`aws_role_to_assume` secret); no long-lived AWS keys.
- **Branch protection** — the gates are advisory until you run
  `scripts/set-branch-protection.sh`, which marks the evals and review checks required. After
  that, the gates cannot be skipped, by agents or humans.
- **The `create-pr` gate** — the footprint's `.claude/settings.json` enables `core-workflow`
  repo-wide, and its PreToolUse hook blocks raw `gh pr create` in every contributor's interactive
  Claude Code session in that repo, humans included, so PRs go through the `create-pr` skill.

## Plugin reference

Each skill documents itself; the SKILL.md is the source of truth:

- `core-workflow`: [plan-from-issue](../plugins/core-workflow/skills/plan-from-issue/SKILL.md),
  [create-pr](../plugins/core-workflow/skills/create-pr/SKILL.md),
  [ci-monitor](../plugins/core-workflow/skills/ci-monitor/SKILL.md),
  [neo-contract](../plugins/core-workflow/skills/neo-contract/SKILL.md)
- `risk-review`: [risk-classify](../plugins/risk-review/skills/risk-classify/SKILL.md),
  [risk-reviewer agent](../plugins/risk-review/agents/risk-reviewer.md)
- `evals`: [run-evals](../plugins/evals/skills/run-evals/SKILL.md)
- `deploy-aws`: [deploy-aws](../plugins/deploy-aws/skills/deploy-aws/SKILL.md),
  [rollback-aws](../plugins/deploy-aws/skills/rollback-aws/SKILL.md)
- `neo-setup`: [neo-setup](../plugins/neo-setup/skills/neo-setup/SKILL.md),
  [neo-uninstall](../plugins/neo-setup/skills/neo-uninstall/SKILL.md)
