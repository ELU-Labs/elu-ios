#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "scripts" / "generate-release-evidence.py"


class GenerateReleaseEvidenceTests(unittest.TestCase):
    def test_revision_only_pin_and_artifact_checksums_are_exact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            resolved = root / "Package.resolved"
            resolved.write_text(
                json.dumps(
                    {
                        "pins": [
                            {
                                "identity": "fixture-runtime",
                                "location": "https://example.test/fixture-runtime.git",
                                "state": {"revision": "abcdef123456"},
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            artifact = root / "release.zip"
            artifact.write_bytes(b"release artifact")
            output = root / "evidence"

            result = subprocess.run(
                [
                    sys.executable,
                    str(GENERATOR),
                    "--output",
                    str(output),
                    "--resolved",
                    str(resolved),
                    "--artifact",
                    str(artifact),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            sbom = json.loads((output / "sbom.cdx.json").read_text(encoding="utf-8"))
            self.assertEqual(sbom["components"][0]["version"], "abcdef123456")
            self.assertEqual(
                sbom["components"][0]["purl"],
                "pkg:swift/fixture-runtime@abcdef123456",
            )
            checksums = json.loads(
                (output / "artifact-checksums.json").read_text(encoding="utf-8")
            )
            self.assertEqual(
                checksums["artifacts"][0]["sha256"],
                hashlib.sha256(artifact.read_bytes()).hexdigest(),
            )
            evidence_sums = (output / "SHA256SUMS").read_text(encoding="utf-8")
            self.assertIn("artifact-checksums.json", evidence_sums)


if __name__ == "__main__":
    unittest.main()
