#!/usr/bin/env python3
"""Deterministic risk tier for a PR: GREEN / YELLOW / RED.

GREEN  -> safe to auto-merge with no human review (only if the AI review also has no blocking findings).
YELLOW -> human review required.
RED    -> human review + protected-environment approval required.

The deterministic rules here gate on blast radius (lines, paths). The AI reviewer (risk-reviewer
agent) can only downgrade GREEN, never upgrade past these rules. Conservative by design; widen the
GREEN allowlist as the observed rollback rate stays low.

Usage:
  classify.py --policy .agent/risk-policy.yml --numstat <(git diff --numstat origin/main...HEAD)
  # or pipe `git diff --numstat` on stdin
Outputs minified JSON: {"tier": "...", "added": N, "removed": N, "reasons": [...]}
"""
import argparse
import fnmatch
import json
import sys

try:
    import yaml
except ImportError:
    yaml = None

DEFAULT_POLICY = {
    "max_lines_green": 80,
    "green_paths": ["docs/**", "**/*.md", "config/flags/**"],
    "blocked_paths": [
        "**/migrations/**", "**/schema.*", "**/*.sql",
        "**/auth/**", "**/billing/**", "**/payments/**",
        "infra/**", "terraform/**", "**/Dockerfile", "**/.github/workflows/**",
    ],
}


def load_policy(path):
    if not path:
        return DEFAULT_POLICY
    try:
        with open(path) as f:
            if yaml is None:
                return DEFAULT_POLICY
            data = yaml.safe_load(f) or {}
    except FileNotFoundError:
        return DEFAULT_POLICY
    merged = dict(DEFAULT_POLICY)
    merged.update({k: v for k, v in data.items() if v is not None})
    return merged


def matches_any(path, globs):
    return any(fnmatch.fnmatch(path, g) for g in globs)


def parse_numstat(text):
    files = []
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        added, removed, path = parts
        added = 0 if added == "-" else int(added)
        removed = 0 if removed == "-" else int(removed)
        files.append((added, removed, path))
    return files


def classify(files, policy):
    reasons = []
    total = sum(a + r for a, r, _ in files)
    paths = [p for _, _, p in files]

    blocked_hits = [p for p in paths if matches_any(p, policy["blocked_paths"])]
    if blocked_hits:
        reasons.append(f"touches blocked/critical paths: {', '.join(sorted(set(blocked_hits))[:5])}")
        return "RED", total, reasons

    over_limit = total > policy["max_lines_green"]
    non_green = [p for p in paths if not matches_any(p, policy["green_paths"])]

    if over_limit:
        reasons.append(f"changed lines {total} > green limit {policy['max_lines_green']}")
    if non_green:
        reasons.append(f"paths outside green allowlist: {', '.join(sorted(set(non_green))[:5])}")

    if not over_limit and not non_green:
        reasons.append("small change confined to green-allowlisted paths")
        return "GREEN", total, reasons
    return "YELLOW", total, reasons


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--policy", default=".agent/risk-policy.yml")
    ap.add_argument("--numstat", help="path to a `git diff --numstat` file; reads stdin if omitted")
    args = ap.parse_args()

    text = open(args.numstat).read() if args.numstat else sys.stdin.read()
    files = parse_numstat(text)
    policy = load_policy(args.policy)
    tier, total, reasons = classify(files, policy)
    added = sum(a for a, _, _ in files)
    removed = sum(r for _, r, _ in files)
    print(json.dumps({"tier": tier, "added": added, "removed": removed,
                      "total": total, "reasons": reasons}, separators=(",", ":")))


if __name__ == "__main__":
    main()
