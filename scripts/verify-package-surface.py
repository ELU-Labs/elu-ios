#!/usr/bin/env python3
"""Compare `swift package dump-package` output with the package snapshot."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "Baselines" / "package-validation" / "package-metadata.json"
DEPENDENCIES = ROOT / "legal" / "THIRD_PARTY_NOTICES.dependencies.json"
PACKAGE_MANIFEST = ROOT / "Package.swift"
SNAPSHOT_VERSION = 3


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("baseline", "strict"), default="baseline")
    parser.add_argument("dump", type=pathlib.Path)
    return parser.parse_args()


def fail(message: str) -> None:
    print(f"package surface verification failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def verify_manifest_provenance(expected: dict[str, object]) -> None:
    if expected.get("snapshotVersion") != SNAPSHOT_VERSION:
        fail(f"package snapshot version must be {SNAPSHOT_VERSION}")
    if "sourceCommit" in expected:
        fail("package snapshot must not depend on Git history")

    provenance = expected.get("manifestProvenance")
    if not isinstance(provenance, dict):
        fail("package snapshot is missing manifest provenance")
    if set(provenance) != {"path", "sha256"}:
        fail("manifest provenance fields changed")
    if provenance.get("path") != "Package.swift":
        fail("manifest provenance must identify Package.swift")

    recorded_digest = provenance.get("sha256")
    if (
        not isinstance(recorded_digest, str)
        or len(recorded_digest) != 64
        or any(character not in "0123456789abcdef" for character in recorded_digest)
    ):
        fail("manifest provenance has an invalid SHA-256 digest")
    actual_digest = hashlib.sha256(PACKAGE_MANIFEST.read_bytes()).hexdigest()
    if actual_digest != recorded_digest:
        fail("Package.swift does not match its recorded SHA-256 digest")


def main() -> int:
    args = parse_args()
    actual = json.loads(args.dump.read_text(encoding="utf-8"))
    expected = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    verify_manifest_provenance(expected)
    dependency = json.loads(DEPENDENCIES.read_text(encoding="utf-8"))["packages"][0]
    package = expected["package"]

    if actual.get("name") != package["name"]:
        fail("package name changed")
    if actual.get("toolsVersion", {}).get("_version") != package["toolsVersion"]:
        fail("tools version changed")
    actual_platforms = [
        {"name": item["platformName"], "minimumVersion": item["version"]}
        for item in actual.get("platforms", [])
    ]
    if actual_platforms != package["platforms"]:
        fail(f"platforms changed: {actual_platforms!r}")
    actual_products = [
        {
            "name": item["name"],
            "type": next(iter(item["type"])),
            "targets": item["targets"],
        }
        for item in actual.get("products", [])
    ]
    if actual_products != package["products"]:
        fail(f"products changed: {actual_products!r}")
    actual_targets = [
        {"name": item["name"], "type": item["type"]} for item in actual.get("targets", [])
    ]
    if args.mode == "baseline" and actual_targets != package["targets"]:
        fail(f"targets changed: {actual_targets!r}")
    if args.mode == "strict":
        actual_target_names = {item["name"] for item in actual_targets}
        required_target_names = {item["name"] for item in package["targets"]}
        if not required_target_names.issubset(actual_target_names):
            fail("strict package removed a frozen facade or test target")

    actual_target_settings: dict[str, list[dict[str, str]]] = {}
    for target in actual.get("targets", []):
        settings: list[dict[str, str]] = []
        for setting in target.get("settings", []):
            kind = setting.get("kind", {})
            linked_library = kind.get("linkedLibrary") if isinstance(kind, dict) else None
            if (
                setting.get("tool") != "linker"
                or not isinstance(linked_library, dict)
                or set(linked_library) != {"_0"}
                or not isinstance(linked_library.get("_0"), str)
            ):
                fail(f"unsupported target setting on {target.get('name')}")
            settings.append({"tool": "linker", "linkedLibrary": linked_library["_0"]})
        actual_target_settings[target["name"]] = settings
    if actual_target_settings != package["targetSettings"]:
        fail(f"target linker settings changed: {actual_target_settings!r}")

    dependencies = actual.get("dependencies", [])
    if args.mode == "strict":
        print("verified strict Package.swift metadata and public product surface")
        return 0
    if len(dependencies) != 1:
        fail("manifest must have exactly one inventoried dependency")
    source_control = dependencies[0].get("sourceControl", [])
    if len(source_control) != 1:
        fail("dependency is not a single source-control requirement")
    item = source_control[0]
    remote = item.get("location", {}).get("remote", [])
    requirement = item.get("requirement", {}).get("exact", [])
    if item.get("identity") != dependency["identity"]:
        fail("dependency identity differs from legal inventory")
    if remote != [{"urlString": dependency["source"]}]:
        fail("dependency source differs from legal inventory")
    if requirement != [dependency["version"]]:
        fail("dependency is not pinned to the inventoried exact version")

    print("verified Package.swift metadata and public product surface")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
