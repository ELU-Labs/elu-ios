import Foundation
import XCTest
@testable import EluAnalytics

final class EluNativeReplaySealerTests: XCTestCase {
    func testCanonicalEnvelopeKeepsOriginalIdentityPrivacyAndVersions() throws {
        let binding = try fixture()
        var sealer = try binding.sealer()
        let request = try sealer.seal([frame(0)])
        XCTAssertEqual(request.sequence, 0)
        XCTAssertEqual(request.sessionId, "session-sealer")
        XCTAssertEqual(request.anonymousId, "anon-sealer")
        XCTAssertEqual(request.userId, "user-sealer")
        XCTAssertEqual(request.identityRevision, 3)
        XCTAssertEqual(request.contextRevision, 7)
        XCTAssertEqual(request.effectivePolicyHash, binding.privacy.effectivePolicyHash)
        XCTAssertEqual(request.maskingProfileHash, EluNativeMaskingProfile.blanketMask().hash)
        XCTAssertEqual(request.codec, "elu-native-wireframe-v1")
        XCTAssertEqual(request.compression, "gzip")
        XCTAssertEqual(request.body, try EluV1StrictCanonicalJSON.parse(request.body).canonicalData)
        let root = try object(request), chunk = try XCTUnwrap(root["chunk"] as? [String: Any])
        XCTAssertEqual(chunk["startedAt"] as? String, "2026-08-05T00:01:00.123Z")
        XCTAssertEqual(chunk["endedAt"] as? String, "2026-08-05T00:01:00.123Z")
        let versions = try XCTUnwrap(chunk["versions"] as? [String: Any])
        XCTAssertEqual(versions["schemaVersion"] as? Int, 2)
        XCTAssertEqual(versions["contractVersion"] as? String, "2.0.0")
        XCTAssertEqual(versions["build"] as? String, "fixture-build")
        XCTAssertEqual(binding.versions.schemaVersion, 1)
        XCTAssertEqual(binding.versions.contractVersion, "1.0.0")
        try export(request, name: "first-request.json")
    }

    func testIdenticalInputsAreByteIdenticalAndSuffixRetainsStreamHistory() throws {
        let binding = try fixture()
        var left = try binding.sealer(), right = try binding.sealer()
        let first = try left.seal([frame(0)])
        XCTAssertEqual(first, try right.seal([frame(0)]))
        let suffix = try left.seal([frame(1, withNode: true), frame(2)])
        XCTAssertEqual(suffix, try right.seal([frame(1, withNode: true), frame(2)]))
        XCTAssertEqual(suffix.sequence, 1)
        XCTAssertEqual(first.replayId, suffix.replayId)
        XCTAssertNotEqual(first.chunkId, suffix.chunkId)
        XCTAssertNotEqual(first.requestId, suffix.requestId)
        try export(suffix, name: "suffix-request.json")
    }

    func testInvalidFrameAndTimestampLeaveOriginalEncoderHistoryAvailable() throws {
        let binding = try fixture()
        var sealer = try binding.sealer()
        XCTAssertThrowsError(try sealer.seal([frame(1)]))
        XCTAssertThrowsError(try sealer.seal([frame(0, timestamp: 253_402_300_800_000)]))
        let first = try sealer.seal([frame(0)])
        XCTAssertEqual(first.sequence, 0)
        XCTAssertThrowsError(try sealer.seal([frame(1, timestamp: 1)]))
        let suffix = try sealer.seal([frame(1)])
        XCTAssertEqual(suffix.sequence, 1)
    }

    func testCompressionLimitFailureDoesNotConsumeSequenceOrNodeIdentity() throws {
        var reference = try fixture().sealer()
        let expected = try reference.seal([frame(0)])
        let binding = try fixture(maximumBytes: expected.body.count)
        var bounded = try binding.sealer()
        let large = try frame(0, nodeCount: 120)
        XCTAssertThrowsError(try bounded.seal([large])) { error in
            XCTAssertEqual(error as? EluNativeReplaySealingError, .requestLimit)
        }
        XCTAssertEqual(try bounded.seal([frame(0)]), expected)
        var tooSmall = try fixture(maximumBytes: expected.body.count - 1).sealer()
        XCTAssertThrowsError(try tooSmall.seal([frame(0)]))
    }

    func testMinimumRequestLimitRejectsWithoutAnEnvelopeOrEncoderAdvance() throws {
        var sealer = try fixture(maximumBytes: 1024).sealer()
        for _ in 0 ..< 2 {
            XCTAssertThrowsError(try sealer.seal([frame(0)])) { error in
                XCTAssertEqual(error as? EluNativeReplaySealingError, .requestLimit)
            }
        }
    }

