#!/usr/bin/env python3
"""Validate the byte-pinned v1 feature-flag contract copies."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import sys
from typing import Any, NoReturn


ROOT = pathlib.Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "Conformance" / "V1"
EXPECTED_SHA256 = {
    "schemas/flags-request.schema.json": "aef0ae186355db81806561abb4b1c89885ee5024eb3d99a587531a9c7430a770",
    "schemas/flags-response.schema.json": "723161b3c0f3a448d679faa7a0723cb819cdb162e62ba605fc7935e15df69db2",
    "Fixtures/flags-request.json": "19b4f681c8f2c059d39403a5621c0c60a4b6b4328e2bbe8ae28341724604238a",
    "Fixtures/flags-response.json": "ae943a59d4362cd297e2ea6d7838f5075ad1f949d1401d07d5585db0102326be",
    "TestVectors/feature-flag-activity.json": "dbceaa7bee48caf8bf54b73e494fb3f28460eeaf366bbe26f606b659c62a47c4",
}
EXPECTED_SCENARIO_IDS = {
    "install-and-read-complete-snapshot",
    "empty-snapshot-replaces",
    "context-change-drops-response",
    "older-completion-cannot-overwrite-newer-begin",
    "cache-expiry-retains-config-barrier",
    "config-expiry-is-durable-restriction",
    "newer-revoke-rejects-old-completion",
    "cache-corruption-rotates-only-request-epoch",
    "authority-corruption-is-terminal",
    "future-schema-is-preserved",
}
REQUIRED_VECTOR_RUNNER_TESTS = {
    "testFrozenActivityScenariosExecuteEveryStepAndExpectation",
    "testFrozenActivityScenarioExpectationMutationIsDetected",
}


def fail(message: str) -> NoReturn:
    print(f"v1 flag conformance failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def closed_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def load_pinned(relative: str) -> Any:
    data = (SNAPSHOT / relative).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != EXPECTED_SHA256[relative]:
        fail(f"{relative} digest {digest}, expected {EXPECTED_SHA256[relative]}")
    try:
        return json.loads(data, object_pairs_hook=closed_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{relative} is not strict JSON: {error}")


def exact_keys(value: Any, required: set[str], name: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != required:
        fail(f"{name} must contain exactly {sorted(required)}")
    return value


def main() -> int:
    request_schema = load_pinned("schemas/flags-request.schema.json")
    response_schema = load_pinned("schemas/flags-response.schema.json")
    request = exact_keys(
        load_pinned("Fixtures/flags-request.json"),
        {
            "schemaVersion", "requestId", "contextRevision", "identity",
            "personProperties", "groups", "groupProperties", "versions",
        },
        "request fixture",
    )
    response = exact_keys(
        load_pinned("Fixtures/flags-response.json"),
        {
            "schemaVersion", "requestId", "contextRevision", "identityRevision",
            "flagsRevision", "evaluatedAt", "expiresAt", "flags", "payloads",
        },
        "response fixture",
    )
    vector = load_pinned("TestVectors/feature-flag-activity.json")
    if request_schema.get("additionalProperties") is not False:
        fail("request schema must remain closed")
    if response_schema.get("additionalProperties") is not False:
        fail("response schema must remain closed")
    identity = exact_keys(
        request.get("identity"), {"anonymousId", "userId", "revision"}, "request identity"
    )
    if request.get("schemaVersion") != 1 or response.get("schemaVersion") != 1:
        fail("fixture schemaVersion must be 1")
    if response.get("requestId") != request.get("requestId"):
        fail("response requestId does not echo request")
    if response.get("contextRevision") != request.get("contextRevision"):
        fail("response contextRevision does not echo request")
    if response.get("identityRevision") != identity.get("revision"):
        fail("response identityRevision does not echo request")
    if not isinstance(response.get("flags"), dict) or not isinstance(response.get("payloads"), dict):
        fail("response flags and payloads must be objects")
    if vector.get("schemaVersion") != 1 or vector.get("vectorId") != "elu-feature-flag-activity-v1":
        fail("feature-flag activity vector identity changed")
    oracle = vector.get("requestOracle")
    if not isinstance(oracle, dict) or oracle.get("canonicalSha256") != (
        "sha256:f5de81f5fcfb0ed0eeb3b5ba7f64430a82332bb5077175e5474e42512139f568"
    ):
        fail("feature-flag request oracle changed")
    scenarios = vector.get("scenarios")
    if not isinstance(scenarios, list) or any(not isinstance(item, dict) for item in scenarios):
        fail("feature-flag scenarios must be an array of objects")
    scenario_ids = [item.get("id") for item in scenarios]
    if len(scenario_ids) != len(set(scenario_ids)) or set(scenario_ids) != EXPECTED_SCENARIO_IDS:
        fail("feature-flag scenario IDs are unknown, duplicated, or lack executable iOS coverage")
    invalid_utf8 = vector.get("invalidUtf8Cases")
    if not isinstance(invalid_utf8, list) or {
        item.get("id") for item in invalid_utf8 if isinstance(item, dict)
    } != {"leading-utf8-bom", "invalid-continuation-byte"}:
        fail("invalidUtf8Cases are unknown or incomplete")
    swift_tests = (
        ROOT / "Tests/EluAnalyticsTests/EluV1FlagRuntimeTests.swift"
    ).read_text(encoding="utf-8")
    declared_tests = set(re.findall(r"\bfunc\s+(test\w+)\s*\(", swift_tests))
    missing_tests = REQUIRED_VECTOR_RUNNER_TESTS - declared_tests
    if missing_tests:
        fail(f"executable vector runner tests are missing: {sorted(missing_tests)}")
    print("validated 5 byte-pinned feature-flag contract files and fixture echoes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
