#!/usr/bin/env python3
"""Verify the recorded dependency graph or require an empty runtime graph."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEPENDENCIES = ROOT / "legal" / "THIRD_PARTY_NOTICES.dependencies.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("baseline", "strict"), default="baseline")
    parser.add_argument("--resolved", type=pathlib.Path, default=ROOT / "Package.resolved")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.resolved.is_file():
        if args.mode == "strict":
            print("verified no resolved third-party dependency graph")
            return 0
        print(f"missing resolved dependency graph: {args.resolved}", file=sys.stderr)
        return 1
    resolved = json.loads(args.resolved.read_text(encoding="utf-8"))
    pins = resolved.get("pins")
    if not isinstance(pins, list):
        print("resolved dependency graph has no pins array", file=sys.stderr)
        return 1

    dependency_inventory = json.loads(DEPENDENCIES.read_text(encoding="utf-8"))
    inventoried = dependency_inventory["packages"]
    inventoried_identities = {package["identity"].casefold() for package in inventoried}
    inventoried_sources = {package["source"].casefold() for package in inventoried}

    if args.mode == "strict":
        leaked = [
            pin
            for pin in pins
            if str(pin.get("identity", "")).casefold() in inventoried_identities
            or str(pin.get("location", "")).casefold() in inventoried_sources
        ]
        if leaked:
            print("strict dependency gate failed: inventoried runtime still resolves", file=sys.stderr)
            return 1
        print("verified resolved graph has no inventoried runtime dependency")
        return 0

    if len(inventoried) != 1 or len(pins) != 1:
        print("baseline dependency graph must contain exactly the inventoried package", file=sys.stderr)
        return 1
    expected = inventoried[0]
    pin = pins[0]
    state = pin.get("state", {})
    checks = {
        "identity": pin.get("identity") == expected["identity"],
        "source": pin.get("location") == expected["source"],
        "version": state.get("version") == expected["version"],
        "revision": state.get("revision") == expected["revision"],
    }
    failed = [name for name, passed in checks.items() if not passed]
    if failed:
        print(f"baseline dependency mismatch: {', '.join(failed)}", file=sys.stderr)
        return 1
    print("verified exact dependency against legal inventory")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
