#!/usr/bin/env python3
"""Verify that every reviewed public facade declaration is still present.

`Baselines/current/public-api.txt` lists public declarations of the `Elu`
facade that apps already call. Each line must still appear, unchanged, in
`Sources/EluAnalytics/Elu.swift`. New declarations are allowed here; the exact
public surface is checked against `Baselines/current/public-symbols.json` by
`scripts/verify-symbol-graph.py` after an iOS build.
"""

from __future__ import annotations

import argparse
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
BASELINE = ROOT / "Baselines" / "current" / "public-api.txt"
FACADE = ROOT / "Sources" / "EluAnalytics" / "Elu.swift"


def public_declarations(source: str) -> list[str]:
    declarations = ["module EluAnalytics"]
    for line in source.splitlines():
        stripped = line.strip()
        if not stripped.startswith("public "):
            continue
        if stripped.endswith(" {"):
            stripped = stripped[:-2]
        declarations.append(stripped)
    return declarations


def missing_declarations(baseline: pathlib.Path = BASELINE, facade: pathlib.Path = FACADE) -> list[str]:
    expected = [line for line in baseline.read_text(encoding="utf-8").splitlines() if line.strip()]
    if not expected or expected[0] != "module EluAnalytics":
        raise ValueError(f"{baseline.name} must start with 'module EluAnalytics'")
    if len(expected) != len(set(expected)):
        raise ValueError(f"{baseline.name} contains duplicate declarations")
    current = set(public_declarations(facade.read_text(encoding="utf-8")))
    return [declaration for declaration in expected if declaration not in current]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--baseline", type=pathlib.Path, default=BASELINE)
    parser.add_argument("--facade", type=pathlib.Path, default=FACADE)
    args = parser.parse_args()
    try:
        missing = missing_declarations(args.baseline, args.facade)
    except (OSError, ValueError) as error:
        print(f"public API baseline verification failed: {error}", file=sys.stderr)
        return 1
    if missing:
        print("public API baseline verification failed; removed or changed declarations:", file=sys.stderr)
        for declaration in missing:
            print(f"  {declaration}", file=sys.stderr)
        return 1
    print("verified reviewed public facade declarations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
