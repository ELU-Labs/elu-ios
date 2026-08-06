#!/usr/bin/env python3
"""Validate the byte-pinned config and replay v2 contract without dependencies."""

from __future__ import annotations

import base64
import binascii
import copy
import gzip
import hashlib
import json
import math
import pathlib
import re
import runpy
import struct
import sys
import zlib
from decimal import Decimal
from typing import Any, NoReturn
from urllib.parse import urlsplit


ROOT = pathlib.Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "Conformance" / "V2"
V1_SNAPSHOT = ROOT / "Conformance" / "V1"
QUEUE_VALIDATOR = runpy.run_path(str(ROOT / "Conformance" / "validate-v1-queue.py"))
SchemaViolation = QUEUE_VALIDATOR["SchemaViolation"]
validate_schema_instance = QUEUE_VALIDATOR["validate_schema_instance"]
CHECKSUM_LINE = re.compile(r"^([a-f0-9]{64})  ([A-Za-z0-9./_-]+)$")
JSON_NUMBER = re.compile(r"-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?")
PRIVACY_SCHEMA_ID = "https://sdk.elu.dev/contracts/v1/privacy-policy.schema.json"
POSITIVE_INT64_LIMIT = "9223372036854775807"
NEGATIVE_INT64_LIMIT = "9223372036854775808"
MAXIMUM_SAFE_INTEGER = 9_007_199_254_740_991
CANONICAL_JSON_V1_SHA256 = (
    "80b07e6a5456588727cbdd7d05e1e37cc6e49336993b2de8c9ba08bd1ed3eb99"
)
EXPECTED_CONFIG_CORS = {
    "optionsRequest": {
        "method": "OPTIONS",
        "authorizationRequired": False,
    },
    "optionsResponse": {
        "accessControlAllowOrigin": "*",
        "accessControlAllowMethods": ["GET", "OPTIONS"],
        "accessControlAllowCredentials": "omitted",
    },
    "getResponse": {
        "accessControlAllowOrigin": "*",
        "accessControlAllowCredentials": "omitted",
    },
}
EXPECTED_REPLAY_CORS = {
    "preflightRequest": {
        "method": "OPTIONS",
        "authorizationRequired": False,
        "accessControlRequestMethod": "POST",
        "accessControlRequestHeaders": ["authorization", "content-type"],
    },
    "preflightResponse": {
        "accessControlAllowOrigin": "*",
        "accessControlAllowMethods": ["POST", "OPTIONS"],
        "accessControlAllowHeaders": ["Authorization", "Content-Type"],
    },
    "postResponse": {
        "accessControlAllowOrigin": "*",
        "accessControlExposeHeaders": ["Retry-After"],
    },
}
FIXTURE_SCHEMAS = {
    "fixtures/config-enabled.json": "schemas/config.schema.json",
    "fixtures/config-disabled.json": "schemas/config.schema.json",
    "fixtures/replay.json": "schemas/replay.schema.json",
    "fixtures/replay-request.json": "schemas/replay-request.schema.json",
    "fixtures/replay-ack.json": "schemas/replay-ack.schema.json",
    "fixtures/replay-error-identity-conflict.json": "schemas/replay-error.schema.json",
}


