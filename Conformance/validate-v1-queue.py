#!/usr/bin/env python3
"""Validate byte-pinned v1 event/mutation/version queue contracts."""

from __future__ import annotations

import copy
import contextlib
import hashlib
import io
import json
import math
import pathlib
import re
import sys
from datetime import datetime
from typing import Any, NoReturn


ROOT = pathlib.Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "Conformance" / "V1"
EXPECTED_SHA256 = {
    "schemas/event.schema.json": "4a0deeb19b8406d31aa519bf1d3978294d6d06eb451d4588668cb6f67f4edee9",
    "schemas/mutation.schema.json": "8482af6b66c04701b014acd27e6d59aaef3f27864086c755f9abde498e5c8f5f",
    "schemas/version.schema.json": "3b4ca74e470efbf6610f2a1743f2bc78805882bd294a6984ef2c93fe42fea4ab",
    "Fixtures/event.json": "44ea5d14646ec08aaa1805dffd8ea6403487ba7cb48e8ce7ea7f3752b241809d",
    "Fixtures/mutations.json": "a02a4db1d1ef0bf6b9eac0334fe83c3564526cbd21c79ccfe14aa303ff2ae3d4",
    "Fixtures/version.json": "61bf97e8eeea78df05df13434501a4bc9e81eaa3351fecaff2bdc06da9f1f8e2",
}
RUNTIME_NAME = re.compile(r"^elu-[a-z0-9-]+$")
FACADE_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9._-]+$")
RFC3339 = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})"
    r"(?:\.\d+)?(?:[Zz]|([+-])(\d{2}):(\d{2}))$"
)


class SchemaViolation(ValueError):
    pass


