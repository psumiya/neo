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

This repo is a plugin marketplace plus reusable GitHub workflows; a target repo installs a
minimal footprint (one config file, one caller workflow, an issue template) and references
everything else from here. Every PR passes a deterministic eval gate, a GREEN/YELLOW/RED risk
classifier driven by your repo's policy, and an AI review; GREEN PRs auto-merge, and the opt-in
AWS adapter deploys blue-green with heartbeat-driven rollback.

See [docs/architecture.md](docs/architecture.md) for the layout, pipeline stages, and trust
boundaries, and [docs/configuration.md](docs/configuration.md) for the `.neo/config.yml`
reference.

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
git clone --depth 1 https://github.com/psumiya/neo.git && cd neo
scripts/neo-setup.sh --dir <path-to-app-checkout> [--repo owner/name] \
    [--deploy none|aws] [--anthropic-key-file <f>] [--dry-run]
```

Interactive by default; add `--non-interactive` for CI. `--repo` is inferred from `origin` if
omitted; secrets are read from a file or a hidden prompt, never from the command line. Re-runnable;
existing files are kept, never clobbered, and your repo's `CLAUDE.md` is left untouched.

Then:
1. Edit `.neo/config.yml` (build/test commands, risk policy, and — if `deploy: aws` — the AWS
   service + heartbeat). Commit and push. See [docs/configuration.md](docs/configuration.md).
2. Open an issue, add the `neo:build` label, and watch the PR appear.
3. After the first PR runs, lock the gates so they can't be skipped:
   `scripts/set-branch-protection.sh --repo owner/name --dry-run`.

**Versioning.** New installs track the floating `v0` tag and pick up releases automatically; `v0`
only ever moves to a release that needs no change to your repo's footprint. Pin an exact tag or
SHA instead if you want a narrower grant. Details, and the maintainer release process, in
[docs/releasing.md](docs/releasing.md).

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

Common failure modes (no PR after labeling, review checks not running, GREEN PRs stuck unmerged,
`workflow was not found`, permission errors) are collected in
[docs/troubleshooting.md](docs/troubleshooting.md).
