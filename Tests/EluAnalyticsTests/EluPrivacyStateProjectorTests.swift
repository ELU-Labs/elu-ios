import Foundation
import XCTest
@testable import EluAnalytics

final class EluPrivacyStateProjectorTests: XCTestCase {
    private let activeNow = Date(timeIntervalSince1970: 1_785_801_660) // 2026-08-04T00:01:00Z
    private let v2Now = Date(timeIntervalSince1970: 1_785_888_090) // 2026-08-05T00:01:30Z
    private let nativePair = EluV1ReplayTransportPair(codec: "elu-ios-native-v1", compression: .gzip)

    func testProjectedStateAuthorizesCaptureAndReplayThroughTheConfigManager() throws {
        let manager = try installedManager()
        let projected = try EluPrivacyStateProjector.project(
            context: try manager.activePrivacyProjectionContext(now: activeNow),
            input: input()
        )

        XCTAssertEqual(
            projected.onDeviceDecision,
            EluProjectedOnDeviceDecision(decision: .allow, source: .deviceRegion, reason: nil)
        )
        XCTAssertTrue(projected.captureAllowed)
        XCTAssertTrue(projected.replayAllowed)
        XCTAssertTrue(projected.replaySampled)
        XCTAssertTrue(projected.maskingValidated)
        XCTAssertTrue(projected.platformFallbackApplied)
        XCTAssertEqual(projected.replayTransport, nativePair)
        XCTAssertEqual(projected.replayBudgetRemainingSeconds, 3_599)
        XCTAssertEqual(
            projected.effectivePolicyHash,
            try EluV1ConfigManager.computedEffectivePolicyHash(for: projected.stateData)
        )

        let decoded = try JSONDecoder().decode(EluV1EffectivePrivacyState.self, from: projected.stateData)
        XCTAssertEqual(decoded.policyRevision, "privacy-1")
        XCTAssertEqual(decoded.contextRevision, 5)
        XCTAssertEqual(decoded.onDeviceDecision.evaluatedAt, "2026-08-04T00:01:00.000Z")
        XCTAssertEqual(decoded.replayTransport?.codec, nativePair.codec)
        XCTAssertEqual(decoded.replayTransport?.advertised, true)
        XCTAssertTrue(decoded.effectiveMasking.secureInputsMasked)

        let result = try manager.authorize(
            effectivePrivacyStateData: projected.stateData,
            identity: identity(contextRevision: 5),
            now: activeNow
        )
        XCTAssertEqual(result.captureAuthorization, .authorized)
        XCTAssertEqual(
            result.replayAuthorization,
            .authorized(EluV1ReplayTransportSelection(codec: nativePair.codec, compression: .gzip)!)
        )
        XCTAssertEqual(result.decisionHash, projected.effectivePolicyHash)
        XCTAssertEqual(result.endpoints.roles, Set([.events, .replay, .flags]))
    }

    func testEuRegionGuardFailsClosedAndBlocksCapture() throws {
        for identifier in ["Europe/Paris", "Atlantic/Canary", "", nil] {
            let manager = try installedManager()
            let projected = try EluPrivacyStateProjector.project(
                context: try manager.activePrivacyProjectionContext(now: activeNow),
                input: input(timeZoneIdentifier: identifier)
            )
            XCTAssertEqual(
                projected.onDeviceDecision,
                EluProjectedOnDeviceDecision(
                    decision: .block,
                    source: .deviceRegion,
                    reason: EluPrivacyStateProjector.regionalPolicyReason
                ),
                identifier ?? "nil"
            )
            XCTAssertFalse(projected.captureAllowed)
            XCTAssertFalse(projected.replayAllowed)

            let result = try manager.authorize(
                effectivePrivacyStateData: projected.stateData,
                identity: identity(contextRevision: 5),
                now: activeNow
            )
            XCTAssertEqual(result.captureAuthorization, .restricted(.onDeviceBlocked))
            XCTAssertEqual(result.replayAuthorization, .restricted(.captureUnavailable))
            XCTAssertEqual(result.endpoints.roles, Set([.flags]))
        }
    }

    func testOptedOutIdentityProjectsALocalConsentBlock() throws {
        let manager = try installedManager()
        let projected = try EluPrivacyStateProjector.project(
            context: try manager.activePrivacyProjectionContext(now: activeNow),
            input: input(identityOptedOut: true)
        )
        XCTAssertEqual(
            projected.onDeviceDecision,
            EluProjectedOnDeviceDecision(
                decision: .block,
                source: .localConsent,
                reason: EluPrivacyStateProjector.identityOptedOutReason
            )
        )
        XCTAssertFalse(projected.captureAllowed)

        let result = try manager.authorize(
            effectivePrivacyStateData: projected.stateData,
            identity: identity(contextRevision: 5, optedOut: true),
            now: activeNow
        )
        XCTAssertEqual(result.captureAuthorization, .restricted(.identityOptedOut))
        XCTAssertEqual(result.replayAuthorization, .restricted(.captureUnavailable))
    }