    func testCanonicalFullPrivacyAndIdentityAreRequiredAtBinding() throws {
        let original = try fixture()
        var missingSession = original.identity
        missingSession.identity.session = nil
        XCTAssertThrowsError(try original.sealer(identity: missingSession))
        var contextChanged = original.identity
        contextChanged.identity.contextRevision += 1
        XCTAssertThrowsError(try original.sealer(identity: contextChanged))
        var optedOut = original.identity
        optedOut.identity.optedOut = true
        XCTAssertThrowsError(try original.sealer(identity: optedOut))
        let noncanonical = Data([0x20]) + original.privacy.stateData
        XCTAssertThrowsError(try original.sealer(privacy: original.withPrivacyData(noncanonical)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original.privacy.stateData) as? [String: Any])
        object["replayBudgetRemainingSeconds"] = 59
        let changed = try EluV1StrictCanonicalJSON.parse(JSONSerialization.data(withJSONObject: object)).canonicalData
        XCTAssertThrowsError(try original.sealer(privacy: original.withPrivacyData(changed)))
    }

    func testUnsupportedProofOrCaptureDenialCannotBecomeBinding() throws {
        for mode in ["no-proof", "no-advertisement", "opt-out", "no-sample", "no-budget", "no-capture"] {
            let binding = try fixture(mode: mode)
            XCTAssertThrowsError(try binding.sealer(), mode)
        }
    }

    func testOriginalWholeMillisecondsAndRepresentableDateBounds() throws {
        for timestamp: Int64 in [1, 999, 1000, 1001, 253_402_300_799_999] {
            var sealer = try fixture().sealer()
            let request = try sealer.seal([frame(0, timestamp: timestamp)])
            let chunk = try XCTUnwrap(try object(request)["chunk"] as? [String: Any])
            let value = try XCTUnwrap(chunk["startedAt"] as? String)
            XCTAssertTrue(value.hasSuffix(String(format: ".%03lldZ", timestamp % 1000)))
            try export(request, name: "timestamp-\(timestamp).json")
        }
    }

    func testUnicodeAndMaximumSafeIdentityStayExactAndReplayIdentityIsDistinct() throws {
        let user = "customer_e\u{301}/東京/🚀"
        let binding = try fixture(contextRevision: 9_007_199_254_740_991, userId: user)
        var sealer = try binding.sealer(), other = try binding.sealer(replayId: "replay-other")
        let first = try sealer.seal([frame(0)]), second = try other.seal([frame(0)])
        XCTAssertEqual(Array(try XCTUnwrap(first.userId).utf16), Array(user.utf16))
        XCTAssertEqual(first.contextRevision, 9_007_199_254_740_991)
        XCTAssertEqual(first.effectivePolicyHash, second.effectivePolicyHash)
        XCTAssertNotEqual(first.chunkId, second.chunkId)
        XCTAssertNotEqual(first.requestId, second.requestId)
        try export(first, name: "unicode-safe-identity.json")
    }

    func testDifferentOriginalContextsProduceDifferentPrivacyAndRequestIdentity() throws {
        var original = try fixture().sealer(), changed = try fixture(contextRevision: 8).sealer()
        let first = try original.seal([frame(0)]), second = try changed.seal([frame(0)])
        XCTAssertNotEqual(first.contextRevision, second.contextRevision)
        XCTAssertNotEqual(first.effectivePolicyHash, second.effectivePolicyHash)
        XCTAssertNotEqual(first.requestId, second.requestId)
    }

    private struct Binding {
        let identity: EluIdentitySnapshot
        let privacy: EluProjectedPrivacyState
        let resolution: EluV1ConfigResolution
        let versions: EluVersionContext
        func sealer(identity: EluIdentitySnapshot? = nil, privacy: EluProjectedPrivacyState? = nil,
                    replayId: String = "replay-sealer") throws -> EluNativeReplaySealer {
            try EluNativeReplaySealer(replayId: replayId, identity: identity ?? self.identity,
                authorization: resolution, privacy: privacy ?? self.privacy, profile: .blanketMask(), versions: versions)
        }
        func withPrivacyData(_ data: Data) -> EluProjectedPrivacyState {
            .init(stateData: data, effectivePolicyHash: privacy.effectivePolicyHash,
                onDeviceDecision: privacy.onDeviceDecision, captureAllowed: privacy.captureAllowed,
                replayAllowed: privacy.replayAllowed, replaySampled: privacy.replaySampled,
                maskingValidated: privacy.maskingValidated, platformFallbackApplied: privacy.platformFallbackApplied,
                effectiveMasking: privacy.effectiveMasking, replayTransport: privacy.replayTransport,
                replayBudgetRemainingSeconds: privacy.replayBudgetRemainingSeconds)
        }
    }

