from __future__ import annotations

import gzip
import importlib.util
import io
import json
import pathlib
import tempfile
import types
import unittest
from email.message import Message


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "run-upgrade-evidence.py"
PROJECT = ROOT / "UpgradeEvidence" / "0.1.0" / "Harness" / "UpgradeHarness.xcodeproj" / "project.pbxproj"
HARNESS_SOURCE = ROOT / "UpgradeEvidence" / "0.1.0" / "Harness" / "AppDelegate.swift"
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
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

    def test_harness_establishes_public_network_before_creating_identity(self) -> None:
        source = HARNESS_SOURCE.read_text(encoding="utf-8")
        start_body = source.split("static func start()", 1)[1].split(
            "private static func probeNetwork", 1
        )[0]
        probe_body = source.split("private static func probeNetwork", 1)[1].split(
            "private static func waitForSystemReachability", 1
        )[0]
        reachability_body = source.split(
            "private static func waitForSystemReachability", 1
        )[1].split(
            "private static func begin", 1
        )[0]
        begin_body = source.split("private static func begin", 1)[1].split(
            "private static func waitForIdentity", 1
        )[0]
        self.assertIn('URL(string: "https://github.com/favicon.ico")!', source)
        self.assertIn("private static let networkProbeTimeout: TimeInterval = 10", source)
        self.assertIn("private static let reachabilityProbeTimeout: TimeInterval = 10", source)
        self.assertIn("private static let requiredReachabilitySamples = 2", source)
        self.assertIn("probeNetwork { ready in", start_body)
        self.assertIn("guard ready else", start_body)
        self.assertEqual(start_body.count('write(build: "invalid", identityCheck: false)'), 1)
        self.assertEqual(
            start_body.count('write(build: "network-unready", identityCheck: false)'),
            2,
        )
        self.assertIn("URLSessionConfiguration.ephemeral", probe_body)
        self.assertIn(
            "configuration.timeoutIntervalForResource = networkProbeTimeout",
            probe_body,
        )
        self.assertIn('request.httpMethod = "GET"', probe_body)
        self.assertIn("request.cachePolicy = .reloadIgnoringLocalCacheData", probe_body)
        self.assertIn("request.timeoutInterval = networkProbeTimeout", probe_body)
        self.assertIn("response is HTTPURLResponse", probe_body)
        self.assertNotIn("expectedIdentity", probe_body)
        self.assertNotIn("Elu.", probe_body)
        self.assertIn("waitForSystemReachability(", start_body)
        self.assertIn("guard reachable else", start_body)
        self.assertIn("SCNetworkReachabilityCreateWithAddress", reachability_body)
        self.assertIn("SCNetworkReachabilityGetFlags", reachability_body)
        self.assertIn("flags.contains(.reachable)", reachability_body)
        self.assertIn("nextReachableSamples >= requiredReachabilitySamples", reachability_body)
        self.assertIn("reachableSamples: nextReachableSamples", reachability_body)
        self.assertNotIn("expectedIdentity", reachability_body)
        self.assertNotIn("Elu.", reachability_body)
        self.assertIn("expectedIdentity = UUID().uuidString", begin_body)
        self.assertIn("Elu.setup", begin_body)

    def test_runner_deadline_covers_network_and_identity_timeouts(self) -> None:
        source = HARNESS_SOURCE.read_text(encoding="utf-8")
        self.assertIn("private static let networkProbeTimeout: TimeInterval = 10", source)
        self.assertIn("private static let reachabilityProbeTimeout: TimeInterval = 10", source)
        self.assertIn("private static let timeoutSeconds: TimeInterval = 20", source)
        self.assertEqual(RUNNER.RUN_RESULT_WAIT_SECONDS, 60)
        self.assertGreater(RUNNER.RUN_RESULT_WAIT_SECONDS, 10 + 10 + 20 + 5)

    def test_upgrade_harness_uses_the_supported_simulator_image(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        upgrade_job = workflow.split("  upgrade-evidence:", 1)[1]
        self.assertIn("    runs-on: macos-15\n", upgrade_job)
        self.assertNotIn("macos-15-intel", upgrade_job)

    def test_app_delegate_window_can_witness_the_protocol_requirement(self) -> None:
        source = HARNESS_SOURCE.read_text(encoding="utf-8")
        self.assertIn("    var window: UIWindow?", source)
        self.assertNotIn("private var window: UIWindow?", source)

    def test_harness_polls_past_anonymous_identity_until_the_fixed_deadline(self) -> None:
        source = HARNESS_SOURCE.read_text(encoding="utf-8")
        wait_body = source.split("private static func waitForIdentity", 1)[1].split(
            "private static func write", 1
        )[0]
        self.assertIn("private static let timeoutSeconds: TimeInterval = 20", source)
        self.assertIn("deadline: Date().addingTimeInterval(timeoutSeconds)", source)
        self.assertIn("guard Date() < deadline else", wait_body)
        self.assertIn("if Elu.distinctId() == expectedIdentity", wait_body)
        self.assertIn("deadline: deadline", wait_body)
        self.assertNotIn("identityCheck: matches", wait_body)
        self.assertNotIn("if let observed = Elu.distinctId()", wait_body)

    def test_marker_capture_is_single_shot_with_bounded_flush_retries(self) -> None:
        source = HARNESS_SOURCE.read_text(encoding="utf-8")
        flush_body = source.split("private static func flushMarker", 1)[1].split(
            "private static func write", 1
        )[0]
        self.assertEqual(source.count("Elu.capture("), 1)
        self.assertIn("private static let flushRetryCount = 5", source)
        self.assertIn("private static let flushRetryInterval: TimeInterval = 1", source)
        self.assertEqual(flush_body.count("Elu.flush()"), 1)
        self.assertIn("guard retriesRemaining > 0 else { return }", flush_body)
        self.assertIn(".now() + flushRetryInterval", flush_body)
        self.assertIn("retriesRemaining: retriesRemaining - 1", flush_body)

    def test_marker_wait_exceeds_provider_timer_and_uses_fixed_codes(self) -> None:
        self.assertEqual(RUNNER.MARKER_WAIT_SECONDS, 45)
        self.assertGreater(RUNNER.MARKER_WAIT_SECONDS, 30)
        self.assertEqual(
            RUNNER.CaptureLedger.wait_for.__defaults__, (RUNNER.MARKER_WAIT_SECONDS,)
        )
        self.assertEqual(
            RUNNER.MARKER_BLOCKER_CODES,
            {
                "source": {
                    "exactBatchNotObserved": "SOURCE_EXACT_BATCH_NOT_OBSERVED",
                    "batchUnreadable": "SOURCE_BATCH_UNREADABLE",
                    "markerEventAbsent": "SOURCE_MARKER_EVENT_ABSENT",
                    "markerIdentityAbsent": "SOURCE_MARKER_IDENTITY_ABSENT",
                    "markerSessionAbsent": "SOURCE_MARKER_SESSION_ABSENT",
                },
                "candidate": {
                    "exactBatchNotObserved": "CANDIDATE_EXACT_BATCH_NOT_OBSERVED",
                    "batchUnreadable": "CANDIDATE_BATCH_UNREADABLE",
                    "markerEventAbsent": "CANDIDATE_MARKER_EVENT_ABSENT",
                    "markerIdentityAbsent": "CANDIDATE_MARKER_IDENTITY_ABSENT",
                    "markerSessionAbsent": "CANDIDATE_MARKER_SESSION_ABSENT",
                },
            },
        )
        self.assertEqual(
            RUNNER.CaptureLedger.wait_for.__kwdefaults__, {"after_request": 0}
        )
        for codes in RUNNER.MARKER_BLOCKER_CODES.values():
            for code in codes.values():
                self.assertIn(code, RUNNER.BLOCKER_DETAILS)
                self.assertRegex(code, r"^[A-Z][A-Z0-9_]+$")
                self.assertNotIn("/", code)

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

    def test_run_result_failure_states_are_fixed_and_sanitized(self) -> None:
        cases = (
            (None, "RESULT_MISSING"),
            (b"{", "RESULT_SCHEMA_INVALID"),
            (b"[]", "RESULT_SCHEMA_INVALID"),
            (json.dumps({"build": "source"}).encode(), "RESULT_SCHEMA_INVALID"),
            (
                json.dumps(
                    {"build": "source", "identityCheck": True, "unexpected": "raw"}
                ).encode(),
                "RESULT_SCHEMA_INVALID",
            ),
            (
                b'{"build":"source","build":"candidate","identityCheck":true}',
                "RESULT_SCHEMA_INVALID",
            ),
            (
                json.dumps({"build": "candidate", "identityCheck": True}).encode(),
                "RESULT_BUILD_MISMATCH",
            ),
            (
                json.dumps({"build": "source", "identityCheck": False}).encode(),
                "IDENTITY_FALSE",
            ),
        )
        for payload, expected_failure in cases:
            with self.subTest(expected_failure=expected_failure):
                result, failure = RUNNER.inspect_run_result("source", payload)
                self.assertIsNone(result)
                self.assertEqual(failure, expected_failure)
        for build, prefix in RUNNER.BUILD_PREFIXES.items():
            for failure in RUNNER.RUN_RESULT_FAILURES:
                for observed, observation in RUNNER.CONFIG_GET_OBSERVATIONS.items():
                    code = RUNNER.run_result_blocker_code(build, failure, observed)
                    detail = RUNNER.BLOCKER_DETAILS[code]
                    self.assertEqual(code, f"{prefix}_RUN_{failure}_{observation[0]}")
                    self.assertRegex(code, r"^[A-Z][A-Z0-9_]+$")
                    self.assertNotIn("/", code)
                    self.assertNotIn("PRIVATE_", detail)

        result, failure = RUNNER.inspect_run_result(
            "candidate", json.dumps({"build": "candidate", "identityCheck": True}).encode()
        )
        self.assertEqual(result, {"build": "candidate", "identityCheck": True})
        self.assertIsNone(failure)
        self.assertEqual(
            RUNNER.run_result_blocker_code("invalid/raw", "RESULT_MISSING", True),
            "UNEXPECTED_RUNNER_FAILURE",
        )

    def test_changed_result_files_drive_terminal_loop_states(self) -> None:
        for failure in RUNNER.RUN_RESULT_FAILURES:
            self.assertEqual(
                RUNNER.should_retry_run_result(failure), failure == "RESULT_MISSING"
            )

        with tempfile.TemporaryDirectory() as temporary:
            documents = pathlib.Path(temporary)
            before = RUNNER.snapshot_result_files(documents)
            result, failure = RUNNER.inspect_changed_run_result("source", documents, before)
            self.assertIsNone(result)
            self.assertEqual(failure, "RESULT_MISSING")
            self.assertTrue(RUNNER.should_retry_run_result(failure))

            candidate = documents / RUNNER.RESULT_NAMES["candidate"]
            candidate.write_text(
                json.dumps({"build": "candidate", "identityCheck": True}), encoding="utf-8"
            )
            _, failure = RUNNER.inspect_changed_run_result("source", documents, before)
            self.assertEqual(failure, "RESULT_BUILD_MISMATCH")
            self.assertFalse(RUNNER.should_retry_run_result(failure))

        with tempfile.TemporaryDirectory() as temporary:
            documents = pathlib.Path(temporary)
            before = RUNNER.snapshot_result_files(documents)
            (documents / RUNNER.INVALID_RESULT_NAME).write_text(
                json.dumps({"build": "invalid", "identityCheck": False}), encoding="utf-8"
            )
            _, failure = RUNNER.inspect_changed_run_result("source", documents, before)
            self.assertEqual(failure, "ENVIRONMENT_INVALID")
            self.assertFalse(RUNNER.should_retry_run_result(failure))

        with tempfile.TemporaryDirectory() as temporary:
            documents = pathlib.Path(temporary)
            before = RUNNER.snapshot_result_files(documents)
            (documents / RUNNER.NETWORK_UNREADY_RESULT_NAME).write_text(
                json.dumps({"build": "network-unready", "identityCheck": False}),
                encoding="utf-8",
            )
            _, failure = RUNNER.inspect_changed_run_result("source", documents, before)
            self.assertEqual(failure, "NETWORK_UNREADY")
            self.assertFalse(RUNNER.should_retry_run_result(failure))

        expected_cases = (
            (b"{", None, "RESULT_SCHEMA_INVALID"),
            (
                json.dumps({"build": "source", "identityCheck": False}).encode(),
                None,
                "IDENTITY_FALSE",
            ),
            (
                json.dumps({"build": "source", "identityCheck": True}).encode(),
                {"build": "source", "identityCheck": True},
                None,
            ),
        )
        for payload, expected_result, expected_failure in expected_cases:
            with (
                self.subTest(expected_failure=expected_failure),
                tempfile.TemporaryDirectory() as temporary,
            ):
                documents = pathlib.Path(temporary)
                before = RUNNER.snapshot_result_files(documents)
                (documents / RUNNER.RESULT_NAMES["source"]).write_bytes(payload)
                result, failure = RUNNER.inspect_changed_run_result("source", documents, before)
                self.assertEqual(result, expected_result)
                self.assertEqual(failure, expected_failure)

    def test_prior_source_result_does_not_poison_candidate_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            documents = pathlib.Path(temporary)
            source_result = documents / RUNNER.RESULT_NAMES["source"]
            source_result.write_text(
                json.dumps({"build": "source", "identityCheck": True}), encoding="utf-8"
            )
            before = RUNNER.snapshot_result_files(documents)
            result, failure = RUNNER.inspect_changed_run_result("candidate", documents, before)
            self.assertIsNone(result)
            self.assertEqual(failure, "RESULT_MISSING")

            source_result.write_text(
                json.dumps({"build": "source", "identityCheck": False}), encoding="utf-8"
            )
            _, failure = RUNNER.inspect_changed_run_result("candidate", documents, before)
            self.assertEqual(failure, "RESULT_BUILD_MISMATCH")

    def test_launch_uses_documented_terminate_running_process_option(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('"launch", "--terminate-running-process"', source)
        self.assertNotIn('"launch", "--terminate-running",', source)

    def test_run_result_public_values_do_not_include_raw_payload_values(self) -> None:
        raw_build = "PRIVATE_CUSTOMER_BUILD"
        raw_value = "PRIVATE_IDENTITY_VALUE"
        payload = json.dumps(
            {"build": raw_build, "identityCheck": True, "identity": raw_value}
        ).encode()
        _, failure = RUNNER.inspect_run_result("source", payload)
        code = RUNNER.run_result_blocker_code("source", failure, True)
        detail = RUNNER.BLOCKER_DETAILS[code]
        public_output = json.dumps({"blockers": [{"code": code, "detail": detail}]})
        for sentinel in (raw_build, raw_value):
            with self.subTest(sentinel=sentinel):
                self.assertNotIn(sentinel, code)
                self.assertNotIn(sentinel, detail)
                self.assertNotIn(sentinel, public_output)

    def batch_body(self, events: list[object]) -> bytes:
        return json.dumps({"batch": events}).encode("utf-8")

    def marker_body(self) -> bytes:
        return self.batch_body(
            [
                {
                    "event": "elu_sdk_upgrade_source",
                    "distinct_id": "opaque-identity",
                    "properties": {"$session_id": "source-session"},
                }
            ]
        )

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

    def config_get_count(self, method: str, path: str) -> int:
        with tempfile.TemporaryDirectory() as temporary:
            ledger = RUNNER.CaptureLedger(pathlib.Path(temporary))
            ledger.record(method, path, {}, b"")
            return ledger.exact_config_get_count()

    def test_capture_ledger_accepts_parameter_free_post_batch(self) -> None:
        for path in ("/batch", "/batch?"):
            with self.subTest(path=path):
                self.assertEqual(
                    self.captured_markers("POST", path),
                    {"source": ("opaque-identity", "source-session")},
                )

    def test_capture_ledger_parses_realistic_lowercase_gzip_batch_strictly(self) -> None:
        body = gzip.compress(
            json.dumps(
                {
                    "api_key": "upgrade-evidence-token",
                    "batch": [
                        {
                            "event": "Application Opened",
                            "distinct_id": "opaque-identity",
                            "properties": {"$session_id": "source-session"},
                        },
                        {
                            "event": "elu_sdk_upgrade_source",
                            "distinct_id": "opaque-identity",
                            "properties": {"$session_id": "source-session"},
                        },
                        {
                            "event": "elu_sdk_upgrade_candidate",
                            "distinct_id": "opaque-identity",
                            "properties": {},
                        },
                    ],
                }
            ).encode("utf-8")
        )
        with tempfile.TemporaryDirectory() as temporary:
            ledger = RUNNER.CaptureLedger(pathlib.Path(temporary))
            ledger.record("POST", "/batch", {"content-encoding": "gzip"}, body)
            self.assertEqual(
                ledger.markers,
                {"source": ("opaque-identity", "source-session")},
            )

        with tempfile.TemporaryDirectory() as temporary:
            ledger = RUNNER.CaptureLedger(pathlib.Path(temporary))
            ledger.record("POST", "/batch?forged=1", {"content-encoding": "gzip"}, body)
            self.assertEqual(ledger.markers, {})

    def test_marker_blocker_classifies_each_capture_stage(self) -> None:
        unreadable_cases = (
            ({}, self.marker_body(), False),
            ({"Content-Encoding": "gzip"}, b"not-gzip", True),
            ({"Content-Encoding": "br"}, self.marker_body(), True),
            ({}, b"{", True),
            ({}, json.dumps({"events": []}).encode("utf-8"), True),
        )
        for headers, body, body_readable in unreadable_cases:
            with self.subTest(headers=headers, body=body, body_readable=body_readable):
                with tempfile.TemporaryDirectory() as temporary:
                    ledger = RUNNER.CaptureLedger(pathlib.Path(temporary))
                    cursor = ledger.observation_cursor()
                    ledger.record(
                        "POST",
                        "/batch",
                        headers,
                        body,
                        body_readable=body_readable,
                    )
                    self.assertEqual(
                        ledger.marker_blocker_code("source", after_request=cursor),
                        "SOURCE_BATCH_UNREADABLE",
                    )

        cases = (
            (
                "/batch?not-exact=1",
                self.marker_body(),
                "SOURCE_EXACT_BATCH_NOT_OBSERVED",
            ),
            (
                "/batch",
                self.batch_body([{"event": "Application Opened"}]),
                "SOURCE_MARKER_EVENT_ABSENT",
            ),
            (
                "/batch",
                self.batch_body(
                    [
                        {
                            "event": "elu_sdk_upgrade_source",
                            "properties": {"$session_id": "source-session"},
                        }
                    ]
                ),
                "SOURCE_MARKER_IDENTITY_ABSENT",
            ),
            (
                "/batch",
                self.batch_body(
                    [
                        {
                            "event": "elu_sdk_upgrade_source",
                            "distinct_id": "opaque-identity",
                            "properties": {},
                        }
                    ]
                ),
                "SOURCE_MARKER_SESSION_ABSENT",
            ),
        )
        for path, body, expected in cases:
            with self.subTest(expected=expected):
                with tempfile.TemporaryDirectory() as temporary:
                    ledger = RUNNER.CaptureLedger(pathlib.Path(temporary))
                    cursor = ledger.observation_cursor()
                    ledger.record("POST", path, {}, body)
                    self.assertEqual(
                        ledger.marker_blocker_code("source", after_request=cursor),
                        expected,
                    )

    def test_marker_blocker_uses_strongest_conclusive_stage(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            ledger = RUNNER.CaptureLedger(pathlib.Path(temporary))
            cursor = ledger.observation_cursor()
            ledger.record(
                "POST",
                "/batch",
                {},
                self.batch_body([{"event": "Application Opened"}]),
            )
            ledger.record("POST", "/batch", {}, b"{", body_readable=True)
            self.assertEqual(
                ledger.marker_blocker_code("source", after_request=cursor),
                "SOURCE_BATCH_UNREADABLE",
            )

            ledger.record(
                "POST",
                "/batch",
                {},
                self.batch_body([{"event": "elu_sdk_upgrade_source"}]),
            )
            self.assertEqual(
                ledger.marker_blocker_code("source", after_request=cursor),
                "SOURCE_MARKER_IDENTITY_ABSENT",
            )

            ledger.record(
                "POST",
                "/batch",
                {},
                self.batch_body(
                    [
                        {
                            "event": "elu_sdk_upgrade_source",
                            "distinct_id": "opaque-identity",
                            "properties": {},
                        }
                    ]
                ),
            )
            self.assertEqual(
                ledger.marker_blocker_code("source", after_request=cursor),
                "SOURCE_MARKER_SESSION_ABSENT",
            )

            ledger.record("POST", "/batch", {}, self.marker_body())
            self.assertTrue(ledger.wait_for("source", timeout=0, after_request=cursor))
            self.assertIsNone(
                ledger.marker_blocker_code("source", after_request=cursor)
            )
            ledger.raise_marker_timeout("source", after_request=cursor)

    def test_marker_observation_cursor_isolates_each_launch(self) -> None:
        candidate_body = self.batch_body(
            [
                {
                    "event": "elu_sdk_upgrade_candidate",
                    "distinct_id": "opaque-identity",
                    "properties": {"$session_id": "candidate-session"},
                }
            ]
        )
        with tempfile.TemporaryDirectory() as temporary:
            ledger = RUNNER.CaptureLedger(pathlib.Path(temporary))
            prior_request = ledger.begin_request("POST", "/batch")
            cursor = ledger.observation_cursor()
            ledger.record(
                "POST",
                "/batch",
                {},
                candidate_body,
                request_number=prior_request,
            )
            self.assertFalse(ledger.wait_for("candidate", timeout=0, after_request=cursor))
            self.assertEqual(
                ledger.marker_blocker_code("candidate", after_request=cursor),
                "CANDIDATE_EXACT_BATCH_NOT_OBSERVED",
            )
            with self.assertRaises(RUNNER.HarnessBlocked) as blocked:
                ledger.raise_marker_timeout("candidate", after_request=cursor)
            self.assertEqual(blocked.exception.code, "CANDIDATE_EXACT_BATCH_NOT_OBSERVED")

            ledger.record("POST", "/batch", {}, self.marker_body())
            self.assertEqual(
                ledger.marker_blocker_code("candidate", after_request=cursor),
                "CANDIDATE_MARKER_EVENT_ABSENT",
            )

    def test_out_of_order_completion_keeps_the_newest_marker(self) -> None:
        def candidate_body(identity: str, session: str) -> bytes:
            return self.batch_body(
                [
                    {
                        "event": "elu_sdk_upgrade_candidate",
                        "distinct_id": identity,
                        "properties": {"$session_id": session},
                    }
                ]
            )

        with tempfile.TemporaryDirectory() as temporary:
            ledger = RUNNER.CaptureLedger(pathlib.Path(temporary))
            stale_request = ledger.begin_request("POST", "/batch")
            cursor = ledger.observation_cursor()
            current_request = ledger.begin_request("POST", "/batch")
            ledger.record(
                "POST",
                "/batch",
                {},
                candidate_body("current-identity", "current-session"),
                request_number=current_request,
            )
            ledger.record(
                "POST",
                "/batch",
                {},
                candidate_body("stale-identity", "stale-session"),
                request_number=stale_request,
            )
            self.assertEqual(ledger.marker_request_numbers["candidate"], current_request)
            self.assertEqual(
                ledger.markers["candidate"],
                ("current-identity", "current-session"),
            )
            self.assertTrue(
                ledger.wait_for("candidate", timeout=0, after_request=cursor)
            )

    def test_started_exact_batch_is_unreadable_until_body_is_recorded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            ledger = RUNNER.CaptureLedger(pathlib.Path(temporary))
            cursor = ledger.observation_cursor()
            request_number = ledger.begin_request("POST", "/batch")
            self.assertEqual(
                ledger.marker_blocker_code("source", after_request=cursor),
                "SOURCE_BATCH_UNREADABLE",
            )

            ledger.record(
                "POST",
                "/batch",
                {},
                self.marker_body(),
                request_number=request_number,
            )
            self.assertIsNone(
                ledger.marker_blocker_code("source", after_request=cursor)
            )

    def test_handler_requires_bounded_complete_content_length(self) -> None:
        def read_body(headers: object, body: bytes) -> tuple[bytes, bool, bool]:
            handler = object.__new__(RUNNER.EvidenceHandler)
            handler.headers = headers
            handler.rfile = io.BytesIO(body)
            handler.close_connection = False
            captured, readable = handler._read_post_body()
            return captured, readable, handler.close_connection

        self.assertEqual(
            read_body({"content-length": "4"}, b"body"),
            (b"body", True, False),
        )
        for headers, body, expected_body in (
            ({}, b"body", b""),
            ({"Content-Length": "invalid"}, b"body", b""),
            ({"Content-Length": "-1"}, b"body", b""),
            ({"Content-Length": "9" * 5000}, b"body", b""),
            ({"Content-Length": "5"}, b"body", b"body"),
            ({"Content-Length": str(RUNNER.MAX_CAPTURE_BODY_BYTES + 1)}, b"body", b""),
            ({"Transfer-Encoding": "chunked"}, b"4\r\nbody\r\n0\r\n\r\n", b""),
            (
                {"Content-Length": "4", "Transfer-Encoding": "chunked"},
                b"body",
                b"",
            ),
        ):
            with self.subTest(headers=headers):
                captured, readable, closes = read_body(headers, body)
                self.assertEqual(captured, expected_body)
                self.assertFalse(readable)
                self.assertTrue(closes)

    def test_handler_rejects_duplicate_content_encoding_before_header_collapse(self) -> None:
        body = gzip.compress(self.marker_body())
        headers = Message()
        headers.add_header("Content-Length", str(len(body)))
        headers.add_header("Content-Encoding", "br")
        headers.add_header("Content-Encoding", "gzip")
        with tempfile.TemporaryDirectory() as temporary:
            ledger = RUNNER.CaptureLedger(pathlib.Path(temporary))
            cursor = ledger.observation_cursor()
            handler = object.__new__(RUNNER.EvidenceHandler)
            handler.command = "POST"
            handler.path = "/batch"
            handler.headers = headers
            handler.rfile = io.BytesIO(body)
            handler.close_connection = False
            handler.server = types.SimpleNamespace(ledger=ledger)
            handler._respond = lambda _value, status=200: None
            handler.do_POST()
            self.assertEqual(ledger.markers, {})
            self.assertEqual(
                ledger.marker_blocker_code("source", after_request=cursor),
                "SOURCE_BATCH_UNREADABLE",
            )

    def test_gzip_decode_is_streamed_and_bounded(self) -> None:
        payload = self.marker_body()
        self.assertEqual(RUNNER.decompress_gzip_bounded(gzip.compress(payload)), payload)
        self.assertIsNone(
            RUNNER.decompress_gzip_bounded(
                gzip.compress(b"x" * 65),
                max_output_bytes=64,
            )
        )
        self.assertIsNone(
            RUNNER.decompress_gzip_bounded(gzip.compress(payload)[:-1])
        )
        self.assertIsNone(
            RUNNER.decompress_gzip_bounded(
                gzip.compress(payload) + gzip.compress(b"trailing-member")
            )
        )

    def test_marker_diagnostics_are_fixed_and_raw_formats_do_not_change(self) -> None:
        raw_identity = "PRIVATE_IDENTITY_SENTINEL"
        raw_session = "PRIVATE_SESSION_SENTINEL"
        with tempfile.TemporaryDirectory() as temporary:
            ledger = RUNNER.CaptureLedger(pathlib.Path(temporary))
            cursor = ledger.observation_cursor()
            ledger.record(
                "POST",
                "/batch",
                {},
                self.batch_body(
                    [
                        {
                            "event": "elu_sdk_upgrade_source",
                            "distinct_id": raw_identity,
                            "properties": {"private": raw_session},
                        }
                    ]
                ),
            )
            code = ledger.marker_blocker_code("source", after_request=cursor)
            assert code is not None
            public = json.dumps(
                {"blockers": [{"code": code, "detail": RUNNER.BLOCKER_DETAILS[code]}]}
            )
        self.assertNotIn(raw_identity, public)
        self.assertNotIn(raw_session, public)

        with tempfile.TemporaryDirectory() as temporary:
            raw_directory = pathlib.Path(temporary)
            ledger = RUNNER.CaptureLedger(raw_directory)
            ledger.record("POST", "/batch", {}, self.marker_body())
            request = json.loads(
                (raw_directory / "requests" / "request-0001.json").read_text(
                    encoding="utf-8"
                )
            )
            status = json.loads(
                (raw_directory / "capture-status.json").read_text(encoding="utf-8")
            )
            self.assertEqual(
                set(request),
                {"method", "path", "headers", "bodyBase64"},
            )
            self.assertEqual(
                set(status),
                {
                    "sourceMarkerObserved",
                    "candidateMarkerObserved",
                    "identityPreserved",
                    "sourceSessionPresent",
                    "candidateSessionPresent",
                    "sessionRotated",
                },
            )

    def test_failed_continuity_diagnostic_contains_only_check_names(self) -> None:
        observed = {
            "sameApplicationContainer": True,
            "identityPreserved": False,
            "sourceSessionPresent": True,
            "candidateSessionPresent": True,
            "sessionRotated": False,
        }

        self.assertEqual(
            RUNNER.failed_continuity_checks(observed),
            ("identityPreserved", "sessionRotated"),
        )

    def test_capture_ledger_rejects_marker_at_wrong_method_or_path(self) -> None:
        for method, path in (
            ("GET", "/batch"),
            ("POST", "/not-batch"),
            ("POST", "/batch?forged=1"),
            ("POST", "/batch??"),
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

        empty_query_statuses, empty_query_markers = self.route_post("/batch?")
        self.assertEqual(empty_query_statuses, [200])
        self.assertEqual(
            empty_query_markers,
            {"source": ("opaque-identity", "source-session")},
        )

    def test_config_observation_requires_the_exact_get(self) -> None:
        cases = (
            ("GET", "/v1/upgrade-evidence/config", 1),
            ("POST", "/v1/upgrade-evidence/config", 0),
            ("GET", "/v1/upgrade-evidence/config?forged=1", 0),
            ("GET", "/prefix/v1/upgrade-evidence/config", 0),
        )
        for method, path, expected in cases:
            with self.subTest(method=method, path=path):
                self.assertEqual(self.config_get_count(method, path), expected)

        with tempfile.TemporaryDirectory() as temporary:
            ledger = RUNNER.CaptureLedger(pathlib.Path(temporary))
            ledger.record("GET", RUNNER.CONFIG_PATH, {}, b"")
            before_candidate = ledger.exact_config_get_count()
            ledger.record("GET", f"{RUNNER.CONFIG_PATH}?stale=1", {}, b"")
            self.assertEqual(ledger.exact_config_get_count(), before_candidate)
            ledger.record("GET", RUNNER.CONFIG_PATH, {}, b"")
            self.assertGreater(ledger.exact_config_get_count(), before_candidate)


if __name__ == "__main__":
    unittest.main()
