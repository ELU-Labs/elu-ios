#!/usr/bin/env python3
"""Run the 0.1.0-to-candidate simulator upgrade evidence harness."""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE_TAG = "0.1.0"
BUNDLE_ID = "dev.elu.sdk-upgrade-evidence"
HARNESS_RELATIVE = pathlib.Path("UpgradeEvidence/0.1.0/Harness")
TEMPLATE = ROOT / "UpgradeEvidence" / "0.1.0" / "manifest.json"
RESOLUTION_INVENTORY = ROOT / "UpgradeEvidence" / "0.1.0" / "dependency-resolutions.json"
APP_NAME = "EluUpgradeHarness.app"
RESULT_NAMES = {
    "source": "elu-upgrade-source-result.json",
    "candidate": "elu-upgrade-candidate-result.json",
}
INVALID_RESULT_NAME = "elu-upgrade-invalid-result.json"
EVENT_NAMES = {
    "source": "elu_sdk_upgrade_source",
    "candidate": "elu_sdk_upgrade_candidate",
}
TELEMETRY_METHOD = "POST"
TELEMETRY_PATH = "/batch"
FLAGS_PATH = "/flags?v=2"
CONFIG_PATH = "/v1/upgrade-evidence/config"
MARKER_WAIT_SECONDS = 45
RUN_RESULT_WAIT_SECONDS = 45
MAX_CAPTURE_BODY_BYTES = 8 * 1024 * 1024
GZIP_INPUT_CHUNK_BYTES = 64 * 1024
MAX_DECOMPRESSED_BODY_BYTES = 8 * 1024 * 1024
HARNESS_SOURCE = ROOT / HARNESS_RELATIVE / "AppDelegate.swift"
HARNESS_DIAGNOSTIC_PATH = f"{HARNESS_RELATIVE.as_posix().casefold()}/appdelegate.swift"
BUILD_PREFIXES = {"source": "SOURCE", "candidate": "CANDIDATE"}
MARKER_STAGE_PRECEDENCE = (
    "markerObserved",
    "markerSessionAbsent",
    "markerIdentityAbsent",
    "batchUnreadable",
    "markerEventAbsent",
)
COMPILER_ORIGINS = {
    "HARNESS_BOOTSTRAP": "the harness bootstrap",
    "HARNESS_VIEW": "the harness view",
    "HARNESS_CONFIG": "the harness config call",
    "HARNESS_IDENTITY": "the harness identity probe",
    "HARNESS_RESULT": "the harness result writer",
    "SDK": "the ELU SDK source",
    "DEPENDENCY": "the resolved dependency source",
    "UNKNOWN": "an unclassified build source",
}
COMPILER_CATEGORIES = {
    "AVAILABILITY": "an API availability error",
    "CONCURRENCY": "a concurrency isolation error",
    "API": "an API or type-checking error",
    "OTHER": "another compiler error",
}
COMPILER_ORIGIN_PRIORITY = (
    "HARNESS_BOOTSTRAP",
    "HARNESS_VIEW",
    "HARNESS_CONFIG",
    "HARNESS_IDENTITY",
    "HARNESS_RESULT",
    "SDK",
    "DEPENDENCY",
    "UNKNOWN",
)
COMPILER_CATEGORY_PRIORITY = ("AVAILABILITY", "CONCURRENCY", "API", "OTHER")
RUN_RESULT_FAILURES = {
    "RESULT_MISSING": "did not write its result before the runner deadline",
    "RESULT_SCHEMA_INVALID": "wrote a result that did not match the fixed result schema",
    "RESULT_BUILD_MISMATCH": "wrote a result for a different build role",
    "ENVIRONMENT_INVALID": "reported that its fixed launch environment was invalid",
    "IDENTITY_FALSE": "reported that the expected identity was not observed",
}
CONFIG_GET_OBSERVATIONS = {
    True: ("CONFIG_GET_OBSERVED", "the exact configuration GET was observed"),
    False: ("CONFIG_GET_NOT_OBSERVED", "the exact configuration GET was not observed"),
}
MARKER_BLOCKER_CODES = {
    "source": {
        "exactBatchNotObserved": "SOURCE_EXACT_BATCH_NOT_OBSERVED",
        "batchUnreadable": "SOURCE_BATCH_UNREADABLE",
        "markerEventAbsent": "SOURCE_MARKER_EVENT_ABSENT",
        "markerIdentityAbsent": "SOURCE_MARKER_IDENTITY_ABSENT",
        "markerSessionAbsent": "SOURCE_MARKER_SESSION_ABSENT",
    },
    "candidate": {
        "exactBatchNotObserved": "CANDIDATE_EXACT_BATCH_NOT_OBSERVED",
        "batchUnreadable": "CANDIDATE_BATCH_UNREADABLE",
        "markerEventAbsent": "CANDIDATE_MARKER_EVENT_ABSENT",
        "markerIdentityAbsent": "CANDIDATE_MARKER_IDENTITY_ABSENT",
        "markerSessionAbsent": "CANDIDATE_MARKER_SESSION_ABSENT",
    },
}
BLOCKER_DETAILS = {
    "FULL_XCODE_REQUIRED": "The selected developer directory does not provide Xcode and the iOS Simulator tools.",
    "CANDIDATE_CHECKOUT_DIRTY": "The candidate checkout must be clean so its revision exactly identifies the tested source.",
    "OUTPUT_MUST_BE_EXTERNAL": "The evidence output directory must be outside the repository.",
    "SOURCE_ARCHIVE_FAILED": "The immutable source version could not be materialized for the harness.",
    "SOURCE_TAG_MISMATCH": "The source tag does not resolve to the revision recorded by the historical inventory.",
    "CANDIDATE_ARCHIVE_FAILED": "The clean candidate revision could not be materialized for the harness.",
    "SIMULATOR_UNAVAILABLE": "No available iOS Simulator runtime and phone device type could be prepared.",
    "SOURCE_BUILD_FAILED": "The source-version harness did not compile for the selected simulator.",
    "CANDIDATE_BUILD_FAILED": "The candidate harness did not compile for the selected simulator.",
    "SOURCE_BUILD_DEPENDENCY_RESOLUTION_FAILED": "The source-version harness dependency graph did not resolve.",
    "CANDIDATE_BUILD_DEPENDENCY_RESOLUTION_FAILED": "The candidate harness dependency graph did not resolve.",
    "SOURCE_BUILD_CONFIGURATION_FAILED": "The source-version harness project configuration was invalid.",
    "CANDIDATE_BUILD_CONFIGURATION_FAILED": "The candidate harness project configuration was invalid.",
    "SOURCE_BUILD_COMPILATION_FAILED": "The source-version harness or package source did not compile.",
    "CANDIDATE_BUILD_COMPILATION_FAILED": "The candidate harness or package source did not compile.",
    "SOURCE_BUILD_LINK_FAILED": "The source-version harness did not link.",
    "CANDIDATE_BUILD_LINK_FAILED": "The candidate harness did not link.",
    "SOURCE_BUILD_PRODUCT_MISSING": "The source-version build completed without the expected app product.",
    "CANDIDATE_BUILD_PRODUCT_MISSING": "The candidate build completed without the expected app product.",
    "DEPENDENCY_RESOLUTION_MISSING": "An exact dependency version and revision were not present in resolved build state.",
    "HISTORICAL_TAG_AUTHENTICATION_FAILED": "The resolved source dependency checkout did not authenticate the dated tag observation.",
    "SOURCE_RUN_FAILED": "The source-version application did not establish observable identity and session evidence.",
    "CANDIDATE_RUN_FAILED": "The candidate application did not produce its same-container continuity result.",
    "SOURCE_EXACT_BATCH_NOT_OBSERVED": "No exact source-version telemetry batch request was observed after launch.",
    "SOURCE_BATCH_UNREADABLE": "A source-version telemetry batch request was observed, but its fixed envelope could not be read.",
    "SOURCE_MARKER_EVENT_ABSENT": "Readable source-version telemetry batches did not contain the fixed marker event.",
    "SOURCE_MARKER_IDENTITY_ABSENT": "The source-version marker event did not contain a non-empty identity.",
    "SOURCE_MARKER_SESSION_ABSENT": "The source-version marker event did not contain a non-empty session identifier.",
    "CANDIDATE_EXACT_BATCH_NOT_OBSERVED": "No exact candidate telemetry batch request was observed after launch.",
    "CANDIDATE_BATCH_UNREADABLE": "A candidate telemetry batch request was observed, but its fixed envelope could not be read.",
    "CANDIDATE_MARKER_EVENT_ABSENT": "Readable candidate telemetry batches did not contain the fixed marker event.",
    "CANDIDATE_MARKER_IDENTITY_ABSENT": "The candidate marker event did not contain a non-empty identity.",
    "CANDIDATE_MARKER_SESSION_ABSENT": "The candidate marker event did not contain a non-empty session identifier.",
    "RAW_CAPTURE_INCOMPLETE": "Observable network evidence did not contain both source and candidate session markers.",
    "UNEXPECTED_RUNNER_FAILURE": "The simulator evidence runner stopped before all required checks completed.",
}
for build_prefix, build_label in (("SOURCE", "source-version"), ("CANDIDATE", "candidate")):
    for origin_code, origin_label in COMPILER_ORIGINS.items():
        for category_code, category_label in COMPILER_CATEGORIES.items():
            BLOCKER_DETAILS[f"{build_prefix}_BUILD_COMPILE_{origin_code}_{category_code}"] = (
                f"The {build_label} build reported {category_label} in {origin_label}."
            )
    for failure_code, failure_label in RUN_RESULT_FAILURES.items():
        for observation_code, observation_label in CONFIG_GET_OBSERVATIONS.values():
            BLOCKER_DETAILS[f"{build_prefix}_RUN_{failure_code}_{observation_code}"] = (
                f"The {build_label} application {failure_label}; {observation_label}."
            )


