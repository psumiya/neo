"""Tests for the deterministic risk gate (plugins/risk-review/scripts/classify.py).

This is the safety-critical core: a wrong classification either blocks safe changes or, worse,
auto-merges a dangerous one. Cover the tier boundaries, blocked-path precedence, and config loading
(new nested .neo/config.yml, legacy flat file, and the missing-file default).
"""
import textwrap

import classify


def _policy(max_lines=80, green=None, blocked=None):
    return {
        "max_lines_green": max_lines,
        "green_paths": green if green is not None else ["docs/**", "**/*.md"],
        "blocked_paths": blocked if blocked is not None else ["**/auth/**", "**/*.sql"],
    }


# --- parse_numstat ---------------------------------------------------------------------------
def test_parse_numstat_counts_and_handles_binary_dashes():
    files = classify.parse_numstat("3\t1\tsrc/a.py\n-\t-\tlogo.png\n")
    assert files == [(3, 1, "src/a.py"), (0, 0, "logo.png")]


def test_parse_numstat_ignores_malformed_lines():
    assert classify.parse_numstat("garbage line\n\n") == []


# --- classify tiers --------------------------------------------------------------------------
def test_green_when_small_and_all_paths_allowed():
    tier, total, _ = classify.classify([(2, 1, "docs/x.md")], _policy())
    assert tier == "GREEN" and total == 3


def test_yellow_when_over_line_limit_even_if_paths_green():
    tier, _, reasons = classify.classify([(60, 30, "docs/x.md")], _policy(max_lines=80))
    assert tier == "YELLOW"
    assert any("green limit" in r for r in reasons)


def test_yellow_when_path_outside_green_allowlist():
    tier, _, _ = classify.classify([(1, 0, "src/app.py")], _policy())
    assert tier == "YELLOW"


def test_line_limit_boundary_is_inclusive():
    # exactly at the limit is still GREEN; one over is not
    assert classify.classify([(80, 0, "docs/x.md")], _policy(max_lines=80))[0] == "GREEN"
    assert classify.classify([(81, 0, "docs/x.md")], _policy(max_lines=80))[0] == "YELLOW"


def test_blocked_path_is_red_and_beats_green():
    # A one-line change to an allowed-looking path is RED if any file hits blocked_paths.
    files = [(1, 0, "docs/x.md"), (1, 0, "app/auth/login.py")]
    tier, _, reasons = classify.classify(files, _policy())
    assert tier == "RED"
    assert any("blocked" in r for r in reasons)


def test_blocked_precedence_even_when_small_and_green_otherwise():
    # Mutation guard: if blocked_paths ever stops taking precedence, this flips to GREEN.
    tier, _, _ = classify.classify([(1, 0, "db/0001.sql")], _policy())
    assert tier == "RED"


# --- load_policy -----------------------------------------------------------------------------
def test_load_policy_reads_nested_risk_block(tmp_path):
    cfg = tmp_path / ".neo" / "config.yml"
    cfg.parent.mkdir()
    cfg.write_text(textwrap.dedent("""
        app: {name: x}
        risk:
          max_lines_green: 3
          green_paths: ["src/copy/**"]
          blocked_paths: ["**/billing/**"]
    """))
    p = classify.load_policy(str(cfg))
    assert p["max_lines_green"] == 3
    assert p["green_paths"] == ["src/copy/**"]
    # And it actually drives classification distinct from the defaults:
    assert classify.classify([(4, 0, "src/copy/s.ts")], p)[0] == "YELLOW"  # 4 > 3
    assert classify.classify([(1, 0, "docs/x.md")], p)[0] == "YELLOW"      # docs not in green


def test_load_policy_legacy_flat_file(tmp_path):
    legacy = tmp_path / ".agent" / "risk-policy.yml"
    legacy.parent.mkdir()
    legacy.write_text("max_lines_green: 5\ngreen_paths: ['**/*.md']\nblocked_paths: ['**/secret/**']\n")
    p = classify.load_policy(str(legacy))
    assert p["max_lines_green"] == 5
    assert "**/secret/**" in p["blocked_paths"]


def test_load_policy_missing_falls_back_to_conservative_defaults():
    p = classify.load_policy("/nonexistent/config.yml")
    assert p == classify.DEFAULT_POLICY
    # Defaults must keep auth/migrations blocked so a missing file never opens the gate.
    assert classify.classify([(1, 0, "app/auth/x.py")], p)[0] == "RED"
