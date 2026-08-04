#!/usr/bin/env python3
"""Verify the temporary baseline pin or the future owned-runtime dependency gate."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROVENANCE = ROOT / "legal" / "THIRD_PARTY_NOTICES.provenance.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("baseline", "owned-runtime"), default="baseline")
    parser.add_argument("--resolved", type=pathlib.Path, default=ROOT / "Package.resolved")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.resolved.is_file():
        if args.mode == "owned-runtime":
            print("verified owned runtime has no resolved third-party dependency graph")
            return 0
        print(f"missing resolved dependency graph: {args.resolved}", file=sys.stderr)
        return 1
    resolved = json.loads(args.resolved.read_text(encoding="utf-8"))
    pins = resolved.get("pins")
    if not isinstance(pins, list):
        print("resolved dependency graph has no pins array", file=sys.stderr)
        return 1

    provenance = json.loads(PROVENANCE.read_text(encoding="utf-8"))
    historical = provenance["packages"]
    historical_identities = {package["identity"].casefold() for package in historical}
    historical_sources = {package["source"].casefold() for package in historical}

    if args.mode == "owned-runtime":
        leaked = [
            pin
            for pin in pins
            if str(pin.get("identity", "")).casefold() in historical_identities
            or str(pin.get("location", "")).casefold() in historical_sources
        ]
        if leaked:
            print("owned-runtime dependency gate failed: historical runtime still resolves", file=sys.stderr)
            return 1
        print("verified resolved graph has no historical runtime dependency")
        return 0

    if len(historical) != 1 or len(pins) != 1:
        print("baseline dependency graph must contain exactly the inventoried parity package", file=sys.stderr)
        return 1
    expected = historical[0]
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
    print("verified exact Phase 1 parity dependency against legal provenance")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
