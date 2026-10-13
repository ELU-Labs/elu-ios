#!/usr/bin/env python3
"""Fail when a forbidden identifier appears in tracked files or build artifacts.

Identifiers are never stored in plain text. Each entry in FORBIDDEN records the
SHA-256 digest of the normalized identifier, its normalized length, and a
one-bit-per-character prefilter. Input is normalized the same way: ASCII letters
are casefolded and whitespace, ASCII punctuation and NUL bytes are removed, so
split or re-cased forms ("A-B", "a_b", "A B", UTF-16 text) are found too. The
scanner looks for windows that pass the prefilter and confirms each one with
SHA-256. File and archive entry names are scanned as well as their contents,
including nested zip and tar archives.

Maintainers can print the entry for a new identifier with `--entry-for`.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import pathlib
import subprocess
import sys
import tarfile
import zipfile
from typing import Iterator, NamedTuple


ROOT = pathlib.Path(__file__).resolve().parents[1]
PREFILTER_SALT = b"elu-identifier-scan-v1"
MAXIMUM_ARCHIVE_DEPTH = 4

# Normalized length, prefilter and SHA-256 of each forbidden identifier.
FORBIDDEN = (
    {"length": 7, "prefilter": "1101111", "sha256": "67e5a3025bc013d09e3a1e6659f2e53efc7d137272ffe72b6dc8344f578461cf"},
)


def _separator_bytes() -> bytes:
    separators = {0x00}
    separators.update(range(0x09, 0x0E))
    for first, last in ((0x20, 0x2F), (0x3A, 0x40), (0x5B, 0x60), (0x7B, 0x7E)):
        separators.update(range(first, last + 1))
    return bytes(sorted(separators))


SEPARATORS = _separator_bytes()
LOWERCASE = bytes.maketrans(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ", b"abcdefghijklmnopqrstuvwxyz")
ALPHANUMERIC = b"abcdefghijklmnopqrstuvwxyz0123456789"


def _class_table() -> bytes:
    table = bytearray(b"." * 256)
    for value in ALPHANUMERIC:
        bit = hashlib.sha256(PREFILTER_SALT + bytes([value])).digest()[0] & 1
        table[value] = ord("1") if bit else ord("0")
    return bytes(table)


CLASSES = _class_table()


class Identifier(NamedTuple):
    length: int
    prefilter: bytes
    digest: bytes


def normalize(data: bytes) -> bytes:
    return data.translate(LOWERCASE, SEPARATORS)


def entry_for(token: str) -> dict[str, object]:
    normalized = normalize(token.encode("utf-8"))
    if len(normalized) < 4 or any(value not in ALPHANUMERIC for value in normalized):
        raise ValueError("identifiers must normalize to at least four ASCII letters or digits")
    return {
        "length": len(normalized),
        "prefilter": normalized.translate(CLASSES).decode("ascii"),
        "sha256": hashlib.sha256(normalized).hexdigest(),
    }


def parse_identifiers(entries: object) -> list[Identifier]:
    if not isinstance(entries, (list, tuple)) or not entries:
        raise ValueError("identifier list must be a non-empty array")
    identifiers: list[Identifier] = []
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict) or set(entry) != {"length", "prefilter", "sha256"}:
            raise ValueError(f"identifier {index} must have exactly length, prefilter and sha256")
        length, prefilter, digest = entry["length"], entry["prefilter"], entry["sha256"]
        if (
            type(length) is not int
            or length < 4
            or not isinstance(prefilter, str)
            or len(prefilter) != length
            or set(prefilter) - {"0", "1"}
            or not isinstance(digest, str)
            or len(digest) != 64
            or set(digest) - set("0123456789abcdef")
        ):
            raise ValueError(f"identifier {index} is malformed")
        identifiers.append(Identifier(length, prefilter.encode("ascii"), bytes.fromhex(digest)))
    return identifiers


def load_identifiers(path: pathlib.Path | None) -> list[Identifier]:
    if path is None:
        return parse_identifiers(FORBIDDEN)
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("schemaVersion") != 1:
        raise ValueError("identifier file schemaVersion must be 1")
    return parse_identifiers(data.get("identifiers"))


def match_starts(normalized: bytes, identifiers: list[Identifier]) -> Iterator[tuple[int, int]]:
    classes = normalized.translate(CLASSES)
    for identifier in identifiers:
        start = classes.find(identifier.prefilter)
        while start >= 0:
            window = normalized[start : start + identifier.length]
            if hashlib.sha256(window).digest() == identifier.digest:
                yield start, identifier.length
            start = classes.find(identifier.prefilter, start + 1)


def count_matches(data: bytes, identifiers: list[Identifier]) -> int:
    return sum(1 for _ in match_starts(normalize(data), identifiers))


def redact(label: str, identifiers: list[Identifier]) -> str:
    raw = label.encode("utf-8", errors="surrogateescape")
    kept: list[int] = [index for index, value in enumerate(raw) if value not in SEPARATORS]
    normalized = bytes(raw[index] for index in kept).translate(LOWERCASE)
    hidden = [False] * len(raw)
    for start, length in match_starts(normalized, identifiers):
        for index in range(kept[start], kept[start + length - 1] + 1):
            hidden[index] = True
    if not any(hidden):
        return label
    output = bytearray()
    for index, value in enumerate(raw):
        if hidden[index]:
            if index == 0 or not hidden[index - 1]:
                output += b"[forbidden]"
        else:
            output.append(value)
    return output.decode("utf-8", errors="replace")


def record(findings: dict[str, int], label: str, data: bytes, identifiers: list[Identifier]) -> None:
    count = count_matches(label.encode("utf-8", errors="surrogateescape"), identifiers)
    count += count_matches(data, identifiers)
    if count:
        findings[label] = findings.get(label, 0) + count


def tracked_paths() -> list[str]:
    output = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT)
    return [item.decode("utf-8", errors="surrogateescape") for item in output.split(b"\0") if item]


def scan_source(identifiers: list[Identifier]) -> dict[str, int]:
    findings: dict[str, int] = {}
    for relative in tracked_paths():
        path = ROOT / relative
        data = path.read_bytes() if path.is_file() else b""
        record(findings, relative, data, identifiers)
    return findings


def archive_entries(data: bytes) -> list[tuple[str, bytes]] | None:
    if zipfile.is_zipfile(io.BytesIO(data)):
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
    except (tarfile.TarError, OSError, EOFError):
        return None


def scan_archive(
    findings: dict[str, int],
    label: str,
    data: bytes,
    identifiers: list[Identifier],
    *,
    depth: int = 0,
) -> bool:
    entries = archive_entries(data)
    if entries is None:
        return False
    record(findings, label, b"", identifiers)
    for entry, entry_data in entries:
        entry_label = f"{label}!/{entry}"
        if archive_entries(entry_data) is not None:
            if depth >= MAXIMUM_ARCHIVE_DEPTH:
                findings[f"{entry_label} [nested-archive-depth-limit]"] = 1
                continue
            scan_archive(findings, entry_label, entry_data, identifiers, depth=depth + 1)
        else:
            record(findings, entry_label, entry_data, identifiers)
    return True


def scan_input(path: pathlib.Path, identifiers: list[Identifier]) -> dict[str, int]:
    if not path.exists():
        raise FileNotFoundError(f"scan input does not exist: {path}")
    findings: dict[str, int] = {}
    files = sorted(item for item in path.rglob("*") if item.is_file()) if path.is_dir() else [path]
    for file_path in files:
        relative = file_path.relative_to(path).as_posix() if path.is_dir() else file_path.name
        label = f"{path.name}/{relative}" if path.is_dir() else path.name
        data = file_path.read_bytes()
        if not scan_archive(findings, label, data, identifiers):
            record(findings, label, data, identifiers)
    return findings


def merge(into: dict[str, int], addition: dict[str, int]) -> None:
    for path, count in addition.items():
        into[path] = into.get(path, 0) + count


def print_findings(title: str, findings: dict[str, int], identifiers: list[Identifier]) -> None:
    if not findings:
        print(f"{title}: clean")
        return
    print(f"{title}: {sum(findings.values())} match(es) across {len(findings)} path(s)")
    for path, count in sorted(findings.items()):
        print(f"  {count:4d}  {redact(path, identifiers)}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--mode", choices=("strict", "report"), default="strict")
    parser.add_argument("--input", type=pathlib.Path, action="append", default=[])
    parser.add_argument("--skip-source", action="store_true", help="do not scan tracked files")
    parser.add_argument("--identifiers", type=pathlib.Path, help="JSON identifier list to use instead of FORBIDDEN")
    parser.add_argument("--entry-for", metavar="TOKEN", help="print the FORBIDDEN entry for TOKEN and exit")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.entry_for is not None:
        try:
            print(json.dumps(entry_for(args.entry_for), indent=4))
        except ValueError as error:
            print(f"invalid identifier: {error}", file=sys.stderr)
            return 2
        return 0
    try:
        identifiers = load_identifiers(args.identifiers)
    except (OSError, ValueError) as error:
        print(f"invalid identifier list: {error}", file=sys.stderr)
        return 2

    source_findings = {} if args.skip_source else scan_source(identifiers)
    artifact_findings: dict[str, int] = {}
    try:
        for path in args.input:
            merge(artifact_findings, scan_input(path, identifiers))
    except FileNotFoundError as error:
        print(redact(str(error), identifiers), file=sys.stderr)
        return 1

    if not args.skip_source:
        print_findings("tracked source", source_findings, identifiers)
    if args.input:
        print_findings("generated/artifact inputs", artifact_findings, identifiers)
    if args.mode == "report":
        return 0
    return 1 if source_findings or artifact_findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
