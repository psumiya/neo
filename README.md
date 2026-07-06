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

**Live proof:** [psumiya/neo-demo](https://github.com/psumiya/neo-demo) runs this pipeline.
[Issue #1](https://github.com/psumiya/neo-demo/issues/1) ("add a truncate function") became
[PR #2](https://github.com/psumiya/neo-demo/pull/2) — implementation, five tests, an eval case,
a GREEN risk classification with AI review, and a squash-merge that closed the issue — with no
human touching the PR.

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

## Prerequisites

- An authenticated `gh` CLI (`gh auth status`).
- An Anthropic API key with billing enabled — it goes into the `ANTHROPIC_API_KEY` secret.
- GitHub Actions enabled on the target repo.
- **The [Claude GitHub App](https://github.com/apps/claude) installed on the target repo.** This is
  required by `anthropics/claude-code-action`. Without it, PRs opened by the build job are created
  with the default `GITHUB_TOKEN`, and GitHub does not trigger `pull_request` workflows for PRs
  created that way — the review gate never runs and the PR stalls unmerged.

## Quick start (per target repo)

Setup is guided and staged so you see every change before it happens: files first (tracked in git),
then GitHub state (labels, auto-merge, secrets — each confirmed and recorded in
`.neo/install-receipt.md`). Two front doors, same engine:

**Inside your repo with Claude Code** (most guided):

```
claude plugin marketplace add psumiya/neo
claude plugin install neo-setup@neo
# then, in your app checkout:
/neo-setup
```

It detects your stack, proposes `.neo/config.yml`, asks your deploy target, and walks the consent
steps. `/neo-uninstall` reverses everything.

**From the shell** (scriptable, no Claude session needed):

```
git clone --depth 1 --branch v0.2.7 https://github.com/psumiya/neo.git && cd neo
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

**Upgrading a consumer repo.** Bump the version in `.github/workflows/neo.yml`,
`.github/workflows/neo-deploy.yml`, and the `ref` under `extraKnownMarketplaces.neo.source` in
`.claude/settings.json` (read `CHANGELOG.md` for breaking changes first). New installs are already
pinned to the current release automatically — `neo-setup` stamps the version from neo's `VERSION`
file into the footprint at install time (override with `--neo-version vX.Y.Z`, or `--neo-version
main` to track the tip).

**Cutting a neo release (maintainers).** Zero-touch: open a PR that bumps the `VERSION` file and adds
a matching `## [X.Y.Z]` section to `CHANGELOG.md` (CI fails the PR if the section is missing). On
merge, `.github/workflows/release.yml` cuts the immutable, fully-pinned tag (sibling `uses:`, the
`git clone`s, and the marketplace `ref` all resolve to the tag) and publishes the GitHub Release from
the changelog. Nothing is run by hand. One-time setup: the workflow needs a `RELEASE_TOKEN` repo
secret (a fine-grained PAT on `psumiya/neo` with contents + workflows write) because the release
commit modifies workflow files, which the default `GITHUB_TOKEN` cannot push. Fallback if the
secret is missing: run `scripts/cut-release.sh` locally from a clean checkout at the `origin/main`
tip.

**Auto-merge caveat.** GitHub does not allow auto-merge on **private** repos on the free plan.
Setup detects this and warns instead of failing; GREEN PRs there wait for a manual merge. Use a
paid plan or a public repo for hands-off GREEN merges.

## Costs

Every PR open/synchronize triggers the evals job plus an AI review run (capped at 25 turns); every
`neo:build` issue triggers a build run (capped at 40 turns). Both run on whatever model the
workflows are configured for (Sonnet by default). Expect API spend roughly proportional to PR and
issue volume, not a fixed monthly number — check your Anthropic Console usage after the first few
runs to calibrate.

## What setup changes for your team

The footprint's `.claude/settings.json` enables the `core-workflow` plugin repo-wide. Its
PreToolUse hook blocks raw `gh pr create` in **every** contributor's interactive Claude Code
session in that repo — humans included, not just agents — so PRs have to go through the
`create-pr` skill instead.

## Troubleshooting

- **Labeled an issue, no PR appears.** Check the Actions run for the `neo` workflow. Confirm
  `ANTHROPIC_API_KEY` is set on the repo and the label is exactly `neo:build`.
- **PR appeared, but no review checks run.** The Claude GitHub App isn't installed — PRs created
  with the default `GITHUB_TOKEN` don't trigger `pull_request` workflows. Install it at
  https://github.com/apps/claude.
- **A GREEN PR sits unmerged.** Either auto-merge isn't enabled (free-plan private repos can't
  enable it — see the caveat above), or your branch protection's required-check names don't match
  the workflow's check names.
- **`workflow was not found` at startup.** The harness repo isn't reachable from your repo:
  reusable workflows resolve only if it's public (or its Actions access policy grants your repo).
  If you forked neo privately, make the fork public or set Settings → Actions → General → Access.
  GitHub reports an arbitrary failing job here, so the workflow it names is usually not the
  problem — check reachability first.
- **`The workflow is requesting 'contents: write' … but is only allowed 'contents: read'`.**
  New repos default `GITHUB_TOKEN` to read-only, and a called reusable workflow can't hold more
  than its caller grants. Installs stamped v0.2.2+ carry job-level `permissions:` blocks in
  `neo.yml`; older installs should copy them from `templates/target-repo/.github/workflows/neo.yml`.
- **Build ran, went green in seconds, no PR and no comments.** The agent's run errored on its
  first API call — most often a bad `ANTHROPIC_API_KEY` or an exhausted Console credit balance.
  From v0.2.2 the build job fails and prints the agent's result payload instead of passing
  silently.
