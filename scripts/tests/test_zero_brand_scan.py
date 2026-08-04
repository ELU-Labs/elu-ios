#!/usr/bin/env python3

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCANNER = ROOT / "scripts" / "zero-brand-scan.py"
NOTICE = ROOT / "legal" / "THIRD_PARTY_NOTICES.md"
NETWORK_SCHEMA = ROOT / "release" / "network-trace.schema.json"
REQUIRED_NETWORK_SCENARIOS = (
    "config",
    "capture",
    "identify",
    "reset",
    "flags",
    "replay",
    "background",
    "foreground",
    "offline-recovery",
)


def forbidden_identifier() -> str:
    marker = "Forbidden-Identifier:"
    for line in NOTICE.read_text(encoding="utf-8").splitlines():
        if line.startswith(marker):
            return line.removeprefix(marker).strip()
    raise AssertionError("identifier marker missing")


def run_scanner(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCANNER), "--skip-source", *arguments],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def network_trace() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "scenarios": list(REQUIRED_NETWORK_SCENARIOS),
        "requests": [
            {
                "scenario": scenario,
                "url": f"https://ingest.elu.dev/v1/{scenario}",
            }
            for scenario in REQUIRED_NETWORK_SCENARIOS
            if scenario != "reset"
        ],
    }


class ZeroBrandScanTests(unittest.TestCase):
    def test_network_schema_declares_the_validator_scenarios_once(self) -> None:
        schema = json.loads(NETWORK_SCHEMA.read_text(encoding="utf-8"))
        scenarios = schema["properties"]["scenarios"]

        self.assertEqual(set(scenarios["items"]["enum"]), set(REQUIRED_NETWORK_SCENARIOS))
        self.assertEqual(scenarios["minItems"], len(REQUIRED_NETWORK_SCENARIOS))
        self.assertEqual(scenarios["maxItems"], len(REQUIRED_NETWORK_SCENARIOS))
        self.assertTrue(scenarios["uniqueItems"])

    def test_strict_allows_only_named_legal_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "LICENSE").write_text(forbidden_identifier(), encoding="utf-8")
            (root / "Module.swiftinterface").write_text("public enum Elu {}", encoding="utf-8")

            result = run_scanner("--mode", "strict", "--input", str(root))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_legal_filename_does_not_allow_forbidden_parent_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            nested = root / forbidden_identifier()
            nested.mkdir()
            (nested / "LICENSE").write_text(forbidden_identifier(), encoding="utf-8")

            result = run_scanner("--mode", "strict", "--input", str(root))

        self.assertNotEqual(result.returncode, 0)

    def test_strict_rejects_interface_and_archive_contents(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "Module.swiftinterface").write_text(forbidden_identifier(), encoding="utf-8")
            archive_path = root / "symbols.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("Symbols.json", forbidden_identifier())

            result = run_scanner("--mode", "strict", "--input", str(root))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Module.swiftinterface", result.stdout)
        self.assertIn("Symbols.json", result.stdout)

    def test_strict_rejects_forbidden_archive_filename_inside_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            archive_path = root / f"{forbidden_identifier()}-symbols.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("clean.json", "{}")

            result = run_scanner("--mode", "strict", "--input", str(root))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symbols.zip", result.stdout)
        self.assertNotIn(forbidden_identifier().casefold(), result.stdout.casefold())

    def test_legal_named_nested_archive_does_not_bypass_scan(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            inner = root / "inner.zip"
            with zipfile.ZipFile(inner, "w") as archive:
                archive.writestr("Runtime.swift", forbidden_identifier())
            outer = root / "outer.zip"
            with zipfile.ZipFile(outer, "w") as archive:
                archive.writestr("LICENSE", inner.read_bytes())

            result = run_scanner("--mode", "strict", "--input", str(outer))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Runtime.swift", result.stdout)

    def test_network_trace_requires_https_on_owned_domain(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            trace = pathlib.Path(directory) / "network.json"
            trace.write_text(json.dumps(network_trace()), encoding="utf-8")
            clean = run_scanner("--mode", "strict", "--network-trace", str(trace))
            rejected_trace = network_trace()
            rejected_trace["requests"][0]["url"] = "https://analytics.example.test/events"
            trace.write_text(
                json.dumps(rejected_trace),
                encoding="utf-8",
            )
            rejected = run_scanner("--mode", "strict", "--network-trace", str(trace))

        self.assertEqual(clean.returncode, 0, clean.stdout + clean.stderr)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("non-ELU host", rejected.stderr)

    def test_network_trace_cannot_be_empty(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            trace = pathlib.Path(directory) / "network.json"
            trace.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "scenarios": list(REQUIRED_NETWORK_SCENARIOS),
                        "requests": [],
                    }
                ),
                encoding="utf-8",
            )

            result = run_scanner("--mode", "strict", "--network-trace", str(trace))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("at least one observed SDK request", result.stderr)

    def test_network_trace_requires_every_release_scenario(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            trace = pathlib.Path(directory) / "network.json"
            payload = network_trace()
            payload["scenarios"].remove("replay")
            trace.write_text(json.dumps(payload), encoding="utf-8")

            result = run_scanner("--mode", "strict", "--network-trace", str(trace))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing release scenarios: replay", result.stderr)

    def test_network_trace_rejects_unknown_declared_scenario(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            trace = pathlib.Path(directory) / "network.json"
            payload = network_trace()
            payload["scenarios"].append("unexpected")
            trace.write_text(json.dumps(payload), encoding="utf-8")

            result = run_scanner("--mode", "strict", "--network-trace", str(trace))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is unknown", result.stderr)

    def test_network_trace_rejects_duplicate_declared_scenario(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            trace = pathlib.Path(directory) / "network.json"
            payload = network_trace()
            payload["scenarios"].append("config")
            trace.write_text(json.dumps(payload), encoding="utf-8")

            result = run_scanner("--mode", "strict", "--network-trace", str(trace))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicates 'config'", result.stderr)

    def test_network_trace_rejects_unknown_request_scenario(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            trace = pathlib.Path(directory) / "network.json"
            payload = network_trace()
            payload["requests"].append(
                {"scenario": "unexpected", "url": "https://ingest.elu.dev/v1/events"}
            )
            trace.write_text(json.dumps(payload), encoding="utf-8")

            result = run_scanner("--mode", "strict", "--network-trace", str(trace))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown or missing scenario", result.stderr)

    def test_reset_scenario_can_execute_without_a_request(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            trace = pathlib.Path(directory) / "network.json"
            payload = network_trace()
            self.assertNotIn("reset", {request["scenario"] for request in payload["requests"]})
            trace.write_text(json.dumps(payload), encoding="utf-8")

            result = run_scanner("--mode", "strict", "--network-trace", str(trace))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_network_trace_allows_multiple_requests_per_scenario(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            trace = pathlib.Path(directory) / "network.json"
            payload = network_trace()
            payload["requests"].append(
                {"scenario": "replay", "url": "https://ingest.elu.dev/v1/replay/chunk-2"}
            )
            trace.write_text(json.dumps(payload), encoding="utf-8")

            result = run_scanner("--mode", "strict", "--network-trace", str(trace))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
