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
# After the immutable tag is published, the floating major tag (v0) is force-moved to the same
# commit. Consumers track that tag by default; exact tags remain for pinning.
#
# Usage: cut-release.sh [vX.Y.Z] [--dry-run]
# --dry-run previews the release notes and the pinned diff from a disposable detached worktree;
# the caller's checkout is never modified.
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

# Idempotent: if the tag is already published, only make sure the floating major tag points at it
# (repairs a cut that failed between the release and the tag move), then no-op.
git fetch -q origin --tags --force
if git rev-parse "$VER" >/dev/null 2>&1; then
  FLOAT="v${BARE%%.*}"
  if [[ "$(git rev-parse "$FLOAT^{}" 2>/dev/null)" != "$(git rev-parse "$VER^{}")" ]]; then
    if $DRYRUN; then
      echo "[dry-run] tag $VER already exists; would move floating tag $FLOAT to it."
      exit 0
    fi
    echo "tag $VER already exists — moving floating tag $FLOAT to it."
    git tag -fa "$FLOAT" -m "neo $FLOAT (currently $VER)" "$VER^{}"
    git push -f -q origin "$FLOAT"
  else
    echo "tag $VER already exists and $FLOAT points at it — nothing to do."
  fi
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

# Rewrite every self-reference in the current directory to $VER: sibling `uses:`, the `git clone`s,
# and the marketplace `ref`. Runs on the throwaway branch for a real cut, in a disposable worktree
# for --dry-run.
apply_pins() {
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
  local leftover
  leftover="$({
    git grep -nE 'psumiya/neo/\.github/workflows/[a-z0-9._-]+\.yml@' -- '*.yml' '*.md' | grep -vF "@$VER" || true
    git grep -nE 'git clone --depth 1 (--branch [^ ]+ )?https://github\.com/psumiya/neo\.git' -- '*.yml' '*.md' \
      | grep -vE -- "--branch $VER https://github\.com/psumiya/neo\.git" || true
  })"
  [[ -z "$leftover" ]] || { echo "FAIL: unpinned references remain:" >&2; echo "$leftover" >&2; exit 1; }
  echo "  clean — no unpinned self-references"
}

# Dry-run: pin inside a disposable detached worktree at HEAD so the caller's tree is never touched.
if $DRYRUN; then
  wt="$(mktemp -d)/neo-dryrun-$VER"
  # shellcheck disable=SC2329  # invoked via the EXIT trap
  cleanup() { git worktree remove --force "$wt" 2>/dev/null || true; }
  trap cleanup EXIT
  git worktree add -q --detach "$wt" HEAD
  (cd "$wt" && apply_pins)
  echo; echo "==> [dry-run] release notes for $VER:"; printf '%s\n' "$notes"
  echo; echo "==> [dry-run] pinned diff:"; git -C "$wt" --no-pager diff
  echo; echo "[dry-run] not tagging, pushing, or releasing (would also move floating tag v${BARE%%.*} to the release commit)."
  exit 0
fi

# Preconditions for a real cut: clean tree at origin/main tip (CI checks out the pushed main commit).
[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean" >&2; exit 1; }
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "HEAD must be at origin/main tip" >&2; exit 1; }

start_ref="$(git branch --show-current)"; [[ -n "$start_ref" ]] || start_ref="$(git rev-parse HEAD)"
tmp="release-tmp-$VER"
cleanup() { git switch -q "$start_ref" 2>/dev/null || git switch -q --detach "$start_ref" 2>/dev/null || true; git branch -qD "$tmp" 2>/dev/null || true; }
trap cleanup EXIT
git switch -qc "$tmp"

apply_pins

git commit -qam "release $VER (pinned self-references)"
git tag -a "$VER" -m "neo $VER"
git push -q origin "$VER"
notes_file="$(mktemp)"; printf '%s\n' "$notes" > "$notes_file"
if gh release view "$VER" >/dev/null 2>&1; then
  echo "==> GitHub Release $VER already exists; tag pushed."
else
  gh release create "$VER" --title "neo $VER" --notes-file "$notes_file"
fi

# Last step, only after the immutable tag and Release exist: re-point the floating major tag
# (v0.2.7 -> v0) that consumers track by default. Force-push is the point — this tag moves on
# every compatible release. No GitHub Release is ever published for it, so it stays movable even
# with immutable releases enabled on the repo.
FLOAT="v${BARE%%.*}"
echo "==> Moving floating tag $FLOAT -> $VER"
git tag -fa "$FLOAT" -m "neo $FLOAT (currently $VER)"
git push -f -q origin "$FLOAT"
echo "==> Released $VER (tag + GitHub Release); $FLOAT now points at it. main is unchanged."
