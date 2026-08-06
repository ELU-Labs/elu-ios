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
    "manifest.json": "98152d8725c286f29402ba3e420bda8dd364200fb6fdf1cfe49b2da9b8f63e54",
    "schemas/identity.schema.json": "c41dee2d3693ece1c831a5adbfd7ee0d5660a9bb8c8e21005b34e1faea38d91d",
    "schemas/event.schema.json": "4a0deeb19b8406d31aa519bf1d3978294d6d06eb451d4588668cb6f67f4edee9",
    "schemas/mutation.schema.json": "8482af6b66c04701b014acd27e6d59aaef3f27864086c755f9abde498e5c8f5f",
    "schemas/version.schema.json": "3b4ca74e470efbf6610f2a1743f2bc78805882bd294a6984ef2c93fe42fea4ab",
    "schemas/batch-request.schema.json": "2e4c5c03e964f81aa0d5bd69230f66a8266137571261e117a1a3cd18ba28dfd8",
    "schemas/batch-ack.schema.json": "95ccd5e87001515b258fd2ea6a6e346ac265220708f8b1931d4f000276e0f3d9",
    "schemas/transport-error.schema.json": "67255aa898bb33fd75440e29573969c14b1d883f5b846865a3b3e5ba3051aaae",
    "schemas/transport-policy.schema.json": "16064cf3f7c513f3a05f57dbb4ad91386918dda4b0910c51aec544a492e2df6b",
    "schemas/replay.schema.json": "1effbcf8defe59013b49cf6c586e601a2a6d4806c89aafb6efe4115b2c078623",
    "schemas/replay-request.schema.json": "d3d8900d8f17b951bbfb3789b964a15ebeefe68fb0a816232ae67ab5a036a7c0",
    "schemas/replay-ack.schema.json": "10a2e6bd6ce528fc8a2083c11e5dc69c12d08bfc7b12e690f8c629eb1350e17c",
    "Fixtures/identity.json": "31da461a12b7f5f0d8a8bf7c8b66db8f7db91f6f1e6c9b51f8c0d0eba898d34b",
    "Fixtures/event.json": "44ea5d14646ec08aaa1805dffd8ea6403487ba7cb48e8ce7ea7f3752b241809d",
    "Fixtures/mutations.json": "a02a4db1d1ef0bf6b9eac0334fe83c3564526cbd21c79ccfe14aa303ff2ae3d4",
    "Fixtures/version.json": "61bf97e8eeea78df05df13434501a4bc9e81eaa3351fecaff2bdc06da9f1f8e2",
    "Fixtures/batch-request.json": "c0446316c5b75c163b27e27abe7b079b1c88bdb198a4985f4ceb544a8d154bbb",
    "Fixtures/batch-ack.json": "0a71284941a71646641095f772c34f9f84d8d7d0083574d7d35ef0148bf22cb5",
    "Fixtures/batch-ack-retryable-head.json": "f9e79b1a7bb913b2a07a3a66257c29f2a68973bbe6db7de99d47b30dbb2aa27e",
    "Fixtures/transport-error-unauthorized.json": "ba7bfd5c60c14dcb306de45515529d12af3310e84b495986c6ca67cb2a0578dc",
    "Fixtures/transport-error-forbidden.json": "630970155fdb2758850ddc5c7a84ece927a7bcba9ce8431b00d6d3edb8d9cf41",
    "Fixtures/transport-error-payload-too-large.json": "ef95b96c01bbbf44559554f9afeaacac15f41bedfc236516095eb0c8f8549259",
    "Fixtures/transport-error-rate-limited.json": "c29a01e3dac3d12e2722a20240201838423c07457f50aca455ebc523bda7a9fd",
    "Fixtures/transport-error-service-unavailable.json": "b93f84f5ee3591a0723f393413a28a1bb85cd7863b39313251fe54d6034f9b9c",
    "Fixtures/transport-policy.json": "992900180683af04f69d5e459b7c0c9e68edf92c6ebf320136ed36dbae8b60ce",
    "Fixtures/replay.json": "73ab61893bc8625f486345b69f2e527aa1ed1ceba05a0aefbd943ec314d75609",
    "Fixtures/replay-request.json": "1fb8ea52be5891a7b140a2f37764c50294f8fc637db1254cb06061ca5165e910",
    "Fixtures/replay-ack.json": "86fdcd571de4d5894bb572b06b6a96c5da653056b2bfb1ced62a5c968db09a63",
    "readback-expectations.json": "4958ca487c1bd3ca6592e42ca28c7de3c2ae929fceae71d53df3e96bca1f7594",
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
    is_number = isinstance(value, (int, float)) and not isinstance(value, bool)
    is_finite_number = is_number and (
        isinstance(value, int) or math.isfinite(value)
    )
    checks = {
        "null": value is None,
        "boolean": isinstance(value, bool),
        "integer": is_finite_number
        and (isinstance(value, int) or value.is_integer()),
        "number": is_finite_number,
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
    if schema is True:
        return
    if schema is False:
        schema_violation(path, "boolean schema rejects every value")
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
    if "allOf" in schema:
        for candidate in schema["allOf"]:
            validate_schema_instance(value, candidate, current_name, schemas, path)
    if "anyOf" in schema:
        matches = 0
        for candidate in schema["anyOf"]:
            try:
                validate_schema_instance(value, candidate, current_name, schemas, path)
            except SchemaViolation:
                continue
            matches += 1
        if matches == 0:
            schema_violation(path, "anyOf matched no branches")
    if "not" in schema:
        try:
            validate_schema_instance(value, schema["not"], current_name, schemas, path)
        except SchemaViolation:
            pass
        else:
            schema_violation(path, "not schema matched")
    if "if" in schema:
        try:
            validate_schema_instance(value, schema["if"], current_name, schemas, path)
        except SchemaViolation:
            conditional = schema.get("else")
        else:
            conditional = schema.get("then")
        if conditional is not None:
            validate_schema_instance(value, conditional, current_name, schemas, path)

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
        prefix_items = schema.get("prefixItems", [])
        for index, item_schema in enumerate(prefix_items):
            if index >= len(value):
                break
            validate_schema_instance(
                value[index],
                item_schema,
                current_name,
                schemas,
                f"{path}[{index}]",
            )
        if "items" in schema:
            start = len(prefix_items) if prefix_items else 0
            for index, item in enumerate(value[start:], start=start):
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
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
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


def batch_record_facts(request: Any) -> list[tuple[int, str, str]]:
    request = require_keys(
        request,
        {"schemaVersion", "requestId", "streamId", "sentAt", "versions", "records"},
    )
    if request["schemaVersion"] != 1:
        fail("batch request schemaVersion must be 1")
    require_string(request["requestId"], "requestId", 1, 256)
    stream_id = require_string(request["streamId"], "streamId", 1, 256)
    require_timestamp(request["sentAt"], "sentAt")
    validate_versions(request["versions"])
    records = request["records"]
    if not isinstance(records, list) or not 1 <= len(records) <= 1_000:
        fail("batch records must contain 1...1000 records")
    facts: list[tuple[int, str, str]] = []
    for record in records:
        if not isinstance(record, dict) or record.get("kind") not in {"event", "mutation"}:
            fail("batch record kind is invalid")
        kind = record["kind"]
        record = require_keys(record, {"kind", kind})
        payload = record[kind]
        if kind == "event":
            validate_event(payload)
            if payload["streamId"] != stream_id:
                fail("batch event stream does not match envelope")
            facts.append((payload["sequence"], payload["eventId"], kind))
        else:
            sequence, record_id, _ = validate_mutation(payload)
            facts.append((sequence, record_id, kind))
    sequences = [fact[0] for fact in facts]
    if sequences != list(range(sequences[0], sequences[0] + len(sequences))):
        fail("batch record sequences are not contiguous")
    if len({(fact[2], fact[1]) for fact in facts}) != len(facts):
        fail("batch record IDs are not kind-scoped unique")
    return facts


def validate_batch_ack(request: Any, acknowledgement: Any) -> None:
    facts = batch_record_facts(request)
    acknowledgement = require_keys(
        acknowledgement,
        {
            "schemaVersion",
            "requestId",
            "streamId",
            "resolvedThroughSequence",
            "retryFromSequence",
            "outcomes",
        },
    )
    if acknowledgement["schemaVersion"] != 1:
        fail("batch acknowledgement schemaVersion must be 1")
    if acknowledgement["requestId"] != request["requestId"]:
        fail("batch acknowledgement requestId mismatch")
    if acknowledgement["streamId"] != request["streamId"]:
        fail("batch acknowledgement streamId mismatch")
    outcomes = acknowledgement["outcomes"]
    if not isinstance(outcomes, list) or not 1 <= len(outcomes) <= len(facts):
        fail("batch acknowledgement outcomes are not a request prefix")

    retryable_index: int | None = None
    for index, outcome in enumerate(outcomes):
        outcome = require_keys(
            outcome,
            {"sequence", "recordId", "kind", "result"},
            {"code"},
        )
        sequence, record_id, kind = facts[index]
        if (outcome["sequence"], outcome["recordId"], outcome["kind"]) != (
            sequence,
            record_id,
            kind,
        ):
            fail("batch acknowledgement outcome mismatch")
        result = outcome["result"]
        if result not in {"accepted", "terminally-rejected", "retryable"}:
            fail("batch acknowledgement result is invalid")
        if result == "accepted" and "code" in outcome:
            fail("accepted outcome carries a code")
        if result != "accepted":
            code = outcome.get("code")
            if not isinstance(code, str) or re.fullmatch(r"[a-z][a-z0-9-]{0,63}", code) is None:
                fail("non-accepted outcome code is invalid")
        if result == "retryable":
            if retryable_index is not None or index != len(outcomes) - 1:
                fail("retryable outcome must be the final reported outcome")
            retryable_index = index

    if retryable_index is None and len(outcomes) != len(facts):
        fail("acknowledgement without retryable head must resolve the request")
    resolved_count = len(outcomes) if retryable_index is None else retryable_index
    expected_resolved = None if resolved_count == 0 else facts[resolved_count - 1][0]
    expected_retry = None if retryable_index is None else facts[retryable_index][0]
    if acknowledgement["resolvedThroughSequence"] != expected_resolved:
        fail("resolvedThroughSequence contradicts the validated prefix")
    if acknowledgement["retryFromSequence"] != expected_retry:
        fail("retryFromSequence contradicts the retryable head")


def validate_transport_error(value: Any, expected_status: int) -> None:
    value = require_keys(
        value,
        {"schemaVersion", "status", "code", "disposition", "message"},
        {"requestId"},
    )
    dispositions = {
        401: "permanent",
        403: "permanent",
        413: "retry-after-reduction",
        429: "retryable",
        503: "retryable",
    }
    if value["schemaVersion"] != 1 or value["status"] != expected_status:
        fail("transport error status/schema mismatch")
    if value["disposition"] != dispositions[expected_status]:
        fail("transport error disposition mismatch")
    if not isinstance(value["code"], str) or re.fullmatch(
        r"[a-z][a-z0-9-]{0,63}", value["code"]
    ) is None:
        fail("transport error code is invalid")
    require_string(value["message"], "transport error message", 1, 256)


def native_manifest_path(relative: str) -> str:
    if relative.startswith("fixtures/"):
        return "Fixtures/" + relative.removeprefix("fixtures/")
    return relative


def validate_manifest_closure(manifest: Any) -> None:
    manifest = require_keys(
        manifest,
        {
            "contract",
            "contractVersion",
            "schemaVersion",
            "status",
            "statusScope",
            "semanticContract",
            "transport",
            "compatibility",
            "schemas",
            "fixtures",
            "gates",
        },
    )
    routed = list(manifest["schemas"].values())
    routed.append(manifest["transport"]["policy"])
    routed.extend(manifest["fixtures"])
    routed.extend(manifest["gates"].values())
    actual = {
        path.relative_to(SNAPSHOT).as_posix()
        for path in SNAPSHOT.rglob("*")
        if path.is_file()
    }
    for relative in routed:
        native = native_manifest_path(relative)
        if native not in actual:
            fail(f"manifest dependency is missing or has wrong case: {native}")


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
    batch_request = load_pinned("Fixtures/batch-request.json")
    batch_ack = load_pinned("Fixtures/batch-ack.json")
    batch_retryable_ack = load_pinned("Fixtures/batch-ack-retryable-head.json")
    transport_policy = load_pinned("Fixtures/transport-policy.json")
    manifest = load_pinned("manifest.json")
    identity = load_pinned("Fixtures/identity.json")
    replay = load_pinned("Fixtures/replay.json")
    replay_request = load_pinned("Fixtures/replay-request.json")
    replay_ack = load_pinned("Fixtures/replay-ack.json")
    readback = load_pinned("readback-expectations.json")
    transport_errors = {
        401: load_pinned("Fixtures/transport-error-unauthorized.json"),
        403: load_pinned("Fixtures/transport-error-forbidden.json"),
        413: load_pinned("Fixtures/transport-error-payload-too-large.json"),
        429: load_pinned("Fixtures/transport-error-rate-limited.json"),
        503: load_pinned("Fixtures/transport-error-service-unavailable.json"),
    }

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
    validate_manifest_closure(manifest)

    validate_against_schema(identity, "identity.schema.json", schemas, "identity fixture")
    validate_against_schema(versions, "version.schema.json", schemas, "version fixture")
    validate_against_schema(event, "event.schema.json", schemas, "event fixture")
    validate_against_schema(
        mutations,
        "mutation.schema.json",
        schemas,
        "mutation fixture",
    )
    validate_against_schema(
        batch_request,
        "batch-request.schema.json",
        schemas,
        "batch request fixture",
    )
    validate_against_schema(
        batch_ack,
        "batch-ack.schema.json",
        schemas,
        "batch acknowledgement fixture",
    )
    validate_against_schema(
        batch_retryable_ack,
        "batch-ack.schema.json",
        schemas,
        "retryable batch acknowledgement fixture",
    )
    for status, transport_error in transport_errors.items():
        validate_against_schema(
            transport_error,
            "transport-error.schema.json",
            schemas,
            f"{status} transport error fixture",
        )
        validate_transport_error(transport_error, status)
    validate_against_schema(
        transport_policy,
        "transport-policy.schema.json",
        schemas,
        "transport policy fixture",
    )
    validate_against_schema(replay, "replay.schema.json", schemas, "replay fixture")
    validate_against_schema(
        replay_request,
        "replay-request.schema.json",
        schemas,
        "replay request fixture",
    )
    validate_against_schema(
        replay_ack,
        "replay-ack.schema.json",
        schemas,
        "replay acknowledgement fixture",
    )
    if replay_request["chunk"] != replay:
        fail("replay request does not contain the byte-pinned replay fixture")
    for field in ("replayId", "chunkId", "sequence"):
        if replay_ack[field] != replay[field]:
            fail(f"replay acknowledgement {field} is not bound to its chunk")
    if replay_ack["requestId"] != replay_request["requestId"]:
        fail("replay acknowledgement requestId is not bound to its request")
    if readback.get("orderedInput", {}).get("replayFixture") != "fixtures/replay.json":
        fail("readback gate does not route the canonical replay fixture")
    validate_batch_ack(batch_request, batch_ack)
    validate_batch_ack(batch_request, batch_retryable_ack)

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
        f"validated {len(EXPECTED_SHA256)} pinned v1 queue, replay, and transport files "
        "against complete manifest routing and strict acknowledgement semantics"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