class HarnessBlocked(RuntimeError):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def harness_compiler_origin(line_number: int) -> str:
    try:
        lines = HARNESS_SOURCE.read_text(encoding="utf-8").splitlines()
    except OSError:
        return "HARNESS_BOOTSTRAP"
    if line_number < 1 or line_number > len(lines):
        return "HARNESS_BOOTSTRAP"

    def line_of(fragment: str, default: int) -> int:
        return next((index for index, line in enumerate(lines, start=1) if fragment in line), default)

    view_start = line_of("private struct UpgradeEvidenceView", len(lines) + 1)
    probe_start = line_of("private enum UpgradeProbe", len(lines) + 1)
    result_start = line_of("private struct UpgradeResult", len(lines) + 1)
    app_start = line_of("@main", len(lines) + 1)
    write_start = line_of("private static func write", len(lines) + 1)
    if result_start <= line_number < app_start or write_start <= line_number:
        return "HARNESS_RESULT"
    if view_start <= line_number < probe_start:
        return "HARNESS_VIEW"

    source_line = lines[line_number - 1].casefold()
    if "elu.setup" in source_line or "elusetupoptions" in source_line:
        return "HARNESS_CONFIG"
    identity_tokens = (
        "expectedidentity",
        "elu.identify",
        "elu.distinctid",
        "identitykey",
        "waitforidentity",
    )
    if any(token in source_line for token in identity_tokens):
        return "HARNESS_IDENTITY"
    return "HARNESS_BOOTSTRAP"


def compiler_error_category(message: str) -> str:
    normalized = message.casefold()
    category_markers = (
        ("AVAILABILITY", ("only available in", "unavailable", "introduced in", "requires ios")),
        (
            "CONCURRENCY",
            (
                "actor-isolated",
                "main actor",
                "sendable",
                "concurrency",
                "data race",
                "task-isolated",
            ),
        ),
        (
            "API",
            (
                "has no member",
                "cannot find",
                "extra argument",
                "missing argument",
                "incorrect argument label",
                "no exact matches",
                "ambiguous use",
                "cannot convert value of type",
                "does not conform to protocol",
                "inaccessible due to",
                "must be declared internal",
            ),
        ),
    )
    for category, markers in category_markers:
        if any(marker in normalized for marker in markers):
            return category
    return "OTHER"


