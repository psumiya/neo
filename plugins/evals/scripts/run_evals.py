#!/usr/bin/env python3
"""Run the repo's eval suite as a merge gate.

Eval cases live in `evals/cases/*.yaml` in the target repo. Two kinds:

  kind: golden        # exact / contains / regex / json-equals assertion on a command's output
    cmd: "python -m app.cli summarize fixtures/doc1.txt"
    expect:
      mode: contains          # exact | contains | regex | json_equals
      value: "key finding"

  kind: judge         # LLM-judge scores a model output against a rubric, must clear threshold
    cmd: "python -m app.cli answer 'What is our refund window?'"
    rubric: "Answer must state the 30-day refund window and cite the policy doc."
    threshold: 0.8          # 0..1; judge returns a score, must be >= threshold

Exit code 0 = all pass (gate green), 1 = any fail.
The LLM judge uses `claude -p` with a small model; set ANTHROPIC_API_KEY (or Bedrock env).
"""
import glob
import json
import os
import re
import subprocess
import sys

try:
    import yaml
except ImportError:
    print("PyYAML required: pip install pyyaml", file=sys.stderr)
    sys.exit(2)

JUDGE_MODEL = os.environ.get("EVAL_JUDGE_MODEL", "claude-haiku-4-5-20251001")


def run_cmd(cmd):
    p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=600)
    return (p.stdout or "") + (p.stderr or "")


def check_golden(output, expect):
    mode = expect.get("mode", "contains")
    value = expect.get("value", "")
    if mode == "exact":
        return output.strip() == str(value).strip()
    if mode == "contains":
        return str(value) in output
    if mode == "regex":
        return re.search(value, output) is not None
    if mode == "json_equals":
        try:
            return json.loads(output) == value
        except json.JSONDecodeError:
            return False
    raise ValueError(f"unknown golden mode: {mode}")


def judge(output, rubric, threshold):
    prompt = (
        "Score the CANDIDATE answer against the RUBRIC from 0.0 to 1.0 for how well it satisfies it. "
        'Respond ONLY with minified JSON {"score": <float>, "why": "<short>"}.\n\n'
        f"RUBRIC:\n{rubric}\n\nCANDIDATE:\n{output}\n"
    )
    res = subprocess.run(
        ["claude", "-p", "--model", JUDGE_MODEL, "--output-format", "text"],
        input=prompt, capture_output=True, text=True, timeout=120,
    )
    m = re.search(r"\{.*\}", res.stdout, re.S)
    if not m:
        return 0.0, "judge produced no JSON"
    data = json.loads(m.group(0))
    return float(data.get("score", 0.0)), data.get("why", "")


def main():
    cases = sorted(glob.glob("evals/cases/*.yaml")) + sorted(glob.glob("evals/cases/*.yml"))
    if not cases:
        print("no eval cases found under evals/cases/ — gate passes vacuously")
        return 0
    failures = 0
    for path in cases:
        with open(path) as f:
            doc = yaml.safe_load(f) or {}
        name = doc.get("name", os.path.basename(path))
        kind = doc.get("kind", "golden")
        output = run_cmd(doc["cmd"])
        if kind == "golden":
            ok = check_golden(output, doc.get("expect", {}))
            detail = "" if ok else f"output did not satisfy {doc.get('expect')}"
        elif kind == "judge":
            score, why = judge(output, doc["rubric"], float(doc.get("threshold", 0.8)))
            ok = score >= float(doc.get("threshold", 0.8))
            detail = f"score={score:.2f} ({why})"
        else:
            ok, detail = False, f"unknown kind: {kind}"
        print(f"[{'PASS' if ok else 'FAIL'}] {name} {detail}".rstrip())
        if not ok:
            failures += 1
    print(f"\n{len(cases) - failures}/{len(cases)} eval cases passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