    func testRemoteBlockNeverReportsAnAllowDecision() throws {
        let config = try configFixture { object in
            var privacy = object["privacy"] as! [String: Any]
            var region = privacy["regionPolicy"] as! [String: Any]
            region["mode"] = "block"
            privacy["regionPolicy"] = region
            object["privacy"] = privacy
        }
        let manager = try installedManager(config: config)
        let projected = try EluPrivacyStateProjector.project(
            context: try manager.activePrivacyProjectionContext(now: activeNow),
            input: input(timeZoneIdentifier: "America/Los_Angeles")
        )
        XCTAssertEqual(
            projected.onDeviceDecision,
            EluProjectedOnDeviceDecision(
                decision: .block,
                source: .remoteKillSwitch,
                reason: EluPrivacyStateProjector.regionalPolicyReason
            )
        )

        let result = try manager.authorize(
            effectivePrivacyStateData: projected.stateData,
            identity: identity(contextRevision: 5),
            now: activeNow
        )
        XCTAssertEqual(result.captureAuthorization, .restricted(.onDeviceBlocked))
    }

    func testAllowRegionModeSkipsEvaluationUnlessOptedOut() throws {
        let allowPolicy = try EluV1RegionPolicyFactory.make(mode: "allow")
        XCTAssertEqual(
            EluPrivacyStateProjector.onDeviceDecision(
                regionPolicy: allowPolicy,
                timeZoneIdentifier: "Europe/Berlin",
                identityOptedOut: false
            ),
            EluProjectedOnDeviceDecision(decision: .allow, source: .notEvaluated, reason: nil)
        )
        XCTAssertEqual(
            EluPrivacyStateProjector.onDeviceDecision(
                regionPolicy: allowPolicy,
                timeZoneIdentifier: "Europe/Berlin",
                identityOptedOut: true
            ).source,
            .localConsent
        )
    }

    func testWeakerAppliedMaskingIsEscalatedAndLeftUnvalidated() throws {
        let manager = try installedManager()
        let weaker = EluPrivacyMaskingCapability(text: .sensitive, inputs: .sensitive, images: .allow)
        let projected = try EluPrivacyStateProjector.project(
            context: try manager.activePrivacyProjectionContext(now: activeNow),
            input: input(appliedMasking: weaker)
        )

        XCTAssertFalse(projected.maskingValidated)
        XCTAssertEqual(
            projected.effectiveMasking,
            EluPrivacyMaskingCapability(text: .sensitive, inputs: .all, images: .block)
        )
        XCTAssertTrue(projected.captureAllowed)
        XCTAssertFalse(projected.replayAllowed)

        let result = try manager.authorize(
            effectivePrivacyStateData: projected.stateData,
            identity: identity(contextRevision: 5),
            now: activeNow
        )
        XCTAssertEqual(result.captureAuthorization, .authorized)
        XCTAssertEqual(result.replayAuthorization, .restricted(.maskingNotValidated))
        XCTAssertEqual(result.endpoints.roles, Set([.events, .flags]))
    }

    func testStrongerAppliedMaskingIsReportedAsApplied() throws {
        let manager = try installedManager()
        let stronger = EluPrivacyMaskingCapability(text: .all, inputs: .all, images: .block)
        let projected = try EluPrivacyStateProjector.project(
            context: try manager.activePrivacyProjectionContext(now: activeNow),
            input: input(appliedMasking: stronger)
        )
        XCTAssertTrue(projected.maskingValidated)
        XCTAssertEqual(projected.effectiveMasking, stronger)
        XCTAssertTrue(projected.replayAllowed)
    }

    func testRecognizedNativeRulesDisableTheFallbackClaim() throws {
        let config = try configFixture { object in
            var privacy = object["privacy"] as! [String: Any]
            var masking = privacy["masking"] as! [String: Any]
            var rules = masking["platformRules"] as! [[String: Any]]
            rules.append([
                "platform": "ios",
                "action": "mask",
                "targetDialect": "elu-ios-view-rule-v1",
                "target": "payment-card",
            ])
            masking["platformRules"] = rules
            privacy["masking"] = masking
            object["privacy"] = privacy
        }
        let manager = try installedManager(config: config)
        let context = try manager.activePrivacyProjectionContext(now: activeNow)

        let unrecognized = try EluPrivacyStateProjector.project(context: context, input: input())
        XCTAssertTrue(unrecognized.platformFallbackApplied)

        let recognized = try EluPrivacyStateProjector.project(
            context: context,
            input: input(recognizedMaskingRuleDialects: ["elu-ios-view-rule-v1"])
        )
        XCTAssertFalse(recognized.platformFallbackApplied)
        let result = try manager.authorize(
            effectivePrivacyStateData: recognized.stateData,
            identity: identity(contextRevision: 5),
            now: activeNow
        )
        XCTAssertEqual(result.replayAuthorization, .restricted(.nativeMaskingFallbackMissing))
    }

