from __future__ import annotations

import pathlib
import runpy
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE = runpy.run_path(str(ROOT / "Conformance/validate-v2-replay.py"))
SCAN = MODULE["scan_v2_runtime_source"]


class V2RuntimeBoundaryTests(unittest.TestCase):
    def test_current_owned_composition_keeps_exact_guards(self) -> None:
        MODULE["verify_runtime_boundary"]()

    def test_generation_and_endpoint_tokens_are_restricted_to_exact_files(self) -> None:
        for token, allowed in [
            ("replayProtocolGeneration", MODULE["V2_GENERATION_SOURCES"]),
            ("/v2/replay", MODULE["V2_ENDPOINT_SOURCES"]),
        ]:
            for relative in allowed:
                self.assertEqual([], SCAN(relative, token))
            for relative in ["Sources/EluAnalytics/Elu.swift",
                             "Sources/EluAnalytics/Internal/Config/Other.swift",
                             "Sources/EluAnalytics/Internal/Replay/Other.swift"]:
                self.assertTrue(SCAN(relative, token))

    def test_unknown_transport_and_public_config_access_are_rejected(self) -> None:
        for relative in MODULE["V2_GENERATION_SOURCES"] | MODULE["V2_ENDPOINT_SOURCES"]:
            self.assertTrue(SCAN(relative, "elu-http-v2"))
        for relative in MODULE["PUBLIC_FACADE_SOURCES"]:
            for token in ["EluV1ConfigManager", "EluV1ConfigDocument"]:
                self.assertTrue(SCAN(relative, token))


if __name__ == "__main__":
    unittest.main()
