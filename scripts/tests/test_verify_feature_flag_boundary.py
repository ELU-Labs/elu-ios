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
