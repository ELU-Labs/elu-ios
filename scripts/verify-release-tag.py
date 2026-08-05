#!/usr/bin/env python3
"""Require an exact reviewed tag signed by an explicitly trusted GPG key."""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import shutil
import subprocess


ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION_SOURCE = ROOT / "Sources" / "EluAnalytics" / "EluState.swift"
VERSION_PATTERN = re.compile(r'^\s*static let sdkVersion = "([^"]+)"\s*$', re.MULTILINE)
TAG_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
REVIEW_PATTERN = re.compile(r"^Reviewed-by:\s+\S(?:.*\S)?$", re.IGNORECASE)
FINGERPRINT_PATTERN = re.compile(r"^[0-9A-F]{40}(?:[0-9A-F]{24})?$")
TRUSTED_FINGERPRINTS_ENV = "ELU_TRUSTED_RELEASE_SIGNING_FINGERPRINTS"


def git(*arguments: str, input_text: str | None = None) -> str:
    return subprocess.run(
        ["git", *arguments],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
        input=input_text,
    ).stdout.strip()


def trusted_fingerprints() -> set[str]:
    raw = os.environ.get(TRUSTED_FINGERPRINTS_ENV, "")
    fingerprints = {item.upper() for item in re.split(r"[\s,]+", raw.strip()) if item}
    if not fingerprints:
        raise SystemExit(
            f"{TRUSTED_FINGERPRINTS_ENV} is not configured; release signing trust fails closed"
        )
    invalid = sorted(item for item in fingerprints if FINGERPRINT_PATTERN.fullmatch(item) is None)
    if invalid:
        raise SystemExit(
            f"{TRUSTED_FINGERPRINTS_ENV} must contain full 40- or 64-hex fingerprints only"
        )
    return fingerprints


def verified_signature_fingerprints(ref: str) -> set[str]:
    gpg_program = shutil.which("gpg")
    if gpg_program is None:
        raise SystemExit("GPG is required to verify a release tag")
    result = subprocess.run(
        [
            "git",
            "-c",
            "gpg.format=openpgp",
            "-c",
            f"gpg.program={gpg_program}",
            "-c",
            f"gpg.openpgp.program={gpg_program}",
            "verify-tag",
            "--raw",
            ref,
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit("release tag must carry a valid GPG signature")

    fingerprints: set[str] = set()
    marker = "[GNUPG:] VALIDSIG "
    for line in f"{result.stdout}\n{result.stderr}".splitlines():
        if not line.startswith(marker):
            continue
        fields = line.removeprefix(marker).split()
        candidates = fields[:1]
        if len(fields) >= 10:
            candidates.append(fields[-1])
        fingerprints.update(
            candidate.upper()
            for candidate in candidates
            if FINGERPRINT_PATTERN.fullmatch(candidate.upper())
        )
    if not fingerprints:
        raise SystemExit("git verified the tag but GPG did not report a full VALIDSIG fingerprint")
    return fingerprints


def tag_has_review_trailer(ref: str) -> bool:
    message = git(
        "for-each-ref",
        "--format=%(contents:subject)%0a%0a%(contents:body)",
        ref,
    )
    trailers = git("interpret-trailers", "--parse", input_text=message)
    return any(REVIEW_PATTERN.fullmatch(line) for line in trailers.splitlines())


def tag_headers(ref: str) -> dict[str, str]:
    raw = git("cat-file", "-p", ref)
    headers: dict[str, str] = {}
    for line in raw.splitlines():
        if not line:
            break
        key, separator, value = line.partition(" ")
        if separator:
            headers[key] = value
    return headers


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("tag")
    args = parser.parse_args()
    tag = args.tag
    if TAG_PATTERN.fullmatch(tag) is None:
        raise SystemExit(f"release tag is not an exact supported semantic version: {tag}")

    matches = VERSION_PATTERN.findall(VERSION_SOURCE.read_text(encoding="utf-8"))
    if len(matches) != 1:
        raise SystemExit("expected exactly one EluCore.sdkVersion declaration")
    version = matches[0]
    if tag != version:
        raise SystemExit(f"tag {tag} does not match EluCore.sdkVersion {version}")

    ref = f"refs/tags/{tag}"
    try:
        object_type = git("cat-file", "-t", ref)
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"release tag does not exist: {tag}") from error
    if object_type != "tag":
        raise SystemExit("release tag must be an annotated GPG-signed tag object")
    headers = tag_headers(ref)
    if headers.get("tag") != tag:
        raise SystemExit("release tag object's signed name does not match the requested tag")
    if headers.get("type") != "commit" or headers.get("object") != git("rev-parse", "HEAD"):
        raise SystemExit("release tag does not point at the checked-out commit")
    if not tag_has_review_trailer(ref):
        raise SystemExit("release tag must contain a Reviewed-by: trailer")

    trusted = trusted_fingerprints()
    observed = verified_signature_fingerprints(ref)
    accepted = trusted.intersection(observed)
    if not accepted:
        raise SystemExit(
            "release tag signature is valid but its full signer fingerprint is not trusted"
        )
    if git("status", "--porcelain=v1", "--untracked-files=all"):
        raise SystemExit("worktree changes, including untracked files, are not publishable")

    print(f"reviewed trusted GPG release tag verified: {tag} ({sorted(accepted)[0]})")


if __name__ == "__main__":
    main()
