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
    "Sources/EluAnalytics/Elu.swift": "34228f503ff3db4cfb6fe4f77d40b81f3d93160733217a696b6a633b909f02ec",
    "Sources/EluAnalytics/EluState.swift": "5aae43787ea81e435e4d82b8aff606eaddbbfa152af7edf8c9d20c2f5fda0e0d",
    "Sources/EluAnalytics/EluConfigClient.swift": "152abfb01a6d0aa81e470d3185ecd4db3aeeef26d8626e67bab8f0a41e20d43d",
    "Sources/EluAnalytics/Internal/Facade/EluRuntimeBackend.swift": "2e37a7844b789dd0e3ab0e80a044843ec9bdefa3897d4f6fc6f2961316b9e6f9",
    "Package.swift": "86701aa42833ddfff4b928e8ed59608cfe46f54e2765656f8166a75633219398",
    "Conformance/V1/manifest.json": "98152d8725c286f29402ba3e420bda8dd364200fb6fdf1cfe49b2da9b8f63e54",
}
RETIRED_STARTUP_SYMBOLS = (
    "EluLegacyStartupSource", "EluLegacyEventsImport", "legacyStartupSource",
    "legacy_events_import", "installLegacyEvents",
)
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
DECLARED_BOOTSTRAP_SELECTION = "configurationFormat: context.declaredRegionReplayEnabled ? .nativeV3 : .v2"
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
NATIVE_PROTOCOL_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluNativeReplayProtocol.swift"
NATIVE_AUTHORITY_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluNativeReplayAuthority.swift"
NATIVE_SEALER_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluNativeReplaySealer.swift"
NATIVE_RASTER_SEALER_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluNativeRasterSealer.swift"
NATIVE_RASTER_RESPONSE_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluNativeRasterResponse.swift"
NATIVE_RASTER_DELIVERY_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluV2ReplayDeliveryCoordinator.swift"
NATIVE_RASTER_DELIVERY_STATE = "Sources/EluAnalytics/Internal/Replay/EluV2ReplayDeliveryState.swift"
NATIVE_RASTER_STORAGE_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluStoredReplayRecord.swift"
NATIVE_RASTER_QUEUE_SOURCE = "Sources/EluAnalytics/Internal/Runtime/EluSQLiteRuntimeQueue.swift"
NATIVE_CAPTURE_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluNativeReplayCaptureOwner.swift"
NATIVE_WINDOW_SOURCE = "Sources/EluAnalytics/EluReplayWindow.swift"
SWIFTUI_COLLECTOR_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluSwiftUIReplayCollector.swift"
NATIVE_COLLECTOR_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluUIKitReplayCollector.swift"
NATIVE_INTERACTION_PROJECTION_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluUIKitReplayInteractionProjection.swift"
NATIVE_TOUCH_OBSERVER_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluUIKitReplayTouchObserver.swift"
NATIVE_INTERACTION_MAILBOX_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluNativeReplayInteractionMailbox.swift"
NATIVE_COMPOSITION_SOURCE = "Sources/EluAnalytics/Internal/Replay/EluNativeReplayComposition.swift"
NATIVE_RUNTIME_SOURCE = "Sources/EluAnalytics/Internal/Runtime/EluStandaloneRuntime.swift"
NATIVE_CAPTURE_CALLERS = frozenset({NATIVE_CAPTURE_SOURCE, NATIVE_AUTHORITY_SOURCE, NATIVE_COMPOSITION_SOURCE, NATIVE_RUNTIME_SOURCE, "Sources/EluAnalytics/Internal/Runtime/EluSQLiteRuntimeQueue.swift"})


