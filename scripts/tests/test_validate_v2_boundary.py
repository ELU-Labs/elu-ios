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

    def test_native_privacy_projector_reads_generation_without_endpoint_authority(self) -> None:
        relative = "Sources/EluAnalytics/Internal/Runtime/EluPrivacyStateProjector.swift"
        self.assertEqual([], SCAN(relative, (ROOT / relative).read_text()))
        self.assertTrue(SCAN(relative, '"/v2/replay"'))
        self.assertTrue(SCAN(relative, '"elu-http-v2"'))
        for sibling in ["EluStandaloneRuntime.swift", "Other.swift"]:
            self.assertTrue(SCAN("Sources/EluAnalytics/Internal/Runtime/" + sibling,
                                 "replayProtocolGeneration"))

    def test_local_policy_and_both_replay_projections_are_required(self) -> None:
        sources = {relative: (ROOT / relative).read_text()
                   for relative in MODULE["V2_ENDPOINT_PROJECTION"]}
        check = MODULE["v2_endpoint_projection_errors"]
        self.assertEqual([], check(sources))
        for relative, requirements in MODULE["V2_ENDPOINT_PROJECTION"].items():
            with self.subTest(missing_source=relative):
                self.assertTrue(check({key: value for key, value in sources.items() if key != relative}))
            for required in requirements:
                with self.subTest(source=relative, removed_guard=required):
                    changed = dict(sources)
                    changed[relative] = changed[relative].replace(required, "removed_projection", 1)
                    self.assertTrue(check(changed))

    def test_cloud_substitution_and_wrong_replay_role_are_rejected(self) -> None:
        sources = {relative: (ROOT / relative).read_text()
                   for relative in MODULE["V2_ENDPOINT_PROJECTION"]}
        mutations = [
            ("Sources/EluAnalytics/Internal/Config/EluV1ConfigManager.swift",
             "endpointPolicy.endpoint(value, role: role, schemaVersion: schemaVersion)",
             "EluEndpointPolicy.cloud.endpoint(value, role: role, schemaVersion: schemaVersion)"),
            ("Sources/EluAnalytics/Internal/Replay/EluV2URLSessionReplayTransport.swift",
             "endpointPolicy.endpoint(request.url.absoluteString, role: .replay)",
             "endpointPolicy.endpoint(request.url.absoluteString, role: .events)"),
            ("Sources/EluAnalytics/Internal/Config/EluEndpointPolicy.swift",
             'schemaVersion == 2 ? "/v2/replay" : "/v1/replay"', '"/v1/replay"'),
            ("Sources/EluAnalytics/Internal/Config/EluEndpointPolicy.swift",
             "parts.percentEncodedPath == prefix + path", "parts.percentEncodedPath == path"),
            ("Sources/EluAnalytics/Internal/Config/EluEndpointPolicy.swift",
             "let prefix = declaredAPIOrigin.flatMap", "let prefix = EluEndpointPolicy.cloud.declaredAPIOrigin.flatMap"),
        ]
        for relative, before, after in mutations:
            with self.subTest(source=relative, replacement=after):
                self.assertIn(before, sources[relative])
                changed = dict(sources)
                changed[relative] = changed[relative].replace(before, after, 1)
                self.assertTrue(MODULE["v2_endpoint_projection_errors"](changed))

    def test_manager_and_transport_cannot_reintroduce_independent_role_paths(self) -> None:
        for relative in ["Sources/EluAnalytics/Internal/Config/EluV1ConfigManager.swift",
                         "Sources/EluAnalytics/Internal/Replay/EluV2URLSessionReplayTransport.swift"]:
            self.assertTrue(SCAN(relative, '"/v2/replay"'))


if __name__ == "__main__":
    unittest.main()
