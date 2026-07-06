#!/usr/bin/env bash
# Cut an immutable, fully-pinned neo release. Normally you never run this by hand: bump the VERSION
# file and add a CHANGELOG section in a PR, and .github/workflows/release.yml runs this on merge.
#
# The version comes from the VERSION file (single source of truth; an explicit arg overrides). neo is
# pinned by consumers via `uses: psumiya/neo/...@vX.Y.Z`, so for that tag to be self-consistent every
# self-reference inside the tagged tree is pinned too (sibling `uses:`, the `git clone`s that fetch
# neo's scripts, the marketplace `ref`). Those pins are applied on a throwaway commit off clean
# `main`; the tag is pushed and a GitHub Release is published from the CHANGELOG. `main` is not
# modified — the version bump and notes came from the merged PR.
#
# Usage: cut-release.sh [vX.Y.Z] [--dry-run]
set -euo pipefail

VER="" DRYRUN=false
for a in "$@"; do
  case "$a" in
    --dry-run) DRYRUN=true ;;
    v*) VER="$a" ;;
    *) echo "usage: cut-release.sh [vX.Y.Z] [--dry-run]" >&2; exit 2 ;;
  esac
done
cd "$(git rev-parse --show-toplevel)"
[[ -n "$VER" ]] || VER="$(tr -d '[:space:]' < VERSION 2>/dev/null || true)"
[[ "$VER" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "no valid version (arg or VERSION file): '$VER'" >&2; exit 2; }
BARE="${VER#v}"

# Idempotent: if the tag is already published, this is a no-op (e.g. re-run, or the PR that first
# introduced VERSION at an already-cut tag).
git fetch -q origin --tags
if git rev-parse "$VER" >/dev/null 2>&1; then
  echo "tag $VER already exists — nothing to do."
  exit 0
fi

# Require release notes: the CHANGELOG must have a "## [X.Y.Z]" section. Extract it (trimming
# leading/trailing blank lines) as the release body. Match the header as a literal prefix — passing
# a backslash-escaped regex through `awk -v` mangles it.
notes="$(awk -v hdr="## [$BARE]" '
  index($0, hdr) == 1 {g=1; next}
  g && /^## / {exit}
  g {buf[++n]=$0}
  END {
    s=1; while (s<=n && buf[s] ~ /^[[:space:]]*$/) s++
    e=n; while (e>=s && buf[e] ~ /^[[:space:]]*$/) e--
    for (i=s; i<=e; i++) print buf[i]
  }' CHANGELOG.md)"
[[ -n "$notes" ]] || { echo "CHANGELOG.md has no '## [$BARE]' section — add release notes before releasing." >&2; exit 1; }

# Preconditions for a real cut: clean tree at origin/main tip (CI checks out the pushed main commit).
# Skipped for --dry-run so a preview works from any branch.
if ! $DRYRUN; then
  [[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean" >&2; exit 1; }
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "HEAD must be at origin/main tip" >&2; exit 1; }
fi

start_ref="$(git branch --show-current)"; [[ -n "$start_ref" ]] || start_ref="$(git rev-parse HEAD)"
tmp="release-tmp-$VER"
cleanup() { git switch -q "$start_ref" 2>/dev/null || git switch -q --detach "$start_ref" 2>/dev/null || true; git branch -qD "$tmp" 2>/dev/null || true; }
trap cleanup EXIT
git switch -qc "$tmp"

echo "==> Pinning self-references to $VER"
while IFS= read -r f; do
  perl -0pi -e "s{(psumiya/neo/\.github/workflows/[a-z0-9._-]+\.yml)\@[^\s\"']+}{\$1\@$VER}g" "$f"
done < <(git grep -lE 'psumiya/neo/\.github/workflows/[a-z0-9._-]+\.yml@' -- '*.yml' || true)
while IFS= read -r f; do
  perl -0pi -e "s{git clone --depth 1 (?:--branch \S+ )?(https://github\.com/psumiya/neo\.git)}{git clone --depth 1 --branch $VER \$1}g" "$f"
done < <(git grep -lE 'git clone --depth 1 (--branch [^ ]+ )?https://github\.com/psumiya/neo\.git' -- '*.yml' '*.md' || true)
python3 - "$VER" <<'PY'
import json, sys
ver, p = sys.argv[1], "templates/target-repo/.claude/settings.json"
d = json.load(open(p)); d["extraKnownMarketplaces"]["neo"]["source"]["ref"] = ver
with open(p, "w") as f: json.dump(d, f, indent=2); f.write("\n")
PY

# Any sibling `uses:` or `git clone` still pointing somewhere other than $VER (unpinned @main,
# unpinned clone, or a clone/uses left pinned to a stale ref) is a bug in the rewrite above.
leftover="$({
  git grep -nE 'psumiya/neo/\.github/workflows/[a-z0-9._-]+\.yml@' -- '*.yml' '*.md' | grep -vF "@$VER" || true
  git grep -nE 'git clone --depth 1 (--branch [^ ]+ )?https://github\.com/psumiya/neo\.git' -- '*.yml' '*.md' \
    | grep -vE -- "--branch $VER https://github\.com/psumiya/neo\.git" || true
})"
[[ -z "$leftover" ]] || { echo "FAIL: unpinned references remain:" >&2; echo "$leftover" >&2; exit 1; }
echo "  clean — no unpinned self-references"

if $DRYRUN; then
  echo; echo "==> [dry-run] release notes for $VER:"; printf '%s\n' "$notes"
  echo; echo "==> [dry-run] pinned diff:"; git --no-pager diff
  echo; echo "[dry-run] not tagging, pushing, or releasing."
  exit 0
fi

git commit -qam "release $VER (pinned self-references)"
git tag -a "$VER" -m "neo $VER"
git push -q origin "$VER"
notes_file="$(mktemp)"; printf '%s\n' "$notes" > "$notes_file"
if gh release view "$VER" >/dev/null 2>&1; then
  echo "==> GitHub Release $VER already exists; tag pushed."
else
  gh release create "$VER" --title "neo $VER" --notes-file "$notes_file"
fi
echo "==> Released $VER (tag + GitHub Release). main is unchanged."
