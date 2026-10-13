#!/usr/bin/env python3
"""Validate the byte-pinned public v1 config/privacy contract without dependencies."""

from __future__ import annotations

import hashlib
import json
import math
import pathlib
import re
import sys
from typing import Any
from urllib.parse import urlsplit


ROOT = pathlib.Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "Conformance" / "V1"
FIXTURES = SNAPSHOT / "Fixtures"
SCHEMAS = SNAPSHOT / "schemas"
EXPECTED_SHA256 = {
    "manifest.json": "98152d8725c286f29402ba3e420bda8dd364200fb6fdf1cfe49b2da9b8f63e54",
    "schemas/config.schema.json": "4cd1e8fce0298048ec60ded16f9a215d10dc1022477f059e01db0349ec478307",
    "schemas/privacy-policy.schema.json": "73beb1856358f5e3cc45b225fdf0608294124e6d6f7c13e2ec3db1c285db6fc4",
    "schemas/privacy.schema.json": "830726002dce98eafce30981067ea892afe12db2b985296514a8da3597776b14",
    "Fixtures/config-enabled.json": "91be45589959f53c73a78f916f5e722b77a853fa0a6b952601400bf107b591e5",
    "Fixtures/config-disabled.json": "c60d32c9701ea726cac342a8c06b89d9a6bd0cf6cea3441bcdd37c2de9055270",
    "Fixtures/privacy-allowed.json": "a0fa41fbb06f263510b35c8d27863e8c69ecc52c940eac8fa23bdd4411c68f40",
    "Fixtures/privacy-blocked.json": "503a2d118737bff7206f05c3cb83f4098579a5c92e7f49670b80e86df2e1e24d",
}
SUPPORTED_KEYWORDS = {
    "$schema",
    "$id",
    "$ref",
    "title",
    "type",
    "additionalProperties",
    "required",
    "properties",
    "const",
    "enum",
    "minimum",
    "maximum",
    "minLength",
    "maxLength",
    "pattern",
    "format",
    "minItems",
    "maxItems",
    "uniqueItems",
    "items",
    "allOf",
    "anyOf",
    "not",
    "if",
    "then",
    "else",
}
RFC3339 = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})"
    r"(?:\.\d+)?(?:[Zz]|([+-])(\d{2}):(\d{2}))$"
)


def fail(message: str) -> None:
    print(f"v1 config conformance failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def stable_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def load_pinned(relative: str) -> Any:
    path = SNAPSHOT / relative
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    expected = EXPECTED_SHA256[relative]
    if actual != expected:
        fail(f"{relative} digest {actual}, expected {expected}")
    try:
        return json.loads(data)
    except json.JSONDecodeError as error:
        fail(f"{relative} is not valid JSON: {error}")


def is_leap_year(year: int) -> bool:
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)


def days_in_month(year: int, month: int) -> int:
    if month == 2:
        return 29 if is_leap_year(year) else 28
    if month in (4, 6, 9, 11):
        return 30
    return 31


def days_from_civil(year: int, month: int, day: int) -> int:
    adjusted_year = year - (1 if month <= 2 else 0)
    era = adjusted_year // 400
    year_of_era = adjusted_year - era * 400
    adjusted_month = month + (-3 if month > 2 else 9)
    day_of_year = (153 * adjusted_month + 2) // 5 + day - 1
    day_of_era = year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year
    return era * 146097 + day_of_era - 719468


def is_rfc3339(value: str) -> bool:
    match = RFC3339.fullmatch(value)
    if not match:
        return False
    year, month, day, hour, minute, second = map(int, match.groups()[:6])
    offset_hour = int(match.group(8) or 0)
    offset_minute = int(match.group(9) or 0)
    if not (
        0 <= year <= 9999
        and 1 <= month <= 12
        and 1 <= day <= days_in_month(year, month)
        and 0 <= hour <= 23
        and 0 <= minute <= 59
        and 0 <= second <= 60
        and 0 <= offset_hour <= 23
        and 0 <= offset_minute <= 59
    ):
        return False
    if second != 60:
        return True

    magnitude = offset_hour * 3600 + offset_minute * 60
    offset = -magnitude if match.group(7) == "-" else magnitude
    local_base = (
        days_from_civil(year, month, day) * 86400
        + hour * 3600
        + minute * 60
        + 59
    )
    boundary = local_base - offset + 1
    if boundary % 86400 != 0:
        return False
    boundary_day = boundary // 86400
    return any(
        boundary_day in (
            days_from_civil(candidate, 1, 1),
            days_from_civil(candidate, 7, 1),
        )
        for candidate in range(year - 1, year + 2)
    )


