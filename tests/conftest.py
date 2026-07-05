"""Make the plugin scripts importable by their module basenames from the tests.

The scripts live under plugins/*/scripts and aren't a package, so add those dirs to sys.path.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for rel in (
    "plugins/risk-review/scripts",
    "plugins/evals/scripts",
    "plugins/deploy-aws/scripts",
):
    sys.path.insert(0, os.path.join(ROOT, rel))