    private func fixture(maximumBytes: Int = EluV2ReplayPreparedRequest.maximumBytes, mode: String = "allowed",
                         contextRevision: Int64 = 7, userId: String = "user-sealer") throws -> Binding {
        // Pure sealer fixture: explicit synthetic proof; no collector, queue, endpoint or registry activation.
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = ProcessInfo.processInfo.environment["ELU_SEALER_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? repositoryRoot.appendingPathComponent("Conformance/V2/Fixtures/config-enabled.json")
        let data = try Data(contentsOf: fixtureURL)
        var config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var capabilities = config["capabilities"] as! [String: Any], replay = capabilities["replay"] as! [String: Any]
        let codec = mode == "no-advertisement" ? "elu-browser-dom-v1" : "elu-native-wireframe-v1"
        replay["transports"] = [["codec": codec, "compression": "gzip"]]
        capabilities["replay"] = replay; config["capabilities"] = capabilities
        var limits = config["limits"] as! [String: Any]
        limits["replayChunkBytes"] = maximumBytes; config["limits"] = limits
        if mode == "no-capture" {
            var features = config["features"] as! [String: Any]; features["capture"] = false; config["features"] = features
        }
        let now = try EluV1Timestamp("2026-08-05T00:01:00.000Z").date
        let pair = EluV1ReplayTransportSelection(codec: "elu-native-wireframe-v1", compression: .gzip)!
        let manager = EluV1ConfigManager(readbackProvenReplayTransports: mode == "no-proof" ? [] : [pair])
        _ = try manager.update(configData: JSONSerialization.data(withJSONObject: config), now: now)
        let session = try EluSessionState(id: "session-sealer", startedAt: now, lastActivityAt: now, timeoutSeconds: 1800)
        let state = try EluIdentityState(revision: 3, contextRevision: contextRevision, anonymousId: "anon-sealer", userId: userId,
            groups: [:], superProperties: [:], session: session, optedOut: mode == "opt-out", updatedAt: now)
        let identity = EluIdentitySnapshot(identity: state, streamId: "stream-sealer", nextSequence: 0, flagContext: .init())
        let privacy = try EluPrivacyStateProjector.project(context: manager.activePrivacyProjectionContext(now: now),
            input: .init(contextRevision: contextRevision, identityOptedOut: state.optedOut, timeZoneIdentifier: "America/Los_Angeles",
                evaluatedAt: now, appliedMasking: .init(text: .all, inputs: .all, images: .block),
                replaySampleDraw: mode == "no-sample" ? 0.9 : 0, replaySessionEligible: true,
                replayBudgetRemainingSeconds: mode == "no-budget" ? 0 : 60,
                localReplayTransports: [.init(codec: pair.codec, compression: pair.compression)]))
        let resolution = try manager.authorize(effectivePrivacyStateData: privacy.stateData, identity: identity, now: now)
        let versions = try EluVersionContext(runtime: .init(name: "elu-ios", version: "1.0.0"),
            facade: .init(name: "EluAnalytics", version: "1.0.0"), build: "fixture-build")
        return Binding(identity: identity, privacy: privacy, resolution: resolution, versions: versions)
    }

    private func frame(_ ordinal: Int64, timestamp: Int64? = nil, withNode: Bool = false, nodeCount: Int = 0) throws -> EluNativeMaskedSnapshot {
        var nodes: [EluNativeMaskedNode] = []
        for index in 0 ..< max(nodeCount, withNode ? 1 : 0) {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            let rect = try EluNativeRect(x: Double(index % 20) * 11.7, y: Double(index / 20) * 9.3, width: 7.1, height: 5.3)
            nodes.append(.init(identity: id, kind: .text, bounds: rect, clip: rect, style: try .init()))
        }
        return .init(ordinal: ordinal, timestamp: timestamp ?? (1_785_888_060_123 + ordinal),
            viewport: try .init(width: 320, height: 640), nodes: nodes)
    }
    private func object(_ request: EluV2ReplayPreparedRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }
    private func export(_ request: EluV2ReplayPreparedRequest, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["ELU_SEALER_OUTPUT"] else { return }
        try request.body.write(to: URL(fileURLWithPath: path).appendingPathComponent(name), options: .withoutOverwriting)
    }
}
