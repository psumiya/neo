# Versioning and releases

## How consumers track neo

New installs track the floating major tag (`...@v0`), the same convention as
`actions/checkout@v4`: every release also gets an immutable exact tag (e.g. `v0.2.8`), and `v0`
is re-pointed at the latest release as the final step of each cut. You get fixes the moment they
ship, with no upgrade PR in your repo.

**The compatibility promise:** `v0` only ever moves to a release that needs no change to the
client footprint (`.neo/`, `neo.yml`, `neo-deploy.yml`, `.claude/settings.json`); a release that
does change the footprint gets a new floating tag and an explicit migration note in
`CHANGELOG.md`.

## Pinning instead

If you'd rather upgrade deliberately (neo runs in your CI with merge-capable credentials, so a
narrower grant is a legitimate choice), install with `--neo-version vX.Y.Z` — or a commit SHA for
the narrowest grant, which is what OpenSSF Scorecard recommends for third-party workflows. To
change later, edit the ref in `.github/workflows/neo.yml`, `.github/workflows/neo-deploy.yml`,
and under `extraKnownMarketplaces.neo.source` in `.claude/settings.json` (read `CHANGELOG.md`
first). Exact release tags are never moved or deleted.

## Cutting a release (maintainers)

Zero-touch: open a PR that bumps the `VERSION` file and adds a matching `## [X.Y.Z]` section to
`CHANGELOG.md` (CI fails the PR if the section is missing). On merge,
`.github/workflows/release.yml`:

1. cuts the immutable, fully-pinned tag (sibling `uses:`, the `git clone`s, and the marketplace
   `ref` all resolve to the tag),
2. publishes the GitHub Release from the changelog,
3. force-moves the floating `v0` tag to the release commit — consumers on `@v0` pick it up on
   their next workflow run.

Nothing is run by hand.

**One-time setup:** the workflow needs a `RELEASE_TOKEN` repo secret (a fine-grained PAT on
`psumiya/neo` with contents + workflows write) because the release commit modifies workflow
files, which the default `GITHUB_TOKEN` cannot push.

**Fallback** if the secret is missing: run `scripts/cut-release.sh` locally from a clean checkout
at the `origin/main` tip.
