from __future__ import annotations

import importlib.util
import io
import json
import pathlib
import tempfile
import types
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "run-upgrade-evidence.py"
PROJECT = ROOT / "UpgradeEvidence" / "0.1.0" / "Harness" / "UpgradeHarness.xcodeproj" / "project.pbxproj"
SPEC = importlib.util.spec_from_file_location("run_upgrade_evidence", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class UpgradeEvidenceCaptureTests(unittest.TestCase):
    def test_harness_product_is_bound_to_the_local_package(self) -> None:
        project = PROJECT.read_text(encoding="utf-8")
        self.assertIn(
            'package = A10000000000000000000011 /* XCLocalSwiftPackageReference "../../.." */;',
            project,
        )

    def test_build_failure_classification_is_fixed_enum_only(self) -> None:
        cases = (
            ("source", b"", b"Could not resolve package dependencies", "SOURCE_BUILD_DEPENDENCY_RESOLUTION_FAILED"),
            ("source", b"error: Missing package product 'Example'", b"", "SOURCE_BUILD_CONFIGURATION_FAILED"),
            ("candidate", b"SwiftCompile normal arm64 /private/path.swift", b"", "CANDIDATE_BUILD_COMPILATION_FAILED"),
            ("candidate", b"", b"linker command failed with exit code 1", "CANDIDATE_BUILD_LINK_FAILED"),
            ("source", b"private path with no known marker", b"", "SOURCE_BUILD_FAILED"),
        )
        for build, stdout, stderr, expected in cases:
            with self.subTest(expected=expected):
                code = RUNNER.classify_build_failure(build, stdout, stderr)
                self.assertEqual(code, expected)
                self.assertRegex(code, r"^[A-Z][A-Z0-9_]+$")
                self.assertNotIn("/", code)

    def marker_body(self) -> bytes:
        return json.dumps(
            {
                "batch": [
                    {
                        "event": "elu_sdk_upgrade_source",
                        "distinct_id": "opaque-identity",
                        "properties": {"$session_id": "source-session"},
                    }
                ]
            }
        ).encode("utf-8")

    def captured_markers(self, method: str, path: str) -> dict[str, tuple[str, str]]:
        with tempfile.TemporaryDirectory() as temporary:
            ledger = RUNNER.CaptureLedger(pathlib.Path(temporary))
            ledger.record(method, path, {}, self.marker_body())
            return dict(ledger.markers)

    def route_post(self, path: str) -> tuple[list[int], dict[str, tuple[str, str]]]:
        with tempfile.TemporaryDirectory() as temporary:
            ledger = RUNNER.CaptureLedger(pathlib.Path(temporary))
            body = self.marker_body()
            handler = object.__new__(RUNNER.EvidenceHandler)
            handler.command = "POST"
            handler.path = path
            handler.headers = {"Content-Length": str(len(body))}
            handler.rfile = io.BytesIO(body)
            handler.server = types.SimpleNamespace(ledger=ledger)
            statuses: list[int] = []
            handler._respond = lambda _value, status=200: statuses.append(status)
            handler.do_POST()
            return statuses, dict(ledger.markers)

    def test_capture_ledger_accepts_exact_post_batch(self) -> None:
        self.assertEqual(
            self.captured_markers("POST", "/batch"),
            {"source": ("opaque-identity", "source-session")},
        )

    def test_capture_ledger_rejects_marker_at_wrong_method_or_path(self) -> None:
        for method, path in (
            ("GET", "/batch"),
            ("POST", "/not-batch"),
            ("POST", "/batch?forged=1"),
        ):
            with self.subTest(method=method, path=path):
                self.assertEqual(self.captured_markers(method, path), {})

    def test_server_accepts_batch_and_rejects_unexpected_post_path(self) -> None:
        unexpected_statuses, unexpected_markers = self.route_post("/not-batch")
        self.assertEqual(unexpected_statuses, [404])
        self.assertEqual(unexpected_markers, {})

        prefixed_statuses, prefixed_markers = self.route_post("/flags-forged")
        self.assertEqual(prefixed_statuses, [404])
        self.assertEqual(prefixed_markers, {})

        flags_statuses, flags_markers = self.route_post("/flags?v=2")
        self.assertEqual(flags_statuses, [200])
        self.assertEqual(flags_markers, {})

        batch_statuses, batch_markers = self.route_post("/batch")
        self.assertEqual(batch_statuses, [200])
        self.assertEqual(
            batch_markers,
            {"source": ("opaque-identity", "source-session")},
        )


if __name__ == "__main__":
    unittest.main()
