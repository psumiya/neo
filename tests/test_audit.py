"""Audit resolution of reusable-workflow callers and deploy opt-in."""
import audit

NEO_YML = """
name: neo

on:
  issues:
    types: [labeled]
  pull_request:
    types: [opened]

jobs:
  build:
    if: github.event_name == 'issues'
    permissions:
      contents: write
    uses: psumiya/neo/.github/workflows/neo-build.yml@v0
    with:
      issue_number: ${{ github.event.issue.number }}

  review:
    uses: psumiya/neo/.github/workflows/ai-review.yml@v0

  maintenance:
    uses: psumiya/neo/.github/workflows/maintenance.yml@v0
"""


def test_parse_callers_maps_callee_to_calling_job():
    assert audit.parse_callers(NEO_YML) == {
        "neo-build.yml": ["build"],
        "ai-review.yml": ["review"],
        "maintenance.yml": ["maintenance"],
    }


def test_parse_callers_ignores_actions():
    yml = "jobs:\n  x:\n    steps:\n      - uses: actions/setup-python@v5\n"
    assert audit.parse_callers(yml) == {}


def test_deploy_target_none():
    cfg = "app:\n  name: x\ndeploy:\n  target: none\n  aws:\n    region: us-east-1\n"
    assert audit.deploy_target(cfg) == "none"


def test_deploy_target_aws():
    cfg = "deploy:\n  target: aws\n  aws:\n    region: us-east-1\nevals:\n  dir: x\n"
    assert audit.deploy_target(cfg) == "aws"


def test_deploy_target_missing_config():
    assert audit.deploy_target("") is None
    assert audit.deploy_target("app:\n  name: x\n") is None


def test_deploy_target_ignores_target_outside_deploy_block():
    cfg = "other:\n  target: aws\ndeploy:\n  target: none\n"
    assert audit.deploy_target(cfg) == "none"


def test_job_ran_matches_nested_reusable_job_names():
    cache = {7: [("review / classify", "success"), ("review / evals", "success")]}
    assert audit.job_ran("o/r", 7, "review", cache)
    assert not audit.job_ran("o/r", 7, "build", cache)


def test_job_ran_matches_top_level_job_name():
    cache = {8: [("build", "success")]}
    assert audit.job_ran("o/r", 8, "build", cache)


def test_job_ran_ignores_skipped_jobs():
    cache = {9: [("build", "skipped"), ("maintenance / audit / audit", "success")]}
    assert not audit.job_ran("o/r", 9, "build", cache)
    assert audit.job_ran("o/r", 9, "maintenance", cache)