def is_uri(value: str) -> bool:
    if any(not 0x21 <= ord(character) <= 0x7E for character in value):
        return False
    for index, character in enumerate(value):
        if character == "%" and (
            index + 2 >= len(value)
            or not all(candidate in "0123456789abcdefABCDEF" for candidate in value[index + 1 : index + 3])
        ):
            return False
    try:
        parsed = urlsplit(value)
        return bool(parsed.scheme and parsed.netloc and parsed.hostname)
    except ValueError:
        return False


def matches_type(value: Any, expected: str) -> bool:
    if expected == "null":
        return value is None
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return (
            isinstance(value, (int, float))
            and not isinstance(value, bool)
            and math.isfinite(value)
        )
    raise ValueError(f"unsupported JSON Schema type {expected}")


def assert_supported(schema: Any, path: str = "$") -> None:
    if isinstance(schema, bool):
        return
    if not isinstance(schema, dict):
        fail(f"schema at {path} is not an object or boolean")
    unsupported = set(schema) - SUPPORTED_KEYWORDS
    if unsupported:
        fail(f"unsupported schema keywords at {path}: {sorted(unsupported)}")
    for key, value in (schema.get("properties") or {}).items():
        assert_supported(value, f"{path}/properties/{key}")
    for keyword in ("allOf", "anyOf"):
        for index, value in enumerate(schema.get(keyword) or []):
            assert_supported(value, f"{path}/{keyword}/{index}")
    for keyword in ("items", "not", "if", "then", "else", "additionalProperties"):
        if keyword in schema:
            assert_supported(schema[keyword], f"{path}/{keyword}")


class Validator:
    def __init__(self, schemas: dict[str, dict[str, Any]]) -> None:
        self.schemas = schemas
        for name, schema in schemas.items():
            assert_supported(schema, name)

    def validate(self, value: Any, schema: Any, path: str = "$") -> list[str]:
        errors: list[str] = []
        self._evaluate(value, schema, path, errors)
        return errors

    def _evaluate(self, value: Any, schema: Any, path: str, errors: list[str]) -> None:
        if schema is True:
            return
        if schema is False:
            errors.append(f"{path} is forbidden")
            return

        if "$ref" in schema:
            reference = schema["$ref"]
            target = self.schemas.get(pathlib.PurePosixPath(reference).name)
            if target is None:
                fail(f"unresolved schema reference {reference}")
            self._evaluate(value, target, path, errors)

        expected_types = schema.get("type", [])
        if isinstance(expected_types, str):
            expected_types = [expected_types]
        if expected_types and not any(matches_type(value, candidate) for candidate in expected_types):
            errors.append(f"{path} must have type {' or '.join(expected_types)}")
            return

        if "const" in schema and stable_json(value) != stable_json(schema["const"]):
            errors.append(f"{path} must equal {stable_json(schema['const'])}")
        if "enum" in schema and all(stable_json(value) != stable_json(item) for item in schema["enum"]):
            errors.append(f"{path} is not an allowed enum value")

        for child in schema.get("allOf", []):
            self._evaluate(value, child, path, errors)
        if "anyOf" in schema and not any(not self.validate(value, child, path) for child in schema["anyOf"]):
            errors.append(f"{path} must match an anyOf branch")
        if "not" in schema and not self.validate(value, schema["not"], path):
            errors.append(f"{path} matches a forbidden schema")
        if "if" in schema:
            branch = "then" if not self.validate(value, schema["if"], path) else "else"
            if branch in schema:
                self._evaluate(value, schema[branch], path, errors)

        if isinstance(value, dict):
            for required in schema.get("required", []):
                if required not in value:
                    errors.append(f"{path}.{required} is required")
            properties = schema.get("properties", {})
            for key, child in properties.items():
                if key in value:
                    self._evaluate(value[key], child, f"{path}.{key}", errors)
            if schema.get("additionalProperties") is False:
                for key in value.keys() - properties.keys():
                    errors.append(f"{path}.{key} is not allowed")

        if isinstance(value, list):
            if len(value) < schema.get("minItems", 0):
                errors.append(f"{path} has too few items")
            if "maxItems" in schema and len(value) > schema["maxItems"]:
                errors.append(f"{path} has too many items")
            if schema.get("uniqueItems") and len({stable_json(item) for item in value}) != len(value):
                errors.append(f"{path} items must be unique")
            if "items" in schema:
                for index, item in enumerate(value):
                    self._evaluate(item, schema["items"], f"{path}[{index}]", errors)

        if isinstance(value, str):
            if len(value) < schema.get("minLength", 0):
                errors.append(f"{path} is too short")
            if "maxLength" in schema and len(value) > schema["maxLength"]:
                errors.append(f"{path} is too long")
            if "pattern" in schema and re.search(schema["pattern"], value) is None:
                errors.append(f"{path} does not match its pattern")
            if schema.get("format") == "date-time" and not is_rfc3339(value):
                errors.append(f"{path} is not an RFC 3339 date-time")
            if schema.get("format") == "uri" and not is_uri(value):
                errors.append(f"{path} is not an absolute URI")

        if isinstance(value, (int, float)) and not isinstance(value, bool):
            if "minimum" in schema and value < schema["minimum"]:
                errors.append(f"{path} is below its minimum")
            if "maximum" in schema and value > schema["maximum"]:
                errors.append(f"{path} is above its maximum")