def classify_compiler_failure(build: str, diagnostic: str) -> str | None:
    prefix = BUILD_PREFIXES.get(build)
    if prefix is None:
        return "UNEXPECTED_RUNNER_FAILURE"
    error_pattern = re.compile(
        r"(?P<path>.+?\.(?:swift|m|mm|c|cc|cpp|cxx|h|hh|hpp|hxx)):"
        r"(?P<line>\d+)(?::(?P<column>\d+))?:\s*(?:fatal\s+)?error:\s*(?P<message>.*)",
        re.IGNORECASE,
    )
    records: list[tuple[str, int, str]] = []
    for raw_line in diagnostic.splitlines():
        match = error_pattern.search(raw_line)
        if match is not None:
            records.append((match.group("path"), int(match.group("line")), match.group("message")))
    if not records:
        normalized_diagnostic = diagnostic.casefold()
        compiler_markers = (
            "emit-swiftmodule command failed",
            "emit-module command failed",
            "swift compiler error",
            "compilec command failed",
        )
        if not any(marker in normalized_diagnostic for marker in compiler_markers):
            return None
        return f"{prefix}_BUILD_COMPILE_UNKNOWN_OTHER"

    classified: list[tuple[str, str]] = []
    for path, line_number, message in records:
        normalized_path = path.replace("\\", "/").casefold()
        if "/checkouts/" in normalized_path or "/sourcepackages/" in normalized_path:
            origin = "DEPENDENCY"
        elif "/sources/eluanalytics/" in normalized_path:
            origin = "SDK"
        elif normalized_path == HARNESS_DIAGNOSTIC_PATH or normalized_path.endswith(
            f"/{HARNESS_DIAGNOSTIC_PATH}"
        ):
            origin = harness_compiler_origin(line_number)
        else:
            origin = "UNKNOWN"
        classified.append((origin, compiler_error_category(message)))
    origin_rank = {origin: index for index, origin in enumerate(COMPILER_ORIGIN_PRIORITY)}
    category_rank = {category: index for index, category in enumerate(COMPILER_CATEGORY_PRIORITY)}
    origin, category = min(
        set(classified),
        key=lambda item: (origin_rank[item[0]], category_rank[item[1]]),
    )
    return f"{prefix}_BUILD_COMPILE_{origin}_{category}"


def classify_build_failure(build: str, stdout: bytes, stderr: bytes) -> str:
    prefix = BUILD_PREFIXES.get(build)
    if prefix is None:
        return "UNEXPECTED_RUNNER_FAILURE"
    diagnostic = (stdout + b"\n" + stderr).decode("utf-8", errors="replace").casefold()
    categories = (
        (
            "DEPENDENCY_RESOLUTION_FAILED",
            (
                "could not resolve package dependencies",
                "failed to resolve dependencies",
                "failed to clone repository",
                "couldn't update repository",
                "package resolution errors must be fixed",
            ),
        ),
        (
            "CONFIGURATION_FAILED",
            (
                "missing package product",
                "does not contain a scheme named",
                "is not currently configured for the build action",
                "unable to find a destination matching",
                "could not open project",
            ),
        ),
        (
            "LINK_FAILED",
            (
                "linker command failed",
                "undefined symbols for architecture",
                "ld: symbol(s) not found",
            ),
        ),
    )
    for category, markers in categories:
        if any(marker in diagnostic for marker in markers):
            return f"{prefix}_BUILD_{category}"
    compiler_code = classify_compiler_failure(build, diagnostic)
    if compiler_code is not None:
        return compiler_code
    return f"{prefix}_BUILD_FAILED"


def inspect_run_result(
    build: str, payload: bytes | None
) -> tuple[dict[str, Any] | None, str | None]:
    if build not in BUILD_PREFIXES:
        return None, "UNEXPECTED_RUNNER_FAILURE"
    if payload is None:
        return None, "RESULT_MISSING"

    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate result key")
            result[key] = value
        return result

    try:
        loaded = json.loads(payload, object_pairs_hook=reject_duplicate_keys)
    except (UnicodeDecodeError, ValueError, RecursionError):
        return None, "RESULT_SCHEMA_INVALID"
    if not isinstance(loaded, dict) or set(loaded) != {"build", "identityCheck"}:
        return None, "RESULT_SCHEMA_INVALID"
    result_build = loaded.get("build")
    identity_check = loaded.get("identityCheck")
    if not isinstance(result_build, str) or not isinstance(identity_check, bool):
        return None, "RESULT_SCHEMA_INVALID"
    if result_build != build:
        return None, "RESULT_BUILD_MISMATCH"
    if identity_check is not True:
        return None, "IDENTITY_FALSE"
    return {"build": result_build, "identityCheck": True}, None


def result_file_stamp(path: pathlib.Path) -> tuple[int, int, int] | None:
    try:
        stat = path.stat()
    except OSError:
        return None
    return stat.st_ino, stat.st_size, stat.st_mtime_ns


def snapshot_result_files(documents: pathlib.Path) -> dict[str, tuple[int, int, int] | None]:
    names = {**RESULT_NAMES, "invalid": INVALID_RESULT_NAME}
    return {role: result_file_stamp(documents / name) for role, name in names.items()}


def inspect_changed_run_result(
    build: str,
    documents: pathlib.Path,
    before: dict[str, tuple[int, int, int] | None],
) -> tuple[dict[str, Any] | None, str | None]:
    if build not in BUILD_PREFIXES:
        return None, "UNEXPECTED_RUNNER_FAILURE"
    names = {**RESULT_NAMES, "invalid": INVALID_RESULT_NAME}
    changed = {
        role: path
        for role, name in names.items()
        if (path := documents / name).is_file()
        and result_file_stamp(path) != before.get(role)
    }
    expected = changed.get(build)
    if expected is not None:
        try:
            payload = expected.read_bytes()
        except OSError:
            payload = b""
        return inspect_run_result(build, payload)
    if "invalid" in changed:
        return None, "ENVIRONMENT_INVALID"
    for role in BUILD_PREFIXES:
        if role == build or role not in changed:
            continue
        try:
            payload = changed[role].read_bytes()
        except OSError:
            payload = b""
        return inspect_run_result(build, payload)
    return None, "RESULT_MISSING"


def should_retry_run_result(failure: str | None) -> bool:
    return failure == "RESULT_MISSING"


def run_result_blocker_code(build: str, failure: str, config_get_observed: bool) -> str:
    prefix = BUILD_PREFIXES.get(build)
    observation = CONFIG_GET_OBSERVATIONS.get(config_get_observed)
    if prefix is None or failure not in RUN_RESULT_FAILURES or observation is None:
        return "UNEXPECTED_RUNNER_FAILURE"
    return f"{prefix}_RUN_{failure}_{observation[0]}"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument(
        "--custody",
        choices=("external", "operator-managed", "runner-transient"),
        default="operator-managed",
    )
    return parser.parse_args()


