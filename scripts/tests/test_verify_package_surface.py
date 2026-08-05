#!/usr/bin/env python3

from __future__ import annotations

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "scripts" / "verify-package-surface.py"
SNAPSHOT = ROOT / "Baselines" / "package-validation" / "package-metadata.json"
DEPENDENCIES = ROOT / "legal" / "THIRD_PARTY_NOTICES.dependencies.json"
PACKAGE_MANIFEST = ROOT / "Package.swift"


def package_dump() -> dict[str, object]:
    dependency = json.loads(DEPENDENCIES.read_text(encoding="utf-8"))["packages"][0]
    return {
        "name": "EluAnalytics",
        "toolsVersion": {"_version": "5.9.0"},
        "platforms": [{"platformName": "ios", "version": "13.0"}],
        "products": [
            {
                "name": "EluAnalytics",
                "type": {"library": ["automatic"]},
                "targets": ["EluAnalytics"],
            }
        ],
        "targets": [
            {"name": "EluAnalytics", "type": "regular"},
            {"name": "EluAnalyticsTests", "type": "test"},
        ],
        "dependencies": [
            {
                "sourceControl": [
                    {
                        "identity": dependency["identity"],
                        "location": {
                            "remote": [
                                {
                                    "urlString": dependency["source"]
                                }
                            ]
                        },
                        "requirement": {"exact": [dependency["version"]]},
                    }
                ]
            }
        ],
    }


def prepare_fresh_root(parent: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    root = parent / "fresh-root"
    (root / "scripts").mkdir(parents=True)
    (root / "Baselines" / "package-validation").mkdir(parents=True)
    (root / "legal").mkdir(parents=True)
    shutil.copy2(VERIFIER, root / "scripts" / VERIFIER.name)
    shutil.copy2(SNAPSHOT, root / "Baselines" / "package-validation" / SNAPSHOT.name)
    shutil.copy2(DEPENDENCIES, root / "legal" / DEPENDENCIES.name)
    shutil.copy2(PACKAGE_MANIFEST, root / PACKAGE_MANIFEST.name)
    dump = root / "package-dump.json"
    dump.write_text(json.dumps(package_dump()), encoding="utf-8")
    return root, dump


def run_verifier(
    root: pathlib.Path, dump: pathlib.Path, *, mode: str = "baseline"
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(root / "scripts" / VERIFIER.name),
            "--mode",
            mode,
            str(dump),
        ],
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
    )


class VerifyPackageSurfaceTests(unittest.TestCase):
    def test_fresh_single_root_repository_does_not_need_historical_commits(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, dump = prepare_fresh_root(pathlib.Path(directory))
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(
                [
                    "git",
                    "-c",
                    "user.name=Fixture",
                    "-c",
                    "user.email=fixture@example.test",
                    "commit",
                    "-qm",
                    "fresh root",
                ],
                cwd=root,
                check=True,
            )

            result = run_verifier(root, dump)
            commit_count = subprocess.run(
                ["git", "rev-list", "--count", "HEAD"],
                cwd=root,
                text=True,
                capture_output=True,
                check=True,
            )

        self.assertEqual(commit_count.stdout.strip(), "1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("verified Package.swift metadata", result.stdout)

    def test_manifest_tampering_is_rejected_by_recorded_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, dump = prepare_fresh_root(pathlib.Path(directory))
            manifest = root / "Package.swift"
            manifest.write_bytes(manifest.read_bytes() + b"\n// tampered\n")

            results = [
                run_verifier(root, dump, mode=mode)
                for mode in ("baseline", "strict")
            ]

        for result in results:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match its recorded SHA-256 digest", result.stderr)

    def test_snapshot_uses_content_provenance_not_a_source_commit(self) -> None:
        snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))

        self.assertNotIn("sourceCommit", snapshot)
        self.assertEqual(snapshot["manifestProvenance"]["path"], "Package.swift")
        self.assertEqual(len(snapshot["manifestProvenance"]["sha256"]), 64)


if __name__ == "__main__":
    unittest.main()
