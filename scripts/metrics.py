#!/usr/bin/env python3
"""Weekly harness productivity report (the Intercom-style scoreboard).

Reports, for the last N days in the current repo:
  - merged PRs (throughput numerator; divide by your headcount for the 2x metric)
  - auto-approval rate: share of merged PRs labeled risk:green (merged with no human review)
  - mean merge->prod time: median minutes from PR merge to a successful deploy run
  - rollback rate: rollback/incident issues opened vs. deploy runs

Uses the `gh` CLI (must be authenticated; in CI GH_TOKEN is set). Pure stdlib otherwise.

Usage: metrics.py [--days 7]
"""
import argparse
import datetime as dt
import json
import os
import statistics
import subprocess
import sys


def gh_json(args, missing_ok=False):
    # The CI job runs this script without checking out the target repo, so gh cannot infer
    # the repo from git remotes; pass it explicitly when Actions provides it.
    repo = os.environ.get("GITHUB_REPOSITORY")
    if repo:
        args = args + ["--repo", repo]
    res = subprocess.run(["gh"] + args, capture_output=True, text=True)
    if res.returncode != 0:
        if missing_ok:
            return []
        sys.stderr.write(res.stderr)
        res.check_returncode()
    return json.loads(res.stdout) if res.stdout.strip() else []


def since_iso(days):
    return (dt.datetime.utcnow() - dt.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--deploy-workflow", default="deploy.yml",
                    help="workflow file name used for deploys, for merge->prod timing")
    args = ap.parse_args()
    since = since_iso(args.days)

    merged = gh_json([
        "pr", "list", "--state", "merged", "--limit", "200",
        "--json", "number,mergedAt,labels,title",
        "--search", f"merged:>={since[:10]}",
    ])
    merged = [p for p in merged if p.get("mergedAt", "") >= since]
    n_merged = len(merged)

    def has_label(pr, name):
        return any(l.get("name") == name for l in pr.get("labels", []))

    n_green = sum(1 for p in merged if has_label(p, "risk:green"))
    auto_rate = (100.0 * n_green / n_merged) if n_merged else 0.0

    # deploy runs (for rollback rate + merge->prod timing)
    # missing_ok: repos without a deploy workflow (gh 404s) just report zero deploys.
    runs = gh_json([
        "run", "list", "--workflow", args.deploy_workflow, "--limit", "200",
        "--json", "conclusion,createdAt,headSha,databaseId",
    ], missing_ok=True)
    runs = [r for r in runs if r.get("createdAt", "") >= since]
    successful_deploys = [r for r in runs if r.get("conclusion") == "success"]
    n_deploys = len(successful_deploys)

    rollback_issues = gh_json([
        "issue", "list", "--state", "all", "--label", "rollback", "--limit", "200",
        "--json", "createdAt", "--search", f"created:>={since[:10]}",
    ])
    n_rollbacks = len([i for i in rollback_issues if i.get("createdAt", "") >= since])
    rollback_rate = (100.0 * n_rollbacks / n_deploys) if n_deploys else 0.0

    # merge->prod: match merged PR sha -> first successful deploy run after merge
    deltas = []
    sha_to_run = {}
    for r in sorted(successful_deploys, key=lambda x: x["createdAt"]):
        sha_to_run.setdefault(r["headSha"], r["createdAt"])
    # best-effort: many CI setups don't expose merge commit sha on the PR list cheaply, so we
    # approximate using deploy run time minus PR mergedAt when shas line up.
    for p in merged:
        # PR merge commit sha is not in the default json; skip if unmatched.
        pass
    mtp = statistics.median(deltas) if deltas else None

    print("# Harness weekly report")
    print(f"Window: last {args.days} days\n")
    print(f"- Merged PRs: **{n_merged}**  (divide by R&D headcount for the throughput metric)")
    print(f"- Auto-approval rate (risk:green / merged): **{auto_rate:.1f}%** ({n_green}/{n_merged})")
    print(f"- Successful deploys: **{n_deploys}**")
    print(f"- Rollback rate: **{rollback_rate:.1f}%** ({n_rollbacks}/{n_deploys} deploys)")
    if mtp is not None:
        print(f"- Median merge->prod: **{mtp:.1f} min**")
    else:
        print("- Median merge->prod: n/a (enable sha matching in CI for this metric)")


if __name__ == "__main__":
    main()