    func testSamplingSessionBudgetAndTransportRestrictReplayOnly() throws {
        let manager = try installedManager()
        let context = try manager.activePrivacyProjectionContext(now: activeNow)
        let cases: [(EluPrivacyProjectionInput, EluV1ReplayRestrictionReason)] = [
            (input(replaySampleDraw: 0.9), .notSampled),
            (input(replaySessionEligible: false), .sessionIneligible),
            (input(replayBudgetRemainingSeconds: -1), .budgetExhausted),
            (input(localReplayTransports: []), .transportNotSelected),
            (
                input(localReplayTransports: [
                    EluV1ReplayTransportPair(codec: "elu-ios-other-v1", compression: .gzip),
                ]),
                .transportNotSelected
            ),
        ]
        for (projectionInput, expected) in cases {
            let projected = try EluPrivacyStateProjector.project(context: context, input: projectionInput)
            XCTAssertTrue(projected.captureAllowed)
            XCTAssertFalse(projected.replayAllowed)
            let result = try manager.authorize(
                effectivePrivacyStateData: projected.stateData,
                identity: identity(contextRevision: 5),
                now: activeNow
            )
            XCTAssertEqual(result.captureAuthorization, .authorized)
            XCTAssertEqual(result.replayAuthorization, .restricted(expected))
        }
    }

    func testBudgetIsClampedToThePolicyMaximumAndTransportPreferenceIsOrdered() throws {
        let manager = try installedManager()
        let context = try manager.activePrivacyProjectionContext(now: activeNow)
        let other = EluV1ReplayTransportPair(codec: "elu-ios-other-v1", compression: .gzip)
        let uncompressed = EluV1ReplayTransportPair(codec: nativePair.codec, compression: .none)

        let projected = try EluPrivacyStateProjector.project(
            context: context,
            input: input(
                replayBudgetRemainingSeconds: 100_000,
                localReplayTransports: [other, uncompressed, nativePair]
            )
        )
        XCTAssertEqual(projected.replayBudgetRemainingSeconds, 3_600)
        XCTAssertEqual(projected.replayTransport, uncompressed)
    }

