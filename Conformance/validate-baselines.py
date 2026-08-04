#!/usr/bin/env python3
"""Validate baseline fixtures without adding a package dependency."""

from __future__ import annotations

import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
BASELINES = ROOT / "Conformance" / "Baselines"
REQUIRED_AREAS = {
    "identity",
    "reset",
    "groups",
    "flags",
    "lifecycle",
    "events",
    "replay",
    "privacy",
    "persistence",
    "network",
}


def validate(path: pathlib.Path) -> list[str]:
    errors: list[str] = []
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    if data.get("contractStatus") != "provisional-awaiting-browser-v1":
        errors.append("contractStatus must remain provisional until the shared contract freezes")
    baseline = data.get("baseline", {})
    for key in ("sdkVersion", "sourceTag", "sourceCommit"):
        if not baseline.get(key):
            errors.append(f"baseline.{key} is required")
    cases = data.get("cases")
    if not isinstance(cases, list):
        return errors + ["cases must be an array"]
    ids: set[str] = set()
    areas: set[str] = set()
    for index, case in enumerate(cases):
        prefix = f"cases[{index}]"
        case_id = case.get("id")
        if not isinstance(case_id, str) or not case_id:
            errors.append(f"{prefix}.id is required")
        elif case_id in ids:
            errors.append(f"duplicate case id: {case_id}")
        else:
            ids.add(case_id)
        area = case.get("area")
        if area not in REQUIRED_AREAS:
            errors.append(f"{prefix}.area is unknown: {area!r}")
        else:
            areas.add(area)
        if not isinstance(case.get("given"), dict):
            errors.append(f"{prefix}.given must be an object")
        if not isinstance(case.get("operations"), list) or not case["operations"]:
            errors.append(f"{prefix}.operations must be a non-empty array")
        if not isinstance(case.get("expected"), dict) or not case["expected"]:
            errors.append(f"{prefix}.expected must be a non-empty object")
        evidence = case.get("evidence")
        if not isinstance(evidence, dict) or evidence.get("status") not in {
            "verified",
            "foundation-only",
            "pending",
        }:
            errors.append(f"{prefix}.evidence has an invalid status")
    missing = REQUIRED_AREAS - areas
    if missing:
        errors.append(f"missing required areas: {', '.join(sorted(missing))}")
    return errors


def main() -> int:
    paths = sorted(BASELINES.glob("*/behavior.json"))
    if not paths:
        print("no baseline fixtures found", file=sys.stderr)
        return 1
    failed = False
    for path in paths:
        errors = validate(path)
        if errors:
            failed = True
            for error in errors:
                print(f"{path.relative_to(ROOT)}: {error}", file=sys.stderr)
        else:
            print(f"validated {path.relative_to(ROOT)}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
