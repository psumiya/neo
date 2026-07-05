---
name: neo-setup
description: Guided onboarding of the current repo to neo. Use when the user says "set up neo", "/neo-setup", or wants to install the neo harness into a repo. Walks staged consent — files first, then GitHub state — and never overwrites the repo's CLAUDE.md.
---

# neo-setup

Onboard the current repo to neo interactively. You drive the conversation and the consent; the
mutating steps go through the canonical `scripts/neo-setup.sh` so the slash command and the CLI
stay identical. Keep the footprint minimal and reversible.

## 0. Preflight
- Confirm `git` and an authenticated `gh` (`gh auth status`). Resolve the repo from `origin`.
- Get the harness scripts: `git clone --depth 1 --branch v0.1.0 https://github.com/psumiya/neo.git /tmp/neo`.

## 1. Detect the stack, propose config
Inspect the repo and propose values for `.neo/config.yml`:
- `package.json` → build `npm ci`, test `npm test`, lint `npm run lint`.
- `pyproject.toml`/`requirements.txt` → `pip install -e .`, `pytest`, `ruff check`.
- `go.mod` → `go build ./...`, `go test ./...`, `go vet ./...`.
Show the proposed `app` block and ask the user to correct it.

## 2. Deploy target
Ask: `none` or `aws`? Explain `none` ships no deploy workflow (issue → PR → gated-merge; they
deploy themselves) and is the safe default. Only pick `aws` if it's an ECS/CodeDeploy service.

## 3. Apply — files first (reversible)
Run, then let the user review the diff before committing:

    /tmp/neo/scripts/neo-setup.sh --dir . --repo <owner/name> --deploy <none|aws> --non-interactive

Then edit `.neo/config.yml` in place with the values agreed in step 1–2. Never write or overwrite
the repo's root `CLAUDE.md`.

## 4. GitHub state — ask before each
The script (step 3) creates the neo labels and enables repo-wide auto-merge, and writes
`.neo/install-receipt.md`. Confirm the user wants auto-merge before running; if not, tell them to
skip it and set branch protection to require the review checks instead.

For secrets, do **not** handle raw keys. Tell the user to run:
- `gh secret set ANTHROPIC_API_KEY --repo <owner/name>`
- (aws only) `gh secret set AWS_ROLE_TO_ASSUME --repo <owner/name>`

## 5. Hand off
- Commit and push the footprint.
- Open an issue, add the `neo:build` label.
- After the first PR runs, lock the gates: `/tmp/neo/scripts/set-branch-protection.sh --repo <owner/name> --dry-run`.

## Hard rules
- Never overwrite the repo's `CLAUDE.md`. neo reads `.neo/config.yml` and the `neo-contract` skill.
- Files before GitHub state; confirm auto-merge explicitly; record everything non-git in the receipt.
- To reverse: `/neo-uninstall` (the `neo-uninstall` skill) or follow `.neo/install-receipt.md`.
