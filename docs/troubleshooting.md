# Troubleshooting

Failure modes seen in the field, roughly in pipeline order.

## Labeled an issue, no PR appears

Check the Actions run for the `neo` workflow. Confirm `ANTHROPIC_API_KEY` is set on the repo and
the label is exactly `neo:build`.

## Build ran, went green in seconds, no PR and no comments

The agent's run errored on its first API call — most often a bad `ANTHROPIC_API_KEY` or an
exhausted Console credit balance. From v0.2.2 the build job fails and prints the agent's result
payload instead of passing silently.

## PR appeared, but no review checks run

The Claude GitHub App isn't installed — PRs created with the default `GITHUB_TOKEN` don't trigger
`pull_request` workflows. Install it at https://github.com/apps/claude.

## A GREEN PR sits unmerged

Either auto-merge isn't enabled (free-plan private repos can't enable it — GREEN PRs there wait
for a manual merge; use a paid plan or a public repo), or your branch protection's required-check
names don't match the workflow's check names.

## `workflow was not found` at startup

The harness repo isn't reachable from your repo: reusable workflows resolve only if it's public
(or its Actions access policy grants your repo). If you forked neo privately, make the fork
public or set Settings → Actions → General → Access. GitHub reports an arbitrary failing job
here, so the workflow it names is usually not the problem — check reachability first.

## `The workflow is requesting 'contents: write' … but is only allowed 'contents: read'`

New repos default `GITHUB_TOKEN` to read-only, and a called reusable workflow can't hold more
than its caller grants. Installs stamped v0.2.2+ carry job-level `permissions:` blocks in
`neo.yml`; older installs should copy them from
[`templates/target-repo/.github/workflows/neo.yml`](../templates/target-repo/.github/workflows/neo.yml).
