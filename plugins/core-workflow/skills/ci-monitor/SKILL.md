---
name: ci-monitor
description: Watch a PR's CI checks to completion without burning API rate limits, then react to failures. Use after opening a PR or when asked to check why CI is red.
---

# ci-monitor

Poll a PR's checks efficiently and act on the result.

## Steps
1. Identify the PR: `gh pr view --json number,headRefName,statusCheckRollup`.
2. Poll with backoff (start 20s, cap 60s). Prefer a single rollup call over per-check calls:
   `gh pr checks <number> --watch --interval 20` when available, else loop `gh pr checks <number>`.
   Stop as soon as every required check is `pass` or any is `fail`.
3. On **all pass**: report green and stop. The `ai-review` workflow handles approval/merge.
4. On **failure**:
   - Fetch the failing job's log: `gh run view <run-id> --log-failed`.
   - Diagnose from the actual error output — never guess the root cause without log data.
   - Fix on the same branch, push, and re-enter this skill.
   - Never disable, skip, or `xfail` a test as a "fix". If a test is genuinely flaky, quarantine it
     via the documented flaky-test path and file an issue, don't delete coverage.

## Rate-limit etiquette
Use `--watch` (server-side wait) where possible; otherwise honor backoff. If you hit a secondary
rate limit, sleep 60s and resume.

## Definition of done
Every required check is green, or a fix has been pushed and you are re-watching.
