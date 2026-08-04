#!/usr/bin/env python3
"""Run the 0.1.0-to-candidate simulator upgrade evidence harness."""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import threading
import time
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
EVENT_NAMES = {
    "source": "elu_sdk_upgrade_source",
    "candidate": "elu_sdk_upgrade_candidate",
}
TELEMETRY_METHOD = "POST"
TELEMETRY_PATH = "/batch"
FLAGS_PATH = "/flags?v=2"
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
    "RAW_CAPTURE_INCOMPLETE": "Observable network evidence did not contain both source and candidate session markers.",
    "UNEXPECTED_RUNNER_FAILURE": "The simulator evidence runner stopped before all required checks completed.",
}


class HarnessBlocked(RuntimeError):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def classify_build_failure(build: str, stdout: bytes, stderr: bytes) -> str:
    prefix = build.upper()
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
        (
            "COMPILATION_FAILED",
            (
                "swiftcompile normal",
                "swiftemitmodule normal",
                "emit-swiftmodule command failed",
                "compilec ",
                " error:",
            ),
        ),
    )
    for category, markers in categories:
        if any(marker in diagnostic for marker in markers):
            return f"{prefix}_BUILD_{category}"
    return f"{prefix}_BUILD_FAILED"


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


class CaptureLedger:
    def __init__(self, raw_directory: pathlib.Path):
        self.raw_directory = raw_directory
        self.capture_directory = raw_directory / "requests"
        self.capture_directory.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self.request_count = 0
        self.markers: dict[str, tuple[str, str]] = {}

    def record(self, method: str, path: str, headers: dict[str, str], body: bytes) -> None:
        with self.lock:
            self.request_count += 1
            record = {
                "method": method,
                "path": path,
                "headers": dict(sorted(headers.items())),
                "bodyBase64": base64.b64encode(body).decode("ascii"),
            }
            write_json(self.capture_directory / f"request-{self.request_count:04d}.json", record)
            self._inspect(method, path, headers, body)
            self._write_status()

    def _inspect(self, method: str, path: str, headers: dict[str, str], body: bytes) -> None:
        if method != TELEMETRY_METHOD or path != TELEMETRY_PATH:
            return
        if headers.get("Content-Encoding", "").casefold() == "gzip":
            try:
                body = gzip.decompress(body)
            except (OSError, EOFError):
                return
        try:
            payload = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return
        if not isinstance(payload, dict) or not isinstance(payload.get("batch"), list):
            return
        for event in payload["batch"]:
            if not isinstance(event, dict):
                continue
            build = next((name for name, marker in EVENT_NAMES.items() if event.get("event") == marker), None)
            properties = event.get("properties")
            identity = event.get("distinct_id")
            session = properties.get("$session_id") if isinstance(properties, dict) else None
            if build and isinstance(identity, str) and identity and isinstance(session, str) and session:
                self.markers[build] = (identity, session)

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

    def wait_for(self, build: str, timeout: float = 15) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock:
                if build in self.markers:
                    return True
            time.sleep(0.2)
        return False


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

    def _record(self, body: bytes = b"") -> None:
        headers = {str(key): str(value) for key, value in self.headers.items()}
        self.server.ledger.record(self.command, self.path, headers, body)

    def _respond(self, value: object, status: int = 200) -> None:
        data = json.dumps(value, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802
        self._record()
        if self.path == "/v1/upgrade-evidence/config":
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
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        self._record(body)
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
    code = "SOURCE_BUILD_FAILED" if build == "source" else "CANDIDATE_BUILD_FAILED"
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
        raise HarnessBlocked(f"{build.upper()}_BUILD_PRODUCT_MISSING")
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
    code = "SOURCE_RUN_FAILED" if build == "source" else "CANDIDATE_RUN_FAILED"
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
    run_command(
        ["xcrun", "simctl", "launch", "--terminate-running", udid, BUNDLE_ID],
        code=code,
        diagnostics=diagnostics,
        env=environment,
    )
    result_path = container / "Documents" / RESULT_NAMES[build]
    deadline = time.monotonic() + 30
    result: dict[str, Any] | None = None
    while time.monotonic() < deadline:
        try:
            loaded = json.loads(result_path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict) and loaded.get("build") == build:
                result = loaded
                break
        except (OSError, json.JSONDecodeError):
            pass
        time.sleep(0.2)
    if result is None or result.get("identityCheck") is not True:
        raise HarnessBlocked(code)
    write_json(
        raw_directory / "application-results" / f"{build}.json",
        {"build": build, "identityCheck": True},
    )
    if not ledger.wait_for(build):
        raise HarnessBlocked("RAW_CAPTURE_INCOMPLETE")
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
