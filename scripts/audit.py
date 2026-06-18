#!/usr/bin/env python3
"""Audit that the harness pipeline actually ran end-to-end for a repo.

Reconciles EXPECTED vs ACTUAL across two layers:
  Layer A (did the workflow fire?): per-PR status checks + per-workflow run history.
  Layer B (did the agent do the work?): durable artifacts each stage should leave —
    a plan comment on the issue, a structured PR body, a risk:* label, a matching deploy run.

Because the harness workflows are REUSABLE (workflow_call), they never show as standalone runs in
the agent-harness repo — they run nested inside the caller (app) repo. So this audits the APP repo.

Usage:
  audit.py --repo owner/app [--days 7] [--deploy-workflow deploy.yml] [--review-workflow ai-review]
Exit 0 = no hard gaps; exit 1 = at least one hard gap (use it as a gate).

Requires the `gh` CLI, authenticated with read access to --repo.
"""
import argparse
import datetime as dt
import json
import re
import subprocess
import sys

BODY_SECTIONS = ["## Intent", "## Tests & evals", "## Risk", "## Rollback"]
CLOSES_RE = re.compile(r"closes #\d+", re.I)
PLAN_MARKERS = ("Files to change", "Risk read", "**Intent")


def gh_json(args):
    out = subprocess.run(["gh"] + args, capture_output=True, text=True)
    if out.returncode != 0:
        print(f"  ! gh {' '.join(args)} failed: {out.stderr.strip()}", file=sys.stderr)
        return []
    return json.loads(out.stdout) if out.stdout.strip() else []


def since_date(days):
    return (dt.datetime.utcnow() - dt.timedelta(days=days)).strftime("%Y-%m-%d")


def run_index(repo, workflow, days):
    """Map head SHA -> conclusion for a workflow's runs in the window."""
    runs = gh_json([
        "run", "list", "--repo", repo, "--workflow", workflow, "--limit", "200",
        "--created", f">={since_date(days)}",
        "--json", "headSha,conclusion,event,createdAt,status",
    ])
    idx = {}
    for r in runs:
        idx.setdefault(r.get("headSha"), r.get("conclusion") or r.get("status"))
    return idx, len(runs)


def pr_checks(pr, review_workflow):
    """Return (ran_review, review_failed, ran_evals) from a PR's statusCheckRollup."""
    ran_review = ran_evals = review_failed = False
    for c in pr.get("statusCheckRollup", []) or []:
        wf = (c.get("workflowName") or "").lower()
        name = (c.get("name") or c.get("context") or "").lower()
        concl = (c.get("conclusion") or c.get("state") or "").upper()
        if review_workflow.lower() in wf or review_workflow.lower() in name:
            ran_review = True
            if concl in ("FAILURE", "ERROR", "CANCELLED"):
                review_failed = True
            if "eval" in name:
                ran_evals = True
    return ran_review, review_failed, ran_evals


def has_plan_comment(repo, issue_number):
    data = gh_json(["issue", "view", str(issue_number), "--repo", repo, "--json", "comments"])
    comments = (data or {}).get("comments", []) if isinstance(data, dict) else []
    return any(any(m in (c.get("body") or "") for m in PLAN_MARKERS) for c in comments)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="owner/name of the app repo to audit")
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--deploy-workflow", default="deploy.yml")
    ap.add_argument("--review-workflow", default="ai-review",
                    help="workflow NAME (not file) that runs risk-classify + evals")
    ap.add_argument("--expected-workflows", default="agent-build.yml,ai-review.yml,deploy.yml",
                    help="comma-separated workflow files expected to have run at least once")
    args = ap.parse_args()
    repo = args.repo

    print(f"# Pipeline audit — {repo} (last {args.days} days)\n")

    # --- Layer A: workflow coverage ---
    print("## Workflow coverage")
    coverage_gap = False
    for wf in [w.strip() for w in args.expected_workflows.split(",") if w.strip()]:
        _, n = run_index(repo, wf, args.days)
        flag = "" if n else "  <- NEVER RAN"
        if not n:
            coverage_gap = True
        print(f"- {wf}: {n} run(s){flag}")
    print()

    deploy_idx, _ = run_index(repo, args.deploy_workflow, args.days)

    # --- Per-PR reconciliation ---
    prs = gh_json([
        "pr", "list", "--repo", repo, "--state", "merged", "--limit", "100",
        "--search", f"merged:>={since_date(args.days)}",
        "--json", "number,title,body,labels,mergedAt,mergeCommit,headRefOid,"
                  "statusCheckRollup,closingIssuesReferences",
    ])

    hard_gaps = []
    soft_gaps = []
    print(f"## Merged PRs ({len(prs)})")
    for pr in prs:
        n = pr["number"]
        labels = {l["name"] for l in pr.get("labels", [])}
        risk_label = next((l for l in labels if l.startswith("risk:")), None)
        body = pr.get("body") or ""
        ran_review, review_failed, ran_evals = pr_checks(pr, args.review_workflow)
        missing_sections = [s for s in BODY_SECTIONS if s not in body]
        has_closes = bool(CLOSES_RE.search(body))
        merge_sha = (pr.get("mergeCommit") or {}).get("oid")
        deploy_concl = deploy_idx.get(merge_sha)

        issues = [r["number"] for r in (pr.get("closingIssuesReferences") or [])]
        plan_ok = any(has_plan_comment(repo, i) for i in issues) if issues else None

        problems = []
        if not risk_label:
            problems.append("no risk:* label (ai-review may not have classified)")
        if not ran_review:
            problems.append("no ai-review status check ran")
        if review_failed:
            problems.append("ai-review check failed")
        if merge_sha and deploy_concl is None:
            problems.append("no deploy run for merge commit")
        elif deploy_concl and deploy_concl.upper() not in ("SUCCESS", "COMPLETED"):
            problems.append(f"deploy run not successful ({deploy_concl})")
        # Layer B soft signals
        softs = []
        if missing_sections:
            softs.append(f"PR body missing {', '.join(missing_sections)}")
        if not has_closes:
            softs.append("PR body has no 'Closes #'")
        if plan_ok is False:
            softs.append("no plan comment on linked issue")

        status = "OK" if not problems else "GAP"
        line = f"- #{n} [{risk_label or 'no-risk'}] {status}: {pr['title'][:60]}"
        if problems:
            line += "\n    HARD: " + "; ".join(problems)
            hard_gaps.append(n)
        if softs:
            line += "\n    soft: " + "; ".join(softs)
            soft_gaps.append(n)
        print(line)
    print()

    # --- Rollbacks (informational) ---
    rollbacks = gh_json([
        "issue", "list", "--repo", repo, "--state", "all", "--label", "rollback",
        "--limit", "50", "--search", f"created:>={since_date(args.days)}",
        "--json", "number,title",
    ])
    print(f"## Rollback/incident issues ({len(rollbacks)})")
    for i in rollbacks:
        print(f"- #{i['number']}: {i['title']}")
    print()

    print("## Summary")
    print(f"- PRs with hard gaps: {sorted(set(hard_gaps)) or 'none'}")
    print(f"- PRs with soft gaps: {sorted(set(soft_gaps)) or 'none'}")
    print(f"- Workflow coverage gap: {'yes' if coverage_gap else 'no'}")

    return 1 if (hard_gaps or coverage_gap) else 0


if __name__ == "__main__":
    sys.exit(main())
