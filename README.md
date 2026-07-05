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

### How the pieces map to the pipeline

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

## Quick start (per target repo)

Setup is guided and staged so you see every change before it happens: files first (tracked in git),
then GitHub state (labels, auto-merge, secrets — each confirmed and recorded in
`.neo/install-receipt.md`). Two front doors, same engine:

**Inside your repo with Claude Code** (most guided):

```
claude plugin marketplace add psumiya/neo
# then, in your app checkout:
/neo-setup
```

It detects your stack, proposes `.neo/config.yml`, asks your deploy target, and walks the consent
steps. `/neo-uninstall` reverses everything.

**From the shell** (scriptable, no Claude session needed):

```
scripts/neo-setup.sh --dir <path-to-app-checkout> [--repo owner/name] \
    [--deploy none|aws] [--anthropic-key-file <f>] [--dry-run]
```

Interactive by default; add `--non-interactive` for CI. `--repo` is inferred from `origin` if
omitted; secrets are read from a file or a hidden prompt, never from the command line. Re-runnable;
existing files are kept, never clobbered, and your repo's `CLAUDE.md` is left untouched.

Then:
1. Edit `.neo/config.yml` (build/test commands, risk policy, and — if `deploy: aws` — the AWS
   service + heartbeat). Commit and push.
2. Open an issue, add the `neo:build` label, and watch the PR appear.
3. After the first PR runs, lock the gates so they can't be skipped:
   `scripts/set-branch-protection.sh --repo owner/name --dry-run`.

See `templates/target-repo/.neo/config.yml` for the per-repo contract (build/test, risk policy,
deploy target, heartbeat).

**Versioning.** The caller workflows pin neo to a release tag (`...@v0.1.0`), not `@main`, so your
pipeline only changes when you bump the tag in `neo.yml` (and `neo-deploy.yml`). Upgrade
deliberately.

**Upgrading.** Each release tag is a fully-pinned, immutable snapshot (the sibling workflows, the
scripts fetched by `git clone`, and the plugin marketplace `ref` all resolve to the same tag — see
`scripts/cut-release.sh`). To move to a new version: read `CHANGELOG.md` for breaking changes, then
bump the version in `.github/workflows/neo.yml`, `.github/workflows/neo-deploy.yml`, and the
`ref` under `extraKnownMarketplaces.neo.source` in `.claude/settings.json`. Maintainers cut a
release with `scripts/cut-release.sh vX.Y.Z`.

**Auto-merge caveat.** GitHub does not allow auto-merge on **private** repos on the free plan.
Setup detects this and warns instead of failing; GREEN PRs there wait for a manual merge. Use a
paid plan or a public repo for hands-off GREEN merges.
