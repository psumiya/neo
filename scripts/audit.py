#!/usr/bin/env python3
"""Audit that the harness pipeline actually ran end-to-end for a repo.

Reconciles EXPECTED vs ACTUAL across two layers:
  Layer A (did the workflow fire?): per-PR status checks + per-workflow run history.
  Layer B (did the agent do the work?): durable artifacts each stage should leave —
    a plan comment on the issue, a structured PR body, a risk:* label, a matching deploy run.

Because the harness workflows are REUSABLE (workflow_call), they never show as standalone runs —
not in the neo repo, and not in the app repo either. A caller (e.g. `neo.yml`) invokes them and the
runs are attributed to the CALLER's file, with the callee's jobs nested under the calling job name.
So coverage is resolved by reading the app repo's own workflow files, mapping each harness workflow
to the caller job that invokes it, and looking for that job in the caller's runs.

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
# `uses: owner/repo/.github/workflows/<file>@ref` — a reusable-workflow call, not an action.
REUSABLE_USES_RE = re.compile(r"uses:\s*\S+/\.github/workflows/([\w.-]+\.ya?ml)@")
# A top-level mapping key (2-space indent, no inline value) — job ids look like this.
TOP_KEY_RE = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")
# Cap on `gh run view` calls spent resolving nested job names.
MAX_JOB_LOOKUPS = 120


def gh_json(args):
    out = subprocess.run(["gh"] + args, capture_output=True, text=True)
    if out.returncode != 0:
        print(f"  ! gh {' '.join(args)} failed: {out.stderr.strip()}", file=sys.stderr)
        return []
    return json.loads(out.stdout) if out.stdout.strip() else []


def gh_text(args):
    out = subprocess.run(["gh"] + args, capture_output=True, text=True)
    if out.returncode != 0:
        return ""
    return out.stdout


def since_date(days):
    return (dt.datetime.utcnow() - dt.timedelta(days=days)).strftime("%Y-%m-%d")


def parse_callers(text):
    """Map reusable workflow file -> [caller job id] for one workflow file's YAML text."""
    found = {}
    job = None
    for line in text.splitlines():
        key = TOP_KEY_RE.match(line)
        if key:
            job = key.group(1)
            continue
        use = REUSABLE_USES_RE.search(line)
        if use:
            found.setdefault(use.group(1), []).append(job)
    return found


def deploy_target(config_text):
    """Read deploy.target out of .neo/config.yml. Returns None if absent/unparseable."""
    in_deploy = False
    for line in config_text.splitlines():
        if re.match(r"^deploy:\s*$", line):
            in_deploy = True
            continue
        if in_deploy:
            if line and not line[0].isspace():
                break
            m = re.match(r"^  target:\s*([A-Za-z0-9_-]+)", line)
            if m:
                return m.group(1)
    return None


def repo_file(repo, path):
    return gh_text(["api", f"repos/{repo}/contents/{path}",
                    "-H", "Accept: application/vnd.github.raw"])


def caller_map(repo):
    """Map reusable workflow file -> [(caller workflow file, caller job id)] for the app repo."""
    entries = gh_json(["api", f"repos/{repo}/contents/.github/workflows"])
    callers = {}
    if not isinstance(entries, list):
        return callers
    for e in entries:
        name = e.get("name") or ""
        if not name.endswith((".yml", ".yaml")):
            continue
        for callee, jobs in parse_callers(repo_file(repo, e.get("path"))).items():
            callers.setdefault(callee, []).extend((name, j) for j in jobs)
    return callers


def workflow_runs(repo, workflow, days, cache):
    """Runs of a workflow FILE in the window, newest first."""
    if workflow not in cache:
        cache[workflow] = gh_json([
            "run", "list", "--repo", repo, "--workflow", workflow, "--limit", "200",
            "--created", f">={since_date(days)}",
            "--json", "databaseId,headSha,conclusion,event,createdAt,status",
        ])
    return cache[workflow]


