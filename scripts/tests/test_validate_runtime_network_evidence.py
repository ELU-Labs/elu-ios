from __future__ import annotations

import pathlib
import runpy
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
VALIDATE = runpy.run_path(str(ROOT / "scripts/validate-runtime-network-evidence.py"))["validate"]


def trace() -> dict:
    return {"schemaVersion": 1, "evidenceKind": "ios-runtime-network-capture", "runtimeEvidence": True,
        "scenarios": ["config", "capture", "flags", "replay", "reset"],
        "requests": [
            {"scenario": "config", "method": "GET", "url": "https://elu.dev/api/sdk/v2/config"},
            {"scenario": "capture", "method": "POST", "url": "https://ingest.elu.dev/v1/batch"},
            {"scenario": "flags", "method": "POST", "url": "https://ingest.elu.dev/v1/flags"},
            {"scenario": "replay", "method": "POST", "url": "https://ingest.elu.dev/v2/replay", "requestBody": {
                "schemaVersion": 2, "chunk": {"schemaVersion": 2, "codec": "elu-native-wireframe-v1",
                    "compression": "gzip", "payload": "fixture-payload"}}},
        ]}


class RuntimeNetworkEvidenceTests(unittest.TestCase):
    def test_generated_native_trace_is_complete_without_reset_request(self) -> None:
        self.assertEqual([], VALIDATE(trace()))

    def test_declaring_a_scenario_without_observing_it_is_rejected(self) -> None:
        for scenario in ("config", "capture", "flags", "replay"):
            candidate = trace()
            candidate["requests"] = [r for r in candidate["requests"] if r["scenario"] != scenario]
            self.assertTrue(any(f"observed {scenario}" in error for error in VALIDATE(candidate)))

    def test_static_smoke_or_wrong_method_cannot_qualify(self) -> None:
        for field, value in [("runtimeEvidence", False), ("evidenceKind", "parser-smoke")]:
            candidate = trace(); candidate[field] = value
            self.assertTrue(VALIDATE(candidate))
        for index in range(4):
            candidate = trace(); candidate["requests"][index]["method"] = "HEAD"
            self.assertTrue(VALIDATE(candidate))

    def test_native_replay_requires_exact_endpoint_and_wire_format(self) -> None:
        for url in ("https://ingest.elu.dev/v1/replay", "https://other.elu.dev/v2/replay", "https://ingest.elu.dev:444/v2/replay", "https://ingest.elu.dev:bad/v2/replay", "https://ingest.elu.dev/v2/replay?site_key=fixture"):
            candidate = trace(); candidate["requests"][3]["url"] = url
            self.assertTrue(VALIDATE(candidate), url)
        for field, value in [("schemaVersion", 1), ("codec", "browser-dom-v1"), ("compression", "none"), ("payload", "")]:
            candidate = trace(); candidate["requests"][3]["requestBody"]["chunk"][field] = value
            self.assertTrue(VALIDATE(candidate), field)
        candidate = trace(); del candidate["requests"][3]["requestBody"]
        self.assertTrue(VALIDATE(candidate))

    def test_malformed_trace_is_rejected(self) -> None:
        for candidate in (None, [], {}, {"requests": None}):
            self.assertTrue(VALIDATE(candidate))
        candidate = trace(); candidate["requests"] = [None, {"scenario": []}]
        self.assertTrue(VALIDATE(candidate))


if __name__ == "__main__":
    unittest.main()
