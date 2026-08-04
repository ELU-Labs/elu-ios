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
HARNESS_SOURCE = ROOT / "UpgradeEvidence" / "0.1.0" / "Harness" / "AppDelegate.swift"
SPEC = importlib.util.spec_from_file_location("run_upgrade_evidence", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class UpgradeEvidenceCaptureTests(unittest.TestCase):
    def test_harness_view_remains_ios_13_compatible(self) -> None:
        source = HARNESS_SOURCE.read_text(encoding="utf-8")
        project = PROJECT.read_text(encoding="utf-8")
        self.assertNotIn(".accessibilityIdentifier(", source)
        self.assertIn("IPHONEOS_DEPLOYMENT_TARGET = 13.0;", project)

    def test_app_delegate_window_can_witness_the_protocol_requirement(self) -> None:
        source = HARNESS_SOURCE.read_text(encoding="utf-8")
        self.assertIn("    var window: UIWindow?", source)
        self.assertNotIn("private var window: UIWindow?", source)

    def test_harness_product_is_bound_to_the_local_package(self) -> None:
        project = PROJECT.read_text(encoding="utf-8")
        self.assertIn(
            'package = A10000000000000000000011 /* XCLocalSwiftPackageReference "../../.." */;',
            project,
        )

    def test_build_failure_classification_is_fixed_enum_only(self) -> None:
        self.assertEqual(RUNNER.BUILD_PREFIXES, {"source": "SOURCE", "candidate": "CANDIDATE"})
        cases = (
            ("source", b"", b"Could not resolve package dependencies", "SOURCE_BUILD_DEPENDENCY_RESOLUTION_FAILED"),
            ("source", b"error: Missing package product 'Example'", b"", "SOURCE_BUILD_CONFIGURATION_FAILED"),
            ("candidate", b"SwiftCompile normal arm64 /private/path.swift", b"", "CANDIDATE_BUILD_FAILED"),
            ("candidate", b"", b"linker command failed with exit code 1", "CANDIDATE_BUILD_LINK_FAILED"),
            ("source", b"private path with no known marker", b"", "SOURCE_BUILD_FAILED"),
            ("../../private-build", b"cannot find secret", b"", "UNEXPECTED_RUNNER_FAILURE"),
        )
        for build, stdout, stderr, expected in cases:
            with self.subTest(expected=expected):
                code = RUNNER.classify_build_failure(build, stdout, stderr)
                self.assertEqual(code, expected)
                self.assertRegex(code, r"^[A-Z][A-Z0-9_]+$")
                self.assertNotIn("/", code)
                self.assertIn(code, RUNNER.BLOCKER_DETAILS)

    def test_compiler_failure_classification_has_safe_origin_and_category(self) -> None:
        source_lines = HARNESS_SOURCE.read_text(encoding="utf-8").splitlines()

        def line_number(fragment: str) -> int:
            return next(index for index, line in enumerate(source_lines, start=1) if fragment in line)

        harness_path = "/private/build/UpgradeEvidence/0.1.0/Harness/AppDelegate.swift"
        cases = (
            (
                line_number('Text("SDK upgrade evidence")'),
                "'modifier' is only available in iOS 14.0 or newer",
                "SOURCE_BUILD_COMPILE_HARNESS_VIEW_AVAILABILITY",
            ),
            (
                line_number("Elu.setup("),
                "type 'Elu' has no member 'setup'",
                "SOURCE_BUILD_COMPILE_HARNESS_CONFIG_API",
            ),
            (
                line_number("Elu.distinctId()"),
                "main actor-isolated call in a nonisolated context",
                "SOURCE_BUILD_COMPILE_HARNESS_IDENTITY_CONCURRENCY",
            ),
            (
                line_number("JSONEncoder().encode"),
                "the compiler is unable to type-check this expression",
                "SOURCE_BUILD_COMPILE_HARNESS_RESULT_OTHER",
            ),
            (
                line_number("var window"),
                "property must be declared internal",
                "SOURCE_BUILD_COMPILE_HARNESS_BOOTSTRAP_API",
            ),
        )
        for line, message, expected in cases:
            with self.subTest(expected=expected):
                diagnostic = f"{harness_path}:{line}:9: error: {message}".encode()
                code = RUNNER.classify_build_failure("source", diagnostic, b"")
                self.assertEqual(code, expected)
                self.assertIn(code, RUNNER.BLOCKER_DETAILS)
                self.assertNotIn("/", code)

        bare_diagnostic = (
            f"warning: only available in iOS 99\n"
            f"AppDelegate.swift:{line_number('var window')}:9: error: property must be declared internal"
        )
        bare_code = RUNNER.classify_build_failure("source", bare_diagnostic.encode(), b"")
        self.assertEqual(bare_code, "SOURCE_BUILD_COMPILE_UNKNOWN_API")

        unknown_code = RUNNER.classify_build_failure(
            "candidate",
            b"warning: only available in iOS 99\nemit-swiftmodule command failed",
            b"",
        )
        self.assertEqual(unknown_code, "CANDIDATE_BUILD_COMPILE_UNKNOWN_OTHER")

        external_cases = (
            (
                "/private/build/Sources/EluAnalytics/EluState.swift:8:2: error: cannot find symbol",
                "SOURCE_BUILD_COMPILE_SDK_API",
            ),
            (
                "/private/build/SourcePackages/checkouts/vendor/Sources/Vendor.swift:8:2: error: unavailable API",
                "SOURCE_BUILD_COMPILE_DEPENDENCY_AVAILABILITY",
            ),
        )
        for diagnostic, expected in external_cases:
            with self.subTest(expected=expected):
                code = RUNNER.classify_build_failure("source", diagnostic.encode(), b"")
                self.assertEqual(code, expected)
                self.assertIn(code, RUNNER.BLOCKER_DETAILS)
                self.assertNotIn("/", code)

    def test_compiler_diagnostics_handle_path_and_format_edge_cases(self) -> None:
        source_lines = HARNESS_SOURCE.read_text(encoding="utf-8").splitlines()
        window_line = next(
            index for index, line in enumerate(source_lines, start=1) if "var window" in line
        )
        harness_path = "/private/build/UpgradeEvidence/0.1.0/Harness/AppDelegate.swift"
        cases = (
            (
                f"{harness_path}:{window_line}: error: property must be declared internal",
                "SOURCE_BUILD_COMPILE_HARNESS_BOOTSTRAP_API",
            ),
            (
                "/private/build/SourcePackages/checkouts/vendor/AppDelegate.swift:8:2: "
                "error: cannot find symbol",
                "SOURCE_BUILD_COMPILE_DEPENDENCY_API",
            ),
            (
                "/private/build/SourcePackages/checkouts/vendor/UpgradeEvidence/0.1.0/"
                "Harness/AppDelegate.swift:8:2: error: cannot find symbol",
                "SOURCE_BUILD_COMPILE_DEPENDENCY_API",
            ),
            (
                "/private/build/SourcePackages/checkouts/vendor/Sources/Thing.cpp:8: "
                "error: cannot find symbol",
                "SOURCE_BUILD_COMPILE_DEPENDENCY_API",
            ),
        )
        for diagnostic, expected in cases:
            with self.subTest(expected=expected):
                self.assertEqual(
                    RUNNER.classify_build_failure("source", diagnostic.encode(), b""), expected
                )

    def test_compiler_multi_error_selection_is_order_invariant(self) -> None:
        source_lines = HARNESS_SOURCE.read_text(encoding="utf-8").splitlines()
        setup_line = next(
            index for index, line in enumerate(source_lines, start=1) if "Elu.setup(" in line
        )
        records = [
            "/private/build/Sources/EluAnalytics/EluState.swift:8:2: "
            "error: unavailable declaration",
            f"/private/build/UpgradeEvidence/0.1.0/Harness/AppDelegate.swift:{setup_line}:2: "
            "error: cannot find setup",
            f"/private/build/UpgradeEvidence/0.1.0/Harness/AppDelegate.swift:{setup_line}:2: "
            "error: cannot find setup",
        ]
        forward = RUNNER.classify_build_failure("candidate", "\n".join(records).encode(), b"")
        reverse = RUNNER.classify_build_failure(
            "candidate", "\n".join(reversed(records)).encode(), b""
        )
        self.assertEqual(forward, "CANDIDATE_BUILD_COMPILE_HARNESS_CONFIG_API")
        self.assertEqual(reverse, forward)

    def test_compiler_failure_public_values_do_not_include_raw_diagnostics(self) -> None:
        raw_path = "/private/customer-secret/project/Sources/SecretThing.swift"
        raw_message = "cannot find CUSTOMER_PRIVATE_SYMBOL"
        code = RUNNER.classify_build_failure(
            "source", f"{raw_path}:7:3: error: {raw_message}".encode(), b""
        )
        detail = RUNNER.BLOCKER_DETAILS[code]
        public_output = json.dumps({"blockers": [{"code": code, "detail": detail}]})
        public_output += f"\nupgrade evidence blocked: {code}"
        for sentinel in (raw_path, raw_message, "CUSTOMER_PRIVATE_SYMBOL"):
            with self.subTest(sentinel=sentinel):
                self.assertNotIn(sentinel, code)
                self.assertNotIn(sentinel, detail)
                self.assertNotIn(sentinel, public_output)

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
