#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Export or check ABI arrays using the pinned Foundry configuration; no RPC needed."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true", help="fail if a committed ABI is missing or stale")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
failed = False
for name in ("STREAK", "BuyStreakHook"):
    result = subprocess.run(
        ["forge", "inspect", f"src/{name}.sol:{name}", "abi", "--json"],
        cwd=root, check=True, capture_output=True, text=True,
    )
    serialized = json.dumps(json.loads(result.stdout), indent=2) + "\n"
    destination = root / "docs" / "abi" / f"{name}.json"
    if args.check:
        matches = destination.exists() and destination.read_text() == serialized
        print(f"{name}: {'current' if matches else 'MISSING OR STALE'}")
        failed |= not matches
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(serialized)
        print(f"Exported docs/abi/{name}.json")
raise SystemExit(1 if failed else 0)
