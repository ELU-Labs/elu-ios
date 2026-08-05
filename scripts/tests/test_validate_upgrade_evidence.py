from __future__ import annotations

import copy
import base64
import gzip
import hashlib
import io
import json
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "validate-upgrade-evidence.py"
MANIFEST = ROOT / "UpgradeEvidence" / "0.1.0" / "manifest.json"
INVENTORY = ROOT / "UpgradeEvidence" / "0.1.0" / "dependency-resolutions.json"


class UpgradeEvidenceValidationTests(unittest.TestCase):
    def run_validator(
        self,
        *,
        manifest: pathlib.Path = MANIFEST,
        inventory: pathlib.Path = INVENTORY,
        raw_archive: pathlib.Path | None = None,
        require_verified: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(SCRIPT),
            "--manifest",
            str(manifest),
            "--inventory",
            str(inventory),
        ]
        if raw_archive is not None:
            command.extend(["--raw-archive", str(raw_archive)])
        if require_verified:
            command.append("--require-verified")
        return subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)

    def write_json(self, directory: pathlib.Path, name: str, value: object) -> pathlib.Path:
        path = directory / name
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def verified_manifest(self) -> dict[str, object]:
        inventory = json.loads(INVENTORY.read_text(encoding="utf-8"))
        resolution = inventory["observations"][0]["resolution"]
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
        data["candidateRevision"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT).decode().strip()
        data["resolvedDependency"] = {
            "inventoryReference": "legal/THIRD_PARTY_NOTICES.dependencies.json",
            "source": resolution,
            "candidate": resolution,
        }
        data["environment"] = {
            "xcodeVersion": "Xcode 16.4 (16F6)",
            "iOSVersion": "18.5",
            "bundleId": "dev.elu.sdk-upgrade-evidence",
        }
        data["observedContinuity"] = {
            "sameApplicationContainer": True,
            "identityPreserved": True,
            "sourceSessionPresent": True,
            "candidateSessionPresent": True,
            "sessionRotated": True,
        }
        data["rawEvidence"] = {
            "sha256": "c" * 64,
            "custody": "operator-managed",
            "status": "captured",
        }
        data["verificationStatus"] = "verified"
        data["blockers"] = []
        return data

    def historical_identity(self) -> str:
        inventory = json.loads(INVENTORY.read_text(encoding="utf-8"))
        blob = inventory["dependencyInventory"]["gitBlob"]
        payload = subprocess.check_output(["git", "cat-file", "blob", blob], cwd=ROOT)
        return json.loads(payload)["packages"][0]["identity"]

    def tag_payload(self) -> bytes:
        inventory = json.loads(INVENTORY.read_text(encoding="utf-8"))
        tag = inventory["observations"][0]["annotatedTag"]
        payload = (
            f"object {tag['peeledSourceRevision']}\n"
            "type commit\n"
            f"tag {tag['name']}\n"
            "tagger github-actions[bot] <github-actions[bot]@users.noreply.github.com> 1785486087 +0000\n"
            "\n"
            f"{tag['name']}\n"
        ).encode("utf-8")
        object_revision = hashlib.sha1(f"tag {len(payload)}\0".encode("ascii") + payload).hexdigest()
        self.assertEqual(object_revision, tag["objectRevision"])
        return payload

    def json_bytes(self, value: object) -> bytes:
        return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")

    def request_bytes(
        self,
        event: str,
        identity: str,
        session: str,
        *,
        method: str = "POST",
        path: str = "/batch",
    ) -> bytes:
        body = gzip.compress(
            json.dumps(
                {
                    "batch": [
                        {
                            "event": event,
                            "distinct_id": identity,
                            "properties": {"$session_id": session},
                        }
                    ]
                }
            ).encode("utf-8")
        )
        return self.json_bytes(
            {
                "method": method,
                "path": path,
                "headers": {"Content-Encoding": "gzip"},
                "bodyBase64": base64.b64encode(body).decode("ascii"),
            }
        )

    def write_raw_archive(
        self,
        directory: pathlib.Path,
        manifest: dict[str, object],
        *,
        candidate_absent: bool = False,
        contradict_absence: bool = False,
        candidate_session: str = "candidate-session",
        source_identity_check: bool = True,
        source_method: str = "POST",
        source_path: str = "/batch",
        source_container_sentinel: bytes = b"s" * 32,
        candidate_container_sentinel: bytes | None = None,
        omit_candidate_container_sentinel: bool = False,
    ) -> pathlib.Path:
        if candidate_container_sentinel is None:
            candidate_container_sentinel = source_container_sentinel
        identity = self.historical_identity()
        resolution = manifest["resolvedDependency"]["source"]  # type: ignore[index]
        source_graph = self.json_bytes(
            {"schemaVersion": 1, "dependencies": [{"identity": identity, **resolution}]}
        )
        candidate_dependencies = (
            [] if candidate_absent and not contradict_absence else [{"identity": identity, **resolution}]
        )
        candidate_graph = self.json_bytes({"schemaVersion": 1, "dependencies": candidate_dependencies})
        if candidate_absent:
            manifest["resolvedDependency"]["candidate"] = {  # type: ignore[index]
                "status": "absent",
                "proof": {
                    "kind": "resolved-package-graph-sha256",
                    "sha256": hashlib.sha256(candidate_graph).hexdigest(),
                },
            }
        provenance = {
            "sourceVersion": manifest["sourceVersion"],
            "sourceRevision": manifest["sourceRevision"],
            "candidateRevision": manifest["candidateRevision"],
            "resolvedDependency": {
                "source": manifest["resolvedDependency"]["source"],  # type: ignore[index]
                "candidate": manifest["resolvedDependency"]["candidate"],  # type: ignore[index]
            },
            "environment": manifest["environment"],
            "applicationContainer": {
                "sentinelRelativePath": (
                    "Library/Application Support/dev.elu.sdk-upgrade-evidence/container-sentinel.bin"
                ),
                "sourcePathSha256": "e" * 64,
                "candidatePathSha256": "f" * 64,
                "sourceSentinelSha256": hashlib.sha256(source_container_sentinel).hexdigest(),
                "candidateSentinelSha256": hashlib.sha256(candidate_container_sentinel).hexdigest(),
            },
        }
        files = {
            "run-provenance.json": self.json_bytes(provenance),
            "capture-status.json": self.json_bytes(
                {
                    "sourceMarkerObserved": True,
                    "candidateMarkerObserved": True,
                    "identityPreserved": True,
                    "sourceSessionPresent": True,
                    "candidateSessionPresent": True,
                    "sessionRotated": candidate_session != "source-session",
                }
            ),
            "application-results/source.json": self.json_bytes(
                {"build": "source", "identityCheck": source_identity_check}
            ),
            "application-results/candidate.json": self.json_bytes(
                {"build": "candidate", "identityCheck": True}
            ),
            "requests/request-0001.json": self.request_bytes(
                "elu_sdk_upgrade_source",
                "opaque-identity",
                "source-session",
                method=source_method,
                path=source_path,
            ),
            "requests/request-0002.json": self.request_bytes(
                "elu_sdk_upgrade_candidate", "opaque-identity", candidate_session
            ),
            "resolved-package-graphs/source.json": source_graph,
            "resolved-package-graphs/candidate.json": candidate_graph,
            "historical-dependency-tag-object.txt": self.tag_payload(),
            "application-container/source-sentinel.bin": source_container_sentinel,
        }
        if not omit_candidate_container_sentinel:
            files["application-container/candidate-sentinel.bin"] = candidate_container_sentinel
        archive_path = directory / "raw-evidence.tar.gz"
        with tarfile.open(archive_path, "w:gz") as archive:
            for name, payload in sorted(files.items()):
                info = tarfile.TarInfo(name)
                info.size = len(payload)
                info.mtime = 0
                archive.addfile(info, io.BytesIO(payload))
        manifest["rawEvidence"] = {
            "sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
            "custody": "operator-managed",
            "status": "captured",
        }
        return archive_path

    def test_checked_manifest_is_valid_but_not_verified(self) -> None:
        self.assertEqual(self.run_validator().returncode, 0)
        self.assertNotEqual(self.run_validator(require_verified=True).returncode, 0)

    def test_complete_verified_manifest_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            manifest = self.verified_manifest()
            archive = self.write_raw_archive(directory, manifest)
            path = self.write_json(directory, "manifest.json", manifest)
            result = self.run_validator(manifest=path, raw_archive=archive, require_verified=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_container_continuity_allows_absolute_path_relocation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            manifest = self.verified_manifest()
            archive = self.write_raw_archive(directory, manifest)
            path = self.write_json(directory, "manifest.json", manifest)
            result = self.run_validator(
                manifest=path,
                raw_archive=archive,
                require_verified=True,
            )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_container_continuity_rejects_changed_or_missing_sentinel(self) -> None:
        cases = (
            {"candidate_container_sentinel": b"c" * 32},
            {"omit_candidate_container_sentinel": True},
        )
        for options in cases:
            with self.subTest(options=options), tempfile.TemporaryDirectory() as temporary:
                directory = pathlib.Path(temporary)
                manifest = self.verified_manifest()
                archive = self.write_raw_archive(directory, manifest, **options)
                path = self.write_json(directory, "manifest.json", manifest)
                result = self.run_validator(
                    manifest=path,
                    raw_archive=archive,
                    require_verified=True,
                )
            self.assertNotEqual(result.returncode, 0)

    def test_missing_candidate_sentinel_is_valid_failed_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            manifest = self.verified_manifest()
            manifest["observedContinuity"]["sameApplicationContainer"] = False  # type: ignore[index]
            manifest["verificationStatus"] = "failed"
            manifest["blockers"] = [
                {
                    "code": "CONTINUITY_NOT_PRESERVED",
                    "detail": "Application data was not preserved.",
                }
            ]
            archive = self.write_raw_archive(
                directory,
                manifest,
                candidate_container_sentinel=b"",
            )
            path = self.write_json(directory, "manifest.json", manifest)
            result = self.run_validator(manifest=path, raw_archive=archive)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_parameter_free_post_batch_marker_is_accepted(self) -> None:
        for source_path in ("/batch", "/batch?"):
            with (
                self.subTest(source_path=source_path),
                tempfile.TemporaryDirectory() as temporary,
            ):
                directory = pathlib.Path(temporary)
                manifest = self.verified_manifest()
                archive = self.write_raw_archive(
                    directory,
                    manifest,
                    source_method="POST",
                    source_path=source_path,
                )
                path = self.write_json(directory, "manifest.json", manifest)
                result = self.run_validator(
                    manifest=path,
                    raw_archive=archive,
                    require_verified=True,
                )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_marker_shaped_payload_at_wrong_method_or_path_is_rejected(self) -> None:
        cases = (
            ("GET", "/batch"),
            ("POST", "/not-batch"),
            ("POST", "/batch?forged=1"),
            ("POST", "/batch??"),
        )
        for method, path_value in cases:
            with self.subTest(method=method, path=path_value), tempfile.TemporaryDirectory() as temporary:
                directory = pathlib.Path(temporary)
                manifest = self.verified_manifest()
                archive = self.write_raw_archive(
                    directory,
                    manifest,
                    source_method=method,
                    source_path=path_value,
                )
                path = self.write_json(directory, "manifest.json", manifest)
                result = self.run_validator(manifest=path, raw_archive=archive, require_verified=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("captured requests", result.stderr)

    def test_verified_manifest_requires_public_identity_check(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            manifest = self.verified_manifest()
            archive = self.write_raw_archive(directory, manifest, source_identity_check=False)
            path = self.write_json(directory, "manifest.json", manifest)
            result = self.run_validator(manifest=path, raw_archive=archive, require_verified=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("public identity facade", result.stderr)

    def test_verified_manifest_requires_session_continuity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            data = self.verified_manifest()
            archive = self.write_raw_archive(directory, data, candidate_session="source-session")
            path = self.write_json(directory, "manifest.json", data)
            result = self.run_validator(manifest=path, raw_archive=archive, require_verified=True)
        self.assertNotEqual(result.returncode, 0)

    def test_verified_manifest_accepts_proven_candidate_dependency_absence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            data = self.verified_manifest()
            archive = self.write_raw_archive(directory, data, candidate_absent=True)
            path = self.write_json(directory, "manifest.json", data)
            result = self.run_validator(manifest=path, raw_archive=archive, require_verified=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_candidate_dependency_absence_rejects_graph_with_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            data = self.verified_manifest()
            archive = self.write_raw_archive(
                directory,
                data,
                candidate_absent=True,
                contradict_absence=True,
            )
            path = self.write_json(directory, "manifest.json", data)
            result = self.run_validator(manifest=path, raw_archive=archive, require_verified=True)
        self.assertNotEqual(result.returncode, 0)

    def test_verified_manifest_recomputes_raw_archive_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            data = self.verified_manifest()
            archive = self.write_raw_archive(directory, data)
            path = self.write_json(directory, "manifest.json", data)
            with archive.open("ab") as stream:
                stream.write(b"tampered")
            result = self.run_validator(manifest=path, raw_archive=archive, require_verified=True)
        self.assertNotEqual(result.returncode, 0)

    def test_verified_manifest_rejects_self_asserted_digest_without_raw_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_json(pathlib.Path(temporary), "manifest.json", self.verified_manifest())
            result = self.run_validator(manifest=path, require_verified=True)
        self.assertNotEqual(result.returncode, 0)

    def test_failed_manifest_cannot_report_all_checks_passing(self) -> None:
        data = self.verified_manifest()
        data["verificationStatus"] = "failed"
        data["blockers"] = [{"code": "CONTINUITY_NOT_PRESERVED", "detail": "fixture"}]
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_json(pathlib.Path(temporary), "manifest.json", data)
            result = self.run_validator(manifest=path)
        self.assertNotEqual(result.returncode, 0)

    def test_manifest_rejects_raw_evidence_paths(self) -> None:
        data = self.verified_manifest()
        data["rawEvidence"]["path"] = "/private/raw-capture"  # type: ignore[index]
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_json(pathlib.Path(temporary), "manifest.json", data)
            result = self.run_validator(manifest=path)
        self.assertNotEqual(result.returncode, 0)

    def test_inventory_rejects_universal_claim(self) -> None:
        data = copy.deepcopy(json.loads(INVENTORY.read_text(encoding="utf-8")))
        data["observations"][0]["universalHistoricalClaim"] = True
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_json(pathlib.Path(temporary), "inventory.json", data)
            result = self.run_validator(inventory=path)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