def scan_replay_storage_source(path: pathlib.Path, text: str) -> list[str]:
    errors: list[str] = []
    exact = path.as_posix()
    allowed = REPLAY_STORAGE_SOURCES | REPLAY_DELIVERY_SOURCES | {NATIVE_AUTHORITY_SOURCE, NATIVE_SEALER_SOURCE, NATIVE_CAPTURE_SOURCE, NATIVE_COMPOSITION_SOURCE, NATIVE_RUNTIME_SOURCE}
    if exact == NATIVE_PROTOCOL_SOURCE:
        required = [
            'case .v1: return "elu-native-wireframe-v1"', 'case .v2: return "elu-native-wireframe-v2"',
            'case .v1: return "protocol-generation-v1"', 'case .v2: return "protocol-generation-v2"',
            'compression.utf8.elementsEqual("gzip".utf8)',
            '$0.codec.utf8.elementsEqual(codec.utf8) && $0.generation.utf8.elementsEqual(generation.utf8)',
        ]
        cases = re.findall(r"^    case (v[0-9]+)$", text, re.MULTILINE)
        if cases != ["v1", "v2"] or any(token not in text for token in required) or re.search(r"\b(URLSession|EluSQLiteRuntimeQueue|EluNativeReplayPermit)\b", text):
            errors.append(f"{path} weakens the closed descriptive native protocol tuples")
    tuple_guards = {
        NATIVE_AUTHORITY_SOURCE: ["capabilities.transports(for: original.context.capabilities.replay.replayProtocolGeneration)",
            "capabilities.transports(for: prepared.resolution.replayProtocolGeneration).contains(pair)"],
        "Sources/EluAnalytics/Internal/Runtime/EluPrivacyStateProjector.swift": ["capabilities.pairs(for: observation.context.capabilities.replay.replayProtocolGeneration)"],
        "Sources/EluAnalytics/Internal/Runtime/EluSQLiteRuntimeQueue.swift": [
            "if EluNativeReplayProtocol.isNativeCodec(prepared.codec), nativeAdmission == nil",
            "let tuple = EluNativeReplayProtocol.matching(codec: prepared.codec",
            "pair == tuple.transport", "EluV2ReplayText.equal(tuple.generation, admission.permit.resolution.replayProtocolGeneration)",
            "capabilities.transports(for: document.capabilities?.replay.replayProtocolGeneration)",
        ],
        "Sources/EluAnalytics/Internal/Config/EluV1ConfigManager.swift": [
            "EluNativeReplayProtocol.matching(codec: $0.codec, compression: $0.compression.rawValue,", "generation: generation) != nil &&",
        ],
    }
    # Inspect real complete owners, not the token-only boundary negative controls.
    if exact in tuple_guards and ("import Foundation" in text):
        if any(token not in text for token in tuple_guards[exact]):
            errors.append(f"{path} weakens original-generation native tuple selection or admission")
    capture_references = re.sub(r"\bEluNativeReplayCaptureError\b", "", text) if exact == SWIFTUI_COLLECTOR_SOURCE else text
    if re.search(r"\bEluNativeReplayCapture\w*\b", capture_references) and exact not in NATIVE_CAPTURE_CALLERS:
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
            errors.append(f"{path} bypasses the supported runtime capture construction")
    if exact == NATIVE_COMPOSITION_SOURCE and "actor EluNativeReplayComposition" in text:
        for token in ["declaredRegionReplaySupported: Bool = false", "if declaredRegionReplaySupported",
                      "EluSwiftUIReplayRegistry.discover(in: selected)",
                      "declaredSelection.sameRoot(as: selected)", "blockedRaster.sameCaptureContext(as: value)",
                      "retainEpochRefusal(outcome)", "await original.stop()"]:
            if token not in text: errors.append(f"{path} loses original declared-root selection or epoch refusal")
    if exact == STACK_SOURCE and "static func make(" in text:
        for token in ["configurationFormat: EluV2ConfigRequest.Format = .v2",
                      "declaredRegionReplaySupported: Bool = false", "format: configurationFormat",
                      "declaredRegionReplaySupported: declaredRegionReplaySupported"]:
            if token not in text: errors.append(f"{path} changes the explicit dormant original source selection")
    if re.search(r"\bEluSwiftUIReplay(?:Registry|Binding|Registration)\b", text) and exact not in {
            SWIFTUI_COLLECTOR_SOURCE, "Sources/EluAnalytics/EluSwiftUIReplayScope.swift",
            NATIVE_COMPOSITION_SOURCE, NATIVE_RUNTIME_SOURCE, NATIVE_CAPTURE_SOURCE}:
        errors.append(f"{path} escapes original declared-root registration ownership")
    if exact == SWIFTUI_COLLECTOR_SOURCE and "final class EluSwiftUIReplayRegistry" in text:
        for token in ["weak var host: UIView?", "weak var window: UIWindow?",
                      "Self.installed.count < 64", "Self.discoveryClosed = true",
                      "$0.value == nil && ($0.host == nil || $0.window == nil)",
                      "matches.allSatisfy({ $0.value != nil })",
                      "originalSource?.revoke()", "bindingFence.withdraw()"]:
            if token not in text: errors.append(f"{path} loses bounded persistent declared-root intent or source revocation")
    if re.search(r"\bEluNativeReplayComposition\w*\b", text) and exact not in {NATIVE_COMPOSITION_SOURCE, NATIVE_RUNTIME_SOURCE}:
        errors.append(f"{path} references native composition outside its exact runtime")
    if "requiringCurrent" in text and exact not in {NATIVE_RUNTIME_SOURCE, "Sources/EluAnalytics/Internal/Runtime/EluSQLiteRuntimeQueue.swift"}:
        errors.append(f"{path} consumes sealed local authority outside its exact runtime")
    if "ownsPrepared" in text and exact not in {NATIVE_RUNTIME_SOURCE, NATIVE_AUTHORITY_SOURCE}:
        errors.append(f"{path} consumes native prepared ownership outside its exact runtime")
    if re.search(r"\bEluUIKitReplayCollector\b", text) and exact not in {NATIVE_CAPTURE_SOURCE, NATIVE_COLLECTOR_SOURCE, NATIVE_INTERACTION_PROJECTION_SOURCE}:
        errors.append(f"{path} references the native collector outside its physical owner or exact detached projection")
    interaction_callers = {
        "EluUIKitReplayCollectedProjection": {NATIVE_COLLECTOR_SOURCE, NATIVE_INTERACTION_PROJECTION_SOURCE},
        "EluUIKitReplayInteractionProjection": {NATIVE_INTERACTION_PROJECTION_SOURCE, NATIVE_TOUCH_OBSERVER_SOURCE, NATIVE_CAPTURE_SOURCE},
        "EluUIKitReplayTouchObserver": {NATIVE_TOUCH_OBSERVER_SOURCE, NATIVE_CAPTURE_SOURCE, NATIVE_WINDOW_SOURCE},
        "EluUIKitReplayTouchWorkBudget": {NATIVE_TOUCH_OBSERVER_SOURCE},
        "EluUIKitReplayTouchFact": {NATIVE_TOUCH_OBSERVER_SOURCE},
        "EluNativeReplayInteractionMailbox": {NATIVE_INTERACTION_MAILBOX_SOURCE, NATIVE_TOUCH_OBSERVER_SOURCE, NATIVE_CAPTURE_SOURCE},
        "EluReplayWindow": {NATIVE_WINDOW_SOURCE, NATIVE_CAPTURE_SOURCE},
    }
    for token, callers in interaction_callers.items():
        if re.search(rf"\b{token}\b", text) and exact not in callers:
            errors.append(f"{path} escapes original native interaction ownership")
    if exact in {NATIVE_INTERACTION_PROJECTION_SOURCE, NATIVE_TOUCH_OBSERVER_SOURCE, NATIVE_INTERACTION_MAILBOX_SOURCE}:
        forbidden = ("EluSQLiteRuntimeQueue", "EluNativeReplayAuthority", "EluNativeReplayCapabilities",
            "EluNativeReplayPermit", "EluNativeWireframeV2Encoder", "EluNativeReplaySealer",
            "URLSession", "URLRequest", "UIGestureRecognizer", "addGestureRecognizer", "method_exchangeImplementations")
        if any(re.search(rf"\b{token}\b", text) for token in forbidden) or re.search(r"\b(?:UUID|Task)\s*\(|\bTask(?:\.detached)?\s*\{|\bclass\s+\w+\s*:\s*UIWindow\b", text):
            errors.append(f"{path} adds authority, IDs, async work or automatic host interception to dormant interaction values")
    if exact == NATIVE_COLLECTOR_SOURCE and "final class EluUIKitReplayCollector" in text and "retainInteractionProjection: Bool = false" not in text:
        errors.append(f"{path} adds interaction witness work to ordinary v1 capture")
    if exact == NATIVE_COLLECTOR_SOURCE and "final class EluUIKitReplayCollector" in text:
        for token in ["paintVetoes: interactionPaintVetoes", "let confined = view.clipsToBounds || layer.masksToBounds",
                      "interactionPaintVetoes[projection.identity] = try rect(veto)",
                      "interactionInheritedClip: interactionClip"]:
            if token not in text: errors.append(f"{path} loses private/unknown paint confinement in dormant interaction projection")
    if exact == NATIVE_INTERACTION_PROJECTION_SOURCE and "final class EluUIKitReplayInteractionProjection" in text:
        if any(token not in text for token in ["for clip in current.1.values",
                "original.currentGeometry(deadline: deadline, now: now)",
                "let ordered = encoded[node.identity]", "Double(x) < ordered.clip.x + ordered.clip.width",
                "let emittedInside = Double(x) >= clip.x", "if actualInside || emittedInside { return nil }"]):
            errors.append(f"{path} loses private/unknown paint footprint vetoes")
    if exact == NATIVE_TOUCH_OBSERVER_SOURCE and "final class EluUIKitReplayTouchObserver" in text:
        required = ["maximumWorkNanoseconds: UInt64 = 2_000_000", "maximumWorkPerSecond: UInt64 = 20_000_000",
            "if delivering", "reentered = true", "original.projection === projection", "projection.privacyIsCurrent",
            "mailbox.withdraw()", "cancelAndIgnore()", "time.timestamp - old.timestamp < 100",
            "maximumCharges = 128", "charges.removeAll { now - $0.ended >= 1_000_000_000 }",
            "Charge(ended: second.ended, cost: merged)", "budget.charge(from: begun, through: preEnd)",
            "budget.charge(from: postBegin, through: continuous())",
            "time.continuous - old.continuous < 100_000_000 { retain = false }",
            "guard original.retain else { return }"]
        if any(token not in text for token in required):
            errors.append(f"{path} weakens dormant original delivery, privacy, or bounded work guards")
    if exact == NATIVE_WINDOW_SOURCE:
        required = ["public final class EluReplayWindow: UIWindow", "public override func sendEvent(_ event: UIEvent)",
            "original.observe(event) { super.sendEvent(event) }", "replayDeliveryDepth += 1", "replayDeliveryDepth -= 1",
            "pendingReplayDetach", "await withCheckedContinuation", "original.belongs(to: self)",
            "if replayObserver === original", "original.withdraw()"]
        forbidden = ["EluSQLiteRuntimeQueue", "EluNativeReplayAuthority", "EluNativeReplayPermit", "EluNativeReplayCapabilities",
            "EluNativeReplaySealer", "UIGestureRecognizer", "addGestureRecognizer", "method_exchangeImplementations", "URLSession"]
        if any(token not in text for token in required) or any(token in text for token in forbidden) or re.search(r"\bTask(?:\.detached)?\s*\{|\bTask\s*\(", text):
            errors.append(f"{path} widens explicit synchronous window delivery or loses original physical detachment")
        if re.findall(r"public\s+(?:override\s+)?func\s+(\w+)", text) != ["sendEvent"]:
            errors.append(f"{path} exposes a public interaction installation or authority bypass")
    if exact == NATIVE_CAPTURE_SOURCE and "private func captureInteractions" in text:
        required = ["switch try await queue.appendNativeReplay(request, admission: admission, physicalUse: use)",
            "try buffer.committed(seal)", "attachment = original", "original.install()",
            "originalAttachment.drain()", "originalAttachment.handoff(projection, at:",
            "try await accept(preceding + captured.3)", "buffer.appendGeometry(captured.0",
            "if let interactionAttachment { await interactionAttachment.close() }", "physicalUse.settle()",
            "enrollment.quarantine(retaining: pendingRequest)", "root.window is EluReplayWindow"]
        if any(token not in text for token in required):
            errors.append(f"{path} loses original commit, ordered projection, explicit window or physical settlement")
        append = text.find("switch try await queue.appendNativeReplay(request, admission: admission, physicalUse: use)")
        if not (append < text.find("try buffer.committed(seal)") < text.find("attachment = original\n") < text.find("original.install()")):
            errors.append(f"{path} installs touch observation before original known initial commit")
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
    helper_only_raster = False
    if exact == NATIVE_RASTER_SEALER_SOURCE:
        # Reuse only the two existing static byte/timestamp helpers. Do not add
        # this path to the v2 storage/capture allowlist or permit the old recorder.
        remaining = re.sub(r"\bEluNativeReplaySealer\s*\.\s*(?:timestamp|gzip)\s*\(", "", text)
        helper_only_raster = re.search(r"\bEluNativeReplaySealer\b", remaining) is None
        forbidden = ("EluSQLiteRuntimeQueue", "EluNativeReplayAuthority", "EluNativeReplayCapabilities",
            "EluNativeReplayScope", "EluNativeReplayPermit", "EluNativeReplaySynchronousGuard",
            "EluNativeReplayPreparedAuthority", "EluNativeReplayProjectionInput", "appendNativeReplay",
            "appendReplay", "reconcileReplay", "ensureReplaySchema", "ensureReplayDeliverySchema",
            "ensureNativeReplayAuthoritySchema", "nativeReplayProjection", "installNativeReplayPrivacy",
            "beginNativeReplayStartAccounting", "stopNativeReplayAccounting", "nativeReplayPermitGuard",
            "persistNativeReplayClockDenial")
        if not helper_only_raster or any(re.search(rf"\b{token}\b", text) for token in forbidden) or any(
            token in text for token in (*NETWORK_TOKENS, "import UIKit")
        ) or re.search(r"\bTask(?:\.detached)?\s*[{(]", text):
            errors.append(f"{path} widens the pure raster sealer beyond static byte helpers and retained values")
    storage_only_raster = False
    if exact == NATIVE_RASTER_STORAGE_SOURCE:
        references = set(re.findall(r"\bEluV2(?:Replay|SealedReplay)\w*\b", text))
        forbidden = ("EluSQLiteRuntimeQueue", "EluNativeReplayAuthority", "EluNativeRasterPermit",
            "EluNativeRasterSealer", "EluNativeRasterPreparedRequest", "EluSwiftUIReplayFrame",
            "EluSwiftUIReplayRegistry", "appendNativeRaster", "EluNativeRasterResponse")
        storage_only_raster = not (references - {"EluV2ReplayStoredChunk", "EluV2ReplayText"}
            or any(re.search(rf"\b{token}\b", text) for token in forbidden)
            or any(token in text for token in (*NETWORK_TOKENS, "import UIKit"))
            or re.search(r"\bTask(?:\.detached)?\s*[{(]", text))
        if not storage_only_raster:
            errors.append(f"{path} adds live authority, capture or delivery to restored raster values")
    raster_runtime_owner = exact in {NATIVE_RUNTIME_SOURCE, NATIVE_COMPOSITION_SOURCE}
    raster_physical_owner = exact == NATIVE_CAPTURE_SOURCE
    if raster_runtime_owner:
        forbidden = ("EluNativeRasterPermit", "EluNativeRasterCaptureAdmission", "EluNativeRasterPreparedRequest",
            "EluNativeRasterSealer", "EluSwiftUIReplayFrame", "appendNativeRaster",
            "EluNativeRasterStoredRequest", "EluStoredReplayRecord", "EluNativeRasterSourceLedger")
        if any(re.search(rf"\b{token}\b", text) for token in forbidden):
            errors.append(f"{path} bypasses original raster physical capture or durable ownership")
    if raster_physical_owner and re.search(r"\b(?:EluStoredReplayRecord|EluNativeRasterStored\w*|EluNativeRasterSourceLedger)\b", text):
        errors.append(f"{path} restores raster storage outside the original queue")
    if raster_physical_owner and "private final class EluNativeRasterCaptureRun" in text:
        required = ["queue.enrollNativeReplayCapture()", "original.takePhysicalUse()",
            "authority.startRaster(prepared, selection: selection, physicalUse: physical)",
            "authority.captureAdmission(for: permit, physicalUse: physical)",
            "sourceIdentity: binding.sourceIdentity", "sourceIsCurrent:", "try await validate(permit)",
            "queue.appendNativeRaster(request, admission: admission, physicalUse: physical)",
            "UInt64(prepared.minimumDurationSeconds) * 1_000_000_000",
            "captured.2 - beginning >= minimum", "try await commit(retained)",
            "case .committedThenWithdrawn", "EluRuntimeQueueError.nativeRasterEpochBlocked",
            "first = nil; fence.withdraw()", "use.settle()", "queue.finishNativeReplayCapture(enrollment)"]
        if any(token not in text for token in required):
            errors.append(f"{path} loses original raster duration, admission, source or physical settlement")
    raster_durable_owner = exact in {NATIVE_RASTER_QUEUE_SOURCE, NATIVE_AUTHORITY_SOURCE}
    if raster_durable_owner:
        forbidden = ("EluNativeRasterSealer", "EluNativeRasterResponse",
            "EluSwiftUIReplayFrame", "EluSwiftUIReplayRegistry")
        if exact == NATIVE_AUTHORITY_SOURCE:
            forbidden += ("EluNativeRasterResponseOutcome",)
        if any(re.search(rf"\b{token}\b", text) for token in forbidden) or re.search(
            r"\bEluNativeRasterPreparedRequest\s*(?:\.\s*init)?\s*\(", text):
            errors.append(f"{path} adds a raster recorder, request constructor or response dispatch to durable admission")
    if re.search(r"\b(?:EluStoredReplayRecord|EluNativeRaster(?:Stored\w*|SourceLedger|Permit|PreparedAuthority|Capture\w*|AppendResult))\b", text) and not (
        raster_durable_owner or raster_runtime_owner or raster_physical_owner or exact == NATIVE_RASTER_STORAGE_SOURCE or (
            exact == NATIVE_RASTER_RESPONSE_SOURCE and not re.search(
                r"\b(?:EluStoredReplayRecord|EluNativeRaster(?:Stored\w*|SourceLedger|Permit|PreparedAuthority|Capture\w*|AppendResult))\b",
                re.sub(r"\brequest\s*:\s*EluNativeRasterStoredRequest\b", "", text)))):
        errors.append(f"{path} consumes dormant raster storage/admission outside the original queue and authority")
    response_only_raster = False
    if exact == NATIVE_RASTER_RESPONSE_SOURCE:
        remaining = re.sub(r"\brequest\s*:\s*EluNativeRaster(?:Prepared|Stored)Request\b", "", text)
        remaining = re.sub(r"\bEluV2ReplayText\.equal\s*\(", "(", remaining)
        remaining = re.sub(r"\bEluV1BatchDeliveryCoordinator\.parseRetryAfter\s*\(", "(", remaining)
        forbidden = ("EluSQLiteRuntimeQueue", "EluStandaloneRuntime", "EluNativeReplayAuthority",
            "EluNativeReplayCapabilities", "EluNativeReplayScope", "EluNativeReplayPermit",
            "EluSwiftUIReplayRegistry", "EluSwiftUIReplayFrame", "EluNativeReplaySealer",
            "appendNativeReplay", "appendReplay", "reconcileReplay", "ensureReplaySchema",
            "ensureReplayDeliverySchema", "ensureNativeReplayAuthoritySchema")
        response_only_raster = not (
            re.search(r"\bEluNativeRaster(?:Sealer|PreparedRequest|PolicyBinding|SealingError)\b", remaining)
            or re.search(r"\bEluV2(?:Replay|SealedReplay)\w*\b|\bEluV1BatchDeliveryCoordinator\b", remaining)
            or any(re.search(rf"\b{token}\b", text) for token in forbidden)
            or any(token in text for token in (*NETWORK_TOKENS, "import UIKit"))
            or re.search(r"\bTask(?:\.detached)?\s*[{(]", text)
        )
        if not response_only_raster:
            errors.append(f"{path} widens the pure raster response classifier beyond original request reads and static helpers")
    if re.search(r"\bEluNativeRaster(?:Response\w*|ConflictScope)\b", text) and exact not in {
            NATIVE_RASTER_RESPONSE_SOURCE, NATIVE_RASTER_DELIVERY_SOURCE, NATIVE_RASTER_QUEUE_SOURCE}:
        errors.append(f"{path} installs raster response handling outside the original value and delivery owners")
    if exact == NATIVE_RASTER_DELIVERY_SOURCE:
        remaining = re.sub(r"\bEluNativeRasterResponse\.classify\s*\(", "(", text)
        if re.search(r"\bEluNativeRasterResponse\b|\bEluNativeRaster(?:Sealer|PreparedRequest|StoredRequest|PolicyBinding)\b", remaining):
            errors.append(f"{path} constructs raster values or bypasses the exact response classifier")
    delivery_selection_owners = {NATIVE_RASTER_QUEUE_SOURCE, NATIVE_RASTER_DELIVERY_STATE, REPLAY_TRANSPORT_SOURCE}
    delivery_selection_text = text
    if exact == NATIVE_RUNTIME_SOURCE:
        delivery_selection_text = delivery_selection_text.replace(
            "support: declaredRegionReplaySupported ? .includingRaster : .wireframeOnly", "")
    if re.search(r"\bEluReplayDelivery(?:Format|Support)\b|\.includingRaster\b", delivery_selection_text) and exact not in delivery_selection_owners:
        errors.append(f"{path} activates raster delivery outside its original explicit internal selection")
    if exact == NATIVE_RASTER_QUEUE_SOURCE and "support: EluReplayDeliverySupport = .wireframeOnly" not in text:
        errors.append(f"{path} changes the dormant raster delivery default")
    if re.search(r"\bEluNativeRaster(?:Sealer|PreparedRequest|PolicyBinding|SealingError)\b", text) and exact != NATIVE_RASTER_SEALER_SOURCE and not response_only_raster and not raster_durable_owner and not raster_physical_owner:
        errors.append(f"{path} installs the unintegrated raster sealer outside its exact value file")
    if re.search(r"\bEluNativeReplaySealer\b", text) and exact not in {NATIVE_SEALER_SOURCE, NATIVE_CAPTURE_SOURCE} and not helper_only_raster:
        errors.append(f"{path} references the native sealer outside its exact physical owner")
    if (re.search(r"\bEluV2(?:Replay|SealedReplay)\w*\b", text) or "ensureReplaySchema" in text or "ensureReplayDeliverySchema" in text) and exact not in allowed and not response_only_raster and not storage_only_raster:
        errors.append(f"{path} references owned replay storage outside its exact files")
    if exact in allowed and "/Replay/" in exact:
        permitted = {"URLSession", "URLRequest"} if exact == REPLAY_TRANSPORT_SOURCE else ({"import UIKit"} if exact == NATIVE_CAPTURE_SOURCE else set())
        for token in (*NETWORK_TOKENS, "import UIKit"):
            if token in text and token not in permitted:
                errors.append(f"{path} adds capture/network/provider behavior to opaque replay storage")
    if re.search(rf"\b{REPLAY_TRANSPORT_NAME}\b", text) and exact not in {REPLAY_TRANSPORT_SOURCE, NATIVE_RUNTIME_SOURCE}:
        errors.append(f"{path} references the owned concrete replay transport")
    if re.search(rf"\b{REPLAY_TRANSPORT_NAME}\s*\(", text) and exact != NATIVE_RUNTIME_SOURCE:
        errors.append(f"{path} constructs the replay transport outside its exact runtime")
    if exact == NATIVE_RUNTIME_SOURCE and "installNativeReplayComposition" in text:
        normalized = re.sub(r"\s+", " ", text)
        exact_capability = (
            "static let readbackProvenReplayCapabilities = EluNativeReplayCapabilities( "
            "readbackProvenTransports: [ "
            'EluV1ReplayTransportSelection(codec: "elu-native-wireframe-v1", compression: .gzip)!, '
            'EluV1ReplayTransportSelection(codec: "elu-native-wireframe-v2", compression: .gzip)!], '
            'readbackProvenProtocolGenerations: ["protocol-generation-v1", "protocol-generation-v2"])'
        )
        if normalized.count(exact_capability) != 1 or text.count("static let readbackProvenReplayCapabilities") != 1:
            errors.append(f"{path} changed the exact binary-supported native capabilities")
        required = ["declaredRegionReplaySupported: Bool = false",
                    "support: declaredRegionReplaySupported ? .includingRaster : .wireframeOnly",
                    "guard declaredRegionReplaySupported, phase != .closed",
                    "prepared.sourceIdentity === binding.sourceIdentity",
                    "authority?.withdraw(); relay.withdrawCapture(); relay.request()",
                    "EluSwiftUIReplayRegistration.shared.remove(declaredRegionObserver)",
                    "capabilities: EluNativeReplayCapabilities = EluNativeReplayCapabilities()",
                    "nativeAuthority.ownsPrepared(prepared)", "prepared.supportedProtocolGeneration != nil",
                    "value?.requiringCurrent", "configurationWitness == source", "readZone() == zone"]
        if any(token not in text for token in required) or len(re.findall(rf"\b{REPLAY_TRANSPORT_NAME}\s*\(", text)) != 1 or len(re.findall(r"\bEluNativeReplayCaptureOwner\s*\(", text)) != 2:
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
    bootstrap_requirements = {
        "Sources/EluAnalytics/Elu.swift": ["public var declaredRegionReplayEnabled = false"],
        "Sources/EluAnalytics/EluState.swift": ["private var declaredRegionReplayEnabled = false",
            "declaredRegionReplayEnabled = options.declaredRegionReplayEnabled",
            "declaredRegionReplayEnabled: declaredRegionReplayEnabled"],
        "Sources/EluAnalytics/Internal/Facade/EluRuntimeBackend.swift": ["let declaredRegionReplayEnabled: Bool",
            "declaredRegionReplayEnabled: Bool = false",
            "self.declaredRegionReplayEnabled = declaredRegionReplayEnabled"],
    }
    if exact_path in bootstrap_requirements and any(text.count(token) != 1 for token in bootstrap_requirements[exact_path]):
        errors.append(f"{path} changes default-off copied declared-region setup selection")
    if "EluV1FlagClient" in text and not allowed_caller:
        errors.append(f"{path} references the flag client outside the wired callers")
    if any(re.search(rf"\b{protocol}\b", text) for protocol in FLAG_TRANSPORT_PROTOCOLS) and not (allowed_caller or bound_authority):
        errors.append(f"{path} references the injected flag transport boundary")
    if stack:
        # One reviewed construction site, with no platform networking or direct
        # client/schema activation. Caller-supplied transports stay injectable.
        references = re.findall(rf"\b{FLAG_TRANSPORT_NAME}\b", text)
        construction = re.findall(rf"\b{FLAG_TRANSPORT_NAME}\(siteKey: siteKey, endpointPolicy: endpointPolicy\)", text)
        if len(references) != 1 or len(construction) != 1:
            errors.append(f"{path} changed the exact owned flag transport construction")
        if re.search(r"\b(?:URLSession|URLRequest|NWConnection)\b|import\s+(?:Network|CFNetwork)\b", text):
            errors.append(f"{path} performs platform networking outside a transport")
        if re.search(r"\bEluV1FlagClient\s*[.(]", text):
            errors.append(f"{path} bypasses the runtime-owned flag client activation")
    elif re.search(rf"\b{FLAG_TRANSPORT_NAME}\b", text):
        errors.append(f"{path} references the owned concrete flag transport")
    if exact_path in {STACK_SOURCE, STANDALONE_FACADE_SOURCE} and any(token in text for token in ["readbackProvenTransports", "readbackProvenProtocolGenerations"]):
        errors.append(f"{path} constructs native capability sets outside the owned runtime")
    if exact_path == STANDALONE_FACADE_SOURCE:
        if "installNativeReplayComposition" in text and (text.count("deferredUntilActivation: true") != 2 or "await runtime.activateNativeReplayComposition()" not in text):
            errors.append(f"{path} bypasses ordered native composition activation")
        normalized = re.sub(r"\s+", " ", text)
        selected_capabilities = (
            "capabilities: EluStandaloneRuntime.readbackProvenReplayCapabilities, "
            "deferredUntilActivation: true"
        )
        if normalized.count(selected_capabilities) != 2:
            errors.append(f"{path} changed the exact owned native capability selection")
        if normalized.count("if let initialConsent = context.initialConsent { acceptConsent(initialConsent) }") != 2:
            errors.append(f"{path} removed constructor consent projection before asynchronous startup")
        if ("guard accepted, await self.persistStartupConsent(to: stack.runtime) else" not in normalized or
                "guard accepted, await persistStartupConsent(to: runtime) else" not in normalized):
            errors.append(f"{path} removed durable consent gating from startup")
        owned_factory = (
            "openStack: { try await makeStack(context: context, rootDirectoryURL: rootDirectoryURL) }, "
            "guardedFlagsDidLoad: context.guardedFlagsDidLoad"
        )
        if normalized.count(owned_factory) != 1:
            errors.append(f"{path} changed the exact owned bootstrap host/callback binding")
        owned_stack = (
            "static func makeStack(context: EluRuntimeBackendContext, rootDirectoryURL: URL, "
            "configTransport: (any EluV2ConfigTransport)? = nil) async throws -> EluStandaloneStack { "
            "try await EluStandaloneStack.make( rootDirectoryURL: rootDirectoryURL, siteKey: context.siteKey, "
            "configHost: context.configHost, endpointPolicy: context.endpointPolicy, configTransport: configTransport, "
            + DECLARED_BOOTSTRAP_SELECTION + ", declaredRegionReplaySupported: context.declaredRegionReplayEnabled, "
            "performance: context.performance, diagnostics: context.diagnostics, personProfiles: context.personProfiles, "
            "persistence: context.persistence, rateLimiting: context.rateLimiting ) }"
        )
        if normalized.count(owned_stack) != 1 or len(re.findall(r"\bEluStandaloneStack\.make\s*\(", text)) != 1:
            errors.append(f"{path} changed the exact owned bootstrap host/callback or atomic declared-region option binding")
    errors.extend(scan_transport_conformers(text))
    if bound_authority:
        # This seam may define protocols and delegate to an injected transport,
        # but it cannot construct a flag transport or gain platform networking.
        errors.extend(scan_flag_source(text, path))
    if "ensureFlagSchema" in text and path.name != "EluSQLiteRuntimeQueue.swift":
        errors.append(f"{path} invokes the lazy flag migration")
    return errors


