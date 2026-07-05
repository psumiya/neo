"""Tests for the eval gate's pure logic (plugins/evals/scripts/run_evals.py).

The live golden/judge execution needs a subprocess/API, so cover check_golden's modes and the
case-directory discovery precedence instead.
"""
import os

import run_evals


def test_golden_contains():
    assert run_evals.check_golden("the total is 42 items", {"mode": "contains", "value": "42"})
    assert not run_evals.check_golden("nope", {"mode": "contains", "value": "42"})


def test_golden_exact_trims_whitespace():
    assert run_evals.check_golden("  hi\n", {"mode": "exact", "value": "hi"})
    assert not run_evals.check_golden("hi there", {"mode": "exact", "value": "hi"})


def test_golden_regex():
    assert run_evals.check_golden("id,name,created_at", {"mode": "regex", "value": r"^id,name"})


def test_golden_json_equals():
    assert run_evals.check_golden('{"a": 1}', {"mode": "json_equals", "value": {"a": 1}})
    assert not run_evals.check_golden("not json", {"mode": "json_equals", "value": {"a": 1}})


def test_golden_defaults_to_contains():
    assert run_evals.check_golden("has value", {"value": "value"})


def test_golden_unknown_mode_raises():
    import pytest
    with pytest.raises(ValueError):
        run_evals.check_golden("x", {"mode": "bogus", "value": "x"})


def test_case_discovery_prefers_neo_dir_over_legacy(tmp_path, monkeypatch):
    (tmp_path / ".neo" / "evals" / "cases").mkdir(parents=True)
    (tmp_path / ".neo" / "evals" / "cases" / "a.yaml").write_text("name: a\ncmd: 'true'\n")
    (tmp_path / "evals" / "cases").mkdir(parents=True)
    (tmp_path / "evals" / "cases" / "legacy.yaml").write_text("name: legacy\ncmd: 'true'\n")
    monkeypatch.chdir(tmp_path)
    # No cmd should actually run: force every case to a trivial golden pass and count discovery.
    monkeypatch.setattr(run_evals, "run_cmd", lambda cmd: "ok")
    monkeypatch.setattr(run_evals, "check_golden", lambda out, expect: True)
    # main() prints the discovered set; assert it looked in .neo and not the legacy dir.
    import io
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = run_evals.main()
    out = buf.getvalue()
    assert rc == 0
    assert "1/1 eval cases passed" in out  # only the .neo case, legacy ignored


def test_no_cases_passes_vacuously(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert run_evals.main() == 0