def fail(message: str) -> NoReturn:
    print(f"v1 queue conformance failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def reject_constant(value: str) -> NoReturn:
    fail(f"non-finite JSON number {value}")


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
        return json.loads(
            data,
            object_pairs_hook=closed_object,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{relative} is not strict JSON: {error}")


def schema_violation(path: str, message: str) -> None:
    raise SchemaViolation(f"{path}: {message}")


def resolve_pointer(document: Any, fragment: str, path: str) -> Any:
    if fragment in ("", "#"):
        return document
    if not fragment.startswith("#/"):
        schema_violation(path, f"unsupported reference fragment {fragment!r}")
    value = document
    for encoded in fragment[2:].split("/"):
        token = encoded.replace("~1", "/").replace("~0", "~")
        if not isinstance(value, dict) or token not in value:
            schema_violation(path, f"unresolved reference fragment {fragment!r}")
        value = value[token]
    return value


def resolve_reference(
    reference: str,
    current_name: str,
    schemas: dict[str, Any],
    path: str,
) -> tuple[Any, str]:
    target_name, separator, fragment = reference.partition("#")
    resolved_name = target_name or current_name
    if resolved_name not in schemas:
        schema_violation(path, f"unresolved schema reference {reference!r}")
    target = schemas[resolved_name]
    resolved_fragment = f"#{fragment}" if separator else ""
    return resolve_pointer(target, resolved_fragment, path), resolved_name


def is_schema_type(value: Any, expected: str) -> bool:
    checks = {
        "null": value is None,
        "boolean": isinstance(value, bool),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "string": isinstance(value, str),
        "array": isinstance(value, list),
        "object": isinstance(value, dict),
    }
    return checks.get(expected, False)


def validate_schema_instance(
    value: Any,
    schema: Any,
    current_name: str,
    schemas: dict[str, Any],
    path: str = "$",
) -> None:
    if not isinstance(schema, dict):
        schema_violation(path, "schema node is not an object")
    if "$ref" in schema:
        target, target_name = resolve_reference(
            schema["$ref"], current_name, schemas, path
        )
        validate_schema_instance(value, target, target_name, schemas, path)
        return
    if "oneOf" in schema:
        matches = 0
        for candidate in schema["oneOf"]:
            try:
                validate_schema_instance(value, candidate, current_name, schemas, path)
            except SchemaViolation:
                continue
            matches += 1
        if matches != 1:
            schema_violation(path, f"oneOf matched {matches} branches")
        return

    if "const" in schema and value != schema["const"]:
        schema_violation(path, "value does not match const")
    if "enum" in schema and value not in schema["enum"]:
        schema_violation(path, "value is outside enum")

    declared_type = schema.get("type")
    if declared_type is not None:
        allowed_types = declared_type if isinstance(declared_type, list) else [declared_type]
        if not any(is_schema_type(value, expected) for expected in allowed_types):
            schema_violation(path, f"expected type {allowed_types!r}")

    if isinstance(value, dict):
        required = schema.get("required", [])
        missing = [key for key in required if key not in value]
        if missing:
            schema_violation(path, f"missing required keys {missing!r}")
        properties = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        for key, item in value.items():
            child_path = f"{path}.{key}"
            if key in properties:
                validate_schema_instance(
                    item, properties[key], current_name, schemas, child_path
                )
            elif additional is False:
                schema_violation(child_path, "additional property is forbidden")
            elif isinstance(additional, dict):
                validate_schema_instance(
                    item, additional, current_name, schemas, child_path
                )
        maximum = schema.get("maxProperties")
        if maximum is not None and len(value) > maximum:
            schema_violation(path, "too many properties")

    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            schema_violation(path, "too few items")
        maximum = schema.get("maxItems")
        if maximum is not None and len(value) > maximum:
            schema_violation(path, "too many items")
        if schema.get("uniqueItems"):
            stable = [
                json.dumps(item, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
                for item in value
            ]
            if len(stable) != len(set(stable)):
                schema_violation(path, "array items are not unique")
        if "items" in schema:
            for index, item in enumerate(value):
                validate_schema_instance(
                    item,
                    schema["items"],
                    current_name,
                    schemas,
                    f"{path}[{index}]",
                )

    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            schema_violation(path, "string is too short")
        maximum = schema.get("maxLength")
        if maximum is not None and len(value) > maximum:
            schema_violation(path, "string is too long")
        if "pattern" in schema and re.fullmatch(schema["pattern"], value) is None:
            schema_violation(path, "string does not match pattern")
        if schema.get("format") == "date-time" and RFC3339.fullmatch(value) is None:
            schema_violation(path, "string is not RFC3339 date-time")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if not math.isfinite(value):
            schema_violation(path, "number is not finite")
        if "minimum" in schema and value < schema["minimum"]:
            schema_violation(path, "number is below minimum")
        if "maximum" in schema and value > schema["maximum"]:
            schema_violation(path, "number is above maximum")


def validate_against_schema(
    value: Any,
    schema_name: str,
    schemas: dict[str, Any],
    description: str,
) -> None:
    try:
        validate_schema_instance(value, schemas[schema_name], schema_name, schemas)
    except SchemaViolation as error:
        fail(f"{description} does not satisfy {schema_name}: {error}")


def expect_schema_rejected(
    value: Any,
    schema_name: str,
    schemas: dict[str, Any],
    description: str,
) -> None:
    try:
        validate_schema_instance(value, schemas[schema_name], schema_name, schemas)
    except SchemaViolation:
        return
    fail(f"negative schema probe was accepted: {description}")


def require_keys(value: Any, required: set[str], optional: set[str] = set()) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail("expected an object")
    actual = set(value)
    if actual != required | (actual & optional):
        fail(f"closed object fields {sorted(actual)}, expected {sorted(required)} plus {sorted(optional)}")
    return value


def require_string(value: Any, name: str, minimum: int, maximum: int) -> str:
    if not isinstance(value, str) or not minimum <= len(value) <= maximum:
        fail(f"{name} is not a bounded string")
    return value


def require_integer(value: Any, name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        fail(f"{name} is not a non-negative integer")
    return value


def require_timestamp(value: Any, name: str) -> None:
    text = require_string(value, name, 20, 64)
    if RFC3339.fullmatch(text) is None:
        fail(f"{name} is not an RFC3339 timestamp")
    try:
        datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        fail(f"{name} is not an RFC3339 timestamp")


def validate_json(value: Any, depth: int = 0) -> None:
    if depth > 16:
        fail("JSON fixture nesting is too deep")
    if value is None or isinstance(value, (str, bool, int)):
        return
    if isinstance(value, float):
        if not math.isfinite(value):
            fail("JSON fixture contains a non-finite number")
        return
    if isinstance(value, list):
        for item in value:
            validate_json(item, depth + 1)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            require_string(key, "property key", 1, 256)
            validate_json(item, depth + 1)
        return
    fail("fixture contains a non-JSON value")


def validate_versions(value: Any) -> None:
    value = require_keys(
        value,
        {"schemaVersion", "contractVersion", "platform", "runtime", "facade"},
        {"build"},
    )
    if value["schemaVersion"] != 1 or value["contractVersion"] != "1.0.0":
        fail("version fixture must use schema 1 / contract 1.0.0")
    if value["platform"] not in {"browser", "android", "ios"}:
        fail("version platform is unsupported")
    runtime = require_keys(value["runtime"], {"name", "version"})
    facade = require_keys(value["facade"], {"name", "version"})
    if not RUNTIME_NAME.fullmatch(require_string(runtime["name"], "runtime.name", 1, 128)):
        fail("runtime.name is malformed")
    require_string(runtime["version"], "runtime.version", 1, 64)
    if not FACADE_NAME.fullmatch(require_string(facade["name"], "facade.name", 1, 128)):
        fail("facade.name is malformed")
    require_string(facade["version"], "facade.version", 1, 64)
    if "build" in value:
        require_string(value["build"], "build", 1, 128)


def validate_identity(value: Any, mutation: bool) -> None:
    revision_key = "identityRevision" if mutation else "revision"
    value = require_keys(value, {"anonymousId", "userId", revision_key})
    require_string(value["anonymousId"], "anonymousId", 1, 256)
    if value["userId"] is not None:
        require_string(value["userId"], "userId", 1, 512)
    require_integer(value[revision_key], revision_key)


def validate_properties(value: Any) -> None:
    if not isinstance(value, dict):
        fail("properties must be an object")
    validate_json(value)


def validate_unset(value: Any) -> None:
    if not isinstance(value, list) or len(value) > 256:
        fail("unset must be a bounded array")
    names = [require_string(item, "unset item", 1, 512) for item in value]
    if len(names) != len(set(names)):
        fail("unset entries must be unique")


def validate_change(value: Any) -> str:
    if not isinstance(value, dict) or not isinstance(value.get("type"), str):
        fail("mutation change is malformed")
    change_type = value["type"]
    if change_type == "identify":
        value = require_keys(value, {"type", "userId", "set", "setOnce"})
        require_string(value["userId"], "identify.userId", 1, 512)
        validate_properties(value["set"])
        validate_properties(value["setOnce"])
    elif change_type == "linkAlias":
        value = require_keys(value, {"type", "aliasId", "canonicalId"})
        require_string(value["aliasId"], "aliasId", 1, 512)
        require_string(value["canonicalId"], "canonicalId", 1, 512)
    elif change_type == "setPersonProperties":
        value = require_keys(value, {"type", "set", "setOnce", "unset"})
        validate_properties(value["set"])
        validate_properties(value["setOnce"])
        validate_unset(value["unset"])
    elif change_type == "associateGroup":
        value = require_keys(value, {"type", "groupType", "groupKey"})
        require_string(value["groupType"], "groupType", 1, 256)
        require_string(value["groupKey"], "groupKey", 1, 512)
    elif change_type == "setGroupProperties":
        value = require_keys(
            value,
            {"type", "groupType", "groupKey", "set", "setOnce", "unset"},
        )
        require_string(value["groupType"], "groupType", 1, 256)
        require_string(value["groupKey"], "groupKey", 1, 512)
        validate_properties(value["set"])
        validate_properties(value["setOnce"])
        validate_unset(value["unset"])
    else:
        fail(f"unsupported mutation change {change_type!r}")
    return change_type


def validate_mutation(value: Any) -> tuple[int, str, str]:
    value = require_keys(
        value,
        {"mutationId", "sequence", "contextRevision", "occurredAt", "subject", "change"},
    )
    mutation_id = require_string(value["mutationId"], "mutationId", 1, 256)
    sequence = require_integer(value["sequence"], "sequence")
    require_integer(value["contextRevision"], "contextRevision")
    require_timestamp(value["occurredAt"], "occurredAt")
    validate_identity(value["subject"], mutation=True)
    return sequence, mutation_id, validate_change(value["change"])


def validate_event(value: Any) -> None:
    value = require_keys(
        value,
        {
            "schemaVersion",
            "eventId",
            "streamId",
            "sequence",
            "contextRevision",
            "kind",
            "name",
            "occurredAt",
            "identity",
            "sessionId",
            "properties",
            "groups",
            "versions",
        },
    )
    if value["schemaVersion"] != 1:
        fail("event schemaVersion must be 1")
    require_string(value["eventId"], "eventId", 1, 256)
    require_string(value["streamId"], "streamId", 1, 256)
    require_integer(value["sequence"], "sequence")
    require_integer(value["contextRevision"], "contextRevision")
    if value["kind"] not in {"capture", "screen", "exception", "diagnostic"}:
        fail("event kind is unsupported")
    require_string(value["name"], "name", 1, 512)
    require_timestamp(value["occurredAt"], "occurredAt")
    validate_identity(value["identity"], mutation=False)
    require_string(value["sessionId"], "sessionId", 1, 256)
    validate_properties(value["properties"])
    groups = value["groups"]
    if not isinstance(groups, dict) or len(groups) > 64:
        fail("event groups must be a bounded object")
    for group_type, group_key in groups.items():
        require_string(group_type, "group type", 1, 256)
        require_string(group_key, "group key", 1, 512)
    validate_versions(value["versions"])


def expect_rejected(value: Any, validator: Any, description: str) -> None:
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            validator(value)
        except SystemExit:
            return
    fail(f"negative probe was accepted: {description}")


def main() -> int:
    pinned_schemas = {
        relative: load_pinned(relative)
        for relative in EXPECTED_SHA256
        if relative.startswith("schemas/")
    }
    schemas = {
        pathlib.PurePosixPath(relative).name: schema
        for relative, schema in pinned_schemas.items()
    }
    event = load_pinned("Fixtures/event.json")
    mutations = load_pinned("Fixtures/mutations.json")
    versions = load_pinned("Fixtures/version.json")

    if schemas["event.schema.json"].get("additionalProperties") is not False:
        fail("event schema must remain closed")
    mutation_defs = schemas["mutation.schema.json"].get("$defs", {})
    if set(mutation_defs) != {
        "jsonProperties",
        "propertyNames",
        "mutation",
        "identify",
        "linkAlias",
        "setPersonProperties",
        "associateGroup",
        "setGroupProperties",
    }:
        fail("mutation schema definitions drifted")
    if schemas["version.schema.json"].get("additionalProperties") is not False:
        fail("version schema must remain closed")

    validate_against_schema(versions, "version.schema.json", schemas, "version fixture")
    validate_against_schema(event, "event.schema.json", schemas, "event fixture")
    validate_against_schema(
        mutations,
        "mutation.schema.json",
        schemas,
        "mutation fixture",
    )

    validate_versions(versions)
    validate_event(event)
    envelope = require_keys(mutations, {"schemaVersion", "streamId", "versions", "mutations"})
    if envelope["schemaVersion"] != 1:
        fail("mutation envelope schemaVersion must be 1")
    require_string(envelope["streamId"], "streamId", 1, 256)
    validate_versions(envelope["versions"])
    if not isinstance(envelope["mutations"], list) or not 1 <= len(envelope["mutations"]) <= 100:
        fail("mutations fixture must contain 1...100 records")
    facts = [validate_mutation(mutation) for mutation in envelope["mutations"]]
    sequences = [fact[0] for fact in facts]
    if sequences != list(range(sequences[0], sequences[0] + len(sequences))):
        fail("mutation fixture sequences are not contiguous")
    if len({fact[1] for fact in facts}) != len(facts):
        fail("mutation fixture IDs are not unique")
    if [fact[2] for fact in facts] != [
        "identify",
        "linkAlias",
        "setPersonProperties",
        "associateGroup",
        "setGroupProperties",
    ]:
        fail("mutation fixture no longer covers every v1 change")
    if event["versions"] != versions or envelope["versions"] != versions:
        fail("fixtures do not share the pinned version context")

    unknown = copy.deepcopy(event)
    unknown["provider"] = "forbidden"
    expect_schema_rejected(
        unknown,
        "event.schema.json",
        schemas,
        "unknown event field",
    )
    expect_rejected(unknown, validate_event, "unknown event field")
    missing = copy.deepcopy(event)
    del missing["eventId"]
    expect_schema_rejected(
        missing,
        "event.schema.json",
        schemas,
        "missing event ID",
    )
    expect_rejected(missing, validate_event, "missing event ID")
    invalid_versions = copy.deepcopy(versions)
    invalid_versions["schemaVersion"] = 2
    expect_schema_rejected(
        invalid_versions,
        "version.schema.json",
        schemas,
        "future version schema",
    )
    expect_rejected(invalid_versions, validate_versions, "future version schema")

    invalid_mutations = copy.deepcopy(mutations)
    invalid_mutations["mutations"][0]["change"]["type"] = "mergeIdentity"
    expect_schema_rejected(
        invalid_mutations,
        "mutation.schema.json",
        schemas,
        "unknown mutation change",
    )
    expect_rejected(
        invalid_mutations["mutations"][0],
        validate_mutation,
        "unknown mutation change",
    )

    broken_reference_schemas = copy.deepcopy(schemas)
    broken_reference_schemas["event.schema.json"]["properties"]["versions"] = {
        "$ref": "missing-version.schema.json"
    }
    expect_schema_rejected(
        event,
        "event.schema.json",
        broken_reference_schemas,
        "unresolved external schema reference",
    )

    broken_fragment_schemas = copy.deepcopy(schemas)
    broken_fragment_schemas["mutation.schema.json"]["properties"]["mutations"][
        "items"
    ] = {"$ref": "#/$defs/missingMutation"}
    expect_schema_rejected(
        mutations,
        "mutation.schema.json",
        broken_fragment_schemas,
        "unresolved local schema reference",
    )

    print(
        "validated 6 pinned event/mutation/version files against JSON schemas "
        "and strict queue semantics"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
