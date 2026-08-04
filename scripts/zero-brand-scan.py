#!/usr/bin/env python3
"""Scan source, artifacts, symbols, archives, and network traces for release debt."""

from __future__ import annotations

import argparse
import io
import json
import pathlib
import re
import subprocess
import sys
import tarfile
import zipfile
from urllib.parse import urlparse


ROOT = pathlib.Path(__file__).resolve().parents[1]
NOTICE = ROOT / "legal" / "THIRD_PARTY_NOTICES.md"
ALLOWLIST = ROOT / "legal" / "zero-brand-allowlist.json"
DEFAULT_BASELINE = ROOT / "Baselines" / "phase-1-wrapper" / "zero-brand-debt.json"
DEFAULT_HOSTS = ROOT / "release" / "elu-owned-hosts.txt"
IDENTIFIER_MARKER = "Forbidden-Identifier:"
REQUIRED_NETWORK_SCENARIOS = frozenset(
    {
        "config",
        "capture",
        "identify",
        "reset",
        "flags",
        "replay",
        "background",
        "foreground",
        "offline-recovery",
    }
)


def load_identifier() -> bytes:
    for line in NOTICE.read_text(encoding="utf-8").splitlines():
        if line.startswith(IDENTIFIER_MARKER):
            value = line.removeprefix(IDENTIFIER_MARKER).strip()
            if value:
                return value.casefold().encode("utf-8")
    raise RuntimeError(f"missing {IDENTIFIER_MARKER} in {NOTICE}")


def load_allowlist() -> tuple[set[str], set[str]]:
    data = json.loads(ALLOWLIST.read_text(encoding="utf-8"))
    return set(data["trackedPaths"]), set(data["artifactBasenames"])


def count_identifier(data: bytes, identifier: bytes) -> int:
    return data.lower().count(identifier)


def tracked_paths() -> list[str]:
    output = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT)
    return [item.decode("utf-8") for item in output.split(b"\0") if item]


def record(
    findings: dict[str, int],
    label: str,
    data: bytes,
    identifier: bytes,
    *,
    allowed: bool,
) -> None:
    path_count = label.casefold().encode("utf-8").count(identifier)
    content_count = 0 if allowed else count_identifier(data, identifier)
    count = path_count + content_count
    if count:
        findings[label] = findings.get(label, 0) + count


def scan_source(identifier: bytes, tracked_allowlist: set[str]) -> dict[str, int]:
    findings: dict[str, int] = {}
    for relative in tracked_paths():
        path = ROOT / relative
        if not path.is_file():
            continue
        record(
            findings,
            relative,
            path.read_bytes(),
            identifier,
            allowed=relative in tracked_allowlist,
        )
    return findings


def archive_entries(data: bytes) -> list[tuple[str, bytes]] | None:
    stream = io.BytesIO(data)
    if zipfile.is_zipfile(stream):
        entries: list[tuple[str, bytes]] = []
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for info in archive.infolist():
                if not info.is_dir():
                    entries.append((info.filename, archive.read(info)))
        return entries
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
            entries = []
            for member in archive.getmembers():
                if not member.isfile():
                    continue
                extracted = archive.extractfile(member)
                if extracted is not None:
                    entries.append((member.name, extracted.read()))
            return entries
    except (tarfile.TarError, OSError):
        return None


def scan_archive(
    findings: dict[str, int],
    label: str,
    data: bytes,
    identifier: bytes,
    artifact_allowlist: set[str],
    *,
    depth: int = 0,
    maximum_depth: int = 4,
) -> bool:
    entries = archive_entries(data)
    if entries is None:
        return False
    record(findings, label, b"", identifier, allowed=False)
    for entry, entry_data in entries:
        entry_label = f"{label}!/{entry}"
        nested_entries = archive_entries(entry_data)
        if nested_entries is not None:
            if depth >= maximum_depth:
                findings[f"{entry_label} [nested-archive-depth-limit]"] = 1
                continue
            scan_archive(
                findings,
                entry_label,
                entry_data,
                identifier,
                artifact_allowlist,
                depth=depth + 1,
                maximum_depth=maximum_depth,
            )
        else:
            allowed = pathlib.PurePosixPath(entry).name in artifact_allowlist
            record(findings, entry_label, entry_data, identifier, allowed=allowed)
    return True


def scan_input(
    path: pathlib.Path,
    identifier: bytes,
    artifact_allowlist: set[str],
) -> dict[str, int]:
    findings: dict[str, int] = {}
    if not path.exists():
        raise FileNotFoundError(path)
    files = sorted(item for item in path.rglob("*") if item.is_file()) if path.is_dir() else [path]
    for file_path in files:
        relative = file_path.relative_to(path).as_posix() if path.is_dir() else file_path.name
        label = f"{path.name}/{relative}" if path.is_dir() else path.name
        data = file_path.read_bytes()
        if not scan_archive(findings, label, data, identifier, artifact_allowlist):
            record(
                findings,
                label,
                data,
                identifier,
                allowed=file_path.name in artifact_allowlist,
            )
    return findings


def merge(into: dict[str, int], addition: dict[str, int]) -> None:
    for path, count in addition.items():
        into[path] = into.get(path, 0) + count