def run_index(repo, workflow, days, cache=None):
    """Map head SHA -> conclusion for a workflow's runs in the window."""
    runs = workflow_runs(repo, workflow, days, {} if cache is None else cache)
    idx = {}
    for r in runs:
        idx.setdefault(r.get("headSha"), r.get("conclusion") or r.get("status"))
    return idx, len(runs)


def job_ran(repo, run_id, job_id, cache):
    """Did `job_id` actually execute in this run?

    Nested reusable jobs render as '<caller job> / <job>'. A caller job gated off by an `if:` still
    shows up in the job list with conclusion `skipped`, so those don't count as coverage.
    """
    if run_id not in cache:
        data = gh_json(["run", "view", str(run_id), "--repo", repo, "--json", "jobs"])
        jobs = (data or {}).get("jobs", []) if isinstance(data, dict) else []
        cache[run_id] = [(j.get("name") or "", (j.get("conclusion") or "").lower()) for j in jobs]
    return any((n == job_id or n.startswith(f"{job_id} / ")) and c != "skipped"
               for n, c in cache[run_id])


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
    ap.add_argument("--expected-workflows", default="",
                    help="comma-separated workflow files to check; default is to derive the set "
                         "from the app repo's own workflow files")
    args = ap.parse_args()
    repo = args.repo

    print(f"# Pipeline audit — {repo} (last {args.days} days)\n")

    # Deploy is opt-in: `deploy.target: none` ships no deploy workflow, so a missing deploy run is
    # the configuration working as intended, not a gap.
    target = deploy_target(repo_file(repo, ".neo/config.yml"))
    deploy_expected = target is not None and target.lower() != "none"

    # --- Layer A: workflow coverage ---
    # Resolve each expected workflow through the caller that invokes it: consolidated installs run
    # everything nested inside one caller file, so callee filenames never appear in `gh run list`.
    callers = caller_map(repo)
    explicit = [w.strip() for w in args.expected_workflows.split(",") if w.strip()]
    stages = {w: callers.get(w) or [(w, None)] for w in explicit} if explicit else dict(callers)

    run_cache, jobs_cache = {}, {}
    budget = MAX_JOB_LOOKUPS
    total_runs = 0
    print("## Workflow coverage")
    if not stages:
        print("- no neo workflows installed in this repo")
    for wf in sorted(stages):
        if not deploy_expected and (wf == args.deploy_workflow or "deploy" in wf):
            print(f"- {wf}: skipped (deploy.target: {target or 'unset'})")
            continue
        for caller, job in stages[wf]:
            runs = workflow_runs(repo, caller, args.days, run_cache)
            total_runs += len(runs)
            approx = ""
            if job is None:
                n = len(runs)
            else:
                n = 0
                for r in runs:
                    if budget <= 0:
                        n, approx = len(runs), "  (job detail unavailable; caller runs counted)"
                        break
                    budget -= 1
                    if job_ran(repo, r.get("databaseId"), job, jobs_cache):
                        n += 1
            via = f" (via {caller} job `{job}`)" if job else ""
            print(f"- {wf}{via}: {n} run(s){approx}")
    # A stage with no runs in a quiet week is normal — build fires on labeled issues, review on PRs.
    # The real coverage signal is a pipeline that fired for nothing at all.
    coverage_gap = bool(stages) and total_runs == 0
    if coverage_gap:
        print(f"\n  <- DORMANT: no runs of any neo caller workflow in {args.days} days")
    print()

    deploy_idx = {}
    if deploy_expected:
        deploy_idx, _ = run_index(repo, args.deploy_workflow, args.days, run_cache)

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
        if deploy_expected and merge_sha and deploy_concl is None:
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
    print(f"- Workflow coverage gap: {'yes (pipeline dormant)' if coverage_gap else 'no'}")
    print(f"- Deploy: {'audited (target: %s)' % target if deploy_expected else 'not configured'}")

    return 1 if (hard_gaps or coverage_gap) else 0


if __name__ == "__main__":
    sys.exit(main())
