#!/usr/bin/env python3
"""Preserve the frozen API and permit only separately reviewed additions."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "Baselines" / "0.1.0" / "public-symbols.json"
ADDITIONS = ROOT / "API" / "public-symbol-additions.json"


def expected_symbols(snapshot: pathlib.Path = SNAPSHOT, additions: pathlib.Path = ADDITIONS) -> tuple[str, set[str]]:
    baseline = json.loads(snapshot.read_text(encoding="utf-8"))
    added = json.loads(additions.read_text(encoding="utf-8"))
    if added.get("module") != baseline["module"] or added.get("baseline") != "Baselines/0.1.0/public-symbols.json":
        raise ValueError("additive API ledger does not match the frozen baseline")
    original_names = [entry["name"] for entry in baseline["symbols"]]
    added_names = [entry["name"] for entry in added["symbols"]]
    if len(set(added_names)) != len(added_names) or set(original_names) & set(added_names):
        raise ValueError("additive API ledger contains duplicate or baseline symbols")
    return baseline["module"], set(original_names) | set(added_names)


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
    try:
        module, expected = expected_symbols()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"invalid API ledger: {error}", file=sys.stderr)
        return 1
    actual: set[str] = set()
    matched_files: list[pathlib.Path] = []
    for path in candidates(args.path):
        try:
            graph = json.loads(path.read_text(encoding="utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if graph.get("module", {}).get("name") != module:
            continue
        matched_files.append(path)
        for symbol in graph.get("symbols", []):
            components = symbol.get("pathComponents")
            if isinstance(components, list) and all(isinstance(item, str) for item in components):
                actual.add(".".join(components))
    if not matched_files:
        print("no EluAnalytics symbol graph found", file=sys.stderr)
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
