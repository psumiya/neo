---
name: neo-uninstall
description: Remove neo from the current repo and reverse the GitHub-side state it created. Use when the user says "/neo-uninstall", "remove neo", or "undo neo setup".
---

# neo-uninstall

Cleanly back neo out of a repo. The footprint files are in git; the labels, auto-merge, and secrets
are not, so read `.neo/install-receipt.md` first for the exact reversal commands recorded at install.

## Steps
1. `git clone --depth 1 --branch v0.2.0 https://github.com/psumiya/neo.git /tmp/neo` if the scripts aren't present.
2. Run: `/tmp/neo/scripts/neo-setup.sh --uninstall --dir . --repo <owner/name>`
   This removes `.neo/`, `.github/workflows/neo*.yml`, the issue template, deletes the neo labels,
   and disables repo-wide auto-merge. It leaves `.claude/settings.json`, the repo's `CLAUDE.md`, and
   secrets untouched.
3. Secrets are left in place; delete if you want:
   `gh secret delete ANTHROPIC_API_KEY --repo <owner/name>` (and `AWS_ROLE_TO_ASSUME` for aws).
4. If branch protection was set, remove it: `gh api --method DELETE repos/<owner/name>/branches/main/protection`.
5. Commit the file removals.