NATIVE_V3_SOURCE_PATH = "Sources/EluAnalytics/Internal/Config/EluV2ConfigSource.swift"
NATIVE_V3_GATE_PATH = "Sources/EluAnalytics/Internal/Config/EluV2ConfigAuthorityGate.swift"
NATIVE_V3_LIFECYCLE_PATH = "Sources/EluAnalytics/Internal/Config/EluV2ConfigLifecycle.swift"
NATIVE_V3_PARSER_PATH = "Sources/EluAnalytics/Internal/Config/EluNativeV3ConfigParser.swift"


def scan_native_v3_source(path: pathlib.Path, text: str) -> list[str]:
    exact = path.as_posix()
    owners = {NATIVE_V3_SOURCE_PATH, NATIVE_V3_GATE_PATH, NATIVE_V3_LIFECYCLE_PATH}
    errors: list[str] = []
    durable_owners = {NATIVE_RASTER_QUEUE_SOURCE, NATIVE_AUTHORITY_SOURCE}
    if "EluNativeV3ConfigParser" in text and exact not in owners | durable_owners | {NATIVE_V3_PARSER_PATH}:
        errors.append(f"{path} references native v3 outside its original configuration owner")
    selection_text = text
    if exact == STANDALONE_FACADE_SOURCE:
        selection_text = selection_text.replace(DECLARED_BOOTSTRAP_SELECTION, "", 1)
    if re.search(r"\.nativeV3\b", selection_text) and exact not in owners | durable_owners:
        errors.append(f"{path} activates or consumes dormant native v3 outside its original owner")
    required = {
        NATIVE_V3_SOURCE_PATH: [
            "enum Format: Equatable, Sendable { case v2, nativeV3 }", "format: Format = .v2",
            "format: EluV2ConfigRequest.Format = .v2", 'format == .v2 ? "v2" : "v3"',
            "let task = Task { try await transport.fetch(request) }",
            "EluNativeV3ConfigParser.parse(data, endpointPolicy: endpointPolicy)",
            "nativeV3 = parsed; baseData = parsed.configV2Data; document = parsed.base",
            "previous.canonicalData == nativeV3.canonicalData", "!previous.conflicted",
            "previous.conflicted = true; envelopeBoundary = previous",
            "document.issuedAt < previous.issuedAt", "document.issuedAt == previous.issuedAt",
            "manager.update(configData: baseData, now: sample.wall)",
            "continuousDeadline: boundedDeadline, nativeV3: nativeV3)", "return .document(baseData)",
        ],
        NATIVE_V3_GATE_PATH: [
            "$0.configV2Data == lease.data && $0.base.expiresAt == lease.expiresAt",
            "retainedLease.receiptData == lease.receiptData", "nativeV3: lease.nativeV3",
            "nativeV3: pinned.nativeV3", "lhs.nativeV3?.data == rhs.nativeV3?.data",
        ],
        NATIVE_V3_LIFECYCLE_PATH: [
            "format: EluV2ConfigRequest.Format = .v2", "format: format, transport: transport",
            "state == .document(lease.data) && publishedLease?.receiptData == lease.receiptData",
            "publish(.document(lease.data), receiptChanged: !unchanged)", "next != state || receiptChanged",
        ],
    }
    if exact in required and any(token not in text for token in required[exact]):
        errors.append(f"{path} lost original native-v3 bytes, conflict, lease or default-selection binding")
    if exact == NATIVE_V3_SOURCE_PATH:
        if text.count("transport.fetch(request)") != 1 or text.count("manager = EluV1ConfigManager(") != 1:
            errors.append(f"{path} adds a native-v3 fallback fetch or independent manager")
        if "envelopeBoundary = nil" in text:
            errors.append(f"{path} discards the native-v3 conflict/ordering boundary")
    if exact == NATIVE_V3_LIFECYCLE_PATH:
        comparison = text.find("let unchanged = state == .document(lease.data)")
        if not (0 <= comparison < text.find("publishedLease = lease", comparison)):
            errors.append(f"{path} replaces the original receipt before comparing publication identity")
    if exact in owners and re.search(r"\b(?:EluSQLiteRuntimeQueue|EluNativeRasterSealer|EluNativeReplayAuthority|"
                                     r"URLSession|URLRequest)\b", text):
        errors.append(f"{path} adds queue, channel authority, raster capture or platform networking")
    denial_owners = owners | {NATIVE_RASTER_QUEUE_SOURCE}
    if re.search(r"\bEluV2ConfigSourceDenials?\b", text) and exact not in denial_owners:
        errors.append(f"{path} gains an original-source denial receipt outside its owner")
    if exact != NATIVE_V3_SOURCE_PATH and re.search(r"\bEluV2ConfigSourceDenials?\s*\(", text):
        errors.append(f"{path} fabricates a source denial")
    denial_required = {
        NATIVE_V3_SOURCE_PATH: [
            "fileprivate init(issuedAt:", "fileprivate init(siteKey:",
            "latest.map({ $0.issuedAt < issuedAt }) ?? true", "latest === candidate",
            "denials.record(issuedAt: previous.issuedAt, original: previous.canonicalData,",
            "conflicting: nativeV3.canonicalData)",
        ],
        NATIVE_V3_GATE_PATH: [
            "sourceDenials?.belongs(to: siteKey) == true", "sourceDenials?.contains(candidate) == true",
            "if sourceDenials?.pending() != nil { witness = nil; return false }",
        ],
        NATIVE_V3_LIFECYCLE_PATH: [
            "sourceDenials: source.denials", "await source.close()",
            "denial !== publishedDenial", "publishedDenial = denial",
        ],
        NATIVE_RASTER_QUEUE_SOURCE: [
            "let denial = gate.pendingDenial()", "exactConstructorSiteKey == gate.siteKey",
            "guard gate.retainsDenial(denial)", "ledger.rasterSource.map({ $0.issuedAt > denial.issuedAt })",
            "ledger.witness.map({ $0.issuedAt > denial.issuedAt })", "rejected.conflicted = true",
            "ledger.admissionEnabled = false", "gate.acknowledgeDenial(denial)",
            "configurationGate?.pendingDenial() != nil { held?.quarantineNativeClockDenial() }",
        ],
        STACK_SOURCE: ["runtime.settleConfigurationDenial()", "await lifecycle.configurationDenialSettled()"],
        NATIVE_RUNTIME_SOURCE: ["return try await queue.persistConfigurationDenial()"],
    }
    if exact in denial_required and any(token not in text for token in denial_required[exact]):
        errors.append(f"{path} lost original denial provenance, settlement, lifetime or ordering")
    if exact == STACK_SOURCE:
        start = text.find("fileprivate func accept(")
        end = text.find("fileprivate func refreshFlags(", start)
        section = text[start:end]
        if not (0 <= section.find("runtime.settleConfigurationDenial()") < section.find("guard let self, self.isCurrent(decision)")):
            errors.append(f"{path} filters restrictive denial behind the latest-only notification")
    if exact == NATIVE_RASTER_QUEUE_SOURCE:
        start = text.find("func persistConfigurationDenial()")
        end = text.find("func reconcileNativeRasterSource(", start)
        section = text[start:end]
        if not (0 <= section.find("try replayStorageTransaction(validate: validate)") < section.find("gate.acknowledgeDenial(denial)")):
            errors.append(f"{path} acknowledges source denial before original SQL settlement")
        migrations = ("try ensureReplaySchema()", "try ensureReplayDeliverySchema()",
                      "try ensureNativeReplayAuthoritySchema()", "try migrateNativeRasterSchema(validate: validate)")
        if any(section.count(call) != 1 for call in migrations) or not (
            0 <= section.find("guard gate.retainsDenial(denial)")
            < section.find("if !EluSQLiteRuntimeSchema.hasRaster(databaseSchemaVersion)")
            < section.find(migrations[0]) < section.find(migrations[1])
            < section.find(migrations[2]) < section.find(migrations[3])):
            errors.append(f"{path} widens denial-only lazy storage migration")
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
        if re.search(r"\b(?:phlibwebp|PHPLCrashReporter|EluProviderRuntime)\b", text):
            errors.append(f"{path.relative_to(root)} restores a removed provider source dependency")
        if any(re.search(rf"\b{symbol}\b", text) for symbol in RETIRED_STARTUP_SYMBOLS):
            errors.append(f"{path.relative_to(root)} restores a retired preview import surface")
        errors.extend(scan_replay_storage_source(path.relative_to(root), text))
        errors.extend(scan_native_v3_source(path.relative_to(root), text))
    replay_activation = {
        path.relative_to(root).as_posix(): path.read_text(encoding="utf-8").count("ensureReplaySchema")
        for path in source_root.rglob("*.swift") if "ensureReplaySchema" in path.read_text(encoding="utf-8")
    }
    if replay_activation != {"Sources/EluAnalytics/Internal/Runtime/EluSQLiteRuntimeQueue.swift": 2, NATIVE_AUTHORITY_SOURCE: 1}:
        errors.append("replay schema activation escaped its owned storage definition")
    delivery_activation = {
        path.relative_to(root).as_posix(): path.read_text(encoding="utf-8").count("ensureReplayDeliverySchema")
        for path in source_root.rglob("*.swift") if "ensureReplayDeliverySchema" in path.read_text(encoding="utf-8")
    }
    if delivery_activation != {"Sources/EluAnalytics/Internal/Runtime/EluSQLiteRuntimeQueue.swift": 2, NATIVE_AUTHORITY_SOURCE: 1}:
        errors.append("replay delivery schema activation escaped its owned definition")
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