def policy_hash(value: dict[str, Any]) -> str:
    without_hash = dict(value)
    without_hash.pop("effectivePolicyHash", None)
    return "sha256:" + hashlib.sha256(stable_json(without_hash).encode("utf-8")).hexdigest()


def main() -> int:
    manifest = load_pinned("manifest.json")
    config_schema = load_pinned("schemas/config.schema.json")
    privacy_policy_schema = load_pinned("schemas/privacy-policy.schema.json")
    privacy_schema = load_pinned("schemas/privacy.schema.json")
    enabled = load_pinned("Fixtures/config-enabled.json")
    disabled = load_pinned("Fixtures/config-disabled.json")
    allowed = load_pinned("Fixtures/privacy-allowed.json")
    blocked = load_pinned("Fixtures/privacy-blocked.json")

    if manifest.get("contractVersion") != "1.0.0" or manifest.get("schemaVersion") != 1:
        fail("manifest must pin semantic contract 1.0.0 / schema v1")
    if manifest.get("transport", {}).get("status") != "specified-not-wired":
        fail("manifest must not claim live transport wiring")
    expected_schema_paths = {
        "config": "schemas/config.schema.json",
        "privacyPolicy": "schemas/privacy-policy.schema.json",
        "privacyState": "schemas/privacy.schema.json",
    }
    for role, expected_path in expected_schema_paths.items():
        if manifest.get("schemas", {}).get(role) != expected_path:
            fail(f"manifest {role} schema path drifted")

    validator = Validator(
        {
            "config.schema.json": config_schema,
            "privacy-policy.schema.json": privacy_policy_schema,
            "privacy.schema.json": privacy_schema,
        }
    )
    for name, value, schema in (
        ("config-enabled.json", enabled, config_schema),
        ("config-disabled.json", disabled, config_schema),
        ("privacy-allowed.json", allowed, privacy_schema),
        ("privacy-blocked.json", blocked, privacy_schema),
    ):
        errors = validator.validate(value, schema)
        if errors:
            fail(f"{name} failed its pinned JSON Schema: {'; '.join(errors)}")

    expected_endpoints = {
        "events": "https://ingest.elu.dev/v1/events",
        "replay": "https://ingest.elu.dev/v1/replay",
        "flags": "https://ingest.elu.dev/v1/flags",
        "assets": "https://assets.elu.dev/sdk/",
    }
    if enabled.get("endpoints") != expected_endpoints:
        fail("enabled fixture endpoint roles drifted")
    if "site" in disabled or "endpoints" in disabled:
        fail("disabled fixture must expose no tenant or routes")
    for name, state in (("privacy-allowed.json", allowed), ("privacy-blocked.json", blocked)):
        if state.get("effectivePolicyHash") != policy_hash(state):
            fail(f"{name} effectivePolicyHash does not match canonical content")

    print(
        f"validated {len(EXPECTED_SHA256)} pinned v1 manifest/schema/fixture files "
        "and 4 schema-bound fixtures"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