def inside_repository(path: pathlib.Path) -> bool:
    try:
        path.resolve().relative_to(ROOT.resolve())
        return True
    except ValueError:
        return False


def write_json(path: pathlib.Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_command(
    command: list[str],
    *,
    code: str,
    diagnostics: pathlib.Path,
    cwd: pathlib.Path = ROOT,
    env: dict[str, str] | None = None,
    build_failure_role: str | None = None,
) -> bytes:
    try:
        result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, check=False)
    except OSError:
        raise HarnessBlocked(code) from None
    if result.returncode != 0:
        diagnostics.mkdir(parents=True, exist_ok=True)
        (diagnostics / f"{code.lower()}-stdout.log").write_bytes(result.stdout)
        (diagnostics / f"{code.lower()}-stderr.log").write_bytes(result.stderr)
        if build_failure_role is not None:
            raise HarnessBlocked(classify_build_failure(build_failure_role, result.stdout, result.stderr))
        raise HarnessBlocked(code)
    return result.stdout


def header_values(headers: Any, name: str) -> list[str]:
    get_all = getattr(headers, "get_all", None)
    if callable(get_all):
        values = get_all(name)
        if values is not None:
            return [str(value) for value in values]
    return [str(value) for key, value in headers.items() if str(key).casefold() == name.casefold()]


def decompress_gzip_bounded(
    body: bytes,
    *,
    max_output_bytes: int = MAX_DECOMPRESSED_BODY_BYTES,
) -> bytes | None:
    if max_output_bytes < 0:
        return None
    inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
    output = bytearray()
    try:
        for offset in range(0, len(body), GZIP_INPUT_CHUNK_BYTES):
            input_chunk = body[offset : offset + GZIP_INPUT_CHUNK_BYTES]
            pending = input_chunk
            while pending:
                remaining = max_output_bytes + 1 - len(output)
                if remaining <= 0:
                    return None
                before = len(pending)
                decoded = inflater.decompress(pending, remaining)
                output.extend(decoded)
                if len(output) > max_output_bytes:
                    return None
                pending = inflater.unconsumed_tail
                if pending and len(pending) == before and not decoded:
                    return None
            if inflater.eof:
                consumed_through = offset + len(input_chunk)
                if inflater.unused_data or consumed_through != len(body):
                    return None
                break
        if not inflater.eof or inflater.unused_data:
            return None
        remaining = max_output_bytes + 1 - len(output)
        output.extend(inflater.flush(remaining))
    except (ValueError, zlib.error):
        return None
    if len(output) > max_output_bytes:
        return None
    return bytes(output)


class CaptureLedger:
    def __init__(self, raw_directory: pathlib.Path):
        self.raw_directory = raw_directory
        self.capture_directory = raw_directory / "requests"
        self.capture_directory.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self.request_count = 0
        self.config_get_count = 0
        self.markers: dict[str, tuple[str, str]] = {}
        self.marker_request_numbers: dict[str, int] = {}
        self.batch_observations: dict[int, dict[str, str]] = {}

    def begin_request(self, method: str, path: str) -> int:
        with self.lock:
            self.request_count += 1
            if method == TELEMETRY_METHOD and path == TELEMETRY_PATH:
                self._record_unreadable_batch(self.request_count)
            return self.request_count

    def record(
        self,
        method: str,
        path: str,
        headers: dict[str, str],
        body: bytes,
        *,
        body_readable: bool = True,
        request_number: int | None = None,
    ) -> None:
        with self.lock:
            if request_number is None:
                self.request_count += 1
                request_number = self.request_count
            record = {
                "method": method,
                "path": path,
                "headers": dict(sorted(headers.items())),
                "bodyBase64": base64.b64encode(body).decode("ascii"),
            }
            write_json(self.capture_directory / f"request-{request_number:04d}.json", record)
            self._inspect(
                request_number,
                method,
                path,
                headers,
                body,
                body_readable=body_readable,
            )
            self._write_status()

    def _record_batch_observation(self, request_number: int, stages: dict[str, str]) -> None:
        self.batch_observations[request_number] = stages

    def _record_unreadable_batch(self, request_number: int) -> None:
        self._record_batch_observation(
            request_number,
            {build: "batchUnreadable" for build in EVENT_NAMES},
        )

    def _marker_stage(self, request_number: int, build: str, events: list[Any]) -> str:
        marker = EVENT_NAMES[build]
        matching = [event for event in events if isinstance(event, dict) and event.get("event") == marker]
        if not matching:
            return "markerEventAbsent"

        identity_present = False
        for event in matching:
            identity = event.get("distinct_id")
            if not isinstance(identity, str) or not identity:
                continue
            identity_present = True
            properties = event.get("properties")
            session = properties.get("$session_id") if isinstance(properties, dict) else None
            if isinstance(session, str) and session:
                previous_request = self.marker_request_numbers.get(build)
                if previous_request is None or request_number >= previous_request:
                    self.markers[build] = (identity, session)
                    self.marker_request_numbers[build] = request_number
                return "markerObserved"
        return "markerSessionAbsent" if identity_present else "markerIdentityAbsent"

    def _inspect(
        self,
        request_number: int,
        method: str,
        path: str,
        headers: dict[str, str],
        body: bytes,
        *,
        body_readable: bool,
    ) -> None:
        if method == "GET" and path == CONFIG_PATH:
            self.config_get_count += 1
        if method != TELEMETRY_METHOD or path != TELEMETRY_PATH:
            return
        if not body_readable:
            self._record_unreadable_batch(request_number)
            return
        encodings = header_values(headers, "Content-Encoding")
        if len(encodings) > 1:
            self._record_unreadable_batch(request_number)
            return
        content_encoding = encodings[0].strip().casefold() if encodings else ""
        if content_encoding == "gzip":
            decompressed = decompress_gzip_bounded(body)
            if decompressed is None:
                self._record_unreadable_batch(request_number)
                return
            body = decompressed
        elif content_encoding not in ("", "identity"):
            self._record_unreadable_batch(request_number)
            return
        try:
            payload = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._record_unreadable_batch(request_number)
            return
        if not isinstance(payload, dict) or not isinstance(payload.get("batch"), list):
            self._record_unreadable_batch(request_number)
            return
        events = payload["batch"]
        self._record_batch_observation(
            request_number,
            {
                build: self._marker_stage(request_number, build, events)
                for build in EVENT_NAMES
            },
        )

    def observation_cursor(self) -> int:
        with self.lock:
            return self.request_count

    def _marker_blocker_code_locked(self, build: str, after_request: int) -> str | None:
        codes = MARKER_BLOCKER_CODES.get(build)
        if codes is None:
            return "UNEXPECTED_RUNNER_FAILURE"
        stages = {
            observation[build]
            for request_number, observation in self.batch_observations.items()
            if request_number > after_request
        }
        for stage in MARKER_STAGE_PRECEDENCE:
            if stage not in stages:
                continue
            if stage == "markerObserved":
                return None
            return codes[stage]
        return codes["exactBatchNotObserved"]

    def marker_blocker_code(self, build: str, *, after_request: int) -> str | None:
        with self.lock:
            return self._marker_blocker_code_locked(build, after_request)

    def raise_marker_timeout(self, build: str, *, after_request: int) -> None:
        with self.lock:
            request_number = self.marker_request_numbers.get(build)
            if request_number is not None and request_number > after_request:
                return
            blocker = self._marker_blocker_code_locked(build, after_request)
            if blocker is not None:
                raise HarnessBlocked(blocker)

    def _write_status(self) -> None:
        source = self.markers.get("source")
        candidate = self.markers.get("candidate")
        write_json(
            self.raw_directory / "capture-status.json",
            {
                "sourceMarkerObserved": source is not None,
                "candidateMarkerObserved": candidate is not None,
                "identityPreserved": source is not None and candidate is not None and source[0] == candidate[0],
                "sourceSessionPresent": source is not None and bool(source[1]),
                "candidateSessionPresent": candidate is not None and bool(candidate[1]),
                "sessionRotated": source is not None and candidate is not None and source[1] != candidate[1],
            },
        )

    def exact_config_get_count(self) -> int:
        with self.lock:
            return self.config_get_count

    def wait_for(
        self,
        build: str,
        timeout: float = MARKER_WAIT_SECONDS,
        *,
        after_request: int = 0,
    ) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock:
                request_number = self.marker_request_numbers.get(build)
                if request_number is not None and request_number > after_request:
                    return True
            time.sleep(0.2)
        with self.lock:
            request_number = self.marker_request_numbers.get(build)
            return request_number is not None and request_number > after_request


class EvidenceServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, ledger: CaptureLedger):
        super().__init__(("127.0.0.1", 0), EvidenceHandler)
        self.ledger = ledger

    @property
    def origin(self) -> str:
        return f"http://127.0.0.1:{self.server_port}"


class EvidenceHandler(BaseHTTPRequestHandler):
    server: EvidenceServer

    def log_message(self, format: str, *args: object) -> None:
        return

    def _record(
        self,
        request_number: int,
        body: bytes = b"",
        *,
        body_readable: bool = True,
    ) -> None:
        headers = {str(key): str(value) for key, value in self.headers.items()}
        content_encodings = header_values(self.headers, "Content-Encoding")
        self.server.ledger.record(
            self.command,
            self.path,
            headers,
            body,
            body_readable=body_readable and len(content_encodings) <= 1,
            request_number=request_number,
        )

    def _read_post_body(self) -> tuple[bytes, bool]:
        transfer_encodings = header_values(self.headers, "Transfer-Encoding")
        content_lengths = header_values(self.headers, "Content-Length")
        if transfer_encodings or len(content_lengths) != 1:
            self.close_connection = True
            return b"", False
        content_length = content_lengths[0].strip()
        if not re.fullmatch(r"[0-9]+", content_length) or len(content_length) > len(
            str(MAX_CAPTURE_BODY_BYTES)
        ):
            self.close_connection = True
            return b"", False
        length = int(content_length)
        if length > MAX_CAPTURE_BODY_BYTES:
            self.close_connection = True
            return b"", False
        try:
            body = self.rfile.read(length)
        except OSError:
            self.close_connection = True
            return b"", False
        if len(body) != length:
            self.close_connection = True
            return body, False
        return body, True

    def _respond(self, value: object, status: int = 200) -> None:
        data = json.dumps(value, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802
        request_number = self.server.ledger.begin_request(self.command, self.path)
        self._record(request_number)
        if self.path == CONFIG_PATH:
            self._respond(
                {
                    "v": 1,
                    "enabled": True,
                    "publicToken": "upgrade-evidence-token",
                    "host": self.server.origin,
                    "privacy": {
                        "blockEu": False,
                        "maskTextInputs": True,
                        "maskAllText": False,
                        "maskImages": False,
                        "replayNewUsersOnly": False,
                        "replayMaxMinutes": 0,
                    },
                }
            )
        else:
            self._respond({"supportedCompression": ["gzip"], "sessionRecording": False})

    def do_POST(self) -> None:  # noqa: N802
        request_number = self.server.ledger.begin_request(self.command, self.path)
        body, body_readable = self._read_post_body()
        self._record(request_number, body, body_readable=body_readable)
        if self.path == FLAGS_PATH:
            self._respond({"flags": {}, "featureFlags": {}})
        elif self.path == TELEMETRY_PATH:
            self._respond({"status": "ok"})
        else:
            self._respond({"status": "not-found"}, status=404)


def select_simulator(raw_directory: pathlib.Path) -> tuple[str, str, str]:
    diagnostics = raw_directory / "diagnostics"
    try:
        runtimes = json.loads(
            run_command(
                ["xcrun", "simctl", "list", "runtimes", "--json"],
                code="SIMULATOR_UNAVAILABLE",
                diagnostics=diagnostics,
            )
        )["runtimes"]
        device_types = json.loads(
            run_command(
                ["xcrun", "simctl", "list", "devicetypes", "--json"],
                code="SIMULATOR_UNAVAILABLE",
                diagnostics=diagnostics,
            )
        )["devicetypes"]
    except (KeyError, TypeError, json.JSONDecodeError):
        raise HarnessBlocked("SIMULATOR_UNAVAILABLE") from None
    ios_runtimes = [
        runtime
        for runtime in runtimes
        if runtime.get("isAvailable") and str(runtime.get("identifier", "")).startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
    ]
    phones = [device for device in device_types if str(device.get("name", "")).startswith("iPhone")]
    if not ios_runtimes or not phones:
        raise HarnessBlocked("SIMULATOR_UNAVAILABLE")
    runtime = sorted(ios_runtimes, key=lambda item: tuple(int(part) for part in item["version"].split(".")))[-1]
    preferred = next((device for device in phones if device.get("name") == "iPhone 16 Pro"), phones[-1])
    udid = run_command(
        ["xcrun", "simctl", "create", "ELU SDK Upgrade Evidence", preferred["identifier"], runtime["identifier"]],
        code="SIMULATOR_UNAVAILABLE",
        diagnostics=diagnostics,
    ).decode("utf-8").strip()
    run_command(
        ["xcrun", "simctl", "boot", udid],
        code="SIMULATOR_UNAVAILABLE",
        diagnostics=diagnostics,
    )
    run_command(
        ["xcrun", "simctl", "bootstatus", udid, "-b"],
        code="SIMULATOR_UNAVAILABLE",
        diagnostics=diagnostics,
    )
    return udid, runtime["version"], preferred["name"]


def materialize_source(work_directory: pathlib.Path, raw_directory: pathlib.Path) -> tuple[pathlib.Path, str]:
    inventory = json.loads(RESOLUTION_INVENTORY.read_text(encoding="utf-8"))
    source_revision = inventory["source"]["revision"]
    resolved_tag = run_command(
        ["git", "rev-parse", f"{SOURCE_TAG}^{{commit}}"],
        code="SOURCE_ARCHIVE_FAILED",
        diagnostics=raw_directory / "diagnostics",
    ).decode("utf-8").strip()
    if resolved_tag != source_revision:
        raise HarnessBlocked("SOURCE_TAG_MISMATCH")
    archive = run_command(
        ["git", "archive", "--format=tar", source_revision],
        code="SOURCE_ARCHIVE_FAILED",
        diagnostics=raw_directory / "diagnostics",
    )
    source_root = work_directory / "source-sdk"
    source_root.mkdir(parents=True)
    try:
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source_archive:
            source_archive.extractall(source_root)
        shutil.copytree(ROOT / HARNESS_RELATIVE, source_root / HARNESS_RELATIVE)
    except (OSError, tarfile.TarError):
        raise HarnessBlocked("SOURCE_ARCHIVE_FAILED") from None
    return source_root, source_revision


def materialize_candidate(work_directory: pathlib.Path, raw_directory: pathlib.Path) -> pathlib.Path:
    archive = run_command(
        ["git", "archive", "--format=tar", "HEAD"],
        code="CANDIDATE_ARCHIVE_FAILED",
        diagnostics=raw_directory / "diagnostics",
    )
    candidate_root = work_directory / "candidate-sdk"
    candidate_root.mkdir(parents=True)
    try:
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as candidate_archive:
            candidate_archive.extractall(candidate_root)
    except (OSError, tarfile.TarError):
        raise HarnessBlocked("CANDIDATE_ARCHIVE_FAILED") from None
    return candidate_root


def build_app(
    sdk_root: pathlib.Path,
    build: str,
    udid: str,
    work_directory: pathlib.Path,
    raw_directory: pathlib.Path,
) -> tuple[pathlib.Path, dict[str, Any]]:
    prefix = BUILD_PREFIXES.get(build)
    if prefix is None:
        raise HarnessBlocked("UNEXPECTED_RUNNER_FAILURE")
    code = f"{prefix}_BUILD_FAILED"
    derived_data = work_directory / f"{build}-derived-data"
    packages = work_directory / f"{build}-packages"
    project = sdk_root / HARNESS_RELATIVE / "UpgradeHarness.xcodeproj"
    run_command(
        [
            "xcodebuild",
            "build",
            "-project",
            str(project),
            "-scheme",
            "EluUpgradeHarness",
            "-configuration",
            "Debug",
            "-destination",
            f"id={udid}",
            "-derivedDataPath",
            str(derived_data),
            "-clonedSourcePackagesDirPath",
            str(packages),
            "-skipMacroValidation",
            "CODE_SIGNING_ALLOWED=NO",
        ],
        code=code,
        diagnostics=raw_directory / "diagnostics",
        cwd=sdk_root / HARNESS_RELATIVE,
        build_failure_role=build,
    )
    app = derived_data / "Build" / "Products" / "Debug-iphonesimulator" / APP_NAME
    if not app.is_dir():
        raise HarnessBlocked(f"{prefix}_BUILD_PRODUCT_MISSING")
    return app, resolved_dependency(
        packages,
        raw_directory,
        build=build,
        allow_absent=build == "candidate",
    )


def resolved_dependency(
    packages: pathlib.Path,
    raw_directory: pathlib.Path,
    *,
    build: str,
    allow_absent: bool,
) -> dict[str, Any]:
    inventory = json.loads(RESOLUTION_INVENTORY.read_text(encoding="utf-8"))
    blob = inventory["dependencyInventory"]["gitBlob"]
    frozen_inventory = run_command(
        ["git", "cat-file", "blob", blob],
        code="DEPENDENCY_RESOLUTION_MISSING",
        diagnostics=raw_directory / "diagnostics",
    )
    legal = json.loads(frozen_inventory)
    identity = legal["packages"][0]["identity"]
    graph_entries: dict[tuple[str, str | None, str | None], dict[str, Any]] = {}
    saw_resolved_graph = False
    matched_subpath: str | None = None
    for state_path in packages.rglob("workspace-state.json"):
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
            dependencies = state.get("object", state).get("dependencies", [])
        except (OSError, json.JSONDecodeError, AttributeError):
            continue
        if not isinstance(dependencies, list):
            continue
        saw_resolved_graph = True
        for dependency in dependencies:
            if not isinstance(dependency, dict):
                continue
            dependency_identity = dependency.get("packageRef", {}).get("identity")
            checkout = dependency.get("state", {}).get("checkoutState", {})
            version = checkout.get("version")
            revision = checkout.get("revision")
            normalized_version = version if isinstance(version, str) and version else None
            normalized_revision = revision if isinstance(revision, str) and revision else None
            if isinstance(dependency_identity, str) and dependency_identity:
                graph_entries[(dependency_identity, normalized_version, normalized_revision)] = {
                    "identity": dependency_identity,
                    "version": normalized_version,
                    "revision": normalized_revision,
                }
            if dependency_identity == identity and isinstance(dependency.get("subpath"), str):
                matched_subpath = dependency["subpath"]

    graph = {
        "schemaVersion": 1,
        "dependencies": sorted(
            graph_entries.values(),
            key=lambda item: (item["identity"], item["version"] or "", item["revision"] or ""),
        ),
    }
    graph_path = raw_directory / "resolved-package-graphs" / f"{build}.json"
    write_json(graph_path, graph)
    graph_digest = hashlib.sha256(graph_path.read_bytes()).hexdigest()

    matches = [entry for entry in graph["dependencies"] if entry["identity"] == identity]
    exact_matches = [
        entry
        for entry in matches
        if isinstance(entry["version"], str)
        and entry["version"]
        and isinstance(entry["revision"], str)
        and len(entry["revision"]) == 40
    ]
    if len(exact_matches) == 1:
        resolution = {"version": exact_matches[0]["version"], "revision": exact_matches[0]["revision"]}
        if build == "source":
            authenticate_historical_tag(packages, matched_subpath, inventory, raw_directory)
        return resolution
    if allow_absent and saw_resolved_graph and not matches:
        return {
            "status": "absent",
            "proof": {
                "kind": "resolved-package-graph-sha256",
                "sha256": graph_digest,
            },
        }
    write_json(raw_directory / "dependency-resolution-missing.json", {"resolved": False})
    raise HarnessBlocked("DEPENDENCY_RESOLUTION_MISSING")


def authenticate_historical_tag(
    packages: pathlib.Path,
    matched_subpath: str | None,
    inventory: dict[str, Any],
    raw_directory: pathlib.Path,
) -> None:
    observation = inventory["observations"][0]["annotatedTag"]
    checkout = packages / "checkouts" / (matched_subpath or "")
    if not matched_subpath or not checkout.is_dir():
        raise HarnessBlocked("HISTORICAL_TAG_AUTHENTICATION_FAILED")
    diagnostics = raw_directory / "diagnostics"
    name = observation["name"]
    object_revision = run_command(
        ["git", "rev-parse", f"refs/tags/{name}"],
        code="HISTORICAL_TAG_AUTHENTICATION_FAILED",
        diagnostics=diagnostics,
        cwd=checkout,
    ).decode("utf-8").strip()
    peeled_revision = run_command(
        ["git", "rev-parse", f"refs/tags/{name}^{{}}"],
        code="HISTORICAL_TAG_AUTHENTICATION_FAILED",
        diagnostics=diagnostics,
        cwd=checkout,
    ).decode("utf-8").strip()
    object_type = run_command(
        ["git", "cat-file", "-t", object_revision],
        code="HISTORICAL_TAG_AUTHENTICATION_FAILED",
        diagnostics=diagnostics,
        cwd=checkout,
    ).decode("utf-8").strip()
    if (
        object_type != "tag"
        or object_revision != observation["objectRevision"]
        or peeled_revision != observation["peeledSourceRevision"]
    ):
        raise HarnessBlocked("HISTORICAL_TAG_AUTHENTICATION_FAILED")
    payload = run_command(
        ["git", "cat-file", "tag", object_revision],
        code="HISTORICAL_TAG_AUTHENTICATION_FAILED",
        diagnostics=diagnostics,
        cwd=checkout,
    )
    (raw_directory / "historical-dependency-tag-object.txt").write_bytes(payload)


def install_and_run(
    app: pathlib.Path,
    build: str,
    udid: str,
    origin: str,
    ledger: CaptureLedger,
    raw_directory: pathlib.Path,
) -> tuple[pathlib.Path, bool]:
    prefix = BUILD_PREFIXES.get(build)
    if prefix is None:
        raise HarnessBlocked("UNEXPECTED_RUNNER_FAILURE")
    code = f"{prefix}_RUN_FAILED"
    diagnostics = raw_directory / "diagnostics"
    run_command(
        ["xcrun", "simctl", "install", udid, str(app)],
        code=code,
        diagnostics=diagnostics,
    )
    container = pathlib.Path(
        run_command(
            ["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"],
            code=code,
            diagnostics=diagnostics,
        ).decode("utf-8").strip()
    )
    environment = os.environ.copy()
    environment["SIMCTL_CHILD_ELU_UPGRADE_BUILD"] = build
    environment["SIMCTL_CHILD_ELU_UPGRADE_ORIGIN"] = origin
    config_gets_before_launch = ledger.exact_config_get_count()
    marker_observation_cursor = ledger.observation_cursor()
    result_documents = container / "Documents"
    result_files_before_launch = snapshot_result_files(result_documents)
    run_command(
        ["xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE_ID],
        code=code,
        diagnostics=diagnostics,
        env=environment,
    )
    deadline = time.monotonic() + RUN_RESULT_WAIT_SECONDS
    result: dict[str, Any] | None = None
    failure = "RESULT_MISSING"
    while time.monotonic() < deadline:
        result, inspected_failure = inspect_changed_run_result(
            build, result_documents, result_files_before_launch
        )
        if inspected_failure is None:
            break
        failure = inspected_failure
        if not should_retry_run_result(failure):
            break
        time.sleep(0.2)
    if result is None:
        config_get_observed = ledger.exact_config_get_count() > config_gets_before_launch
        raise HarnessBlocked(run_result_blocker_code(build, failure, config_get_observed))
    write_json(
        raw_directory / "application-results" / f"{build}.json",
        {"build": build, "identityCheck": True},
    )
    if not ledger.wait_for(build, after_request=marker_observation_cursor):
        ledger.raise_marker_timeout(build, after_request=marker_observation_cursor)
    run_command(
        ["xcrun", "simctl", "terminate", udid, BUNDLE_ID],
        code=code,
        diagnostics=diagnostics,
    )
    return container.resolve(), True


def archive_raw(raw_directory: pathlib.Path, output: pathlib.Path) -> str | None:
    if not raw_directory.exists() or not any(raw_directory.rglob("*")):
        return None
    archive = output / "raw-evidence.tar.gz"
    with tarfile.open(archive, "w:gz") as bundle:
        for path in sorted(raw_directory.rglob("*")):
            if path.is_file():
                bundle.add(path, arcname=path.relative_to(raw_directory).as_posix(), recursive=False)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / "raw-evidence.sha256").write_text(f"{digest}\n", encoding="utf-8")
    return digest


def base_manifest(custody: str) -> dict[str, Any]:
    manifest = json.loads(TEMPLATE.read_text(encoding="utf-8"))
    manifest["rawEvidence"]["custody"] = custody
    return manifest


def main() -> int:
    args = parse_args()
    output = args.output.resolve()
    if inside_repository(output):
        print("upgrade evidence blocked: OUTPUT_MUST_BE_EXTERNAL", file=sys.stderr)
        return 2
    output.mkdir(parents=True, exist_ok=True)
    raw_directory = output / "raw"
    raw_directory.mkdir(parents=True, exist_ok=True)
    work_directory = output / "work"
    work_directory.mkdir(parents=True, exist_ok=True)
    manifest = base_manifest(args.custody)
    simulator_udid: str | None = None
    server: EvidenceServer | None = None
    server_thread: threading.Thread | None = None
    status = 2

    try:
        xcode_version = run_command(
            ["xcodebuild", "-version"],
            code="FULL_XCODE_REQUIRED",
            diagnostics=raw_directory / "diagnostics",
        ).decode("utf-8").strip().replace("\n", " (", 1)
        if " (" in xcode_version:
            xcode_version += ")"
        simctl = run_command(
            ["xcrun", "--find", "simctl"],
            code="FULL_XCODE_REQUIRED",
            diagnostics=raw_directory / "diagnostics",
        )
        if not simctl.strip():
            raise HarnessBlocked("FULL_XCODE_REQUIRED")
        dirty = run_command(
            ["git", "status", "--porcelain"],
            code="CANDIDATE_CHECKOUT_DIRTY",
            diagnostics=raw_directory / "diagnostics",
        )
        if dirty.strip():
            raise HarnessBlocked("CANDIDATE_CHECKOUT_DIRTY")
        candidate_revision = run_command(
            ["git", "rev-parse", "HEAD"],
            code="UNEXPECTED_RUNNER_FAILURE",
            diagnostics=raw_directory / "diagnostics",
        ).decode("utf-8").strip()
        manifest["candidateRevision"] = candidate_revision

        source_root, source_revision = materialize_source(work_directory, raw_directory)
        manifest["sourceRevision"] = source_revision
        candidate_root = materialize_candidate(work_directory, raw_directory)
        simulator_udid, ios_version, _ = select_simulator(raw_directory)
        ledger = CaptureLedger(raw_directory)
        server = EvidenceServer(ledger)
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()

        source_app, source_resolution = build_app(
            source_root, "source", simulator_udid, work_directory, raw_directory
        )
        candidate_app, candidate_resolution = build_app(
            candidate_root, "candidate", simulator_udid, work_directory, raw_directory
        )
        source_container, _ = install_and_run(
            source_app, "source", simulator_udid, server.origin, ledger, raw_directory
        )
        candidate_container, identity_result = install_and_run(
            candidate_app, "candidate", simulator_udid, server.origin, ledger, raw_directory
        )

        source_marker = ledger.markers.get("source")
        candidate_marker = ledger.markers.get("candidate")
        observed = {
            "sameApplicationContainer": source_container == candidate_container,
            "identityPreserved": identity_result
            and source_marker is not None
            and candidate_marker is not None
            and source_marker[0] == candidate_marker[0],
            "sourceSessionPresent": source_marker is not None and bool(source_marker[1]),
            "candidateSessionPresent": candidate_marker is not None and bool(candidate_marker[1]),
            "sessionRotated": source_marker is not None
            and candidate_marker is not None
            and source_marker[1] != candidate_marker[1],
        }
        manifest["resolvedDependency"] = {
            "inventoryReference": "legal/THIRD_PARTY_NOTICES.dependencies.json",
            "source": source_resolution,
            "candidate": candidate_resolution,
        }
        run_environment = {
            "xcodeVersion": xcode_version,
            "iOSVersion": ios_version,
            "bundleId": BUNDLE_ID,
        }
        manifest["environment"] = run_environment
        manifest["observedContinuity"] = observed
        write_json(
            raw_directory / "run-provenance.json",
            {
                "candidateRevision": candidate_revision,
                "sourceVersion": SOURCE_TAG,
                "sourceRevision": source_revision,
                "resolvedDependency": {"source": source_resolution, "candidate": candidate_resolution},
                "environment": run_environment,
                "applicationContainer": {
                    "sourcePathSha256": hashlib.sha256(str(source_container).encode("utf-8")).hexdigest(),
                    "candidatePathSha256": hashlib.sha256(str(candidate_container).encode("utf-8")).hexdigest(),
                },
            },
        )
        if all(observed.values()):
            manifest["verificationStatus"] = "verified"
            manifest["blockers"] = []
            status = 0
        else:
            manifest["verificationStatus"] = "failed"
            manifest["blockers"] = [
                {
                    "code": "CONTINUITY_NOT_PRESERVED",
                    "detail": "At least one same-container identity or observable network-session check failed.",
                }
            ]
            status = 1
    except HarnessBlocked as error:
        manifest["verificationStatus"] = "blocked"
        manifest["observedContinuity"] = None
        manifest["blockers"] = [{"code": error.code, "detail": BLOCKER_DETAILS[error.code]}]
        write_json(raw_directory / "blocker.json", {"code": error.code})
        print(f"upgrade evidence blocked: {error.code}", file=sys.stderr)
    except Exception:
        manifest["verificationStatus"] = "blocked"
        manifest["observedContinuity"] = None
        manifest["blockers"] = [
            {"code": "UNEXPECTED_RUNNER_FAILURE", "detail": BLOCKER_DETAILS["UNEXPECTED_RUNNER_FAILURE"]}
        ]
        write_json(raw_directory / "blocker.json", {"code": "UNEXPECTED_RUNNER_FAILURE"})
        print("upgrade evidence blocked: UNEXPECTED_RUNNER_FAILURE", file=sys.stderr)
    finally:
        if server is not None:
            server.shutdown()
            server.server_close()
        if server_thread is not None:
            server_thread.join(timeout=5)
        if simulator_udid is not None:
            subprocess.run(
                ["xcrun", "simctl", "delete", simulator_udid],
                capture_output=True,
                check=False,
            )
        digest = archive_raw(raw_directory, output)
        if digest is not None:
            manifest["rawEvidence"] = {
                "sha256": digest,
                "custody": args.custody,
                "status": "captured",
            }
        write_json(output / "manifest.json", manifest)
        shutil.rmtree(raw_directory, ignore_errors=True)
        shutil.rmtree(work_directory, ignore_errors=True)

    if status == 0:
        print("upgrade evidence verified")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
