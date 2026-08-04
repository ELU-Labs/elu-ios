#!/usr/bin/env python3
"""Generate checksums, a CycloneDX SBOM, provenance, and legal payload."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess


ROOT = pathlib.Path(__file__).resolve().parents[1]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--artifact", type=pathlib.Path, action="append", default=[])
    parser.add_argument("--resolved", type=pathlib.Path, default=ROOT / "Package.resolved")
    return parser.parse_args()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_directory(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    for file_path in sorted(item for item in path.rglob("*") if item.is_file()):
        relative = file_path.relative_to(path).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(bytes.fromhex(sha256_file(file_path)))
    return digest.hexdigest()


def artifact_record(path: pathlib.Path) -> dict[str, object]:
    resolved = path.resolve()
    try:
        source_path = resolved.relative_to(ROOT).as_posix()
    except ValueError:
        source_path = path.name
    return {
        "name": path.name,
        "kind": "directory" if path.is_dir() else "file",
        "sha256": sha256_directory(path) if path.is_dir() else sha256_file(path),
        "size": sum(item.stat().st_size for item in path.rglob("*") if item.is_file())
        if path.is_dir()
        else path.stat().st_size,
        "sourcePath": source_path,
    }


def command(*arguments: str) -> str:
    return subprocess.check_output(arguments, cwd=ROOT, text=True, stderr=subprocess.STDOUT).strip()


def main() -> int:
    args = parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    artifacts = [artifact_record(path) for path in args.artifact]
    resolved = json.loads(args.resolved.read_text(encoding="utf-8")) if args.resolved.is_file() else {"pins": []}

    components = []
    for pin in resolved.get("pins", []):
        state = pin.get("state", {})
        resolved_version = state.get("version") or state.get("revision")
        if not isinstance(resolved_version, str) or not resolved_version:
            raise ValueError(f"resolved pin has no version or revision: {pin.get('identity', '<unknown>')}")
        components.append(
            {
                "type": "library",
                "name": pin["identity"],
                "version": resolved_version,
                "purl": f"pkg:swift/{pin['identity']}@{resolved_version}",
                "externalReferences": [{"type": "vcs", "url": pin.get("location", "")}],
            }
        )
    sbom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {"component": {"type": "library", "name": "EluAnalytics"}},
        "components": components,
    }
    (args.output / "sbom.cdx.json").write_text(
        json.dumps(sbom, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    commit = command("git", "rev-parse", "HEAD")
    try:
        xcode_version = command("xcodebuild", "-version").splitlines()
    except (FileNotFoundError, subprocess.CalledProcessError):
        xcode_version = []
    provenance = {
        "schemaVersion": 1,
        "source": {
            "repository": command("git", "remote", "get-url", "origin"),
            "commit": commit,
            "commitTimestamp": command("git", "show", "-s", "--format=%cI", commit),
        },
        "toolchain": {
            "swift": command("swift", "--version").splitlines()[0],
            "xcode": xcode_version,
        },
        "artifacts": artifacts,
    }
    (args.output / "provenance.json").write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    artifact_checksums = {
        "schemaVersion": 1,
        "algorithms": {
            "file": "sha256",
            "directory": "sha256-tree-v1(relative-path-length || relative-path || file-sha256)",
        },
        "artifacts": artifacts,
    }
    (args.output / "artifact-checksums.json").write_text(
        json.dumps(artifact_checksums, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    legal_output = args.output / "legal"
    legal_output.mkdir(exist_ok=True)
    for path in (ROOT / "LICENSE", ROOT / "legal" / "THIRD_PARTY_NOTICES.md", ROOT / "legal" / "THIRD_PARTY_NOTICES.provenance.json"):
        shutil.copy2(path, legal_output / path.name)

    checksum_targets = sorted(
        item for item in args.output.rglob("*") if item.is_file() and item.name != "SHA256SUMS"
    )
    checksum_lines = [
        f"{sha256_file(path)}  {path.relative_to(args.output).as_posix()}" for path in checksum_targets
    ]
    (args.output / "SHA256SUMS").write_text("\n".join(checksum_lines) + "\n", encoding="utf-8")
    print(f"generated release evidence for commit {commit} in {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
