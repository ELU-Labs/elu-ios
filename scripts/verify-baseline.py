#!/usr/bin/env python3
"""Verify immutable 0.1.0 package, API, fixture, and dependency snapshots."""

from __future__ import annotations

import hashlib
import json
import pathlib
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
BASELINE = ROOT / "Baselines" / "0.1.0"
TAG = "0.1.0"
COMMIT = "5825dfb4ca9cd1d104d0a07e33d0394128750391"


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", *args], cwd=ROOT)


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


def fail(message: str) -> None:
    print(f"baseline verification failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    resolved = git("rev-parse", f"{TAG}^{{commit}}").decode().strip()
    if resolved != COMMIT:
        fail(f"{TAG} resolved to {resolved}, expected {COMMIT}")

    manifest = git("show", f"{TAG}:Package.swift")
    manifest_sha = hashlib.sha256(manifest).hexdigest()
    if manifest_sha != "9915a886e36d56accadf30f54471b8ff76b74409819ca626fb9496f311d65559":
        fail(f"Package.swift digest changed: {manifest_sha}")

    archive = git("archive", "--format=tar", TAG)
    archive_sha = hashlib.sha256(archive).hexdigest()
    if archive_sha != "9ddfe7d06fe817e77b7e1d3f98f9c3804aca94ecf1983af3c86598eafc0d1a88":
        fail(f"archive digest changed: {archive_sha}")

    expected_api = (BASELINE / "public-api.txt").read_text(encoding="utf-8").splitlines()
    tagged_source = git("show", f"{TAG}:Sources/EluAnalytics/Elu.swift").decode()
    if public_declarations(tagged_source) != expected_api:
        fail("public-api.txt does not match the immutable tag")

    current_source = (ROOT / "Sources" / "EluAnalytics" / "Elu.swift").read_text(encoding="utf-8")
    if public_declarations(current_source) != expected_api:
        fail("current facade differs from the frozen 0.1.0 public API")

    metadata = json.loads((BASELINE / "package-metadata.json").read_text(encoding="utf-8"))
    if metadata["source"]["commit"] != COMMIT:
        fail("package metadata commit is inconsistent")
    symbols = json.loads((BASELINE / "public-symbols.json").read_text(encoding="utf-8"))
    if symbols["sourceCommit"] != COMMIT or symbols["module"] != "EluAnalytics":
        fail("public symbol snapshot is inconsistent")
    dependency_inventory = json.loads(
        (ROOT / "legal" / "THIRD_PARTY_NOTICES.dependencies.json").read_text(encoding="utf-8")
    )
    if dependency_inventory["baseline"] != TAG or not dependency_inventory["packages"]:
        fail("legal dependency inventory is incomplete")

    subprocess.check_call([sys.executable, "Conformance/validate-baselines.py"], cwd=ROOT)
    subprocess.check_call([sys.executable, "scripts/validate-upgrade-evidence.py"], cwd=ROOT)
    print("verified immutable package/API snapshot and conformance fixtures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