def load_owned_hosts(path: pathlib.Path) -> set[str]:
    return {
        line.strip().lower()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def host_is_owned(host: str, owned_hosts: set[str]) -> bool:
    normalized = host.rstrip(".").lower()
    return any(normalized == owned or normalized.endswith("." + owned) for owned in owned_hosts)


def validate_network_trace(path: pathlib.Path, owned_hosts: set[str]) -> list[str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return [f"{path}: trace must be valid JSON"]
    if not isinstance(data, dict):
        return [f"{path}: trace must be an object"]
    if data.get("schemaVersion") != 1:
        return [f"{path}: schemaVersion must be 1"]

    errors: list[str] = []
    scenarios = data.get("scenarios")
    if not isinstance(scenarios, list):
        errors.append(f"{path}: scenarios must be an array")
        declared_scenarios: set[str] = set()
    else:
        declared_scenarios = set()
        for index, scenario in enumerate(scenarios):
            if not isinstance(scenario, str) or scenario not in REQUIRED_NETWORK_SCENARIOS:
                errors.append(f"{path}: scenarios[{index}] is unknown: {scenario!r}")
            elif scenario in declared_scenarios:
                errors.append(f"{path}: scenarios[{index}] duplicates {scenario!r}")
            else:
                declared_scenarios.add(scenario)
    missing_scenarios = REQUIRED_NETWORK_SCENARIOS - declared_scenarios
    if missing_scenarios:
        errors.append(f"{path}: missing release scenarios: {', '.join(sorted(missing_scenarios))}")

    requests = data.get("requests")
    if not isinstance(requests, list):
        return errors + [f"{path}: requests must be an array"]
    if not requests:
        return errors + [f"{path}: requests must contain at least one observed SDK request"]
    for index, request in enumerate(requests):
        scenario = request.get("scenario") if isinstance(request, dict) else None
        if not isinstance(scenario, str) or scenario not in REQUIRED_NETWORK_SCENARIOS:
            errors.append(f"{path}: requests[{index}] has an unknown or missing scenario: {scenario!r}")
        url = request.get("url") if isinstance(request, dict) else None
        try:
            parsed = urlparse(url) if isinstance(url, str) else None
            hostname = parsed.hostname if parsed is not None else None
        except ValueError:
            parsed = None
            hostname = None
        if (
            parsed is None
            or parsed.scheme != "https"
            or not hostname
            or parsed.username is not None
            or parsed.password is not None
        ):
            errors.append(f"{path}: requests[{index}] is not an absolute HTTPS URL")
            continue
        if not host_is_owned(hostname, owned_hosts):
            errors.append(f"{path}: requests[{index}] uses a non-ELU host: {hostname}")
    return errors


def redact(value: str, identifier: bytes) -> str:
    token = identifier.decode("utf-8")
    return re.sub(re.escape(token), "[forbidden]", value, flags=re.IGNORECASE)


def print_findings(title: str, findings: dict[str, int], identifier: bytes) -> None:
    if not findings:
        print(f"{title}: clean")
        return
    print(f"{title}: {sum(findings.values())} match(es) across {len(findings)} path(s)")
    for path, count in sorted(findings.items()):
        print(f"  {count:4d}  {redact(path, identifier)}")


def baseline_errors(findings: dict[str, int], baseline_path: pathlib.Path) -> list[str]:
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    expected = baseline["findings"]
    errors: list[str] = []
    for path, count in sorted(findings.items()):
        if path not in expected:
            errors.append(f"new debt path: {path} ({count})")
        elif count > expected[path]:
            errors.append(f"debt increased: {path} ({expected[path]} -> {count})")
    return errors


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("report", "baseline", "strict"), default="baseline")
    parser.add_argument("--baseline", type=pathlib.Path, default=DEFAULT_BASELINE)
    parser.add_argument("--input", type=pathlib.Path, action="append", default=[])
    parser.add_argument("--network-trace", type=pathlib.Path, action="append", default=[])
    parser.add_argument("--owned-hosts", type=pathlib.Path, default=DEFAULT_HOSTS)
    parser.add_argument("--skip-source", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    identifier = load_identifier()
    tracked_allowlist, artifact_allowlist = load_allowlist()
    source_findings = {} if args.skip_source else scan_source(identifier, tracked_allowlist)
    artifact_findings: dict[str, int] = {}
    for path in args.input:
        merge(artifact_findings, scan_input(path, identifier, artifact_allowlist))
    for trace in args.network_trace:
        merge(artifact_findings, scan_input(trace, identifier, artifact_allowlist))

    owned_hosts = load_owned_hosts(args.owned_hosts)
    network_errors = [
        error
        for trace in args.network_trace
        for error in validate_network_trace(trace, owned_hosts)
    ]

    print_findings("tracked source", source_findings, identifier)
    print_findings("generated/artifact inputs", artifact_findings, identifier)
    for error in network_errors:
        print(redact(error, identifier), file=sys.stderr)

    if args.mode == "report":
        return 0
    if args.mode == "strict":
        return 1 if source_findings or artifact_findings or network_errors else 0

    errors = baseline_errors(source_findings, args.baseline)
    if artifact_findings:
        errors.append("generated/artifact inputs must be strict-clean even while source debt is active")
    errors.extend(network_errors)
    for error in errors:
        print(redact(error, identifier), file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
