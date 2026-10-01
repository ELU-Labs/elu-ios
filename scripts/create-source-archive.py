#!/usr/bin/env python3
"""Create the same source archive from a reviewed commit or its release tag."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "elu-ios-source/"


def create_archive(repository: Path, ref: str, output: Path) -> dict[str, str]:
    # Resolve an annotated tag to its commit before archiving, so tag metadata
    # and local file timestamps cannot change the qualified distribution bytes.
    commit = subprocess.check_output(
        ["git", "rev-parse", "--verify", "--end-of-options", ref + "^{commit}"],
        cwd=repository, text=True,
    ).strip()
    subprocess.run(
        ["git", "archive", "--format=zip", "--prefix=" + PREFIX,
         "--output=" + str(output.resolve()), commit],
        cwd=repository, check=True,
    )
    return {"sourceCommit": commit, "sourceArchiveSha256": hashlib.sha256(output.read_bytes()).hexdigest()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(create_archive(ROOT, args.ref, args.output), sort_keys=True))


if __name__ == "__main__":
    main()
