#!/usr/bin/env bash
# Cut an immutable, fully-pinned neo release.
#
# neo is shared infra: a consumer repo pins `uses: psumiya/neo/...@vX.Y.Z`. For that tag to be
# self-consistent, every self-reference *inside* the tagged tree must also point at the tag — the
# sibling reusable `uses:`, the internal `git clone`s that fetch neo's scripts, and the marketplace
# `ref` that loads its plugins. This script applies those pins on a throwaway commit off clean
# `main`, tags it, and pushes the tag only. `main` keeps floating `@main` refs so it stays
# developable; the tag is the frozen snapshot.
#
# Usage: cut-release.sh vX.Y.Z [--dry-run]
#   --dry-run: apply the transforms, show the diff, but do not tag or push (cleans up after).
set -euo pipefail

VER="${1:-}"
DRYRUN=false
[[ "${2:-}" == --dry-run ]] && DRYRUN=true
[[ "$VER" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: cut-release.sh vX.Y.Z [--dry-run]" >&2; exit 2; }

cd "$(git rev-parse --show-toplevel)"

# Preconditions: clean tree, at origin/main tip, tag not already taken.
[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean; commit or stash first" >&2; exit 1; }
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "HEAD must be at origin/main tip" >&2; exit 1; }
git rev-parse "$VER" >/dev/null 2>&1 && { echo "tag $VER already exists" >&2; exit 1; }

start="$(git rev-parse --abbrev-ref HEAD)"
tmp="release-tmp-$VER"
cleanup() { git switch -q "$start" 2>/dev/null || true; git branch -qD "$tmp" 2>/dev/null || true; }
trap cleanup EXIT
git switch -qc "$tmp"

echo "==> Pinning self-references to $VER"

# 1. Every reusable `uses: psumiya/neo/.github/workflows/<f>.yml@<ref>` -> @VER
#    (covers caller templates already at a version AND sibling calls at @main).
while IFS= read -r f; do
  perl -0pi -e "s{(psumiya/neo/\.github/workflows/[a-z0-9._-]+\.yml)\@[^\s\"']+}{\$1\@$VER}g" "$f"
  echo "  uses -> $VER: $f"
done < <(git grep -lE 'psumiya/neo/\.github/workflows/[a-z0-9._-]+\.yml@' -- '*.yml' || true)

# 2. Internal `git clone ... https://github.com/psumiya/neo.git` -> add --branch VER (idempotent).
while IFS= read -r f; do
  perl -0pi -e "s{git clone --depth 1 (https://github\.com/psumiya/neo\.git)}{git clone --depth 1 --branch $VER \$1}g" "$f"
  echo "  clone --branch $VER: $f"
done < <(git grep -lE 'git clone --depth 1 https://github\.com/psumiya/neo\.git' -- '*.yml' '*.md' || true)

# 3. Marketplace source ref in the target-repo settings template -> VER (pins the plugins).
python3 - "$VER" <<'PY'
import json, sys
ver, p = sys.argv[1], "templates/target-repo/.claude/settings.json"
d = json.load(open(p))
d["extraKnownMarketplaces"]["neo"]["source"]["ref"] = ver
with open(p, "w") as f:
    json.dump(d, f, indent=2); f.write("\n")
print(f"  marketplace ref -> {ver}: {p}")
PY

echo
echo "==> Verifying no unpinned self-references remain"
leftover="$(git grep -nE 'psumiya/neo/\.github/workflows/[a-z0-9._-]+\.yml@main|git clone --depth 1 https://github\.com/psumiya/neo\.git' -- '*.yml' '*.md' || true)"
if [[ -n "$leftover" ]]; then
  echo "FAIL: unpinned references remain:" >&2; echo "$leftover" >&2; exit 1
fi
echo "  clean"

if $DRYRUN; then
  echo; echo "==> [dry-run] diff that WOULD be tagged as $VER:"
  git --no-pager diff
  echo; echo "[dry-run] not tagging or pushing. Cleaning up."
  exit 0
fi

git commit -qam "release $VER (pinned self-references)"
git tag -a "$VER" -m "neo $VER"
git push -q origin "$VER"
echo; echo "==> Tagged and pushed $VER. main is unchanged."
echo "Next: add a $VER section to CHANGELOG.md, and if this is the new stable, bump the caller/"
echo "marketplace refs on main (templates/target-repo) so new installs default to it."
