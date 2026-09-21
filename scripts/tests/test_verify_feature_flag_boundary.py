from __future__ import annotations

import importlib.util
import json
import pathlib
import shutil
import tempfile
import unittest
from contextlib import contextmanager
from collections.abc import Iterator


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "verify-feature-flag-boundary.py"
SPEC = importlib.util.spec_from_file_location("verify_feature_flag_boundary", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FeatureFlagBoundaryScannerTests(unittest.TestCase):
    def test_public_composition_defers_until_initial_calls_and_uses_owned_capabilities(self) -> None:
        path = pathlib.Path(MODULE.STANDALONE_FACADE_SOURCE)
        source = (ROOT / path).read_text()
        self.assertEqual([], MODULE.scan_outside_source(path, source))
        for before in ["deferredUntilActivation: true", "await runtime.activateNativeReplayComposition()"]:
            self.assertIn(before, source)
            self.assertTrue(MODULE.scan_outside_source(path, source.replace(before, "removed_initial_gate")))
        for relative in [MODULE.STACK_SOURCE, MODULE.STANDALONE_FACADE_SOURCE]:
            for token in ["readbackProvenTransports", "readbackProvenProtocolGenerations"]:
                self.assertTrue(MODULE.scan_outside_source(pathlib.Path(relative), (ROOT / relative).read_text() + "\n" + token))

    def test_native_capability_selection_is_exact_and_cannot_be_silently_disabled(self) -> None:
        path = pathlib.Path(MODULE.NATIVE_RUNTIME_SOURCE)
        source = (ROOT / path).read_text()
        for before, after in [
            ('codec: "elu-native-wireframe-v1", compression: .gzip', 'codec: "other", compression: .gzip'),
            ('codec: "elu-native-wireframe-v1", compression: .gzip', 'codec: "elu-native-wireframe-v1", compression: .none'),
            ('readbackProvenProtocolGenerations: ["protocol-generation-v1"]', 'readbackProvenProtocolGenerations: []'),
            ('readbackProvenProtocolGenerations: ["protocol-generation-v1"]', 'readbackProvenProtocolGenerations: ["protocol-generation-v1", "other"]'),
        ]:
            self.assertIn(before, source)
            self.assertTrue(MODULE.scan_replay_storage_source(path, source.replace(before, after, 1)))
        path = pathlib.Path(MODULE.STANDALONE_FACADE_SOURCE)
        source = (ROOT / path).read_text()
        before = "capabilities: EluStandaloneRuntime.readbackProvenReplayCapabilities"
        for after in ["capabilities: EluNativeReplayCapabilities()", "capabilities: other"]:
            self.assertTrue(MODULE.scan_outside_source(path, source.replace(before, after, 1)))

    def test_native_composition_exceptions_are_exact(self) -> None:
        for relative in [MODULE.NATIVE_RUNTIME_SOURCE, MODULE.NATIVE_COMPOSITION_SOURCE]:
            path = pathlib.Path(relative)
            self.assertEqual([], MODULE.scan_replay_storage_source(path, (ROOT / path).read_text()))
        for relative in [MODULE.STACK_SOURCE, MODULE.STANDALONE_FACADE_SOURCE, "Sources/EluAnalytics/Elu.swift", "Sources/EluAnalytics/Internal/Replay/Other.swift"]:
            for token in ["EluNativeReplayComposition()", "EluV2ReplayDeliveryCoordinator()", "authority.requiringCurrent {}", "authority.ownsPrepared(value)"]:
                self.assertTrue(MODULE.scan_replay_storage_source(pathlib.Path(relative), token), (relative, token))

    def test_native_composition_cannot_acquire_storage_capture_or_transport_issuers(self) -> None:
        for relative in [MODULE.NATIVE_COMPOSITION_SOURCE, MODULE.NATIVE_RUNTIME_SOURCE]:
            for token in ["EluV2ReplayPreparedRequest", "EluNativeReplayCapturePhysicalUse", "EluNativeReplayCaptureRun", "EluNativeReplayCaptureEnrollment", "queue.appendNativeReplay()", "queue.ensureNativeReplayAuthoritySchema()", "EluUIKitReplayCollector()", "EluNativeReplaySealer()"]:
                self.assertTrue(MODULE.scan_replay_storage_source(pathlib.Path(relative), token), (relative, token))
        self.assertTrue(MODULE.scan_replay_storage_source(pathlib.Path(MODULE.NATIVE_COMPOSITION_SOURCE), "EluV2URLSessionReplayTransport()"))

    def test_native_runtime_keeps_empty_default_and_exact_original_guards(self) -> None:
        path = pathlib.Path(MODULE.NATIVE_RUNTIME_SOURCE)
        source = (ROOT / path).read_text()
        for before in ["capabilities: EluNativeReplayCapabilities = EluNativeReplayCapabilities()", "nativeAuthority.ownsPrepared(prepared)", "prepared.supportedProtocolGeneration != nil", "value?.requiringCurrent", "configurationWitness == source", "readZone() == zone"]:
            self.assertIn(before, source)
            changed = source.replace(before, "removed_original_guard")
            self.assertTrue(MODULE.scan_replay_storage_source(path, changed), before)
        for added in ["EluV2URLSessionReplayTransport()", "EluNativeReplayCaptureOwner()"]:
            self.assertTrue(MODULE.scan_replay_storage_source(path, source + "\n" + added))

    def test_native_composition_cannot_skip_qualification_or_construct_capture_directly(self) -> None:
        path = pathlib.Path(MODULE.NATIVE_COMPOSITION_SOURCE)
        source = (ROOT / path).read_text()
        for before in ["!capabilities.transports.isEmpty", "!capabilities.readbackProvenProtocolGenerations.isEmpty"]:
            self.assertIn(before, source)
            self.assertTrue(MODULE.scan_replay_storage_source(path, source.replace(before, "true")))
        self.assertTrue(MODULE.scan_replay_storage_source(path, source + "\nEluNativeReplayCaptureOwner()"))

    def test_native_composition_cannot_expand_platform_or_provider_access(self) -> None:
        path = pathlib.Path(MODULE.NATIVE_COMPOSITION_SOURCE)
        for token in ["import UIKit", "URLSession", "URLRequest", "import Network", "class Other: EluV2ReplayHTTPTransport {}"]:
            self.assertTrue(MODULE.scan_replay_storage_source(path, token), token)

    def test_native_capture_owner_can_join_values_and_ui_only_in_exact_file(self) -> None:
        path = pathlib.Path(MODULE.NATIVE_CAPTURE_SOURCE)
        text = "import UIKit\nEluNativeReplayCaptureOwner EluNativeReplayCapturePhysicalUse EluUIKitReplayCollector EluNativeReplaySealer EluV2ReplayPreparedRequest"
        self.assertEqual([], MODULE.scan_replay_storage_source(path, text))
        for token in ["URLSession", "URLRequest", "import Network", "EluV2URLSessionReplayTransport()"]:
            self.assertTrue(MODULE.scan_replay_storage_source(path, token), token)

    def test_native_capture_cannot_escape_to_public_stack_or_sibling_paths(self) -> None:
        for path in [MODULE.STACK_SOURCE, "Sources/EluAnalytics/Elu.swift",
                     "Sources/EluAnalytics/Internal/Replay/Other.swift", "Other/EluNativeReplayCaptureOwner.swift"]:
            for token in ["EluNativeReplayCaptureOwner()", "EluNativeReplayCapturePhysicalUse", "EluUIKitReplayCollector()"]:
                self.assertTrue(MODULE.scan_replay_storage_source(pathlib.Path(path), token), (path, token))
        for path in [MODULE.NATIVE_AUTHORITY_SOURCE, "Sources/EluAnalytics/Internal/Runtime/EluSQLiteRuntimeQueue.swift"]:
            self.assertTrue(MODULE.scan_replay_storage_source(pathlib.Path(path), "EluNativeReplayCaptureOwner()"))
            self.assertTrue(MODULE.scan_replay_storage_source(pathlib.Path(path), "EluUIKitReplayCollector()"))

    def test_pure_native_sealer_cannot_consume_capture_ownership(self) -> None:
        for token in ["EluNativeReplayCaptureEnrollment", "EluNativeReplayCapturePhysicalUse", "EluNativeReplayCaptureAdmission"]:
            self.assertTrue(MODULE.scan_replay_storage_source(pathlib.Path(MODULE.NATIVE_SEALER_SOURCE), token))

    def test_native_sealer_can_only_prepare_values(self) -> None:
        exact = pathlib.Path(MODULE.NATIVE_SEALER_SOURCE)
        self.assertEqual([], MODULE.scan_replay_storage_source(exact, "struct EluNativeReplaySealer { let value: EluV2ReplayPreparedRequest }"))
        for token in ["URLSession", "URLRequest", "import UIKit", "import Network",
                      "EluV2ReplayDeliveryCoordinator", "EluV2ReplayStoredChunk", "ensureReplaySchema()", "ensureReplayDeliverySchema()",
                      "let queue: EluSQLiteRuntimeQueue", "queue.appendReplay(value)", "queue.reconcileReplay()",
                      "EluNativeReplayAuthority()", "EluNativeReplayScope()", "let permit: EluNativeReplayPermit",
                      "EluNativeReplaySynchronousGuard {}", "let prepared: EluNativeReplayPreparedAuthority",
                      "let input: EluNativeReplayProjectionInput", "queue.ensureNativeReplayAuthoritySchema()",
                      "queue.nativeReplayProjection()", "queue.installNativeReplayPrivacy()",
                      "queue.beginNativeReplayStartAccounting()", "queue.stopNativeReplayAccounting()",
                      "queue.nativeReplayPermitGuard()", "queue.persistNativeReplayClockDenial()"]:
            self.assertTrue(MODULE.scan_replay_storage_source(exact, token), token)

    def test_native_sealer_cannot_be_constructed_or_referenced_elsewhere(self) -> None:
        for path in [MODULE.STACK_SOURCE, "Sources/EluAnalytics/Elu.swift", "Sources/EluAnalytics/Internal/Replay/Other.swift"]:
            for token in ["EluNativeReplaySealer()", "let value: EluNativeReplaySealer"]:
                self.assertTrue(MODULE.scan_replay_storage_source(pathlib.Path(path), token))

    def test_native_authority_has_only_one_explicit_activation_per_schema(self) -> None:
        for call in ["ensureReplaySchema", "ensureReplayDeliverySchema"]:
            with verification_root() as root:
                path = root / MODULE.NATIVE_AUTHORITY_SOURCE
                path.write_text(path.read_text() + f"\n// duplicate: {call}()\n")
                self.assertTrue(any("schema activation" in error for error in MODULE.verify(root)))

    def test_native_activation_cannot_move_to_lifecycle_or_gain_networking(self) -> None:
        path = pathlib.Path("Sources/EluAnalytics/Internal/Replay/EluNativeReplayLifecycle.swift")
        self.assertTrue(MODULE.scan_replay_storage_source(path, "queue.ensureReplaySchema()"))
        exact = pathlib.Path(MODULE.NATIVE_AUTHORITY_SOURCE)
        for token in ["URLSession", "URLRequest", "import UIKit", "EluV2URLSessionReplayTransport()"]:
            self.assertTrue(MODULE.scan_replay_storage_source(exact, token))

    def test_exact_replay_transport_seam_cannot_expand_to_other_files_or_construction(self) -> None:
        for path in [MODULE.STACK_SOURCE, "Sources/EluAnalytics/Internal/Replay/Other.swift"]:
            self.assertTrue(MODULE.scan_replay_storage_source(pathlib.Path(path), "EluV2URLSessionReplayTransport()"))
        exact = pathlib.Path(MODULE.REPLAY_TRANSPORT_SOURCE)
        self.assertEqual(MODULE.scan_replay_storage_source(exact, "final class EluV2URLSessionReplayTransport: EluV2ReplayHTTPTransport, @unchecked Sendable { let request: URLRequest }"), [])
        for text in ["EluV2URLSessionReplayTransport()", "import UIKit", "import Network", "class Other: EluV2ReplayHTTPTransport {}"]:
            self.assertTrue(MODULE.scan_replay_storage_source(exact, text))

    def test_replay_delivery_schema_cannot_be_activated_by_factory(self) -> None:
        with verification_root() as root:
            path = root / MODULE.STACK_SOURCE
            path.write_text(path.read_text() + "\n// try await queue.ensureReplayDeliverySchema()\n")
            self.assertTrue(any("replay delivery schema activation" in error for error in MODULE.verify(root)))

    def test_replay_delivery_helpers_cannot_gain_networking(self) -> None:
        path = pathlib.Path("Sources/EluAnalytics/Internal/Replay/EluV2ReplayDeliveryCoordinator.swift")
        self.assertTrue(MODULE.scan_replay_storage_source(path, "let session = URLSession.shared"))
        self.assertTrue(MODULE.scan_replay_storage_source(path, "struct Sender: EluV2ReplayHTTPTransport {}"))

    def test_replay_storage_cannot_escape_to_public_factory_or_a_sibling_file(self) -> None:
        for path in ["Sources/EluAnalytics/Elu.swift", MODULE.STACK_SOURCE,
                     "Sources/EluAnalytics/Internal/Replay/Other.swift"]:
            self.assertTrue(MODULE.scan_replay_storage_source(pathlib.Path(path), "EluV2ReplayPreparedRequest(data)"))
            self.assertTrue(MODULE.scan_replay_storage_source(pathlib.Path(path), "runtime.ensureReplaySchema()"))

    def test_exact_replay_storage_files_cannot_construct_network_provider_or_ui(self) -> None:
        path = pathlib.Path("Sources/EluAnalytics/Internal/Replay/EluV2ReplayPreparedRequest.swift")
        self.assertEqual(MODULE.scan_replay_storage_source(path, "struct EluV2ReplayPreparedRequest {}"), [])
        for token in ["URLSession", "URLRequest", "import UIKit"]:
            self.assertTrue(MODULE.scan_replay_storage_source(path, token))

    def test_replay_schema_definition_cannot_gain_an_eager_call(self) -> None:
        with verification_root() as root:
            path = root / "Sources/EluAnalytics/Internal/Runtime/EluSQLiteRuntimeQueue.swift"
            path.write_text(path.read_text() + "\n// eager: ensureReplaySchema()\n")
            self.assertTrue(any("replay schema activation" in error for error in MODULE.verify(root)))

    def test_rejects_platform_network_construction(self) -> None:
        self.assertTrue(MODULE.scan_flag_source("let request = URLRequest(url: value)"))

    def test_rejects_concrete_transport_conformer(self) -> None:
        self.assertTrue(
            MODULE.scan_flag_source("final class Live: EluV1FlagTransport {}")
        )

    def test_rejects_multiline_concrete_transport_conformer(self) -> None:
        self.assertTrue(
            MODULE.scan_flag_source(
                "final class Live:\n    NSObject,\n    EluV1FlagTransport\n{}"
            )
        )

    def test_allows_protocol_only_injected_boundary(self) -> None:
        self.assertEqual(
            MODULE.scan_flag_source("protocol EluV1FlagTransport: Sendable {}"), []
        )

    def test_rejects_client_reference_outside_internal_module(self) -> None:
        errors = MODULE.scan_outside_source(
            pathlib.Path("Sources/EluAnalytics/Elu.swift"),
            "let client: EluV1FlagClient",
        )
        self.assertTrue(errors)

    def test_rejects_transport_reference_outside_internal_module(self) -> None:
        errors = MODULE.scan_outside_source(
            pathlib.Path("Sources/EluAnalytics/Elu.swift"),
            "let transport: any EluV1FlagTransport",
        )
        self.assertTrue(errors)

    def test_exact_transport_source_is_allowed(self) -> None:
        path = pathlib.Path(MODULE.FLAG_TRANSPORT_SOURCE)
        self.assertEqual(MODULE.scan_flag_source((ROOT / path).read_text(), path), [])

    def test_transport_exception_does_not_follow_basename_or_directory(self) -> None:
        text = (ROOT / MODULE.FLAG_TRANSPORT_SOURCE).read_text()
        for path in [
            pathlib.Path("Sources/EluAnalytics/Internal/Flags/Nested/EluV1URLSessionFlagTransport.swift"),
            pathlib.Path("Sources/EluAnalytics/Internal/Flags/AnotherTransport.swift"),
        ]:
            self.assertTrue(MODULE.scan_flag_source(text, path))

    def test_exact_transport_cannot_add_another_conformer_or_weaken_protocol(self) -> None:
        path = pathlib.Path(MODULE.FLAG_TRANSPORT_SOURCE)
        original = (ROOT / path).read_text()
        for text in [
            original + "\nfinal class Extra: EluV1FlagTransport {}\n",
            original + "\nextension Other: EluV1AuthorizedFlagTransport {}\n",
            original.replace("EluV1AuthorizedFlagTransport, @unchecked Sendable", "EluV1FlagTransport, @unchecked Sendable", 1),
        ]:
            self.assertTrue(any("concrete transport" in error for error in MODULE.scan_flag_source(text, path)))

    def test_exact_transport_does_not_allow_other_network_stacks(self) -> None:
        path = pathlib.Path(MODULE.FLAG_TRANSPORT_SOURCE)
        for token in ["import Network", "import CFNetwork", "NWConnection"]:
            self.assertTrue(MODULE.scan_flag_source(token, path))

    def test_authorized_protocol_cannot_bypass_conformer_or_reference_scan(self) -> None:
        self.assertTrue(MODULE.scan_flag_source("actor Extra: EluV1AuthorizedFlagTransport {}"))
        self.assertTrue(MODULE.scan_outside_source(
            pathlib.Path("Sources/EluAnalytics/Other.swift"), "let value: any EluV1AuthorizedFlagTransport"))

    def test_bound_authority_exception_is_exact_and_protocol_only(self) -> None:
        path = pathlib.Path(MODULE.BOUND_AUTHORITY_SOURCE)
        original = (ROOT / path).read_text()
        self.assertEqual(MODULE.scan_outside_source(path, original), [])
        self.assertTrue(MODULE.scan_outside_source(path.with_name("OtherAuthority.swift"), original))
        for added in ["let session = URLSession.shared", "let client: EluV1FlagClient", "final class Extra: EluV1AuthorizedFlagTransport {}", "let concrete = EluV1URLSessionFlagTransport(siteKey: key)"]:
            self.assertTrue(MODULE.scan_outside_source(path, original + "\n" + added))

    def test_existing_callers_cannot_construct_or_define_concrete_transport(self) -> None:
        for caller in MODULE.FLAG_CLIENT_CALLERS:
            self.assertTrue(MODULE.scan_outside_source(pathlib.Path(caller), "let transport = EluV1URLSessionFlagTransport(siteKey: key)"))
            self.assertTrue(MODULE.scan_outside_source(pathlib.Path(caller), "final class Extra: EluV1AuthorizedFlagTransport {}"))

    def test_mutated_tree_cannot_copy_transport_or_add_concrete_activation(self) -> None:
        with verification_root() as root:
            source = root / MODULE.FLAG_TRANSPORT_SOURCE
            duplicate = source.parent / "Nested" / source.name
            duplicate.parent.mkdir()
            duplicate.write_text(source.read_text())
            self.assertTrue(any("forbidden network" in error for error in MODULE.verify(root)))
        with verification_root() as root:
            runtime = root / "Sources/EluAnalytics/Internal/Runtime/EluStandaloneRuntime.swift"
            runtime.write_text(runtime.read_text() + "\nlet accidental = EluV1URLSessionFlagTransport(siteKey: key)\n")
            self.assertTrue(any("owned concrete" in error for error in MODULE.verify(root)))

    def test_stack_exception_is_exact_and_keeps_platform_networking_in_transports(self) -> None:
        path = pathlib.Path(MODULE.STACK_SOURCE)
        original = (ROOT / path).read_text()
        self.assertEqual(MODULE.scan_outside_source(path, original), [])
        self.assertTrue(MODULE.scan_outside_source(path.with_name("OtherStack.swift"), original))
        for added in ["let session = URLSession.shared", "let request: URLRequest", "import Network", "import CFNetwork", "let connection: NWConnection"]:
            self.assertTrue(MODULE.scan_outside_source(path, original + "\n" + added))

    def test_stack_cannot_add_construction_change_credential_or_bypass_owner_activation(self) -> None:
        path = pathlib.Path(MODULE.STACK_SOURCE)
        original = (ROOT / path).read_text()
        for text in [
            original + "\nlet another = EluV1URLSessionFlagTransport(siteKey: siteKey)",
            original.replace("EluV1URLSessionFlagTransport(siteKey: siteKey)", "EluV1URLSessionFlagTransport(siteKey: otherKey)"),
            original + "\nlet client = EluV1FlagClient.make(runtime: queue, transport: transport, versions: versions)",
            original + "\nfinal class Extra: EluV1AuthorizedFlagTransport {}",
        ]:
            self.assertTrue(MODULE.scan_outside_source(path, text))

    def test_copied_stack_and_stack_migration_activation_fail_full_verifier(self) -> None:
        with verification_root() as root:
            source = root / MODULE.STACK_SOURCE
            source.with_name("OtherStack.swift").write_text(source.read_text())
            self.assertTrue(MODULE.verify(root))
        with verification_root() as root:
            source = root / MODULE.STACK_SOURCE
            source.write_text(source.read_text() + "\ntry await queue.ensureFlagSchema()\n")
            self.assertTrue(any("lazy flag migration" in error for error in MODULE.verify(root)))

    def test_standalone_bootstrap_preserves_exact_host_and_guarded_callback(self) -> None:
        path = pathlib.Path(MODULE.STANDALONE_FACADE_SOURCE)
        source = (ROOT / path).read_text()
        self.assertEqual(MODULE.scan_outside_source(path, source), [])
        for mutation in [
            source.replace("configHost: context.configHost", "configHost: otherHost", 1),
            source.replace("performance: context.performance", "performance: otherPerformance", 1),
            source.replace("guardedFlagsDidLoad: context.guardedFlagsDidLoad", "guardedFlagsDidLoad: unchecked", 1),
            source.replace("try await EluStandaloneStack.make(", "try await EluStandaloneRuntime.make(", 1),
        ]:
            self.assertTrue(any("bootstrap host/callback" in error for error in MODULE.scan_outside_source(path, mutation)))

    def test_bootstrap_core_and_context_remain_pinned(self) -> None:
        for relative in ["Sources/EluAnalytics/EluState.swift", "Sources/EluAnalytics/Internal/Facade/EluRuntimeBackend.swift"]:
            with verification_root() as root:
                source = root / relative
                source.write_text(source.read_text() + "\n// changed bootstrap boundary\n")
                self.assertTrue(any(relative + " digest" in error for error in MODULE.verify(root)))

    def test_default_selection_and_public_selection_remain_denied(self) -> None:
        with verification_root() as root:
            facade = root / "Sources/EluAnalytics/Elu.swift"
            facade.write_text(facade.read_text().replace(MODULE.DEFAULT_SELECTION, "    public var runtimeSelection: EluRuntimeSelection = .standalone\n"))
            errors = MODULE.verify(root)
            self.assertIn("the default runtime selection is no longer standalone", errors)
            self.assertIn("the runtime selection escaped into the public API", errors)

    def test_provider_free_target_rejects_nested_provider_source(self) -> None:
        for token in ["import phlibwebp", "import PHPLCrashReporter", "final class EluProviderRuntime {}"]:
            with verification_root() as root:
                path = root / "Sources/EluAnalytics/Internal/Other/Nested.swift"
                path.parent.mkdir(parents=True)
                path.write_text(token)
                self.assertTrue(any("removed provider source dependency" in error for error in MODULE.verify(root)), token)

    def test_provider_free_package_rejects_source_and_binary_dependencies(self) -> None:
        for token in [".package(url: \"https://example.test/vendor\", exact: \"1.0.0\")", ".binaryTarget(name: \"Vendor\", path: \"Vendor.xcframework\")"]:
            with verification_root() as root:
                path = root / "Package.swift"
                path.write_text(path.read_text() + "\n" + token)
                self.assertIn("standalone package adds an external source or binary dependency", MODULE.verify(root))

    def test_retired_preview_import_surfaces_cannot_return(self) -> None:
        for token in MODULE.RETIRED_STARTUP_SYMBOLS:
            with verification_root() as root:
                path = root / "Sources/EluAnalytics/Internal/Other/PreviewImport.swift"
                path.parent.mkdir(parents=True)
                path.write_text("struct " + token + " {}")
                self.assertTrue(any("retired preview import" in error for error in MODULE.verify(root)))

    def test_verifier_recursively_scans_nested_flag_sources(self) -> None:
        with verification_root() as root:
            path = (
                root
                / "Sources/EluAnalytics/Internal/Flags/Live/LiveFlagTransport.swift"
            )
            path.parent.mkdir(parents=True)
            path.write_text("final class Live: EluV1FlagTransport {}")
            self.assertTrue(
                any("concrete transport" in error for error in MODULE.verify(root))
            )

    def test_verifier_baseline_is_clean(self) -> None:
        with verification_root() as root:
            self.assertEqual(MODULE.verify(root), [])

    def test_rejects_facade_pin_mutation(self) -> None:
        with verification_root() as root:
            path = root / "Sources/EluAnalytics/Elu.swift"
            path.write_text(path.read_text() + "\n// accidental flag wiring\n")
            self.assertTrue(
                any("Elu.swift digest" in error for error in MODULE.verify(root))
            )

    def test_rejects_package_pin_mutation(self) -> None:
        with verification_root() as root:
            path = root / "Package.swift"
            path.write_text(path.read_text() + "\n// accidental product change\n")
            self.assertTrue(
                any("Package.swift digest" in error for error in MODULE.verify(root))
            )

    def test_rejects_manifest_status_mutation(self) -> None:
        with verification_root() as root:
            path = root / "Conformance/V1/manifest.json"
            manifest = json.loads(path.read_text())
            manifest["transport"]["status"] = "wired"
            path.write_text(json.dumps(manifest))
            self.assertIn(
                "v1 transport status is no longer specified-not-wired",
                MODULE.verify(root),
            )

    def test_rejects_manifest_runtime_behavior_mutation(self) -> None:
        with verification_root() as root:
            path = root / "Conformance/V1/manifest.json"
            manifest = json.loads(path.read_text())
            manifest["transport"]["runtimeBehavior"] = "changed"
            path.write_text(json.dumps(manifest))
            self.assertIn(
                "v1 transport runtimeBehavior is no longer unchanged",
                MODULE.verify(root),
            )

    def test_rejects_extra_runtime_migration_call(self) -> None:
        with verification_root() as root:
            path = root / "Sources/EluAnalytics/Internal/Runtime/EluSQLiteRuntimeQueue.swift"
            path.write_text(path.read_text() + "\n// eager: ensureFlagSchema()\n")
            self.assertTrue(
                any("migration occurrences" in error for error in MODULE.verify(root))
            )

    def test_rejects_migration_call_moved_out_of_explicit_activation(self) -> None:
        with verification_root() as root:
            path = root / "Sources/EluAnalytics/Internal/Flags/EluV1FlagClient.swift"
            text = path.read_text()
            text = text.replace(
                "        try await runtime.ensureFlagSchema()\n",
                "        // migration moved elsewhere\n",
                1,
            )
            text += "\n// misplaced call: runtime.ensureFlagSchema()\n"
            path.write_text(text)
            errors = MODULE.verify(root)
            self.assertTrue(any("explicit flag-client activation" in error for error in errors))


@contextmanager
def verification_root() -> Iterator[pathlib.Path]:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        shutil.copytree(
            ROOT / "Sources/EluAnalytics",
            root / "Sources/EluAnalytics",
        )
        (root / "Conformance/V1").mkdir(parents=True)
        shutil.copy2(
            ROOT / "Conformance/V1/manifest.json",
            root / "Conformance/V1/manifest.json",
        )
        shutil.copy2(ROOT / "Package.swift", root / "Package.swift")
        yield root


if __name__ == "__main__":
    unittest.main()