def fail(message: str) -> NoReturn:
    print(f"v2 replay conformance failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def reject_constant(value: str) -> NoReturn:
    fail(f"non-finite JSON number {value}")


def closed_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            fail(f"duplicate JSON key {key!r}")
        value[key] = item
    return value


def utf16_sort_key(value: str) -> bytes:
    return value.encode("utf-16-be")


def normalize_surrogate_pairs(value: str) -> str:
    scalars: list[str] = []
    index = 0
    while index < len(value):
        code = ord(value[index])
        if 0xD800 <= code <= 0xDBFF:
            if index + 1 >= len(value):
                raise ValueError("invalid-unicode")
            low = ord(value[index + 1])
            if not 0xDC00 <= low <= 0xDFFF:
                raise ValueError("invalid-unicode")
            scalars.append(chr(0x10000 + ((code - 0xD800) << 10) + low - 0xDC00))
            index += 2
            continue
        if 0xDC00 <= code <= 0xDFFF:
            raise ValueError("invalid-unicode")
        scalars.append(value[index])
        index += 1
    return "".join(scalars)


def compare_unsigned_decimals(left: str, right: str) -> int:
    if len(left) != len(right):
        return -1 if len(left) < len(right) else 1
    if left == right:
        return 0
    return -1 if left < right else 1


def exact_int64_canonical(token: str) -> str | None:
    unsigned = token
    negative = False
    if unsigned.startswith("-"):
        negative = True
        unsigned = unsigned[1:]

    exponent_match = re.search(r"[eE]", unsigned)
    if exponent_match is None:
        coefficient = unsigned
        exponent = 0
    else:
        coefficient = unsigned[: exponent_match.start()]
        try:
            exponent = int(unsigned[exponent_match.start() + 1 :])
        except ValueError:
            return None
        if abs(exponent) > MAXIMUM_SAFE_INTEGER:
            return None

    point = coefficient.find(".")
    fraction_length = 0 if point < 0 else len(coefficient) - point - 1
    digits = (coefficient if point < 0 else coefficient[:point] + coefficient[point + 1 :]).lstrip("0")
    if not digits:
        return "0"

    scale = exponent - fraction_length
    if scale < 0:
        required_zeros = -scale
        if required_zeros > len(digits) or not digits.endswith("0" * required_zeros):
            return None
        digits = digits[: len(digits) - required_zeros].lstrip("0")
        if not digits:
            return "0"
    else:
        if len(digits) + scale > 19:
            return None
        digits += "0" * scale

    limit = NEGATIVE_INT64_LIMIT if negative else POSITIVE_INT64_LIMIT
    if compare_unsigned_decimals(digits, limit) > 0:
        return None
    return f"-{digits}" if negative else digits


def binary64_json_stringify(value: float) -> str:
    if not math.isfinite(value):
        raise ValueError("non-finite-number")
    if value == 0:
        return "0"

    shortest = repr(value).lower()
    decimal = Decimal(shortest)
    adjusted = decimal.copy_abs().adjusted()
    if -6 <= adjusted < 21:
        fixed = format(decimal, "f")
        if "." in fixed:
            fixed = fixed.rstrip("0").rstrip(".")
        return fixed

    if "e" not in shortest:
        shortest = format(decimal.normalize(), "e")
    coefficient, exponent_text = shortest.split("e", 1)
    coefficient = coefficient.rstrip("0").rstrip(".")
    exponent = int(exponent_text)
    return f"{coefficient}e{'+' if exponent >= 0 else ''}{exponent}"


def canonical_number(token: str) -> str:
    exact = exact_int64_canonical(token)
    if exact is not None:
        return exact
    try:
        return binary64_json_stringify(float(token))
    except (OverflowError, ValueError) as error:
        raise ValueError("non-finite-number") from error


class StrictCanonicalJson:
    def __init__(self, source: str, maximum_nesting_depth: int | None = None):
        self.source = source
        self.offset = 0
        self.maximum_nesting_depth = maximum_nesting_depth

    def parse(self) -> str:
        canonical = self.parse_value(0)
        self.skip_whitespace()
        if self.offset != len(self.source):
            raise ValueError("trailing-json-data")
        return canonical

    def skip_whitespace(self) -> None:
        while self.offset < len(self.source) and self.source[self.offset] in "\t\n\r ":
            self.offset += 1

    def parse_string(self) -> str:
        if self.offset >= len(self.source) or self.source[self.offset] != '"':
            raise ValueError("expected-string")
        start = self.offset
        self.offset += 1
        while self.offset < len(self.source):
            character = self.source[self.offset]
            self.offset += 1
            if character == '"':
                try:
                    value = json.loads(self.source[start : self.offset])
                except json.JSONDecodeError as error:
                    raise ValueError("invalid-string") from error
                return normalize_surrogate_pairs(value)
            if character == "\\":
                if self.offset >= len(self.source):
                    raise ValueError("unterminated-string-escape")
                escape = self.source[self.offset]
                self.offset += 1
                if escape == "u":
                    digits = self.source[self.offset : self.offset + 4]
                    if len(digits) != 4 or re.fullmatch(r"[a-fA-F0-9]{4}", digits) is None:
                        raise ValueError("invalid-unicode-escape")
                    self.offset += 4
                elif escape not in '"\\/bfnrt':
                    raise ValueError("invalid-string-escape")
            elif ord(character) <= 0x1F:
                raise ValueError("unescaped-control-character")
        raise ValueError("unterminated-string")

    def assert_depth(self, depth: int) -> None:
        if self.maximum_nesting_depth is not None and depth > self.maximum_nesting_depth:
            raise ValueError("json-nesting-limit")

    def parse_value(self, depth: int) -> str:
        self.skip_whitespace()
        if self.offset >= len(self.source):
            raise ValueError("missing-json-value")
        character = self.source[self.offset]
        if character == "{":
            return self.parse_object(depth + 1)
        if character == "[":
            return self.parse_array(depth + 1)
        if character == '"':
            return json.dumps(self.parse_string(), ensure_ascii=False, separators=(",", ":"))
        for literal in ("true", "false", "null"):
            if self.source.startswith(literal, self.offset):
                self.offset += len(literal)
                return literal
        match = JSON_NUMBER.match(self.source, self.offset)
        if match is None:
            raise ValueError("invalid-json-value")
        self.offset = match.end()
        return canonical_number(match.group(0))

    def parse_object(self, depth: int) -> str:
        self.assert_depth(depth)
        self.offset += 1
        self.skip_whitespace()
        members: list[tuple[str, str]] = []
        keys: set[str] = set()
        if self.offset < len(self.source) and self.source[self.offset] == "}":
            self.offset += 1
            return "{}"
        while self.offset < len(self.source):
            self.skip_whitespace()
            key = self.parse_string()
            if key in keys:
                raise ValueError("duplicate-key")
            keys.add(key)
            self.skip_whitespace()
            if self.offset >= len(self.source) or self.source[self.offset] != ":":
                raise ValueError("expected-colon")
            self.offset += 1
            members.append((key, self.parse_value(depth)))
            self.skip_whitespace()
            if self.offset < len(self.source) and self.source[self.offset] == "}":
                self.offset += 1
                members.sort(key=lambda member: utf16_sort_key(member[0]))
                return "{" + ",".join(
                    f"{json.dumps(key, ensure_ascii=False, separators=(',', ':'))}:{value}"
                    for key, value in members
                ) + "}"
            if self.offset >= len(self.source) or self.source[self.offset] != ",":
                raise ValueError("expected-object-separator")
            self.offset += 1
        raise ValueError("unterminated-object")

    def parse_array(self, depth: int) -> str:
        self.assert_depth(depth)
        self.offset += 1
        self.skip_whitespace()
        values: list[str] = []
        if self.offset < len(self.source) and self.source[self.offset] == "]":
            self.offset += 1
            return "[]"
        while self.offset < len(self.source):
            values.append(self.parse_value(depth))
            self.skip_whitespace()
            if self.offset < len(self.source) and self.source[self.offset] == "]":
                self.offset += 1
                return "[" + ",".join(values) + "]"
            if self.offset >= len(self.source) or self.source[self.offset] != ",":
                raise ValueError("expected-array-separator")
            self.offset += 1
        raise ValueError("unterminated-array")


def canonicalize_strict_json(source: str, maximum_nesting_depth: int | None = None) -> str:
    return StrictCanonicalJson(source, maximum_nesting_depth).parse()


def strict_json_bytes(data: bytes, name: str) -> Any:
    try:
        source = data.decode("utf-8", errors="strict")
        canonicalize_strict_json(source)
        return json.loads(
            source,
            object_pairs_hook=closed_object,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        fail(f"{name} is not strict JSON: {error}")


def load(relative: str) -> Any:
    return strict_json_bytes((SNAPSHOT / relative).read_bytes(), relative)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json(value: Any) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        try:
            return binary64_json_stringify(value)
        except ValueError:
            fail("canonical JSON received a non-finite number")
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ",".join(canonical_json(item) for item in value) + "]"
    if isinstance(value, dict):
        return (
            "{"
            + ",".join(
                f"{canonical_json(key)}:{canonical_json(value[key])}"
                for key in sorted(value, key=utf16_sort_key)
            )
            + "}"
        )
    fail(f"canonical JSON received unsupported value {type(value).__name__}")


def parse_checksums() -> dict[str, str]:
    checksums: dict[str, str] = {}
    lines = (SNAPSHOT / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
    for line in lines:
        match = CHECKSUM_LINE.fullmatch(line)
        if match is None:
            fail(f"invalid checksum line {line!r}")
        digest, relative = match.groups()
        if relative in checksums:
            fail(f"duplicate checksum path {relative}")
        checksums[relative] = digest
    return checksums


def native_manifest_path(relative: str) -> pathlib.Path:
    if relative.startswith("../v1/"):
        v1_relative = relative.removeprefix("../v1/")
        if v1_relative.startswith("test-vectors/"):
            v1_relative = "TestVectors/" + v1_relative.removeprefix("test-vectors/")
        if v1_relative.startswith("fixtures/"):
            v1_relative = "Fixtures/" + v1_relative.removeprefix("fixtures/")
        return V1_SNAPSHOT / v1_relative
    return SNAPSHOT / relative


def validate_manifest_closure(manifest: dict[str, Any]) -> None:
    routed = list(manifest["schemas"].values())
    routed.extend(manifest["fixtures"])
    routed.extend(manifest["testVectors"].values())
    routed.extend(manifest["gates"].values())
    routed.append(manifest["checksums"])
    routed.extend(value["path"] for value in manifest["dependencies"].values())
    actual = {
        path.relative_to(ROOT / "Conformance").as_posix()
        for path in (ROOT / "Conformance").rglob("*")
        if path.is_file()
    }
    for relative in routed:
        native = native_manifest_path(relative)
        try:
            native_relative = native.relative_to(ROOT / "Conformance").as_posix()
        except ValueError:
            fail(f"manifest path escapes Conformance: {relative}")
        if native_relative not in actual:
            fail(f"manifest dependency is missing or has wrong case: {native_relative}")


def schema_documents(manifest: dict[str, Any]) -> dict[str, Any]:
    schemas: dict[str, Any] = {}
    schema_ids: set[str] = set()
    for relative in manifest["schemas"].values():
        document = load(relative)
        identifier = document.get("$id")
        if not isinstance(identifier, str) or not identifier.startswith(
            "https://sdk.elu.dev/contracts/v2/"
        ):
            fail(f"v2 schema has invalid absolute identifier: {relative}")
        if identifier in schema_ids:
            fail(f"duplicate v2 schema identifier: {identifier}")
        schema_ids.add(identifier)
        schemas[pathlib.PurePosixPath(relative).name] = document
        schemas[identifier] = document
    privacy_policy = strict_json_bytes(
        (V1_SNAPSHOT / "schemas/privacy-policy.schema.json").read_bytes(),
        "V1/schemas/privacy-policy.schema.json",
    )
    schemas["privacy-policy.schema.json"] = privacy_policy
    schemas[PRIVACY_SCHEMA_ID] = privacy_policy
    return schemas


def validate_fixture(
    value: Any,
    schema_name: str,
    schemas: dict[str, Any],
    description: str,
) -> None:
    try:
        validate_schema_instance(
            value,
            schemas[pathlib.PurePosixPath(schema_name).name],
            pathlib.PurePosixPath(schema_name).name,
            schemas,
        )
    except SchemaViolation as error:
        fail(f"{description} failed {schema_name}: {error}")


def schema_rejects(value: Any, schemas: dict[str, Any]) -> bool:
    try:
        validate_schema_instance(
            value,
            schemas["replay-request.schema.json"],
            "replay-request.schema.json",
            schemas,
        )
    except SchemaViolation:
        return True
    return False


def request_identity(chunk: dict[str, Any]) -> tuple[bytes, bytes, str]:
    canonical_chunk = canonical_json(chunk).encode("utf-8")
    material = (
        b"elu-sdk-replay-request-v2"
        + b"\x00"
        + struct.pack(">I", len(canonical_chunk))
        + canonical_chunk
    )
    return canonical_chunk, material, "request_" + sha256(material)


def request_id_matches(request: dict[str, Any]) -> bool:
    return request["requestId"] == request_identity(request["chunk"])[2]


def acknowledgement_matches(
    request: dict[str, Any],
    acknowledgement: dict[str, Any],
) -> bool:
    chunk = request["chunk"]
    return (
        acknowledgement.get("requestId") == request["requestId"]
        and acknowledgement.get("replayId") == chunk["replayId"]
        and acknowledgement.get("chunkId") == chunk["chunkId"]
        and acknowledgement.get("sequence") == chunk["sequence"]
        and acknowledgement.get("result") == "accepted"
    )


def mutate(request: dict[str, Any], vector: dict[str, Any]) -> dict[str, Any]:
    candidate = copy.deepcopy(request)
    owner = candidate
    for segment in vector["path"][:-1]:
        owner = owner[segment]
    key = vector["path"][-1]
    if vector["operation"] == "remove":
        del owner[key]
    else:
        owner[key] = vector["value"]
    return candidate


def validate_endpoint(endpoint: str, expected_path: str, name: str) -> None:
    parsed = urlsplit(endpoint)
    if (
        parsed.scheme != "https"
        or parsed.hostname is None
        or not (parsed.hostname == "elu.dev" or parsed.hostname.endswith(".elu.dev"))
        or parsed.path != expected_path
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        fail(f"{name} is not the exact trusted ELU endpoint")


class AdmissionError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def admission_failure(code: str) -> NoReturn:
    raise AdmissionError(code)


def decode_canonical_base64(value: str) -> bytes:
    if not value or re.search(r"[^A-Za-z0-9+/=]", value):
        admission_failure("invalid-base64")
    if re.fullmatch(r"(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?", value) is None:
        admission_failure("noncanonical-base64")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        admission_failure("invalid-base64")
    if base64.b64encode(decoded).decode("ascii") != value:
        admission_failure("noncanonical-base64")
    return decoded


def stream_single_gzip_member(payload: bytes, maximum_decoded_bytes: int) -> bytes:
    decoder = zlib.decompressobj(wbits=31)
    decoded_parts: list[bytes] = []
    decoded_length = 0
    pending = payload
    try:
        while pending:
            allowance = maximum_decoded_bytes + 1 - decoded_length
            piece = decoder.decompress(pending, max(1, allowance))
            decoded_parts.append(piece)
            decoded_length += len(piece)
            if decoded_length > maximum_decoded_bytes:
                admission_failure("decoded-byte-limit")
            if decoder.eof:
                if decoder.unused_data or decoder.unconsumed_tail:
                    admission_failure("trailing-gzip-data")
                break
            next_pending = decoder.unconsumed_tail
            if not next_pending:
                break
            if next_pending == pending and not piece:
                admission_failure("invalid-gzip")
            pending = next_pending
    except zlib.error:
        admission_failure("invalid-gzip")
    if not decoder.eof:
        admission_failure("invalid-gzip")
    return b"".join(decoded_parts)


def admit_browser_dom_payload(value: str, limits: dict[str, int]) -> tuple[bytes, list[Any]]:
    payload = decode_canonical_base64(value)
    decoded = stream_single_gzip_member(payload, limits["maximumReplayDecodedBytes"])
    if decoded.startswith(b"\x1f\x8b"):
        admission_failure("nested-compression")
    try:
        source = decoded.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        admission_failure("invalid-unicode")
    try:
        canonical = canonicalize_strict_json(
            source,
            maximum_nesting_depth=limits["maximumJsonNestingDepth"],
        )
    except ValueError as error:
        message = str(error)
        if "invalid-unicode" in message:
            admission_failure("invalid-unicode")
        if "json-nesting-limit" in message:
            admission_failure("json-nesting-limit")
        raise
    if canonical != source:
        admission_failure("noncanonical-codec-json")
    records = json.loads(source)
    if not isinstance(records, list):
        admission_failure("invalid-codec-shape")
    if len(records) > limits["maximumReplayLogicalRecords"]:
        admission_failure("logical-record-limit")
    return decoded, records


def classify_generation_row(vector: dict[str, Any]) -> str:
    if not vector["currentGenerationSupported"]:
        return "purge-and-fail-closed"
    if vector["currentGeneration"] != vector["queuedGeneration"]:
        return "purge-before-send"
    return "preserve-and-send"


def resolve_replay_idempotency(
    initial: dict[str, Any], candidate: dict[str, Any]
) -> tuple[str, str | None]:
    request_collision = (
        initial["siteId"] == candidate["siteId"]
        and initial["requestId"] == candidate["requestId"]
    )
    if request_collision and initial["canonicalRequestSha256"] != candidate["canonicalRequestSha256"]:
        return "permanent-conflict", "request"

    chunk_collision = (
        initial["siteId"] == candidate["siteId"]
        and initial["replayId"] == candidate["replayId"]
        and initial["chunkId"] == candidate["chunkId"]
    )
    if chunk_collision and any(
        initial[field] != candidate[field]
        for field in ("requestId", "canonicalRequestSha256", "sequence")
    ):
        return "permanent-conflict", "chunk"

    sequence_collision = (
        initial["siteId"] == candidate["siteId"]
        and initial["replayId"] == candidate["replayId"]
        and initial["sequence"] == candidate["sequence"]
    )
    if sequence_collision and any(
        initial[field] != candidate[field]
        for field in ("requestId", "canonicalRequestSha256", "chunkId")
    ):
        return "permanent-conflict", "sequence"

    if request_collision and chunk_collision and sequence_collision:
        return "same-stored-effective-ack", None
    return "accepted-new-site-scope", None


def validate_raw_canonical_vector(vector: dict[str, Any]) -> None:
    identifier = vector["id"]
    if vector.get("expect") == "reject":
        try:
            canonicalize_strict_json(vector["raw"])
        except ValueError:
            return
        fail(f"canonical JSON negative vector was accepted: {identifier}")
    canonical = canonicalize_strict_json(vector["raw"]).encode("utf-8")
    if (
        base64.b64encode(canonical).decode("ascii") != vector["expectedCanonicalBase64"]
        or "sha256:" + sha256(canonical) != vector["expectedSha256"]
    ):
        fail(f"canonical JSON vector drifted: {identifier}")


def construct_payload_case(
    construction: str,
    replay_payload: str,
    limits: dict[str, int],
) -> str:
    compressed = base64.b64decode(replay_payload, validate=True)
    decoded_limit = limits["maximumReplayDecodedBytes"]
    record_limit = limits["maximumReplayLogicalRecords"]
    depth_limit = limits["maximumJsonNestingDepth"]
    if construction == "canonical-array-bytes-16777216":
        source = f'["{"a" * (decoded_limit - 4)}"]'.encode()
    elif construction == "logical-records-10000":
        source = ("[" + ",".join(["0"] * record_limit) + "]").encode()
    elif construction == "json-nesting-depth-256":
        source = ("[" * depth_limit + "0" + "]" * depth_limit).encode()
    elif construction == "invalid-gzip-bytes":
        return base64.b64encode(b"not-gzip").decode("ascii")
    elif construction == "invalid-base64-alphabet":
        return "***"
    elif construction == "remove-required-padding":
        return replay_payload.rstrip("=")
    elif construction == "gzip-of-gzip":
        return base64.b64encode(gzip.compress(compressed, mtime=0)).decode("ascii")
    elif construction == "concatenated-gzip-members":
        return base64.b64encode(compressed + compressed).decode("ascii")
    elif construction == "gzip-plus-one-byte":
        return base64.b64encode(compressed + b"\x00").decode("ascii")
    elif construction == "decoded-bytes-16777217":
        source = b"a" * (decoded_limit + 1)
    elif construction == "logical-records-10001":
        source = ("[" + ",".join(["0"] * (record_limit + 1)) + "]").encode()
    elif construction == "json-nesting-depth-257":
        source = ("[" * (depth_limit + 1) + "0" + "]" * (depth_limit + 1)).encode()
    elif construction == "escaped-lone-high-surrogate":
        source = b'["\\ud800"]'
    elif construction == "invalid-utf8-in-json-string":
        source = bytes([0x5B, 0x22, 0xC3, 0x28, 0x22, 0x5D])
    else:
        fail(f"unknown payload construction {construction}")
    return base64.b64encode(gzip.compress(source, mtime=0)).decode("ascii")


def verify_public_contract_clean() -> None:
    notice = (ROOT / "legal" / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
    marker = re.search(r"^Forbidden-Identifier:\s*(\S+)\s*$", notice, re.MULTILINE)
    if marker is None:
        fail("third-party notice has no forbidden identifier")
    forbidden = marker.group(1).casefold()
    planning_leakage = re.compile(
        r"\bco" + r"dex\b|\bpha" + r"se[- ]?\d+\b|internal " + r"planning",
        re.IGNORECASE,
    )
    for path in SNAPSHOT.rglob("*"):
        if not path.is_file() or path.name == "SHA256SUMS":
            continue
        source = path.read_text(encoding="utf-8")
        if forbidden in source.casefold():
            fail(f"public v2 artifact contains provider identifier: {path.relative_to(ROOT)}")

    probes = (
        ("README.md", "co" + "dex"),
        ("docs/roadmap.md", "pha" + "se-0"),
        ("CONTRIBUTING.md", "internal " + "planning"),
    )
    for relative, source in probes:
        if planning_leakage.search(relative) is None and planning_leakage.search(source) is None:
            fail(f"public hygiene detector missed its {relative} probe")

    excluded_parts = {
        ".git",
        ".build",
        ".swiftpm",
        ".pytest_cache",
        "DerivedData",
        "__pycache__",
        "build",
        "legal",
    }
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT)
        if any(part in excluded_parts for part in relative.parts):
            continue
        if planning_leakage.search(relative.as_posix()):
            fail(f"public repository path contains planning leakage: {relative}")
        try:
            source = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if planning_leakage.search(source):
            fail(f"public repository file contains planning leakage: {relative}")


def verify_unwired() -> None:
    forbidden = ("elu-http-v2", "replayProtocolGeneration", "/v2/replay")
    for path in (ROOT / "Sources").rglob("*.swift"):
        source = path.read_text(encoding="utf-8")
        for token in forbidden:
            if token in source:
                fail(f"production source activates v2 transport token {token}: {path.relative_to(ROOT)}")


def main() -> int:
    manifest = load("manifest.json")
    activity = load("test-vectors/replay-activity.json")
    if (
        manifest.get("contract") != "elu-sdk"
        or manifest.get("contractVersion") != "2.0.0"
        or manifest.get("schemaVersion") != 2
        or manifest.get("contractScope") != "config-and-replay"
        or manifest.get("status") != "frozen"
        or manifest.get("statusScope") != "semantic-contract"
    ):
        fail("manifest must freeze config-and-replay contract 2.0.0 / schema 2")
    transport = manifest.get("transport", {})
    config_endpoint = transport.get("configurationEndpoint", {})
    replay_endpoint = transport.get("replayEndpoint", {})
    if (
        transport.get("status") != "specified-not-wired"
        or transport.get("runtimeBehavior") != "unchanged"
        or transport.get("liveReadbackVerification") != "pending-external-verification"
        or config_endpoint.get("method") != "GET"
        or config_endpoint.get("pathTemplate") != "/sdk/v2/{siteKey}/config"
        or config_endpoint.get("cors") != EXPECTED_CONFIG_CORS
        or {
            key: config_endpoint.get(key)
            for key in ("delivery", "cors", "successfulResponses", "transientFailures")
        }
        != activity["transport"]["configV2"]
        or {
            key: replay_endpoint.get(key)
            for key in ("method", "path", "replayV1")
        }
        != {"method": "POST", "path": "/v2/replay", "replayV1": "unsupported"}
        or replay_endpoint.get("authorization")
        != {
            "credential": "public-routing-site-key",
            "placement": "Authorization: Bearer {siteKey}",
            "queryFallback": "forbidden",
            "cookies": "forbidden",
            "providerCredentials": "forbidden",
            "serverAuthority": "current-site-route",
            "serverRecordsProtocolGeneration": True,
            "serverRecordedGenerationProvesCaptureGeneration": False,
            "clientQueuePersistsProtocolGeneration": True,
            "generationChangePurgesBeforeSend": True,
            "requestIdentityCarriesConfigRevision": False,
            "requestIdentityCarriesProtocolGeneration": False,
            "captureAuditHashesAuthorizeCaller": False,
        }
        or replay_endpoint.get("delivery")
        != {
            "api": "fetch",
            "mode": "cors",
            "credentials": "omit",
            "contentType": "application/json",
            "httpContentEncoding": "identity",
            "preflight": "required",
            "beacon": "unsupported",
        }
        or replay_endpoint.get("cors") != EXPECTED_REPLAY_CORS
        or {
            key: replay_endpoint.get(key)
            for key in ("authorization", "delivery", "cors", "responses")
        }
        != activity["transport"]["replayV2"]
    ):
        fail("manifest transport boundary drifted")
    validate_manifest_closure(manifest)

    checksums = parse_checksums()
    actual = sorted(
        path.relative_to(SNAPSHOT).as_posix()
        for path in SNAPSHOT.rglob("*")
        if path.is_file() and path.name != "SHA256SUMS"
    )
    if set(checksums) != set(actual):
        fail(f"SHA256SUMS closure {list(checksums)!r} != normative files {actual!r}")
    if list(checksums) != sorted(checksums, key=str.casefold):
        fail("SHA256SUMS paths are not case-insensitively sorted")
    for relative, expected in checksums.items():
        actual_digest = sha256((SNAPSHOT / relative).read_bytes())
        if actual_digest != expected:
            fail(f"{relative} digest {actual_digest}, expected {expected}")

    privacy_dependency = manifest["dependencies"]["privacyPolicyV1"]
    privacy_dependency_digest = sha256(native_manifest_path(privacy_dependency["path"]).read_bytes())
    if (
        privacy_dependency["path"] != "../v1/schemas/privacy-policy.schema.json"
        or privacy_dependency_digest != privacy_dependency["sha256"]
    ):
        fail("v1 privacy-policy dependency digest drifted")
    canonical_dependency = manifest["dependencies"]["canonicalJsonV1"]
    canonical_dependency_digest = sha256(native_manifest_path(canonical_dependency["path"]).read_bytes())
    if (
        canonical_dependency.get("algorithm") != "elu-canonical-json-v1"
        or canonical_dependency["path"] != "../v1/test-vectors/capture-admission-activity.json"
        or canonical_dependency.get("sha256") != CANONICAL_JSON_V1_SHA256
        or canonical_dependency_digest != CANONICAL_JSON_V1_SHA256
    ):
        fail("v1 canonical JSON dependency drifted")

    schemas = schema_documents(manifest)
    config_schema = schemas["config.schema.json"]
    if (
        config_schema.get("properties", {}).get("privacy", {}).get("$ref") != PRIVACY_SCHEMA_ID
        or PRIVACY_SCHEMA_ID not in schemas
        or schemas[PRIVACY_SCHEMA_ID].get("$id") != PRIVACY_SCHEMA_ID
    ):
        fail("config privacy reference is not resolved by its absolute schema identifier")
    if set(FIXTURE_SCHEMAS) != set(manifest["fixtures"]):
        fail("fixture/schema routing does not cover the manifest")
    fixtures = {relative: load(relative) for relative in manifest["fixtures"]}
    for relative, schema in FIXTURE_SCHEMAS.items():
        validate_fixture(fixtures[relative], schema, schemas, relative)

    config = fixtures["fixtures/config-enabled.json"]
    disabled = fixtures["fixtures/config-disabled.json"]
    replay = fixtures["fixtures/replay.json"]
    request = fixtures["fixtures/replay-request.json"]
    acknowledgement = fixtures["fixtures/replay-ack.json"]
    conflict_fixture = fixtures["fixtures/replay-error-identity-conflict.json"]
    if request["chunk"] != replay:
        fail("replay request does not embed the exact replay fixture")
    for field in ("configRevision", "replayProtocolGeneration"):
        if field in request or field in replay:
            fail(f"request identity must not claim server-current authority field {field}")
    if disabled.get("status") != "disabled" or "site" in disabled or "endpoints" in disabled:
        fail("disabled config grants authority")

    successful = config_endpoint["successfulResponses"]
    transient = config_endpoint["transientFailures"]
    if (
        successful["statuses"] != ["enabled", "disabled", "revoked"]
        or successful["maximumTtlSeconds"] != 300
        or successful["maximumRevocationBudgetSeconds"] != 300
        or successful["staleWhileRevalidate"] != "forbidden"
        or successful["sdkRejectsAtOrAfterExpiresAt"] is not True
        or transient["httpStatuses"] != [429, 500, 502, 503, 504]
        or transient["httpResponseCacheControl"] != "no-store, max-age=0, s-maxage=0"
        or transient["validConfigBody"] != "none"
        or transient["staleConfigMayAuthorizeSend"] is not False
        or transient["clientAction"] != "preserve-queue-and-block-send"
    ):
        fail("config cache, expiry, or transient behavior drifted")
    for vector in activity["configCaching"]["cases"]:
        ttl = max(
            0,
            math.floor(
                min(
                    successful["maximumTtlSeconds"],
                    vector["remainingIssuanceLifetimeSeconds"],
                    vector["revocationBudgetSeconds"],
                )
            ),
        )
        if ttl != vector["expectedTtlSeconds"]:
            fail("config caching vector drifted")
        header = successful["cacheControlTemplate"].replace("{ttl}", str(ttl))
        if (
            f"max-age={ttl}" not in header
            or f"s-maxage={ttl}" not in header
            or "must-revalidate" not in header
            or "stale-while-revalidate" in header
        ):
            fail("config cache-control rendering drifted")

    channels = activity["negotiation"]["channels"]
    for channel in ("events", "mutations", "flags"):
        expected = {
            key: channels[channel][key]
            for key in ("contractVersion", "schemaVersion")
        }
        if config["capabilities"][channel] != expected:
            fail(f"{channel} negotiation drifted")
    expected_replay = {
        key: channels["replay"][key]
        for key in (
            "replayContractVersion",
            "replaySchemaVersion",
            "replayProtocolGeneration",
            "transports",
        )
    }
    if config["capabilities"]["replay"] != expected_replay:
        fail("replay negotiation drifted")
    for role, expected_path in {
        "events": "/v1/events",
        "replay": "/v2/replay",
        "flags": "/v1/flags",
        "assets": "/sdk/",
    }.items():
        validate_endpoint(config["endpoints"][role], expected_path, role)

    if len((SNAPSHOT / "fixtures/config-enabled.json").read_bytes()) > 65_536:
        fail("enabled config exceeds the contract byte ceiling")

    for vector in activity["negativeRequests"]:
        candidate = mutate(request, vector)
        rejected = schema_rejects(candidate, schemas)
        if vector.get("validation") == "semantic":
            if rejected or request_id_matches(candidate):
                fail(f"semantic negative vector did not fail only request binding: {vector['id']}")
        elif not rejected:
            fail(f"schema accepted negative vector {vector['id']}")
    missing_context = copy.deepcopy(request)
    del missing_context["chunk"]["contextRevision"]
    if not schema_rejects(missing_context, schemas):
        fail("schema accepted a replay chunk without contextRevision")

    try:
        canonicalize_strict_json(activity["rawStrictJson"]["valid"])
    except ValueError as error:
        fail(f"valid raw strict JSON vector failed: {error}")
    for vector in activity["rawStrictJson"]["duplicateKeyCases"]:
        try:
            canonicalize_strict_json(vector["raw"])
        except ValueError as error:
            if str(error) != vector["expectedError"]:
                fail(f"raw strict JSON vector returned wrong error: {vector['id']}")
        else:
            fail(f"raw strict JSON accepted duplicate vector: {vector['id']}")

    v1_activity = strict_json_bytes(
        native_manifest_path(canonical_dependency["path"]).read_bytes(),
        "V1/TestVectors/capture-admission-activity.json",
    )
    if (
        activity["requestIdentity"]["canonicalization"] != "elu-canonical-json-v1"
        or v1_activity["canonicalization"]["algorithm"] != "elu-canonical-json-v1"
    ):
        fail("replay request identity does not reuse elu-canonical-json-v1")
    for vector in v1_activity["canonicalization"]["cases"]:
        validate_raw_canonical_vector(vector)
    supplement = activity["canonicalizationSupplement"]
    if (
        supplement["algorithm"] != "elu-canonical-json-v1"
        or supplement["integerRule"]
        != "exact-signed-int64-across-integer-decimal-and-exponent-spellings"
        or supplement["fallbackRule"] != "finite-binary64-then-JSON.stringify"
    ):
        fail("canonical number supplement metadata drifted")
    for vector in supplement["cases"]:
        validate_raw_canonical_vector(vector)

    for vector in activity["safeIntegerParity"]["cases"]:
        value = json.loads(vector["raw"])
        accepted = (
            isinstance(value, (int, float))
            and not isinstance(value, bool)
            and float(value).is_integer()
            and 0 <= value <= MAXIMUM_SAFE_INTEGER
        )
        expected = "accept" if accepted else "reject"
        if expected != vector["expect"]:
            fail(f"safe-integer vector drifted: {vector['raw']}")
        candidate = copy.deepcopy(replay)
        candidate["sequence"] = value
        try:
            validate_schema_instance(
                candidate,
                schemas["replay.schema.json"],
                "replay.schema.json",
                schemas,
            )
        except SchemaViolation:
            schema_accepted = False
        else:
            schema_accepted = True
        if schema_accepted != accepted:
            fail(f"replay schema safe-integer parity drifted: {vector['raw']}")
        if accepted and canonical_number(vector["raw"]) != vector["canonical"]:
            fail(f"safe-integer canonical form drifted: {vector['raw']}")
    for invalid in (True, math.nan, math.inf, -math.inf):
        candidate = copy.deepcopy(replay)
        candidate["sequence"] = invalid
        try:
            validate_schema_instance(
                candidate,
                schemas["replay.schema.json"],
                "replay.schema.json",
                schemas,
            )
        except SchemaViolation:
            continue
        fail(f"replay schema accepted non-integer sequence {invalid!r}")

    codec = activity["codecPayload"]
    compressed = base64.b64decode(replay["payload"], validate=True)
    if (
        replay["codec"] != codec["codec"]
        or replay["compression"] != codec["compression"]
        or codec["compressionPasses"] != 1
        or len(compressed) != codec["compressedLength"]
        or "sha256:" + sha256(compressed) != codec["compressedSha256"]
        or base64.b64encode(compressed).decode("ascii") != codec["compressedBase64"]
    ):
        fail("compressed replay codec fixture drifted")
    decompressed, records = admit_browser_dom_payload(replay["payload"], activity["constants"])
    if (
        decompressed.startswith(b"\x1f\x8b")
        or len(decompressed) != codec["decompressedLength"]
        or "sha256:" + sha256(decompressed) != codec["decompressedSha256"]
        or base64.b64encode(decompressed).decode("ascii") != codec["decompressedBase64"]
    ):
        fail("replay codec is empty, nested-compressed, or not byte exact")
    if (
        len(records) != codec["recordCount"]
        or [record["type"] for record in records] != codec["orderedRecordTypes"]
        or canonical_json(records).encode("utf-8") != decompressed
        or records[1]["data"]["node"]["childNodes"][1]["childNodes"][1]["childNodes"][0]["childNodes"][0]["textContent"]
        != codec["maskedText"]
    ):
        fail("decompressed replay codec ordering or masking drifted")

    admission = activity["payloadAdmission"]
    if admission["failure"] != {"disposition": "permanent", "acknowledgement": "none"}:
        fail("payload admission failure disposition drifted")
    for vector in admission["exactLimitCases"]:
        encoded = construct_payload_case(vector["construction"], replay["payload"], activity["constants"])
        exact_decoded, exact_records = admit_browser_dom_payload(encoded, activity["constants"])
        if len(exact_records) != vector["expectedLogicalRecords"]:
            fail(f"payload exact-limit record count drifted: {vector['id']}")
        if "expectedDecodedBytes" in vector and len(exact_decoded) != vector["expectedDecodedBytes"]:
            fail(f"payload exact decoded limit drifted: {vector['id']}")
        if (
            "expectedNestingDepth" in vector
            and vector["expectedNestingDepth"] != activity["constants"]["maximumJsonNestingDepth"]
        ):
            fail(f"payload exact nesting limit drifted: {vector['id']}")
    for vector in admission["negativeCases"]:
        encoded = construct_payload_case(vector["construction"], replay["payload"], activity["constants"])
        try:
            admit_browser_dom_payload(encoded, activity["constants"])
        except AdmissionError as error:
            if error.code != vector["expectedError"]:
                fail(
                    f"payload negative {vector['id']} returned {error.code}, "
                    f"expected {vector['expectedError']}"
                )
        else:
            fail(f"payload negative vector was accepted: {vector['id']}")

    identity = activity["requestIdentity"]
    chunk_bytes, material, computed_request_id = request_identity(request["chunk"])
    canonical_request = canonical_json(request).encode("utf-8")
    expected_values = {
        "canonicalChunkLength": len(chunk_bytes),
        "canonicalChunkLengthUint32beHex": struct.pack(">I", len(chunk_bytes)).hex(),
        "canonicalChunkSha256": "sha256:" + sha256(chunk_bytes),
        "canonicalChunkBase64": base64.b64encode(chunk_bytes).decode("ascii"),
        "materialLength": len(material),
        "materialSha256": "sha256:" + sha256(material),
        "requestId": computed_request_id,
        "canonicalRequestLength": len(canonical_request),
        "canonicalRequestSha256": "sha256:" + sha256(canonical_request),
        "canonicalRequestBase64": base64.b64encode(canonical_request).decode("ascii"),
    }
    for field, actual_value in expected_values.items():
        if identity[field] != actual_value:
            fail(f"request identity vector {field} drifted")
    if request["requestId"] != computed_request_id:
        fail("requestId is not the canonical replay chunk identity")

    masking = activity["masking"]
    profile_bytes = canonical_json(masking["profile"]).encode("utf-8")
    if (
        base64.b64encode(profile_bytes).decode("ascii") != masking["canonicalProfileBase64"]
        or "sha256:" + sha256(profile_bytes) != masking["maskingProfileHash"]
        or replay["privacy"]["maskingProfileHash"] != masking["maskingProfileHash"]
        or replay["privacy"]["appliedBeforeSerialization"] is not True
        or replay["privacy"]["secureInputsMasked"] is not True
        or masking["outerAuditAssertionConstants"]
        != {"appliedBeforeSerialization": True, "secureInputsMasked": True}
    ):
        fail("masking profile or outer audit assertion drifted")
    for relative, expected in activity["artifactCatalog"].items():
        if "sha256:" + sha256((SNAPSHOT / relative).read_bytes()) != expected:
            fail(f"artifact catalog drifted for {relative}")

    if not acknowledgement_matches(request, acknowledgement):
        fail("canonical acknowledgement is not bound to its request")
    for field, replacement in (
        ("requestId", "request_" + "0" * 64),
        ("replayId", "replay_other"),
        ("chunkId", "chunk_other"),
        ("sequence", 2),
        ("result", "retryable"),
    ):
        candidate = dict(acknowledgement)
        candidate[field] = replacement
        if acknowledgement_matches(request, candidate):
            fail(f"acknowledgement binding ignored {field}")

    aggregate = activity["aggregateQueueAccounting"]
    constants = activity["constants"]
    if constants["idempotencyRetentionSeconds"] <= constants["maximumRecordAgeSeconds"]:
        fail("idempotency retention does not exceed client record age")
    for vector in aggregate["cases"]:
        count = vector["eventMutationCount"] + vector["replayCount"]
        byte_count = vector["eventMutationBytes"] + vector["replayRequestBytes"]
        byte_limit = min(vector["configQueueBytes"], constants["maximumAggregateQueueBytes"])
        replay_limit = min(config["limits"]["replayChunkBytes"], constants["maximumReplayRequestBytes"])
        admitted = (
            count <= constants["maximumAggregateQueueRecords"]
            and byte_count <= byte_limit
            and vector["replayRequestBytes"] <= replay_limit
        )
        if (
            count != vector["expectedCount"]
            or byte_count != vector["expectedBytes"]
            or admitted != vector["admit"]
        ):
            fail(f"aggregate queue vector drifted: {vector['id']}")

    invalidation_actions = {vector["id"]: vector["action"] for vector in activity["invalidation"]["cases"]}
    for identifier in (
        "replay-disabled",
        "integration-revoked",
        "identity-opted-out",
        "region-block",
        "region-unknown",
        "masking-profile-stricter",
        "masking-profile-incomparable",
        "transport-pair-removed",
    ):
        if invalidation_actions.get(identifier) != "purge":
            fail(f"invalidation must purge: {identifier}")
    for identifier in ("config-expired", "config-fetch-failed", "wall-clock-untrusted"):
        if invalidation_actions.get(identifier) != "preserve-and-block-send":
            fail(f"invalidation must preserve and block: {identifier}")
    for identifier in (
        "masking-profile-equal",
        "masking-profile-looser",
        "context-revision-changed",
        "sampling-changed",
        "budget-decremented",
        "identity-reset-sealed-row",
    ):
        if invalidation_actions.get(identifier) != "preserve":
            fail(f"invalidation must preserve: {identifier}")

    rows = activity["scheduling"]["rows"]
    for vector in activity["scheduling"]["cases"]:
        per_replay_head: dict[str, dict[str, Any]] = {}
        for row in rows:
            current = per_replay_head.get(row["replayId"])
            if current is None or row["sequence"] < current["sequence"]:
                per_replay_head[row["replayId"]] = row
        eligible = [row for row in per_replay_head.values() if row["eligibleAt"] <= vector["now"]]
        selected = min(eligible, key=lambda row: row["globalOrdinal"])
        if (
            selected["replayId"] != vector["expectedReplayId"]
            or selected["sequence"] != vector["expectedSequence"]
        ):
            fail("multi-replay scheduling vector drifted")

    generation = activity["generationQueue"]
    if (
        generation["persistedField"] != "replayProtocolGeneration"
        or generation["comparisonPoint"] != "before-any-send-attempt"
        or generation["serverRecordsCurrentGeneration"] is not True
        or generation["serverRecordProvesClientCaptureGeneration"] is not False
    ):
        fail("generation queue metadata drifted")
    for vector in generation["cases"]:
        if classify_generation_row(vector) != vector["expectedAction"]:
            fail(f"generation queue action drifted: {vector['id']}")

    idempotency = activity["idempotency"]
    if (
        idempotency["requestScope"] != ["siteId", "requestId"]
        or idempotency["requestBinding"] != ["canonicalRequestSha256"]
        or idempotency["semanticScope"] != ["siteId", "replayId", "chunkId"]
        or idempotency["orderingScope"] != ["siteId", "replayId", "sequence"]
    ):
        fail("site-scoped idempotency keys drifted")
    initial = idempotency["initial"]
    for vector in idempotency["cases"]:
        candidate = {**initial, **vector["overrides"]}
        result, conflict_scope = resolve_replay_idempotency(initial, candidate)
        if result != vector["expected"]:
            fail(f"idempotency result drifted: {vector['id']}")
        if result == "same-stored-effective-ack":
            if acknowledgement != fixtures[initial["storedResponseFixture"]]:
                fail("exact duplicate does not reuse the stored effective acknowledgement")
        elif result == "permanent-conflict":
            response = {
                **conflict_fixture,
                "requestId": candidate["requestId"],
                "conflictScope": conflict_scope,
            }
            validate_fixture(response, "schemas/replay-error.schema.json", schemas, vector["id"])
            if (
                conflict_scope != vector["conflictScope"]
                or response["status"] != 409
                or response["disposition"] != "permanent"
                or "result" in response
                or acknowledgement_matches(request, response)
            ):
                fail(f"idempotency conflict minted a false acknowledgement: {vector['id']}")

    readback = load("readback-expectations.json")
    privacy_evidence = readback["expectedReadback"]["privacyEvidence"]
    planted_secret = privacy_evidence["plantedSecretMarker"]
    if (
        readback["verificationStatus"] != "pending-external-verification"
        or readback["blocking"] is not True
        or privacy_evidence["clientAssertionsAloneAreSufficient"] is not False
        or any(
            privacy_evidence[field] != 0
            for field in (
                "expectedOccurrencesInAcceptedRequest",
                "expectedOccurrencesInStoredPayload",
                "expectedOccurrencesInRenderedReplay",
            )
        )
        or planted_secret in canonical_json(request)
        or planted_secret.encode() in decompressed
        or readback["expectedReadback"]["request"]["requestId"] != request["requestId"]
        or readback["expectedReadback"]["request"]["canonicalRequestSha256"]
        != "sha256:" + sha256(canonical_request)
    ):
        fail("external readback privacy evidence drifted")

    verify_public_contract_clean()
    verify_unwired()
    executable_vectors = (
        len(activity["negativeRequests"])
        + len(activity["rawStrictJson"]["duplicateKeyCases"])
        + len(v1_activity["canonicalization"]["cases"])
        + len(supplement["cases"])
        + len(activity["safeIntegerParity"]["cases"])
        + len(admission["exactLimitCases"])
        + len(admission["negativeCases"])
        + len(activity["configCaching"]["cases"])
        + len(aggregate["cases"])
        + len(activity["invalidation"]["cases"])
        + len(activity["scheduling"]["cases"])
        + len(generation["cases"])
        + len(idempotency["cases"])
    )
    print(
        f"validated {len(checksums)} config/replay v2 artifacts, manifest closure, "
        f"{executable_vectors} executable vectors, request identity, payload admission, "
        "config caching, collisions, privacy evidence, and acknowledgement binding"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
