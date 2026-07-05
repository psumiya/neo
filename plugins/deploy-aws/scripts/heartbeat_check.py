#!/usr/bin/env python3
"""Watch a CloudWatch 'heartbeat' metric during a canary window and decide promote vs roll back.

A heartbeat metric is an OUTCOME signal (Intercom's framing: "stop monitoring systems; start
monitoring outcomes") — e.g. successful request rate, checkout rate, RAG answer-quality canary —
not CPU/memory. We compare the canary window against a baseline and fail if it regresses beyond
tolerance.

Usage:
  heartbeat_check.py --namespace MyApp --metric SuccessfulRequests \
      --stat Sum --window-min 5 --baseline-min 30 --min-ratio 0.95
Exit 0 = healthy (promote ok). Exit 1 = regressed (roll back).
Requires boto3 and AWS creds (OIDC role in CI).
"""
import argparse
import datetime as dt
import sys

try:
    import boto3
except ImportError:
    print("boto3 required", file=sys.stderr)
    sys.exit(2)


def metric_sum(cw, namespace, metric, dimensions, start, end, stat):
    resp = cw.get_metric_statistics(
        Namespace=namespace, MetricName=metric, Dimensions=dimensions,
        StartTime=start, EndTime=end, Period=60, Statistics=[stat],
    )
    points = resp.get("Datapoints", [])
    if not points:
        return None
    return sum(p[stat] for p in points) / len(points)


def decide(canary, baseline, min_ratio):
    """True = healthy (promote); False = regressed (roll back).

    Missing canary/baseline or a zero baseline is treated as regressed — we never promote on the
    absence of a signal.
    """
    if canary is None or baseline is None or baseline == 0:
        return False
    return (canary / baseline) >= min_ratio


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--namespace", required=True)
    ap.add_argument("--metric", required=True)
    ap.add_argument("--stat", default="Average")
    ap.add_argument("--dimension", action="append", default=[],
                    help="Name=Value, repeatable")
    ap.add_argument("--window-min", type=int, default=5)
    ap.add_argument("--baseline-min", type=int, default=30)
    ap.add_argument("--min-ratio", type=float, default=0.95,
                    help="canary must be >= this fraction of baseline")
    args = ap.parse_args()

    dims = []
    for d in args.dimension:
        name, _, value = d.partition("=")
        dims.append({"Name": name, "Value": value})

    cw = boto3.client("cloudwatch")
    now = dt.datetime.utcnow()
    canary = metric_sum(cw, args.namespace, args.metric, dims,
                        now - dt.timedelta(minutes=args.window_min), now, args.stat)
    baseline = metric_sum(cw, args.namespace, args.metric, dims,
                          now - dt.timedelta(minutes=args.baseline_min + args.window_min),
                          now - dt.timedelta(minutes=args.window_min), args.stat)

    healthy = decide(canary, baseline, args.min_ratio)
    if canary is None or baseline is None or baseline == 0:
        print(f"insufficient data (canary={canary}, baseline={baseline}) — treating as REGRESSED")
        return 1
    print(f"heartbeat {args.metric}: canary={canary:.2f} baseline={baseline:.2f} "
          f"ratio={canary / baseline:.3f} min={args.min_ratio} -> {'HEALTHY' if healthy else 'REGRESSED'}")
    return 0 if healthy else 1


if __name__ == "__main__":
    sys.exit(main())