    func testSamplingIsDeterministicAndBoundsTheDraw() throws {
        XCTAssertFalse(try EluPrivacyStateProjector.isSampled(draw: 0, sampleRate: 0))
        XCTAssertTrue(try EluPrivacyStateProjector.isSampled(draw: 0.999, sampleRate: 1))
        XCTAssertTrue(try EluPrivacyStateProjector.isSampled(draw: 0.24, sampleRate: 0.25))
        XCTAssertFalse(try EluPrivacyStateProjector.isSampled(draw: 0.25, sampleRate: 0.25))
        for draw in [1.0, -0.1, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try EluPrivacyStateProjector.isSampled(draw: draw, sampleRate: 0.5)) { error in
                XCTAssertEqual(error as? EluPrivacyStateProjectionError, .invalidSampleDraw)
            }
        }
    }

    func testInvalidLocalFactsFailClosed() throws {
        let manager = try installedManager()
        let context = try manager.activePrivacyProjectionContext(now: activeNow)

        XCTAssertThrowsError(
            try EluPrivacyStateProjector.project(context: context, input: input(contextRevision: -1))
        ) { error in
            XCTAssertEqual(error as? EluPrivacyStateProjectionError, .invalidContextRevision)
        }
        XCTAssertThrowsError(
            try EluPrivacyStateProjector.project(
                context: context,
                input: input(evaluatedAt: Date(timeIntervalSinceReferenceDate: .infinity))
            )
        ) { error in
            XCTAssertEqual(error as? EluPrivacyStateProjectionError, .invalidClock)
        }
        XCTAssertThrowsError(try EluV1ConfigManager().activePrivacyProjectionContext(now: activeNow)) { error in
            XCTAssertEqual(error as? EluV1ConfigResolutionError, .missingActiveConfig)
        }
    }

    func testContextRevisionMismatchIsDetectedByTheManager() throws {
        let manager = try installedManager()
        let projected = try EluPrivacyStateProjector.project(
            context: try manager.activePrivacyProjectionContext(now: activeNow),
            input: input(contextRevision: 4)
        )
        let result = try manager.authorize(
            effectivePrivacyStateData: projected.stateData,
            identity: identity(contextRevision: 5),
            now: activeNow
        )
        XCTAssertEqual(result.captureAuthorization, .invalid(.contextRevisionMismatch))
    }

    func testV2ContextSelectsAnExactAdvertisedPair() throws {
        let browserPair = EluV1ReplayTransportPair(codec: "elu-browser-dom-v1", compression: .gzip)
        let manager = EluV1ConfigManager(
            readbackProvenReplayTransports: [
                EluV1ReplayTransportSelection(codec: browserPair.codec, compression: .gzip)!,
            ]
        )
        _ = try manager.update(configData: fixture("Conformance/V2/fixtures/config-enabled.json"), now: v2Now)

        let projected = try EluPrivacyStateProjector.project(
            context: try manager.activePrivacyProjectionContext(now: v2Now),
            input: input(
                evaluatedAt: v2Now,
                localReplayTransports: [
                    EluV1ReplayTransportPair(codec: browserPair.codec, compression: .none),
                    browserPair,
                ]
            )
        )
        XCTAssertEqual(projected.replayTransport, browserPair)

        let result = try manager.authorize(
            effectivePrivacyStateData: projected.stateData,
            identity: identity(contextRevision: 5),
            now: v2Now
        )
        XCTAssertEqual(result.configSchemaVersion, 2)
        XCTAssertEqual(
            result.replayAuthorization,
            .authorized(EluV1ReplayTransportSelection(codec: browserPair.codec, compression: .gzip)!)
        )
        XCTAssertEqual(result.endpoints[.replay]?.absoluteString, "https://ingest.elu.dev/v2/replay")
    }

    private func input(
        contextRevision: Int64 = 5,
        identityOptedOut: Bool = false,
        timeZoneIdentifier: String? = "America/New_York",
        evaluatedAt: Date? = nil,
        appliedMasking: EluPrivacyMaskingCapability = EluPrivacyMaskingCapability(
            text: .sensitive,
            inputs: .all,
            images: .block
        ),
        recognizedMaskingRuleDialects: Set<String> = [],
        replaySampleDraw: Double = 0.1,
        replaySessionEligible: Bool = true,
        replayBudgetRemainingSeconds: Int = 3_599,
        localReplayTransports: [EluV1ReplayTransportPair]? = nil
    ) -> EluPrivacyProjectionInput {
        EluPrivacyProjectionInput(
            contextRevision: contextRevision,
            identityOptedOut: identityOptedOut,
            timeZoneIdentifier: timeZoneIdentifier,
            evaluatedAt: evaluatedAt ?? activeNow,
            appliedMasking: appliedMasking,
            recognizedMaskingRuleDialects: recognizedMaskingRuleDialects,
            replaySampleDraw: replaySampleDraw,
            replaySessionEligible: replaySessionEligible,
            replayBudgetRemainingSeconds: replayBudgetRemainingSeconds,
            localReplayTransports: localReplayTransports ?? [nativePair]
        )
    }

    private func installedManager(config: Data? = nil) throws -> EluV1ConfigManager {
        let manager = EluV1ConfigManager(
            readbackProvenReplayTransports: [
                EluV1ReplayTransportSelection(codec: nativePair.codec, compression: .gzip)!,
            ]
        )
        _ = try manager.update(configData: config ?? configFixture { _ in }, now: activeNow)
        return manager
    }

    private func identity(contextRevision: Int64, optedOut: Bool = false) throws -> EluIdentitySnapshot {
        let state = try EluIdentityState(
            revision: 0,
            contextRevision: contextRevision,
            anonymousId: "anon-privacy-test",
            userId: nil,
            groups: [:],
            superProperties: [:],
            session: nil,
            optedOut: optedOut,
            updatedAt: activeNow
        )
        return EluIdentitySnapshot(
            identity: state,
            streamId: "stream-privacy-test",
            nextSequence: 0,
            flagContext: EluFlagContext()
        )
    }

    private func fixture(_ relativePath: String) -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try! Data(contentsOf: root.appendingPathComponent(relativePath))
    }

    /// The v1 fixture with the native pair advertised alongside the browser codec.
    private func configFixture(_ mutation: (inout [String: Any]) throws -> Void) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture("Conformance/V1/Fixtures/config-enabled.json"))
                as? [String: Any]
        )
        var capabilities = object["capabilities"] as! [String: Any]
        var replay = capabilities["replay"] as! [String: Any]
        replay["acceptedCodecs"] = ["elu-browser-dom-v1", nativePair.codec]
        replay["acceptedCompressions"] = ["gzip", "none"]
        capabilities["replay"] = replay
        object["capabilities"] = capabilities
        try mutation(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private enum EluV1RegionPolicyFactory {
    static func make(mode: String) throws -> EluV1RegionPolicy {
        try JSONDecoder().decode(EluV1RegionPolicy.self, from: Data("{\"mode\":\"\(mode)\"}".utf8))
    }
}
