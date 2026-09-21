#!/usr/bin/env python3
"""Enforce the injected flag boundary and the default runtime selection."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
PINNED = {
    "Sources/EluAnalytics/Elu.swift": "26a14ad95b577c513dcca6499a443d65b6665249c8b5393fc7b47f1d9f87d628",
    "Sources/EluAnalytics/EluState.swift": "098b5cbcca6842868338f658c6f7ef15ed4f0b5d00d92b1cc0c44204cec1fcc5",
    "Sources/EluAnalytics/EluConfigClient.swift": "152abfb01a6d0aa81e470d3185ecd4db3aeeef26d8626e67bab8f0a41e20d43d",
    "Sources/EluAnalytics/Internal/Facade/EluRuntimeBackend.swift": "5490b85eabf34d4a67b3e6db6a99c0450e9b89a9825ca16914dc41127fc5e5ec",
    "Package.swift": "86701aa42833ddfff4b928e8ed59608cfe46f54e2765656f8166a75633219398",
    "Conformance/V1/manifest.json": "98152d8725c286f29402ba3e420bda8dd364200fb6fdf1cfe49b2da9b8f63e54",
    "Sources/EluAnalytics/Internal/Compatibility/EluLegacyStartupSource.swift": "566fad27cdcf641b74844ac563d2b96630881fb9d08ade9e35b423bc6aeb4e13",
}
LEGACY_SOURCE = "Sources/EluAnalytics/Internal/Compatibility/EluLegacyStartupSource.swift"
# Exact provenance comment only. No provider import, type, or live implementation
# is permitted, including in this reader. Lab upgrade/adoption gates still apply.
LEGACY_PROVENANCE = "// PostHog 3.69.0 source (1c9b3178...). See this overlay's source provenance."
NETWORK_TOKENS = (
    "URLSession",
    "URLRequest",
    "import Network",
    "import CFNetwork",
    "NWConnection",
)
# The flag client is reachable from exactly two files: the runtime that
# composes it over the site-scoped store, and the facade projection that drives
# it. Both are only reached when the runtime selection is standalone.
FLAG_CLIENT_CALLERS = frozenset(
    {
        "Sources/EluAnalytics/Internal/Runtime/EluStandaloneRuntime.swift",
        "Sources/EluAnalytics/Internal/Facade/EluStandaloneFacadeRuntime.swift",
    }
)
# Exact owned seams reviewed independently of the unchanged default selection.
FLAG_TRANSPORT_SOURCE = "Sources/EluAnalytics/Internal/Flags/EluV1URLSessionFlagTransport.swift"
STACK_SOURCE = "Sources/EluAnalytics/Internal/Facade/EluStandaloneStack.swift"
STANDALONE_FACADE_SOURCE = "Sources/EluAnalytics/Internal/Facade/EluStandaloneFacadeRuntime.swift"
BOUND_AUTHORITY_SOURCE = "Sources/EluAnalytics/Internal/Runtime/EluV1TransportAuthority.swift"
FLAG_TRANSPORT_NAME = "EluV1URLSessionFlagTransport"
FLAG_TRANSPORT_PROTOCOLS = ("EluV1FlagTransport", "EluV1AuthorizedFlagTransport")

REPLAY_STORAGE_SOURCES = frozenset({
    "Sources/EluAnalytics/Internal/Replay/EluV2ReplayPreparedRequest.swift",
    "Sources/EluAnalytics/Internal/Replay/EluV2ReplayStoredChunk.swift",
    "Sources/EluAnalytics/Internal/Runtime/EluSQLiteRuntimeQueue.swift",
})


REPLAY_DELIVERY_SOURCES = frozenset({
    "Sources/EluAnalytics/Internal/Config/EluV1ConfigManager.swift",
    "Sources/EluAnalytics/Internal/Replay/EluV2ReplayDeliveryState.swift",
    "Sources/EluAnalytics/Internal/Replay/EluV2ReplayResponse.swift",
    "Sources/EluAnalytics/Internal/Replay/EluV2ReplayDeliveryCoordinator.swift",
    "Sources/EluAnalytics/Internal/Replay/EluV2URLSessionReplayTransport.swift",
})
REPLAY_TRANSPORT_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluV2URLSessionReplayTransport.swift"
REPLAY_TRANSPORT_NAME = "EluV2URLSessionReplayTransport"
NATIVE_AUTHORITY_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluNativeReplayAuthority.swift"
NATIVE_SEALER_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluNativeReplaySealer.swift"
NATIVE_CAPTURE_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluNativeReplayCaptureOwner.swift"
NATIVE_COLLECTOR_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluUIKitReplayCollector.swift"
NATIVE_COMPOSITION_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluNativeReplayComposition.swift"
NATIVE_RUNTIME_SOURCE = "Sources/EluAnalytics/Internal/Runtime/EluStandaloneRuntime.swift"
NATIVE_CAPTURE_CALLERS = frozenset({NATIVE_CAPTURE_SOURCE, NATIVE_AUTHORITY_SOURCE, NATIVE_COMPOSITION_SOURCE, NATIVE_RUNTIME_SOURCE, "Sources/EluAnalytics/Internal/Runtime/EluSQLiteRuntimeQueue.swift"})


def scan_replay_storage_source(path: pathlib.Path, text: str) -> list[str]:
    errors: list[str] = []
    exact = path.as_posix()
    allowed = REPLAY_STORAGE_SOURCES | REPLAY_DELIVERY_SOURCES | {NATIVE_AUTHORITY_SOURCE, NATIVE_SEALER_SOURCE, NATIVE_CAPTURE_SOURCE, NATIVE_COMPOSITION_SOURCE, NATIVE_RUNTIME_SOURCE}
    if re.search(r"\bEluNativeReplayCapture\w*\b", text) and exact not in NATIVE_CAPTURE_CALLERS:
        errors.append(f"{path} references native capture ownership outside its exact internal files")
    physical = set(re.findall(r"\bEluNativeReplayCapture(?:Owner|Run|Fence)\b", text))
    if physical and exact != NATIVE_CAPTURE_SOURCE and not (
        exact in {NATIVE_COMPOSITION_SOURCE, NATIVE_RUNTIME_SOURCE} and physical <= {"EluNativeReplayCaptureOwner"}
    ):
        errors.append(f"{path} references the physical native capture owner outside its exact composition")
    if exact in {NATIVE_COMPOSITION_SOURCE, NATIVE_RUNTIME_SOURCE}:
        permitted_capture = {"EluNativeReplayCaptureOwner"}
        permitted_replay = {"EluV2ReplayDeliveryAuthority", "EluV2ReplayDeliveryCoordinator"}
        if exact == NATIVE_COMPOSITION_SOURCE: permitted_capture.add("EluNativeReplayCaptureOutcome")
        else: permitted_replay.add("EluV2ReplayHTTPTransport")
        if set(re.findall(r"\bEluNativeReplayCapture\w*\b", text)) - permitted_capture or set(re.findall(r"\bEluV2(?:Replay|SealedReplay)\w*\b", text)) - permitted_replay:
            errors.append(f"{path} widens the exact native composition value boundary")
        for token in ["ensureReplaySchema", "ensureReplayDeliverySchema", "ensureNativeReplayAuthoritySchema", "appendNativeReplay", "appendReplay"]:
            if re.search(rf"\b{token}\b", text): errors.append(f"{path} bypasses original native composition ownership")
    if exact == NATIVE_COMPOSITION_SOURCE and "actor EluNativeReplayComposition" in text:
        if "!capabilities.transports.isEmpty" not in text or "!capabilities.readbackProvenProtocolGenerations.isEmpty" not in text or re.search(r"\bEluNativeReplayCaptureOwner\s*\(", text):
            errors.append(f"{path} bypasses the qualified runtime capture construction")
    if re.search(r"\bEluNativeReplayComposition\w*\b", text) and exact not in {NATIVE_COMPOSITION_SOURCE, NATIVE_RUNTIME_SOURCE}:
        errors.append(f"{path} references native composition outside its exact runtime")
    if "requiringCurrent" in text and exact not in {NATIVE_RUNTIME_SOURCE, "Sources/EluAnalytics/Internal/Runtime/EluSQLiteRuntimeQueue.swift"}:
        errors.append(f"{path} consumes sealed local authority outside its exact runtime")
    if "ownsPrepared" in text and exact not in {NATIVE_RUNTIME_SOURCE, NATIVE_AUTHORITY_SOURCE}:
        errors.append(f"{path} consumes native prepared ownership outside its exact runtime")
    if re.search(r"\bEluUIKitReplayCollector\b", text) and exact not in {NATIVE_CAPTURE_SOURCE, NATIVE_COLLECTOR_SOURCE}:
        errors.append(f"{path} references the native collector outside its physical owner")
    if exact == NATIVE_SEALER_SOURCE:
        references = set(re.findall(r"\bEluV2(?:Replay|SealedReplay)\w*\b", text))
        state_operations = ("EluSQLiteRuntimeQueue", "EluNativeReplayAuthority", "EluNativeReplayScope",
                            "EluNativeReplayPermit", "EluNativeReplaySynchronousGuard", "EluNativeReplayPreparedAuthority",
                            "EluNativeReplayProjectionInput", "appendReplay", "reconcileReplay", "ensureReplaySchema",
                            "ensureReplayDeliverySchema", "ensureNativeReplayAuthoritySchema", "nativeReplayProjection",
                            "installNativeReplayPrivacy", "beginNativeReplayStartAccounting", "stopNativeReplayAccounting",
                            "nativeReplayPermitGuard", "persistNativeReplayClockDenial")
        if references - {"EluV2ReplayPreparedRequest"} or any(re.search(rf"\b{token}\b", text) for token in state_operations):
            errors.append(f"{path} adds storage or delivery behavior to the pure native sealer")
    if re.search(r"\bEluNativeReplaySealer\b", text) and exact not in {NATIVE_SEALER_SOURCE, NATIVE_CAPTURE_SOURCE}:
        errors.append(f"{path} references the native sealer outside its exact physical owner")
    if (re.search(r"\bEluV2(?:Replay|SealedReplay)\w*\b", text) or "ensureReplaySchema" in text or "ensureReplayDeliverySchema" in text) and exact not in allowed:
        errors.append(f"{path} references unconstructed replay storage outside its exact files")
    if exact in allowed and "/Replay/" in exact:
        permitted = {"URLSession", "URLRequest"} if exact == REPLAY_TRANSPORT_SOURCE else ({"import UIKit"} if exact == NATIVE_CAPTURE_SOURCE else set())
        for token in (*NETWORK_TOKENS, "import UIKit", "import PostHog"):
            if token in text and token not in permitted:
                errors.append(f"{path} adds capture/network/provider behavior to opaque replay storage")
    if re.search(rf"\b{REPLAY_TRANSPORT_NAME}\b", text) and exact not in {REPLAY_TRANSPORT_SOURCE, NATIVE_RUNTIME_SOURCE}:
        errors.append(f"{path} references the unconstructed concrete replay transport")
    if re.search(rf"\b{REPLAY_TRANSPORT_NAME}\s*\(", text) and exact != NATIVE_RUNTIME_SOURCE:
        errors.append(f"{path} constructs the replay transport outside its exact runtime")
    if exact == NATIVE_RUNTIME_SOURCE and "installNativeReplayComposition" in text:
        required = ["capabilities: EluNativeReplayCapabilities = EluNativeReplayCapabilities()",
                    "nativeAuthority.ownsPrepared(prepared)", "prepared.supportedProtocolGeneration != nil",
                    "value?.requiringCurrent", "configurationWitness == source", "readZone() == zone"]
        if any(token not in text for token in required) or len(re.findall(rf"\b{REPLAY_TRANSPORT_NAME}\s*\(", text)) != 1 or len(re.findall(r"\bEluNativeReplayCaptureOwner\s*\(", text)) != 1:
            errors.append(f"{path} weakens the empty proof/original source native composition gate")
    for match in re.finditer(r"\b(class|struct|actor|enum|extension)\s+(\w+)(?:(?!\{).)*?:([^\{]+)\{", text, re.DOTALL):
        kind, name, bases = match.groups()
        if re.search(r"\bEluV2ReplayHTTPTransport\b", bases) and not (
            exact == REPLAY_TRANSPORT_SOURCE and kind == "class" and name == REPLAY_TRANSPORT_NAME
            and re.sub(r"\s+", " ", bases).strip() == "EluV2ReplayHTTPTransport, @unchecked Sendable"
        ):
            errors.append(f"{path} adds an unapproved replay transport conformer")
    return errors


# The candidate standalone-only default remains internal; proof is gated separately.
DEFAULT_SELECTION = "    var runtimeSelection: EluRuntimeSelection = .standalone\n"


def scan_transport_conformers(text: str, *, exact_transport: bool = False) -> list[str]:
    errors: list[str] = []
    declarations = re.finditer(
        r"\b(class|struct|actor|enum|extension)\s+(\w+)(?:(?!\{).)*?:([^\{]+)\{",
        text,
        re.DOTALL,
    )
    for declaration in declarations:
        kind, name, bases = declaration.groups()
        if not any(re.search(rf"\b{protocol}\b", bases) for protocol in FLAG_TRANSPORT_PROTOCOLS):
            continue
        expected_bases = re.sub(r"\s+", " ", bases).strip()
        if not (
            exact_transport
            and kind == "class"
            and name == FLAG_TRANSPORT_NAME
            and expected_bases == "EluV1AuthorizedFlagTransport, @unchecked Sendable"
        ):
            errors.append("flag module contains an unapproved concrete transport conformer")
    return errors


def scan_flag_source(text: str, path: pathlib.Path | None = None) -> list[str]:
    exact_transport = path is not None and path.as_posix() == FLAG_TRANSPORT_SOURCE
    allowed_network_tokens = {"URLSession", "URLRequest"} if exact_transport else set()
    errors = [
        f"flag module contains forbidden network token {token}"
        for token in NETWORK_TOKENS
        if token in text and token not in allowed_network_tokens
    ]
    errors.extend(scan_transport_conformers(text, exact_transport=exact_transport))
    if not exact_transport and re.search(rf"\b{FLAG_TRANSPORT_NAME}\b", text):
        errors.append("flag module references the concrete transport outside its exact source")
    return errors


def scan_outside_source(path: pathlib.Path, text: str) -> list[str]:
    errors: list[str] = []
    exact_path = path.as_posix()
    stack = exact_path == STACK_SOURCE
    allowed_caller = exact_path in FLAG_CLIENT_CALLERS or stack
    bound_authority = exact_path == BOUND_AUTHORITY_SOURCE
    if "EluV1FlagClient" in text and not allowed_caller:
        errors.append(f"{path} references the flag client outside the wired callers")
    if any(re.search(rf"\b{protocol}\b", text) for protocol in FLAG_TRANSPORT_PROTOCOLS) and not (allowed_caller or bound_authority):
        errors.append(f"{path} references the injected flag transport boundary")
    if stack:
        # One reviewed construction site, with no platform networking or direct
        # client/schema activation. Caller-supplied transports stay injectable.
        references = re.findall(rf"\b{FLAG_TRANSPORT_NAME}\b", text)
        construction = re.findall(rf"\b{FLAG_TRANSPORT_NAME}\(siteKey: siteKey\)", text)
        if len(references) != 1 or len(construction) != 1:
            errors.append(f"{path} changed the exact owned flag transport construction")
        if re.search(r"\b(?:URLSession|URLRequest|NWConnection)\b|import\s+(?:Network|CFNetwork)\b", text):
            errors.append(f"{path} performs platform networking outside a transport")
        if re.search(r"\bEluV1FlagClient\s*[.(]", text):
            errors.append(f"{path} bypasses the runtime-owned flag client activation")
    elif re.search(rf"\b{FLAG_TRANSPORT_NAME}\b", text):
        errors.append(f"{path} references the unconstructed concrete flag transport")
    if exact_path in {STACK_SOURCE, STANDALONE_FACADE_SOURCE} and any(token in text for token in ["readbackProvenTransports", "readbackProvenProtocolGenerations"]):
        errors.append(f"{path} enables native proof in the public composition")
    if exact_path == STANDALONE_FACADE_SOURCE:
        if "installNativeReplayComposition" in text and (text.count("deferredUntilActivation: true") != 2 or "await runtime.activateNativeReplayComposition()" not in text):
            errors.append(f"{path} bypasses ordered native composition activation")
        normalized = re.sub(r"\s+", " ", text)
        owned_factory = (
            "openStack: { try await EluStandaloneStack.make( "
            "rootDirectoryURL: rootDirectoryURL, siteKey: siteKey, "
            "configHost: context.configHost, performance: context.performance, "
            "legacyStartupSource: legacyStartupSource ) }, "
            "guardedFlagsDidLoad: context.guardedFlagsDidLoad"
        )
        if normalized.count(owned_factory) != 1:
            errors.append(f"{path} changed the exact owned bootstrap host/callback binding")
    errors.extend(scan_transport_conformers(text))
    if bound_authority:
        # This seam may define protocols and delegate to an injected transport,
        # but it cannot construct a flag transport or gain platform networking.
        errors.extend(scan_flag_source(text, path))
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

    package_text = (root / "Package.swift").read_text(encoding="utf-8")
    if re.search(r"\.(?:package|binaryTarget)\s*\(", package_text):
        errors.append("standalone package adds an external source or binary dependency")
    source_root = root / "Sources/EluAnalytics"
    for path in source_root.rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        dependency_text = text.replace(LEGACY_PROVENANCE, "", 1) if path.relative_to(root).as_posix() == LEGACY_SOURCE else text
        if re.search(r"\b(?:PostHog\w*|phlibwebp|PHPLCrashReporter|EluProviderRuntime)\b", dependency_text):
            errors.append(f"{path.relative_to(root)} restores a removed provider source dependency")
        errors.extend(scan_replay_storage_source(path.relative_to(root), text))
    replay_activation = {
        path.relative_to(root).as_posix(): path.read_text(encoding="utf-8").count("ensureReplaySchema")
        for path in source_root.rglob("*.swift") if "ensureReplaySchema" in path.read_text(encoding="utf-8")
    }
    if replay_activation != {"Sources/EluAnalytics/Internal/Runtime/EluSQLiteRuntimeQueue.swift": 1, NATIVE_AUTHORITY_SOURCE: 1}:
        errors.append("replay schema activation escaped its unconstructed storage definition")
    delivery_activation = {
        path.relative_to(root).as_posix(): path.read_text(encoding="utf-8").count("ensureReplayDeliverySchema")
        for path in source_root.rglob("*.swift") if "ensureReplayDeliverySchema" in path.read_text(encoding="utf-8")
    }
    if delivery_activation != {"Sources/EluAnalytics/Internal/Runtime/EluSQLiteRuntimeQueue.swift": 1, NATIVE_AUTHORITY_SOURCE: 1}:
        errors.append("replay delivery schema activation escaped its unconstructed definition")
    flag_root = source_root / "Internal/Flags"
    for path in flag_root.rglob("*.swift"):
        errors.extend(scan_flag_source(path.read_text(encoding="utf-8"), path.relative_to(root)))
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

    facade_text = (root / "Sources/EluAnalytics/Elu.swift").read_text(encoding="utf-8")
    if DEFAULT_SELECTION not in facade_text:
        errors.append("the default runtime selection is no longer standalone")
    if "runtimeSelection" in facade_text and "public var runtimeSelection" in facade_text:
        errors.append("the runtime selection escaped into the public API")

    return errors


def main() -> int:
    errors = verify()

    if errors:
        for error in errors:
            print(f"feature-flag boundary verification failed: {error}", file=sys.stderr)
        return 1
    print("verified explicit feature-flag transport seams, pinned wiring, and default selection")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
