# Changelog

All notable changes to neo are documented here. neo follows [semantic versioning](https://semver.org).
Consumer repos pin `uses: psumiya/neo/...@vX.Y.Z` and upgrade by bumping the tag (see the README
"Upgrading" section). Each release tag is a fully-pinned, immutable snapshot cut with
`scripts/cut-release.sh`.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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

[Unreleased]: https://github.com/psumiya/neo/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/psumiya/neo/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/psumiya/neo/releases/tag/v0.1.0
