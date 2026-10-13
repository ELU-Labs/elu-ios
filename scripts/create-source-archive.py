#!/usr/bin/env python3
"""Create the same source archive from a reviewed commit or its release tag.

The archive holds every file tracked at that commit, under `elu-ios-source/`.
It fails if `.gitattributes` export rules would leave a tracked file out.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "elu-ios-source/"


def create_archive(repository: Path, ref: str, output: Path) -> dict[str, str]:
    # Resolve an annotated tag to its commit before archiving, so tag metadata
    # and local file timestamps cannot change the archive bytes.
    commit = subprocess.check_output(
        ["git", "rev-parse", "--verify", "--end-of-options", ref + "^{commit}"],
        cwd=repository, text=True,
    ).strip()
    subprocess.run(
        ["git", "archive", "--format=zip", "--prefix=" + PREFIX,
         "--output=" + str(output.resolve()), commit],
        cwd=repository, check=True,
    )
    tracked = subprocess.check_output(
        ["git", "ls-tree", "-r", "-z", "--name-only", commit], cwd=repository,
    )
    expected = sorted(PREFIX + item.decode("utf-8") for item in tracked.split(b"\0") if item)
    with zipfile.ZipFile(output) as archive:
        archived = sorted(name for name in archive.namelist() if not name.endswith("/"))
    if archived != expected:
        missing = sorted(set(expected) - set(archived))
        raise SystemExit(f"source archive does not match the tracked files of {commit}: missing {missing[:10]}")
    return {"sourceCommit": commit, "sourceArchiveSha256": hashlib.sha256(output.read_bytes()).hexdigest()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(create_archive(ROOT, args.ref, args.output), sort_keys=True))


if __name__ == "__main__":
    main()
