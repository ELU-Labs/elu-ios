#!/usr/bin/env python3
"""Enforce the internal, injected, specified-not-wired flag boundary."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
PINNED = {
    "Sources/EluAnalytics/Elu.swift": "e1eed0e739c4ef08972b3a9ced1f580f490906ac222687d4928272cb81297170",
    "Sources/EluAnalytics/EluState.swift": "e5511949ec2f2e9eff228160f454fab7fa8c209d9c98f6a5c1ce9fe156bd0985",
    "Sources/EluAnalytics/EluConfigClient.swift": "0f633cf989f7212ad4272684723089075792cfccc23dc11eefc7450c50fd55d3",
    "Package.swift": "fb7e4817911a75b2bd2ea0c173163f7a44dcf4c4356b31ac49c5ac13276a348b",
    "Conformance/V1/manifest.json": "98152d8725c286f29402ba3e420bda8dd364200fb6fdf1cfe49b2da9b8f63e54",
}
NETWORK_TOKENS = (
    "URLSession",
    "URLRequest",
    "import Network",
    "import CFNetwork",
    "NWConnection",
)


def scan_flag_source(text: str) -> list[str]:
    errors = [f"new flag module contains forbidden network token {token}" for token in NETWORK_TOKENS if token in text]
    concrete = re.search(
        r"\b(?:class|struct|actor|enum)\s+\w+(?:(?!\{).)*?:(?:(?!\{).)*?"
        r"\bEluV1FlagTransport\b",
        text,
        re.DOTALL,
    )
    if concrete:
        errors.append("new flag module contains a concrete transport conformer")
    return errors


def scan_outside_source(path: pathlib.Path, text: str) -> list[str]:
    errors: list[str] = []
    if "EluV1FlagClient" in text:
        errors.append(f"{path} references the unwired flag client")
    if "EluV1FlagTransport" in text:
        errors.append(f"{path} references the injected flag transport boundary")
    if "ensureFlagSchema" in text and path.name != "EluSQLiteRuntimeQueue.swift":
        errors.append(f"{path} invokes the lazy flag migration")
    return errors


def verify(root: pathlib.Path = ROOT) -> list[str]:
    errors: list[str] = []
    for relative, expected in PINNED.items():
        data = (root / relative).read_bytes()
        actual = hashlib.sha256(data).hexdigest()
        if actual != expected:
            errors.append(f"{relative} digest {actual}, expected {expected}")

    manifest = json.loads((root / "Conformance/V1/manifest.json").read_bytes())
    if manifest.get("transport", {}).get("status") != "specified-not-wired":
        errors.append("v1 transport status is no longer specified-not-wired")
    if manifest.get("transport", {}).get("runtimeBehavior") != "unchanged":
        errors.append("v1 transport runtimeBehavior is no longer unchanged")

    source_root = root / "Sources/EluAnalytics"
    flag_root = source_root / "Internal/Flags"
    for path in flag_root.rglob("*.swift"):
        errors.extend(scan_flag_source(path.read_text(encoding="utf-8")))
    for path in source_root.rglob("*.swift"):
        if flag_root in path.parents:
            continue
        errors.extend(scan_outside_source(path.relative_to(root), path.read_text(encoding="utf-8")))

    runtime_path = source_root / "Internal/Runtime/EluSQLiteRuntimeQueue.swift"
    client_path = flag_root / "EluV1FlagClient.swift"
    ensure_occurrences = {
        path.relative_to(root): path.read_text(encoding="utf-8").count("ensureFlagSchema")
        for path in source_root.rglob("*.swift")
        if "ensureFlagSchema" in path.read_text(encoding="utf-8")
    }
    expected_ensure_occurrences = {
        runtime_path.relative_to(root): 1,
        client_path.relative_to(root): 1,
    }
    if ensure_occurrences != expected_ensure_occurrences:
        errors.append(
            "lazy flag migration occurrences escaped the exact definition/activation boundary: "
            f"{ensure_occurrences}"
        )
    runtime_text = runtime_path.read_text(encoding="utf-8")
    if "\n    func ensureFlagSchema() throws {\n" not in runtime_text:
        errors.append("lazy flag migration definition moved from the runtime actor boundary")
    client_text = client_path.read_text(encoding="utf-8")
    activation = (
        "    ) async throws -> EluV1FlagClient {\n"
        "        try await runtime.ensureFlagSchema()\n"
        "        return EluV1FlagClient(\n"
    )
    if activation not in client_text:
        errors.append("lazy flag migration is not the first explicit flag-client activation step")

    public_sources = [
        root / "Sources/EluAnalytics/Elu.swift",
        root / "Sources/EluAnalytics/EluState.swift",
        root / "Sources/EluAnalytics/EluConfigClient.swift",
    ]
    if any("ensureFlagSchema" in path.read_text(encoding="utf-8") for path in public_sources):
        errors.append("public startup invokes the lazy flag migration")

    return errors


def main() -> int:
    errors = verify()

    if errors:
        for error in errors:
            print(f"feature-flag boundary verification failed: {error}", file=sys.stderr)
        return 1
    print("verified internal injected feature-flag boundary and pinned public wiring")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
