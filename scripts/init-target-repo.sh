#!/usr/bin/env bash
# Deprecated: renamed to neo-setup.sh (guided, staged, less invasive). This shim translates the old
# flags and forwards. Secrets passed via --anthropic-key/--aws-role are moved into a temp key-file
# so they no longer sit in argv; prefer neo-setup.sh --anthropic-key-file directly.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "note: init-target-repo.sh is deprecated; use neo-setup.sh. Forwarding..." >&2

args=(); tmpfiles=()
cleanup() { for f in "${tmpfiles[@]:-}"; do [[ -n "$f" ]] && rm -f "$f"; done; }
trap cleanup EXIT
key_to_file() { local f; f="$(mktemp)"; chmod 600 "$f"; printf '%s' "$1" >"$f"; tmpfiles+=("$f"); printf '%s' "$f"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir|--repo|--force|--dry-run) args+=("$1"); [[ "$1" == --dir || "$1" == --repo ]] && { args+=("$2"); shift; }; shift ;;
    --aws-role) args+=(--deploy aws --aws-role-file "$(key_to_file "$2")"); shift 2 ;;
    --anthropic-key) args+=(--anthropic-key-file "$(key_to_file "$2")"); shift 2 ;;
    --no-plugins) shift ;;  # plugins now load from .claude/settings.json; nothing to install locally
    -h|--help) exec "$SCRIPT_DIR/neo-setup.sh" --help ;;
    *) args+=("$1"); shift ;;
  esac
done

# Old script was non-interactive; preserve that unless the caller is on a TTY.
[[ -t 0 ]] || args+=(--non-interactive)
exec "$SCRIPT_DIR/neo-setup.sh" "${args[@]}"
