#!/usr/bin/env python3
"""Compare the built public symbol graph with the reviewed symbol list.

`Baselines/current/public-symbols.json` lists every public symbol of
EluAnalytics. The check fails when a listed symbol is missing from the build
or when the build exposes a public symbol that is not listed.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "Baselines" / "current" / "public-symbols.json"


def expected_symbols(snapshot: pathlib.Path = SNAPSHOT) -> tuple[str, set[str]]:
    reviewed = json.loads(snapshot.read_text(encoding="utf-8"))
    module = reviewed.get("module")
    if not isinstance(module, str) or not module:
        raise ValueError("symbol list does not name its module")
    names = [entry["name"] for entry in reviewed["symbols"]]
    if not names or not all(isinstance(name, str) and name for name in names):
        raise ValueError("symbol list entries must have names")
    if len(set(names)) != len(names):
        raise ValueError("symbol list contains duplicate symbols")
    return module, set(names)


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
        print(f"invalid public symbol list: {error}", file=sys.stderr)
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
