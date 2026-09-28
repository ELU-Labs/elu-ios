#!/usr/bin/env python3
"""Compare a built EluAnalytics symbol graph with the reviewed public snapshot.

The graph must match Baselines/current exactly and still carry every symbol of
the published 0.1.0 snapshot, so the public API can only grow.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
FROZEN_SNAPSHOT = ROOT / "Baselines" / "0.1.0" / "public-symbols.json"
SNAPSHOT = ROOT / "Baselines" / "current" / "public-symbols.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=pathlib.Path)
    return parser.parse_args()


def candidates(path: pathlib.Path) -> list[pathlib.Path]:
    if path.is_file():
        return [path]
    return sorted(path.rglob("*.symbols.json"))


def main() -> int:
    args = parse_args()
    expected_data = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    expected = {symbol["name"] for symbol in expected_data["symbols"]}
    actual: set[str] = set()
    matched_files: list[pathlib.Path] = []
    for path in candidates(args.path):
        try:
            graph = json.loads(path.read_text(encoding="utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if graph.get("module", {}).get("name") != expected_data["module"]:
            continue
        matched_files.append(path)
        for symbol in graph.get("symbols", []):
            components = symbol.get("pathComponents")
            if isinstance(components, list) and all(isinstance(item, str) for item in components):
                actual.add(".".join(components))
    if not matched_files:
        print("no EluAnalytics symbol graph found", file=sys.stderr)
        return 1
    frozen = {symbol["name"] for symbol in json.loads(FROZEN_SNAPSHOT.read_text(encoding="utf-8"))["symbols"]}
    removed = sorted(frozen - actual)
    if removed:
        print("published 0.1.0 symbols removed:", *removed, sep="\n  ", file=sys.stderr)
        return 1
    missing = sorted(expected - actual)
    added = sorted(actual - expected)
    if missing or added:
        if missing:
            print("missing public symbols:", *missing, sep="\n  ", file=sys.stderr)
        if added:
            print("unexpected public symbols:", *added, sep="\n  ", file=sys.stderr)
        return 1
    print(f"verified {len(actual)} public symbols from {len(matched_files)} graph(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
