#!/usr/bin/env python3
"""Verify that the exact release tag matches the SDK's reported version."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
STATE = ROOT / "Sources" / "EluAnalytics" / "EluState.swift"
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
DECLARATION = re.compile(r'^\s*static let sdkVersion = "([^"]+)"\s*$', re.MULTILINE)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("tag")
    args = parser.parse_args()
    matches = DECLARATION.findall(STATE.read_text(encoding="utf-8"))
    if len(matches) != 1:
        print("release version verification failed: expected one SDK version declaration", file=sys.stderr)
        return 1
    declared = matches[0]
    if not SEMVER.fullmatch(args.tag):
        print("release version verification failed: tag is not exact semantic version", file=sys.stderr)
        return 1
    if declared != args.tag:
        print(
            f"release version verification failed: SDK reports {declared}, tag is {args.tag}",
            file=sys.stderr,
        )
        return 1
    print(f"verified SDK version {declared} matches the release tag")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
