#!/usr/bin/env python3
"""Validate checked and generated iOS upgrade-evidence manifests."""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tarfile
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "UpgradeEvidence" / "0.1.0" / "manifest.json"
DEFAULT_INVENTORY = ROOT / "UpgradeEvidence" / "0.1.0" / "dependency-resolutions.json"
BASELINE_METADATA = ROOT / "Baselines" / "0.1.0" / "package-metadata.json"
NOTICE = ROOT / "legal" / "THIRD_PARTY_NOTICES.md"
IDENTIFIER_MARKER = "Forbidden-Identifier:"
BUNDLE_ID = "dev.elu.sdk-upgrade-evidence"
HEX_40 = re.compile(r"^[0-9a-f]{40}$")
HEX_64 = re.compile(r"^[0-9a-f]{64}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
BLOCKER_CODE = re.compile(r"^[A-Z][A-Z0-9_]+$")
EXPECTED_OPERATIONS = [
    "build-source",
    "build-candidate",
    "install-source",
    "establish-identity-and-session",
    "install-candidate-without-uninstall",
    "relaunch-candidate",
    "verify-identity-and-session-continuity",
]
EXPECTED_CONTINUITY = {
    "identity": "preserved",
    "sourceSession": "present",
    "candidateSession": "present",
    "sessionTransition": "rotated",
}
OBSERVED_FIELDS = {
    "sameApplicationContainer",
    "identityPreserved",
    "sourceSessionPresent",
    "candidateSessionPresent",
    "sessionRotated",
}
EVENT_NAMES = {
    "source": "elu_sdk_upgrade_source",
    "candidate": "elu_sdk_upgrade_candidate",
}
TELEMETRY_METHOD = "POST"
TELEMETRY_PATH = "/batch"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=pathlib.Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--inventory", type=pathlib.Path, default=DEFAULT_INVENTORY)
    parser.add_argument("--raw-archive", type=pathlib.Path)
    parser.add_argument("--require-verified", action="store_true")
    return parser.parse_args()


def load_json(path: pathlib.Path, role: str, errors: list[str]) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        errors.append(f"{role} must be readable JSON")
        return {}
    if not isinstance(value, dict):
        errors.append(f"{role} must be an object")
        return {}
    return value


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def forbidden_identifier() -> str:
    for line in NOTICE.read_text(encoding="utf-8").splitlines():
        if line.startswith(IDENTIFIER_MARKER):
            return line.removeprefix(IDENTIFIER_MARKER).strip().casefold()
    raise RuntimeError("legal notice is missing its identifier marker")


def exact_keys(value: Any, expected: set[str], label: str, errors: list[str]) -> bool:
    if not isinstance(value, dict):
        errors.append(f"{label} must be an object")
        return False
    actual = set(value)
    if actual != expected:
        errors.append(f"{label} fields do not match the schema")
        return False
    return True


def valid_resolution(value: Any, label: str, errors: list[str]) -> bool:
    if not exact_keys(value, {"version", "revision"}, label, errors):
        return False
    valid = True
    if not isinstance(value["version"], str) or not SEMVER.fullmatch(value["version"]):
        errors.append(f"{label}.version must be exact semantic version text")
        valid = False
    if not isinstance(value["revision"], str) or not HEX_40.fullmatch(value["revision"]):
        errors.append(f"{label}.revision must be a full source revision")
        valid = False
    return valid


def valid_dependency_absence(value: Any, label: str, errors: list[str]) -> bool:
    if not exact_keys(value, {"status", "proof"}, label, errors):
        return False
    valid = True
    if value["status"] != "absent":
        errors.append(f"{label}.status must be absent")
        valid = False
    proof = value["proof"]
    if not exact_keys(proof, {"kind", "sha256"}, f"{label}.proof", errors):
        return False
    if proof["kind"] != "resolved-package-graph-sha256":
        errors.append(f"{label}.proof.kind is invalid")
        valid = False
    if not isinstance(proof["sha256"], str) or not HEX_64.fullmatch(proof["sha256"]):
        errors.append(f"{label}.proof.sha256 must be a SHA-256 digest")
        valid = False
    return valid


def validate_manifest(data: dict[str, Any], require_verified: bool) -> list[str]:
    errors: list[str] = []
    expected_fields = {
        "$schema",
        "schemaVersion",
        "sourceVersion",
        "sourceRevision",
        "candidateRevision",
        "resolvedDependency",
        "environment",
        "operations",
        "expectedContinuity",
        "observedContinuity",
        "rawEvidence",
        "verificationStatus",
        "blockers",
    }
    exact_keys(data, expected_fields, "manifest", errors)
    if data.get("schemaVersion") != 1:
        errors.append("manifest.schemaVersion must be 1")
    if data.get("sourceVersion") != "0.1.0":
        errors.append("manifest.sourceVersion must be 0.1.0")
    source_revision = data.get("sourceRevision")
    if not isinstance(source_revision, str) or not HEX_40.fullmatch(source_revision):
        errors.append("manifest.sourceRevision must be a full source revision")
    candidate_revision = data.get("candidateRevision")
    if candidate_revision is not None and (
        not isinstance(candidate_revision, str) or not HEX_40.fullmatch(candidate_revision)
    ):
        errors.append("manifest.candidateRevision must be null or a full source revision")

    dependency = data.get("resolvedDependency")
    if exact_keys(
        dependency,
        {"inventoryReference", "source", "candidate"},
        "manifest.resolvedDependency",
        errors,
    ):
        if dependency["inventoryReference"] != "legal/THIRD_PARTY_NOTICES.dependencies.json":
            errors.append("manifest resolved-dependency inventory reference is invalid")
        if dependency["source"] is not None:
            valid_resolution(dependency["source"], "manifest.resolvedDependency.source", errors)
        candidate_dependency = dependency["candidate"]
        if candidate_dependency is not None:
            if isinstance(candidate_dependency, dict) and candidate_dependency.get("status") == "absent":
                valid_dependency_absence(candidate_dependency, "manifest.resolvedDependency.candidate", errors)
            else:
                valid_resolution(candidate_dependency, "manifest.resolvedDependency.candidate", errors)

    environment = data.get("environment")
    if exact_keys(environment, {"xcodeVersion", "iOSVersion", "bundleId"}, "manifest.environment", errors):
        if environment["bundleId"] != BUNDLE_ID:
            errors.append("manifest.environment.bundleId is not the harness bundle")
        for field in ("xcodeVersion", "iOSVersion"):
            if environment[field] is not None and (
                not isinstance(environment[field], str) or not environment[field].strip()
            ):
                errors.append(f"manifest.environment.{field} must be null or non-empty text")

    if data.get("operations") != EXPECTED_OPERATIONS:
        errors.append("manifest.operations must preserve the same-container upgrade sequence")
    expected = data.get("expectedContinuity")
    if expected != EXPECTED_CONTINUITY:
        errors.append("manifest.expectedContinuity must require identity preservation and session rotation")

    observed = data.get("observedContinuity")
    if observed is not None and exact_keys(
        observed,
        OBSERVED_FIELDS,
        "manifest.observedContinuity",
        errors,
    ):
        if not all(isinstance(observed[field], bool) for field in observed):
            errors.append("manifest.observedContinuity fields must be booleans")

    raw = data.get("rawEvidence")
    if exact_keys(raw, {"sha256", "custody", "status"}, "manifest.rawEvidence", errors):
        digest = raw["sha256"]
        if digest is not None and (not isinstance(digest, str) or not HEX_64.fullmatch(digest)):
            errors.append("manifest.rawEvidence.sha256 must be null or a SHA-256 digest")
        if raw["custody"] not in {"external", "operator-managed", "runner-transient"}:
            errors.append("manifest.rawEvidence.custody is invalid")
        if raw["status"] not in {"not-captured", "captured"}:
            errors.append("manifest.rawEvidence.status is invalid")

    status = data.get("verificationStatus")
    if status not in {"blocked", "failed", "verified"}:
        errors.append("manifest.verificationStatus is invalid")
    blockers = data.get("blockers")
    if not isinstance(blockers, list):
        errors.append("manifest.blockers must be an array")
        blockers = []
    for index, blocker in enumerate(blockers):
        if not exact_keys(blocker, {"code", "detail"}, f"manifest.blockers[{index}]", errors):
            continue
        if not isinstance(blocker["code"], str) or not BLOCKER_CODE.fullmatch(blocker["code"]):
            errors.append(f"manifest.blockers[{index}].code is invalid")
        if not isinstance(blocker["detail"], str) or not blocker["detail"].strip():
            errors.append(f"manifest.blockers[{index}].detail is required")

    if status == "blocked":
        if not blockers:
            errors.append("a blocked manifest must contain a blocker")
        if observed is not None:
            errors.append("a blocked manifest cannot claim observed continuity")
        if isinstance(raw, dict):
            if raw.get("status") == "not-captured" and raw.get("sha256") is not None:
                errors.append("uncaptured raw evidence cannot have a digest")
            if raw.get("status") == "captured" and raw.get("sha256") is None:
                errors.append("captured blocker evidence requires a digest")
    elif status == "verified":
        if blockers:
            errors.append("a verified manifest cannot contain blockers")
        if candidate_revision is None:
            errors.append("a verified manifest requires the candidate revision")
        if not isinstance(dependency, dict) or dependency.get("source") is None or dependency.get("candidate") is None:
            errors.append("a verified manifest requires an exact source resolution and candidate resolution evidence")
        if not isinstance(environment, dict) or not environment.get("xcodeVersion") or not environment.get("iOSVersion"):
            errors.append("a verified manifest requires exact Xcode and iOS versions")
        if observed != {field: True for field in OBSERVED_FIELDS}:
            errors.append("a verified manifest requires all continuity checks to pass")
        if not isinstance(raw, dict) or raw.get("status") != "captured" or raw.get("sha256") is None:
            errors.append("a verified manifest requires a digest for captured raw evidence")
    elif status == "failed":
        if not blockers:
            errors.append("a failed manifest must explain the failed check")
        if candidate_revision is None or not isinstance(source_revision, str):
            errors.append("a failed manifest requires exact source and candidate revisions")
        if not isinstance(dependency, dict) or dependency.get("source") is None or dependency.get("candidate") is None:
            errors.append("a failed manifest requires source and candidate dependency evidence")
        if not isinstance(environment, dict) or not environment.get("xcodeVersion") or not environment.get("iOSVersion"):
            errors.append("a failed manifest requires exact Xcode and iOS versions")
        if not isinstance(observed, dict):
            errors.append("a failed manifest requires observed continuity checks")
        elif all(observed.get(field) is True for field in OBSERVED_FIELDS):
            errors.append("a failed manifest cannot report every continuity check as passing")
        if not isinstance(raw, dict) or raw.get("status") != "captured" or raw.get("sha256") is None:
            errors.append("a failed manifest requires captured evidence with a digest")

    if require_verified and status != "verified":
        errors.append("manifest is not verified")
    return errors


def validate_inventory(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    expected_fields = {
        "$schema",
        "schemaVersion",
        "source",
        "manifestRequirement",
        "lockfile",
        "dependencyInventory",
        "observations",
        "historicalUniversality",
    }
    exact_keys(data, expected_fields, "inventory", errors)
    if data.get("schemaVersion") != 1:
        errors.append("inventory.schemaVersion must be 1")

    baseline = load_json(BASELINE_METADATA, "baseline metadata", errors)
    source = data.get("source")
    if exact_keys(source, {"version", "revision", "manifestSha256"}, "inventory.source", errors):
        baseline_source = baseline.get("source", {})
        if source.get("version") != "0.1.0" or source.get("revision") != baseline_source.get("commit"):
            errors.append("inventory source does not match the immutable baseline")
        if source.get("manifestSha256") != baseline_source.get("manifestSha256"):
            errors.append("inventory manifest digest does not match the immutable baseline")

    requirement = data.get("manifestRequirement")
    if exact_keys(
        requirement,
        {"kind", "lowerBound", "exclusiveUpperBound"},
        "inventory.manifestRequirement",
        errors,
    ):
        baseline_requirement = baseline.get("dependencyObservation", {}).get("manifestRequirement", {})
        if requirement.get("kind") != "up-to-next-minor":
            errors.append("inventory requirement kind is invalid")
        if requirement.get("lowerBound") != baseline_requirement.get("lowerBound") or requirement.get(
            "exclusiveUpperBound"
        ) != baseline_requirement.get("exclusiveUpperBound"):
            errors.append("inventory requirement range does not match the source snapshot")

    lockfile = data.get("lockfile")
    if exact_keys(lockfile, {"status", "meaning"}, "inventory.lockfile", errors):
        if lockfile.get("status") != "absent-at-source":
            errors.append("inventory must record the source lockfile as absent")
        if not isinstance(lockfile.get("meaning"), str) or not lockfile["meaning"].strip():
            errors.append("inventory.lockfile.meaning is required")

    dependency_inventory = data.get("dependencyInventory")
    if exact_keys(
        dependency_inventory,
        {"reference", "gitBlob", "sha256"},
        "inventory.dependencyInventory",
        errors,
    ):
        if dependency_inventory.get("reference") != "legal/THIRD_PARTY_NOTICES.dependencies.json":
            errors.append("inventory legal dependency reference is invalid")
        blob = dependency_inventory.get("gitBlob")
        try:
            frozen_inventory = subprocess.check_output(
                ["git", "cat-file", "blob", str(blob)], cwd=ROOT, stderr=subprocess.DEVNULL
            )
        except subprocess.CalledProcessError:
            errors.append("inventory legal dependency blob is unavailable")
        else:
            frozen_digest = hashlib.sha256(frozen_inventory).hexdigest()
            if dependency_inventory.get("sha256") != frozen_digest:
                errors.append("inventory legal dependency digest does not match its immutable blob")

    observations = data.get("observations")
    if not isinstance(observations, list) or not observations:
        errors.append("inventory.observations must contain at least one dated resolution")
        observations = []
    baseline_observation = baseline.get("dependencyObservation", {}).get("resolvedOn2026-08-03", {})
    for index, observation in enumerate(observations):
        label = f"inventory.observations[{index}]"
        if not exact_keys(
            observation,
            {"observedOn", "resolution", "annotatedTag", "scope", "universalHistoricalClaim", "provenance"},
            label,
            errors,
        ):
            continue
        if observation.get("scope") != "single-dated-resolution":
            errors.append(f"{label}.scope must remain limited to one dated resolution")
        if observation.get("universalHistoricalClaim") is not False:
            errors.append(f"{label} cannot claim a universal historical resolution")
        valid_resolution(observation.get("resolution"), f"{label}.resolution", errors)
        if index == 0 and observation.get("resolution") != baseline_observation:
            errors.append(f"{label}.resolution does not match its baseline provenance")
        tag = observation.get("annotatedTag")
        if exact_keys(
            tag,
            {"name", "objectRevision", "peeledSourceRevision", "authenticationStatus"},
            f"{label}.annotatedTag",
            errors,
        ):
            resolution = observation.get("resolution", {})
            if tag.get("name") != resolution.get("version"):
                errors.append(f"{label}.annotatedTag name must match the resolved version")
            if tag.get("peeledSourceRevision") != resolution.get("revision"):
                errors.append(f"{label}.annotatedTag peeled revision must match the resolved source")
            if not isinstance(tag.get("objectRevision"), str) or not HEX_40.fullmatch(tag["objectRevision"]):
                errors.append(f"{label}.annotatedTag object revision must be full length")
            if tag.get("objectRevision") == tag.get("peeledSourceRevision"):
                errors.append(f"{label}.annotatedTag must distinguish its tag object from peeled source")
            if tag.get("authenticationStatus") != "observational-until-executable-run":
                errors.append(f"{label}.annotatedTag must remain explicitly observational in static inventory")
        provenance = observation.get("provenance")
        if exact_keys(provenance, {"reference", "sha256"}, f"{label}.provenance", errors):
            if provenance.get("reference") != "Baselines/0.1.0/package-metadata.json":
                errors.append(f"{label}.provenance reference is invalid")
            if provenance.get("sha256") != sha256(BASELINE_METADATA):
                errors.append(f"{label}.provenance digest is stale")

    if data.get("historicalUniversality") != "not-established":
        errors.append("inventory must not generalize one resolution to all historical consumers")

    try:
        subprocess.check_call(
            ["git", "cat-file", "-e", "0.1.0:Package.resolved"],
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError:
        pass
    else:
        errors.append("inventory says the source lockfile is absent, but the source tag contains one")

    identity = historical_identity(data, errors)
    checkout = ROOT / ".build" / "checkouts" / identity if identity is not None else None
    if checkout is not None and checkout.is_dir() and observations:
        tag = observations[0].get("annotatedTag", {}) if isinstance(observations[0], dict) else {}
        try:
            object_revision = subprocess.check_output(
                ["git", "rev-parse", f"refs/tags/{tag.get('name')}"], cwd=checkout, stderr=subprocess.DEVNULL
            ).decode().strip()
            peeled_revision = subprocess.check_output(
                ["git", "rev-parse", f"refs/tags/{tag.get('name')}^{{}}"], cwd=checkout, stderr=subprocess.DEVNULL
            ).decode().strip()
            object_type = subprocess.check_output(
                ["git", "cat-file", "-t", object_revision], cwd=checkout, stderr=subprocess.DEVNULL
            ).decode().strip()
        except subprocess.CalledProcessError:
            errors.append("available dependency checkout cannot authenticate the dated tag observation")
        else:
            if object_type != "tag" or object_revision != tag.get("objectRevision") or peeled_revision != tag.get(
                "peeledSourceRevision"
            ):
                errors.append("available dependency checkout contradicts the dated tag observation")
    return errors


def read_raw_archive(path: pathlib.Path, errors: list[str]) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    total_size = 0
    try:
        with tarfile.open(path, mode="r:*") as archive:
            for member in archive.getmembers():
                pure = pathlib.PurePosixPath(member.name)
                canonical = not pure.is_absolute() and ".." not in pure.parts and pure.as_posix() == member.name
                if not canonical:
                    errors.append("raw archive contains a non-canonical member")
                    continue
                if member.isdir():
                    continue
                if not member.isfile() or member.name in files:
                    errors.append("raw archive contains an unsupported or duplicate member")
                    continue
                total_size += member.size
                if member.size > 25 * 1024 * 1024 or total_size > 100 * 1024 * 1024:
                    errors.append("raw archive exceeds the evidence size limit")
                    continue
                extracted = archive.extractfile(member)
                if extracted is None:
                    errors.append("raw archive member could not be read")
                    continue
                files[member.name] = extracted.read()
    except (OSError, tarfile.TarError):
        errors.append("raw archive must be a readable tar archive")
    return files


def raw_json(files: dict[str, bytes], name: str, errors: list[str]) -> dict[str, Any]:
    payload = files.get(name)
    if payload is None:
        errors.append(f"raw archive is missing {name}")
        return {}
    try:
        value = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError):
        errors.append(f"raw archive member {name} must be JSON")
        return {}
    if not isinstance(value, dict):
        errors.append(f"raw archive member {name} must be an object")
        return {}
    return value


def derive_capture(files: dict[str, bytes], errors: list[str]) -> tuple[dict[str, bool], dict[str, tuple[str, str]]]:
    markers: dict[str, tuple[str, str]] = {}
    request_names = sorted(name for name in files if name.startswith("requests/request-") and name.endswith(".json"))
    if not request_names:
        errors.append("raw archive contains no captured requests")
    for name in request_names:
        request = raw_json(files, name, errors)
        if request.get("method") != TELEMETRY_METHOD or request.get("path") != TELEMETRY_PATH:
            continue
        headers = request.get("headers")
        encoded_body = request.get("bodyBase64")
        if not isinstance(headers, dict) or not all(isinstance(key, str) and isinstance(value, str) for key, value in headers.items()):
            errors.append("captured request headers are invalid")
            continue
        if not isinstance(encoded_body, str):
            errors.append("captured request body is invalid")
            continue
        try:
            body = base64.b64decode(encoded_body, validate=True)
        except (ValueError, TypeError):
            errors.append("captured request body is not valid base64")
            continue
        encoding = next((value for key, value in headers.items() if key.casefold() == "content-encoding"), "")
        if encoding.casefold() == "gzip":
            try:
                body = gzip.decompress(body)
            except (OSError, EOFError):
                errors.append("captured gzip request body is invalid")
                continue
        try:
            payload = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if not isinstance(payload, dict) or not isinstance(payload.get("batch"), list):
            continue
        for event in payload["batch"]:
            if not isinstance(event, dict):
                continue
            build = next((key for key, marker in EVENT_NAMES.items() if event.get("event") == marker), None)
            properties = event.get("properties")
            identity = event.get("distinct_id")
            session = properties.get("$session_id") if isinstance(properties, dict) else None
            if build is None or not isinstance(identity, str) or not identity or not isinstance(session, str) or not session:
                continue
            marker = (identity, session)
            if build in markers and markers[build] != marker:
                errors.append(f"captured {build} marker values are inconsistent")
            markers[build] = marker

    source = markers.get("source")
    candidate = markers.get("candidate")
    derived = {
        "identityPreserved": source is not None and candidate is not None and source[0] == candidate[0],
        "sourceSessionPresent": source is not None and bool(source[1]),
        "candidateSessionPresent": candidate is not None and bool(candidate[1]),
        "sessionRotated": source is not None and candidate is not None and source[1] != candidate[1],
    }
    return derived, markers


def historical_identity(inventory: dict[str, Any], errors: list[str]) -> str | None:
    blob = inventory.get("dependencyInventory", {}).get("gitBlob")
    try:
        payload = subprocess.check_output(
            ["git", "cat-file", "blob", str(blob)], cwd=ROOT, stderr=subprocess.DEVNULL
        )
        frozen = json.loads(payload)
        identity = frozen["packages"][0]["identity"]
    except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError, IndexError, TypeError):
        errors.append("historical dependency identity provenance is unavailable")
        return None
    if not isinstance(identity, str) or not identity:
        errors.append("historical dependency identity provenance is invalid")
        return None
    return identity


def verify_graph(
    files: dict[str, bytes],
    build: str,
    evidence: Any,
    identity: str,
    errors: list[str],
) -> None:
    name = f"resolved-package-graphs/{build}.json"
    graph_bytes = files.get(name)
    graph = raw_json(files, name, errors)
    if graph_bytes is None:
        return
    if set(graph) != {"schemaVersion", "dependencies"} or graph.get("schemaVersion") != 1:
        errors.append(f"raw {build} resolved package graph has invalid fields")
        return
    dependencies = graph.get("dependencies")
    if not isinstance(dependencies, list):
        errors.append(f"raw {build} resolved package graph dependencies must be an array")
        return
    matches: list[dict[str, Any]] = []
    for dependency in dependencies:
        if not isinstance(dependency, dict) or set(dependency) != {"identity", "version", "revision"}:
            errors.append(f"raw {build} resolved package graph entry is invalid")
            continue
        if dependency.get("identity") == identity:
            matches.append(dependency)
    if isinstance(evidence, dict) and evidence.get("status") == "absent":
        proof = evidence.get("proof", {})
        if matches:
            errors.append("candidate dependency absence is contradicted by the raw resolved graph")
        if proof.get("kind") != "resolved-package-graph-sha256" or proof.get("sha256") != hashlib.sha256(graph_bytes).hexdigest():
            errors.append("candidate dependency absence digest does not match the raw resolved graph")
        return
    if not isinstance(evidence, dict) or set(evidence) != {"version", "revision"}:
        errors.append(f"manifest {build} dependency resolution is invalid")
        return
    exact = [
        dependency
        for dependency in matches
        if dependency.get("version") == evidence.get("version") and dependency.get("revision") == evidence.get("revision")
    ]
    if len(exact) != 1:
        errors.append(f"manifest {build} dependency resolution is not proven by the raw resolved graph")


def verify_tag_object(files: dict[str, bytes], inventory: dict[str, Any], errors: list[str]) -> None:
    payload = files.get("historical-dependency-tag-object.txt")
    if payload is None:
        errors.append("raw archive is missing historical dependency tag-object provenance")
        return
    observations = inventory.get("observations", [])
    if not observations or not isinstance(observations[0], dict):
        errors.append("historical tag observation is unavailable")
        return
    expected = observations[0].get("annotatedTag", {})
    object_revision = hashlib.sha1(f"tag {len(payload)}\0".encode("ascii") + payload).hexdigest()
    if object_revision != expected.get("objectRevision"):
        errors.append("raw historical dependency tag object has the wrong object revision")
    lines = payload.decode("utf-8", errors="replace").splitlines()
    fields: dict[str, str] = {}
    for line in lines:
        if not line:
            break
        key, separator, value = line.partition(" ")
        if separator:
            fields[key] = value
    if fields.get("type") != "commit" or fields.get("object") != expected.get("peeledSourceRevision"):
        errors.append("raw historical dependency tag object has the wrong peeled source revision")
    if fields.get("tag") != expected.get("name"):
        errors.append("raw historical dependency tag object has the wrong tag name")


def verify_raw_evidence(
    archive_path: pathlib.Path,
    manifest: dict[str, Any],
    inventory: dict[str, Any],
) -> list[str]:
    errors: list[str] = []
    try:
        archive_digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    except OSError:
        return ["raw archive is not readable"]
    raw = manifest.get("rawEvidence", {})
    if raw.get("status") != "captured" or raw.get("sha256") != archive_digest:
        errors.append("manifest raw-evidence digest does not match the supplied archive")
    try:
        candidate_revision = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, stderr=subprocess.DEVNULL
        ).decode().strip()
        source_revision = subprocess.check_output(
            ["git", "rev-parse", "0.1.0^{commit}"], cwd=ROOT, stderr=subprocess.DEVNULL
        ).decode().strip()
    except subprocess.CalledProcessError:
        errors.append("repository revisions are unavailable for raw provenance verification")
    else:
        if manifest.get("candidateRevision") != candidate_revision:
            errors.append("manifest candidate revision does not match the checked-out revision")
        if manifest.get("sourceRevision") != source_revision:
            errors.append("manifest source revision does not match the immutable source tag")
    files = read_raw_archive(archive_path, errors)
    if not files:
        return errors

    provenance = raw_json(files, "run-provenance.json", errors)
    environment = manifest.get("environment")
    dependency = manifest.get("resolvedDependency")
    for field in ("sourceVersion", "sourceRevision", "candidateRevision"):
        if provenance.get(field) != manifest.get(field):
            errors.append(f"raw provenance {field} does not match the manifest")
    if provenance.get("environment") != environment:
        errors.append("raw provenance environment does not match the manifest")
    if provenance.get("resolvedDependency") != {
        "source": dependency.get("source") if isinstance(dependency, dict) else None,
        "candidate": dependency.get("candidate") if isinstance(dependency, dict) else None,
    }:
        errors.append("raw provenance dependency resolutions do not match the manifest")

    container = provenance.get("applicationContainer")
    container_equal = False
    if exact_keys(
        container,
        {"sourcePathSha256", "candidatePathSha256"},
        "raw provenance applicationContainer",
        errors,
    ):
        source_digest = container["sourcePathSha256"]
        candidate_digest = container["candidatePathSha256"]
        if not isinstance(source_digest, str) or not HEX_64.fullmatch(source_digest):
            errors.append("raw provenance source container digest is invalid")
        if not isinstance(candidate_digest, str) or not HEX_64.fullmatch(candidate_digest):
            errors.append("raw provenance candidate container digest is invalid")
        container_equal = source_digest == candidate_digest

    capture, markers = derive_capture(files, errors)
    expected_status = {
        "sourceMarkerObserved": "source" in markers,
        "candidateMarkerObserved": "candidate" in markers,
        **capture,
    }
    if raw_json(files, "capture-status.json", errors) != expected_status:
        errors.append("raw capture status does not match the captured requests")
    for build in ("source", "candidate"):
        application_result = raw_json(files, f"application-results/{build}.json", errors)
        if exact_keys(
            application_result,
            {"build", "identityCheck"},
            f"raw {build} application result",
            errors,
        ) and application_result != {"build": build, "identityCheck": True}:
            errors.append(f"raw {build} application result did not confirm the public identity facade")
    derived_observed = {"sameApplicationContainer": container_equal, **capture}
    if manifest.get("observedContinuity") != derived_observed:
        errors.append("manifest continuity results do not match raw evidence")

    identity = historical_identity(inventory, errors)
    if identity is not None and isinstance(dependency, dict):
        verify_graph(files, "source", dependency.get("source"), identity, errors)
        verify_graph(files, "candidate", dependency.get("candidate"), identity, errors)
    verify_tag_object(files, inventory, errors)
    return errors


def main() -> int:
    args = parse_args()
    errors: list[str] = []
    manifest = load_json(args.manifest, "manifest", errors)
    inventory = load_json(args.inventory, "inventory", errors)
    if manifest:
        errors.extend(validate_manifest(manifest, args.require_verified))
    if inventory:
        errors.extend(validate_inventory(inventory))
    if manifest and inventory and manifest.get("sourceRevision") != inventory.get("source", {}).get("revision"):
        errors.append("manifest.sourceRevision does not match the historical source inventory")

    if args.require_verified and args.raw_archive is None:
        errors.append("verified validation requires --raw-archive")
    if args.raw_archive is not None and manifest and inventory:
        errors.extend(verify_raw_evidence(args.raw_archive, manifest, inventory))

    token = forbidden_identifier()
    for role, data in (("manifest", manifest), ("inventory", inventory)):
        if token and token in json.dumps(data, sort_keys=True).casefold():
            errors.append(f"{role} must reference the legal inventory instead of copying its identifier")

    if errors:
        for error in errors:
            print(f"upgrade evidence validation failed: {error}", file=sys.stderr)
        return 1
    print("validated upgrade evidence manifest and dependency-resolution inventory")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
