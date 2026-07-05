"""Tests for the rollback decision (plugins/deploy-aws/scripts/heartbeat_check.py:decide).

decide() is the promote-vs-rollback boundary. The CloudWatch fetch needs boto3/AWS, so test the
pure decision only. Import guards against boto3 being absent in CI is handled by installing it.
"""
import heartbeat_check


def test_healthy_when_at_or_above_ratio():
    assert heartbeat_check.decide(canary=95, baseline=100, min_ratio=0.95) is True
    assert heartbeat_check.decide(canary=100, baseline=100, min_ratio=0.95) is True


def test_regressed_below_ratio():
    assert heartbeat_check.decide(canary=94, baseline=100, min_ratio=0.95) is False


def test_missing_or_zero_signal_is_regressed():
    # Never promote on the absence of a signal.
    assert heartbeat_check.decide(None, 100, 0.95) is False
    assert heartbeat_check.decide(95, None, 0.95) is False
    assert heartbeat_check.decide(95, 0, 0.95) is False
