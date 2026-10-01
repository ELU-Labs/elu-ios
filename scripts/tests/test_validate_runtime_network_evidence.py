from __future__ import annotations

import pathlib
import copy
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

    def test_current_profile_requires_both_observed_config_and_replay_generations(self) -> None:
        value = current_trace()
        self.assertEqual([], VALIDATE(value, profile="current-native"))
        for index in range(6):
            candidate = copy.deepcopy(value)
            candidate["requests"].pop(index)
            self.assertTrue(VALIDATE(candidate, profile="current-native"), index)
        candidate = trace()
        candidate["scenarios"] += ["config-v3", "replay-v3"]
        self.assertTrue(VALIDATE(candidate, profile="current-native"))
        self.assertTrue(VALIDATE(value), "a current trace is not relabelled as legacy wireframe-v1")

    def test_current_profile_preserves_automatic_native_codec_support(self) -> None:
        for codec in ["elu-native-wireframe-v1", "elu-native-wireframe-v2"]:
            value = current_trace(); value["requests"][3]["requestBody"]["chunk"]["codec"] = codec
            self.assertEqual([], VALIDATE(value, profile="current-native"))

    def test_current_profile_refuses_crossed_formats_and_malformed_original_bodies(self) -> None:
        for index, key, replacement in [
            (3, "codec", "elu-native-raster-v1"), (5, "codec", "elu-native-wireframe-v2"),
            (5, "schemaVersion", 2), (3, "schemaVersion", 3), (5, "schemaVersion", 3.0),
            (5, "codec", []), (5, "compression", "none"), (5, "payload", ""),
        ]:
            value = current_trace(); value["requests"][index]["requestBody"]["chunk"][key] = replacement
            self.assertTrue(VALIDATE(value, profile="current-native"), (index, key, replacement))
        for index in [3, 5]:
            value = current_trace(); value["requests"][index]["requestBody"]["schemaVersion"] = 1
            self.assertTrue(VALIDATE(value, profile="current-native"))

    def test_current_profile_uses_exact_default_cloud_routes(self) -> None:
        for index in range(6):
            for mutate in [lambda u: u.replace("https://", "http://"),
                           lambda u: u.replace(".dev/", ".dev:444/"),
                           lambda u: u.replace(".dev/", ".dev/../"),
                           lambda u: u + "?override=1", lambda u: u + "#fragment",
                           lambda u: u.replace("https://", "https://user@"),
                           lambda u: u.replace(".dev/", ".dev/\n"),
                           lambda u: u.replace("elu.dev", "other.example")]:
                value = current_trace(); value["requests"][index]["url"] = mutate(value["requests"][index]["url"])
                self.assertTrue(VALIDATE(value, profile="current-native"), (index, value["requests"][index]["url"]))
            value = current_trace(); value["requests"][index]["method"] = "HEAD"
            self.assertTrue(VALIDATE(value, profile="current-native"))
        for key in ["", "elu_pk_test_short", "elu_pk_test_" + "a" * 65, "{siteKey}"]:
            value = current_trace(); value["requests"][0]["url"] = f"https://elu.dev/sdk/v2/{key}/config"
            self.assertTrue(VALIDATE(value, profile="current-native"))
        self.assertTrue(VALIDATE(current_trace(), profile="caller-selected"))


def current_trace() -> dict:
    # Synthetic protocol-control inputs only, never observed release evidence.
    value = trace()
    value["requests"][0]["url"] = "https://elu.dev/sdk/v2/elu_pk_test_" + "a" * 24 + "/config"
    value["requests"][1]["url"] = "https://ingest.elu.dev/v1/events"
    value["requests"][3]["requestBody"]["chunk"]["codec"] = "elu-native-wireframe-v2"
    config = copy.deepcopy(value["requests"][0]); config["url"] = config["url"].replace("/v2/", "/v3/")
    replay = copy.deepcopy(value["requests"][3]); replay["url"] = replay["url"].replace("/v2/", "/v3/")
    replay["requestBody"]["schemaVersion"] = replay["requestBody"]["chunk"]["schemaVersion"] = 3
    replay["requestBody"]["chunk"]["codec"] = "elu-native-raster-v1"
    value["requests"] += [config, replay]
    return value


if __name__ == "__main__":
    unittest.main()
