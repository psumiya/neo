# Changelog

All notable changes to neo are documented here. neo follows [semantic versioning](https://semver.org).
Consumer repos pin `uses: psumiya/neo/...@vX.Y.Z` and upgrade by bumping the tag (see the README
"Upgrading" section). Each release tag is a fully-pinned, immutable snapshot cut with
`scripts/cut-release.sh`.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.2.7] - 2026-07-06

### Fixed
- **Weekly metrics job no longer crashes.** `metrics-weekly.yml` runs `scripts/metrics.py`
  without checking out the target repo, so every `gh` call failed with no repo context (the
  stderr was swallowed, leaving only an opaque exit-1 traceback). The script now passes
  `--repo $GITHUB_REPOSITORY` when Actions provides it, prints gh's stderr on real failures,
  and treats a missing deploy workflow (gh 404) as zero deploys — consumer repos without a
  deploy target previously crashed on the default `deploy.yml` lookup.
- **Risk classifier matches `**/` globs against root-level files.** `fnmatch` compiles `**/x`
  to `.*/x`, requiring at least one directory, so root-level files never matched recursive
  globs in either direction: `README.md` fell outside `green_paths` (`**/*.md`) and a docs-only
  fact-check PR classified YELLOW instead of GREEN (neo-demo PR #5), while a root-level
  `init.sql` or `Dockerfile` missed `blocked_paths` and classified YELLOW instead of RED.
  Each pattern is now also tried with its leading `**/` stripped; the blocked-path side is a
  deliberate change toward the conservative tier.

## [0.2.6] - 2026-07-06

### Fixed
- **Template settings.json no longer denies `gh pr merge`.** claude-code-action loads the target
  repo's project settings (`settingSources: user, project, local`), and deny rules always win —
  so the shipped deny blocked the review lane's GREEN auto-merge: on neo-demo PR #2 the agent
  classified GREEN, approved, and was silently refused the merge. The no-merge invariant for the
  build and fact-check lanes is enforced by their `--disallowedTools` (since v0.2.3), which is
  the right scope: the review lane is the merge authority. (This also corrects v0.2.3's claim
  that project settings are not loaded in CI — the action does load them; deny rules apply,
  though allow rules alone proved insufficient to approve tools in headless runs.)

## [0.2.5] - 2026-07-06

### Fixed
- **Review lane accepts bot-initiated events (`allowed_bots: claude`).** The pipeline is
  bot-driven end to end: the PR under review is opened by the claude App, so the `pull_request`
  event's actor is a bot and claude-code-action refused to start ("Workflow initiated by
  non-human actor"). The automatic issue→PR→review chain never worked without this.
- **Caller template skips `risk:*` label echoes.** The review agent's own risk labeling fired
  `pull_request: labeled` again, spawning a redundant second review per PR.
- **Default risk policy no longer blocks `.neo/evals/**`.** Builders are required to add eval
  cases under `.neo/evals/cases/`, but `.neo/**` was a blocked prefix, so every rule-following
  behavioral PR classified RED (both the build and review agents flagged the contradiction on
  neo-demo PR #2). The blocked set is now `.neo/config.yml` and `.neo/deploy/**`.
- **Review prompt handles repos without branch protection.** `gh pr merge --auto` fails when no
  required checks exist; the agent now verifies checks and merges GREEN PRs directly in that case.

## [0.2.4] - 2026-07-06

### Fixed
- **Review and fact-check lanes grant `id-token: write`.** `claude-code-action` exchanges an OIDC
  token for its GitHub App token at startup and dies before the agent runs without it. `neo-build`
  already declared it (which is why the build lane worked); `ai-review`,
  `claudemd-factcheck-weekly`, and the template caller's review/maintenance jobs now do too.

## [0.2.3] - 2026-07-06

### Fixed
- **Agent lanes grant tool permissions explicitly via `claude_args`.** `claude-code-action` runs
  Claude through the Agent SDK, which does not load the target repo's `.claude/settings.json` —
  the permissions block neo ships there never applied in CI. The build agent ran deny-by-default,
  was refused every `gh`/`git`/test command (25 denials), and burned all 40 turns without opening
  a PR. Each lane now passes `--allowedTools`/`--disallowedTools`: the builder and fact-checker
  get broad Bash but can never `gh pr merge` (and raw `gh pr create` stays hook-blocked); the
  review lane keeps merge rights since GREEN auto-merge is its job. The settings.json permissions
  block still governs local/interactive use only.

## [0.2.2] - 2026-07-05

First release validated end-to-end against a real consumer repo
([psumiya/neo-demo](https://github.com/psumiya/neo-demo)). Every fix below is a failure that repo
actually hit on its first `neo:build` issue.

### Fixed
- **Target-repo callers now grant job-level `permissions:`.** New repos default `GITHUB_TOKEN` to
  read-only and a called reusable workflow can never exceed its caller's grant, so every lane
  (`neo-build`, `ai-review`, `maintenance`, deploy/rollback) failed at startup with
  "requesting 'contents: write' … only allowed 'contents: read'" on a fresh install. `neo.yml` and
  `neo-deploy.yml` templates now grant each job exactly what its reusable workflow declares.
- **`neo-build` fails loudly when the agent's run errors.** The action step reported success even
  when the agent died on turn 1 (bad API key, exhausted credit balance), leaving a green run that
  silently produced nothing. The job now parses the execution log and fails with the agent's
  result payload.
- **The evals job installs the Claude Code CLI.** Judge-kind cases shell out to `claude -p`, which
  was never installed on the runner; any repo with a judge case failed its eval gate on every PR.
- **The template eval case no longer ships live.** `example.yaml` targeted a made-up app, so a
  fresh install's first PR failed the eval gate out of the box. It's now `example.yaml.disabled`
  (schema reference only); the gate passes vacuously until you add real cases.

### Added
- README troubleshooting for the two worst-reported GitHub failure modes: `workflow was not found`
  (harness repo not reachable — private fork or Actions access policy; GitHub names an arbitrary
  job in the error) and the read-only-token permissions refusal.

## [0.2.1] - 2026-07-05

### Fixed
- **`cut-release.sh --dry-run` no longer dirties the working tree.** The dry-run applied the pin
  edits on a throwaway branch and switched back without committing, leaving them as uncommitted
  modifications the caller had to revert by hand. The pinning now runs inside a disposable detached
  worktree; the caller's checkout is never touched.
- **CI floating-refs guard covers the JSON marketplace `ref`.** The guard checked `*.yml` and
  `*.md` but not `*.json`, so a pinned `"ref"` in `templates/target-repo/.claude/settings.json`
  would slip through. It now fails on any `"ref"` other than `"main"` in settings JSON under
  `templates/` or `plugins/`.
- **`release.yml` pushes the release with `RELEASE_TOKEN`.** The tag push was always rejected:
  the release commit rewrites `.github/workflows/*.yml`, and the default `GITHUB_TOKEN` can never
  be granted the `workflows` permission GitHub requires for pushes that change workflow files.
  The workflow now checks out and pushes with a `RELEASE_TOKEN` fine-grained PAT (contents +
  workflows write) and fails fast with setup instructions when the secret is missing.

## [0.2.0] - 2026-07-05

### Added
- **Zero-touch releases.** A `VERSION` file is the single source of truth; `.github/workflows/release.yml`
  cuts the pinned tag and publishes the GitHub Release automatically when `VERSION` changes on `main`.
  `neo-setup` stamps the resolved version into a new install's footprint (`--neo-version` to override),
  so the caller/marketplace refs no longer need manual bumping. CI enforces that `VERSION` always has
  a matching `CHANGELOG.md` section.

### Fixed
- **Restored floating self-references on `main`.** A prior change hardcoded `v0.2.0` into 15
  sibling `uses:`, `git clone`, and marketplace `ref` self-references on `main` while no such tag
  existed, breaking `/neo-setup` for new users (it cloned a nonexistent branch) and silently
  no-op'ing `cut-release.sh`'s rewrite. `main` now carries `@main`/unpinned refs again, per the
  documented release design.
- **`cut-release.sh` re-pins already-pinned clones.** The clone-pinning rewrite and its `leftover`
  check previously only recognized the unpinned `git clone` form, so a self-reference already
  pinned to a stale tag would silently survive a new release cut. Both now match an optional
  `--branch <ref>` and re-pin/verify against the version being cut.
- **CI guard for the floating-refs invariant.** `.github/workflows/ci.yml` now fails if `main`
  contains a pinned self-reference (`uses: psumiya/neo/...@<tag>` or a `--branch`-pinned clone)
  under `.github/workflows/`, `templates/`, or `plugins/`.
- **README + `/neo-setup` onboarding fixes.** Documented the missing `claude plugin install`
  step for the Claude Code quick start, the missing `git clone` step for the shell quick start,
  prerequisites (including the Claude GitHub App, required for PR review checks to trigger),
  an approximate cost note, the repo-wide `gh pr create`-blocking hook, and a troubleshooting
  section for the most common stuck states.

## [0.1.0] - 2026-07-05

First tagged release. Establishes the onboarding, the safety gates, and the release process.

### Added
- **Guided, staged onboarding.** `scripts/neo-setup.sh` (+ `scripts/lib/neo-common.sh`) and the
  `/neo-setup` / `/neo-uninstall` plugin commands install neo with staged consent (files first,
  then GitHub state), a `.neo/install-receipt.md` recording every non-git change and its reversal,
  and a full `--uninstall` path. Secrets are read from a file or a hidden prompt, never argv.
- **Minimal, plugin-first footprint.** A target repo carries only `.neo/config.yml` (the one file
  a user edits), `.claude/settings.json`, one `neo.yml` caller (plus opt-in `neo-deploy.yml`), and
  the issue template. The generic working agreement lives in the `neo-contract` plugin skill; a
  repo's own `CLAUDE.md` is never touched.
- **CI + tests** (`.github/workflows/ci.yml`, `tests/`): pytest coverage of the risk classifier,
  eval gate, and heartbeat decision, plus shellcheck, actionlint, manifest validation, and an
  installer dry-run smoke. Secretless.
- **Immutable releases.** `scripts/cut-release.sh vX.Y.Z` pins every self-reference (sibling
  `uses:`, internal `git clone`s, and the marketplace `ref`) to the tag on a throwaway commit,
  tags it, and pushes the tag; `main` keeps floating `@main` refs for development.
- **Reference AWS deploy/rollback adapter** (opt-in): blue-green canary via CodeDeploy watched by a
  CloudWatch heartbeat, with an alarm→`repository_dispatch` rollback path.

### Known limitations
- GitHub blocks auto-merge on free-plan private repos; setup warns rather than failing.

[Unreleased]: https://github.com/psumiya/neo/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/psumiya/neo/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/psumiya/neo/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/psumiya/neo/releases/tag/v0.1.0
