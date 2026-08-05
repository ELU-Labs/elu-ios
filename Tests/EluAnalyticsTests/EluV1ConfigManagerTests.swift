import Foundation
import XCTest
@testable import EluAnalytics

final class EluV1ConfigManagerTests: XCTestCase {
    private let activeNow = Date(timeIntervalSince1970: 1_785_801_660) // 2026-08-04T00:01:00Z

    func testCanonicalBrowserFixtureAuthorizesCaptureAndFlagsButNotNativeReplayOrAssets() throws {
        let manager = EluV1ConfigManager()
        _ = try manager.update(configData: fixture("config-enabled.json"), now: activeNow)

        let result = try manager.authorize(
            effectivePrivacyStateData: fixture("privacy-allowed.json"),
            identity: identity(contextRevision: 5),
            now: activeNow
        )

        XCTAssertEqual(result.endpoints.roles, Set([.events, .flags]))
        XCTAssertEqual(result.captureAuthorization, .authorized)
        XCTAssertEqual(
            result.replayAuthorization,
            .restricted(.nativeMaskingFallbackMissing)
        )
        XCTAssertNil(result.endpoints[.replay])
        XCTAssertNil(result.endpoints[.assets])
    }

    func testBrowserCodecRemainsUnsupportedEvenWithNativeFallbackProof() throws {
        let privacy = try rawPrivacyFixture("privacy-allowed.json") { object in
            var masking = object["effectiveMasking"] as! [String: Any]
            masking["platformFallbackApplied"] = true
            object["effectiveMasking"] = masking
        }
        let manager = EluV1ConfigManager()
        _ = try manager.update(configData: fixture("config-enabled.json"), now: activeNow)

        let result = try manager.authorize(
            effectivePrivacyStateData: privacy,
            identity: identity(contextRevision: 5),
            now: activeNow
        )

        XCTAssertEqual(result.captureAuthorization, .authorized)
        XCTAssertEqual(result.replayAuthorization, .restricted(.unsupportedLocalTransport))
        XCTAssertEqual(result.endpoints.roles, Set([.events, .flags]))
    }

    func testReadbackProvenIOSPairAuthorizesReplayButNeverBrowserAssets() throws {
        let result = try resolve()

        XCTAssertEqual(result.configRevision, "config-2026-08-04-1")
        XCTAssertEqual(result.siteId, "site_demo")
        XCTAssertEqual(result.endpoints.roles, Set([.events, .replay, .flags]))
        XCTAssertEqual(result.endpoints[.events]?.absoluteString, "https://ingest.elu.dev/v1/events")
        XCTAssertEqual(result.endpoints[.replay]?.absoluteString, "https://ingest.elu.dev/v1/replay")
        XCTAssertEqual(result.endpoints[.flags]?.absoluteString, "https://ingest.elu.dev/v1/flags")
        XCTAssertNil(result.endpoints[.assets])
        XCTAssertEqual(result.captureAuthorization, .authorized)
        XCTAssertEqual(result.replayAuthorization, .authorized(nativeTransport))
    }

    func testFrozenPrivacyHashesMatchCanonicalContract() throws {
        XCTAssertEqual(
            try EluV1ConfigManager.computedEffectivePolicyHash(for: fixture("privacy-allowed.json")),
            "sha256:852aa75195a8a72e48ded6f286ea8634d83e64c55277207756632f7a60883ed3"
        )
        XCTAssertEqual(
            try EluV1ConfigManager.computedEffectivePolicyHash(for: fixture("privacy-blocked.json")),
            "sha256:e0c5e50f3127f85b1530be39fced4cc7abeae535d3d50ca48acb30cfcca685f6"
        )
    }

    func testBlockedPrivacyRetainsOnlyFlags() throws {
        let blocked = try privacyFixture("privacy-blocked.json") { object in
            object["policyRevision"] = "privacy-1"
        }
        let result = try resolve(
            privacy: blocked,
            identity: identity(contextRevision: 7)
        )

        XCTAssertEqual(result.endpoints.roles, Set([.flags]))
        XCTAssertEqual(result.captureAuthorization, .restricted(.onDeviceBlocked))
        XCTAssertEqual(result.replayAuthorization, .restricted(.captureUnavailable))
    }

    func testCurrentOptOutRetainsFlagsButRestrictsCaptureAndReplay() throws {
        let optedOutPrivacy = try privacyFixture("privacy-allowed.json") { object in
            object["captureAllowed"] = false
            object["replayAllowed"] = false
            object["identityOptedOut"] = true
        }
        let result = try resolve(
            privacy: optedOutPrivacy,
            identity: identity(contextRevision: 5, optedOut: true)
        )

        XCTAssertEqual(result.endpoints.roles, Set([.flags]))
        XCTAssertEqual(result.captureAuthorization, .restricted(.identityOptedOut))
        XCTAssertEqual(result.replayAuthorization, .restricted(.captureUnavailable))
    }

    func testMissingMalformedAndBadHashPrivacyKeepFlagsWithMachineReadableInvalidity() throws {
        let manager = try installedManager()
        let snapshot = try identity(contextRevision: 5)

        var result = try manager.authorize(
            effectivePrivacyStateData: nil,
            identity: snapshot,
            now: activeNow
        )
        assertBothInvalid(.missingState, result)

        result = try manager.authorize(
            effectivePrivacyStateData: Data("not-json".utf8),
            identity: snapshot,
            now: activeNow
        )
        assertBothInvalid(.malformedState, result)

        let badHash = try jsonFixture("privacy-allowed.json") { object in
            object["captureAllowed"] = false
        }
        result = try manager.authorize(
            effectivePrivacyStateData: badHash,
            identity: snapshot,
            now: activeNow
        )
        assertBothInvalid(.invalidPolicyHash, result)
    }

    func testSharedPolicyContextAndOptMismatchesInvalidateBothChannelsButKeepFlags() throws {
        var result = try resolve(
            privacy: fixture("privacy-blocked.json"),
            identity: identity(contextRevision: 7)
        )
        assertBothInvalid(.policyRevisionMismatch, result)

        result = try resolve(identity: identity(contextRevision: 6))
        assertBothInvalid(.contextRevisionMismatch, result)

        result = try resolve(identity: identity(contextRevision: 5, optedOut: true))
        assertBothInvalid(.identityOptStateMismatch, result)
    }

    func testClaimedAuthorizationMismatchInvalidatesOnlyItsChannel() throws {
        let falseCapture = try privacyFixture("privacy-allowed.json") { object in
            object["captureAllowed"] = false
        }
        var result = try resolve(privacy: falseCapture)
        XCTAssertEqual(result.captureAuthorization, .invalid(.claimedAuthorizationMismatch))
        XCTAssertEqual(result.replayAuthorization, .restricted(.captureUnavailable))
        XCTAssertEqual(result.endpoints.roles, Set([.flags]))

        let falseReplay = try privacyFixture("privacy-allowed.json") { object in
            object["replayAllowed"] = false
        }
        result = try resolve(privacy: falseReplay)
        XCTAssertEqual(result.captureAuthorization, .authorized)
        XCTAssertEqual(result.replayAuthorization, .invalid(.claimedAuthorizationMismatch))
        XCTAssertEqual(result.endpoints.roles, Set([.events, .flags]))
    }

    func testUnadvertisedReplayTransportInvalidatesOnlyReplay() throws {
        let config = try configFixture { object in
            var capabilities = object["capabilities"] as! [String: Any]
            var replay = capabilities["replay"] as! [String: Any]
            replay["acceptedCodecs"] = ["elu-ios-other-v1"]
            capabilities["replay"] = replay
            object["capabilities"] = capabilities
        }
        let result = try resolve(config: config)

        XCTAssertEqual(result.captureAuthorization, .authorized)
        XCTAssertEqual(result.replayAuthorization, .invalid(.unadvertisedReplayTransport))
        XCTAssertEqual(result.endpoints.roles, Set([.events, .flags]))
    }

    func testServerRegionConflictInvalidatesCaptureWithoutRemovingFlags() throws {
        let config = try configFixture { object in
            var privacy = object["privacy"] as! [String: Any]
            var region = privacy["regionPolicy"] as! [String: Any]
            region["mode"] = "block"
            privacy["regionPolicy"] = region
            object["privacy"] = privacy
        }
        let result = try resolve(config: config)

        XCTAssertEqual(result.captureAuthorization, .invalid(.regionPolicyConflict))
        XCTAssertEqual(result.replayAuthorization, .restricted(.captureUnavailable))
        XCTAssertEqual(result.endpoints.roles, Set([.flags]))
    }

    func testMissingOrUnrecognizedIOSRulesRequireRecordedFallbackForReplay() throws {
        let noFallback = try privacyFixture("privacy-allowed.json") { object in
            var masking = object["effectiveMasking"] as! [String: Any]
            masking["platformFallbackApplied"] = false
            object["effectiveMasking"] = masking
        }
        var result = try resolve(privacy: noFallback)
        XCTAssertEqual(result.captureAuthorization, .authorized)
        XCTAssertEqual(
            result.replayAuthorization,
            .restricted(.nativeMaskingFallbackMissing)
        )

        let configWithUnknownIOSRule = try configFixture { object in
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
        result = try resolve(config: configWithUnknownIOSRule, privacy: noFallback)
        XCTAssertEqual(
            result.replayAuthorization,
            .restricted(.nativeMaskingFallbackMissing)
        )

        result = try resolve(config: configWithUnknownIOSRule)
        XCTAssertEqual(result.replayAuthorization, .authorized(nativeTransport))
    }

    func testEffectiveMaskingFailureInvalidatesOnlyReplay() throws {
        let stricter = try privacyFixture("privacy-allowed.json") { object in
            var masking = object["effectiveMasking"] as! [String: Any]
            masking["text"] = "all"
            object["effectiveMasking"] = masking
        }
        XCTAssertEqual(try resolve(privacy: stricter).replayAuthorization, .authorized(nativeTransport))

        let weaker = try privacyFixture("privacy-allowed.json") { object in
            var masking = object["effectiveMasking"] as! [String: Any]
            masking["inputs"] = "sensitive"
            object["effectiveMasking"] = masking
        }
        let result = try resolve(privacy: weaker)
        XCTAssertEqual(result.captureAuthorization, .authorized)
        XCTAssertEqual(
            result.replayAuthorization,
            .invalid(.effectiveMaskingWeakerThanPolicy)
        )
        XCTAssertEqual(result.endpoints.roles, Set([.events, .flags]))
    }

    func testDisabledAndRevokedDocumentsInstallTerminalNoAuthorityBoundaries() throws {
        let disabledManager = manager()
        XCTAssertEqual(
            try disabledManager.update(configData: fixture("config-disabled.json"), now: activeNow),
            .disabled(revision: "config-disabled-1")
        )
        assertMissingActiveConfig(disabledManager)

        let revoked = try jsonFixture("config-disabled.json") { object in
            object["status"] = "revoked"
        }
        let revokedManager = manager()
        XCTAssertEqual(
            try revokedManager.update(configData: revoked, now: activeNow),
            .revoked(revision: "config-disabled-1")
        )
        assertMissingActiveConfig(revokedManager)
    }

    func testExpiryAndValidityWindowFailClosedWithoutIssuedAtValidFromGate() throws {
        let expiredManager = manager()
        XCTAssertEqual(
            try expiredManager.update(
                configData: try configFixture { _ in },
                now: Date(timeIntervalSince1970: 1_785_801_900)
            ),
            .expired(revision: "config-2026-08-04-1")
        )
        assertMissingActiveConfig(expiredManager)

        let zeroWindow = try configFixture { object in
            object["issuedAt"] = object["expiresAt"]
        }
        assertUpdateError(.invalidConfigValidityWindow, config: zeroWindow)

        let reversed = try configFixture { object in
            object["issuedAt"] = "2026-08-04T00:06:00.000Z"
        }
        assertUpdateError(.invalidConfigValidityWindow, config: reversed)

        let futureIssuedMetadata = try configFixture { object in
            object["issuedAt"] = "2026-08-04T00:04:00.000Z"
        }
        XCTAssertNoThrow(try manager().update(configData: futureIssuedMetadata, now: activeNow))
    }

    func testRFC3339OffsetsYearZeroAndInvalidCalendarDates() throws {
        let offsetConfig = try configFixture { object in
            object["issuedAt"] = "2026-08-03T17:00:00-07:00"
            object["expiresAt"] = "2026-08-03T17:05:00-07:00"
        }
        XCTAssertNoThrow(try manager().update(configData: offsetConfig, now: activeNow))
        XCTAssertNoThrow(try EluV1Timestamp("0000-01-01T00:00:00Z"))

        let invalidDate = try configFixture { object in
            object["expiresAt"] = "2026-02-30T00:05:00Z"
        }
        assertUpdateError(.malformedConfig, config: invalidDate)
    }

    func testRFC3339LeapSecondBoundariesAndExactOrdering() throws {
        XCTAssertNoThrow(try EluV1Timestamp("2016-12-31T23:59:60Z"))
        XCTAssertNoThrow(try EluV1Timestamp("1990-12-31T15:59:60-08:00"))
        XCTAssertNoThrow(try EluV1Timestamp("2030-06-30T23:59:60Z"))

        for invalid in [
            "2016-12-31T12:00:60Z",
            "2016-12-30T23:59:60Z",
            "2016-12-31T23:59:61Z",
        ] {
            XCTAssertThrowsError(try EluV1Timestamp(invalid))
        }

        let before = try EluV1Timestamp("2016-12-31T23:59:59.999999Z")
        let leap = try EluV1Timestamp("2016-12-31T23:59:60.999999Z")
        let midnight = try EluV1Timestamp("2017-01-01T00:00:00Z")
        XCTAssertLessThan(before, leap)
        XCTAssertLessThan(leap, midnight)
    }

    func testSubMillisecondExpiryRemainsAuthorizedUntilItsExactBoundary() throws {
        let config = try configFixture { object in
            object["expiresAt"] = "2026-08-04T00:01:00.000000001Z"
        }
        let manager = self.manager()

        XCTAssertEqual(
            try manager.update(configData: config, now: activeNow),
            .enabled(
                revision: "config-2026-08-04-1",
                expiresAt: Date(timeIntervalSince1970: 1_785_801_660)
            )
        )
        XCTAssertEqual(
            try manager.authorize(
                effectivePrivacyStateData: try privacyFixture("privacy-allowed.json") { _ in },
                identity: identity(contextRevision: 5),
                now: activeNow
            ).captureAuthorization,
            .authorized
        )
    }

    func testExpiryUsesDatesNativeReferencePrecision() throws {
        let referenceWholeSecond = activeNow.timeIntervalSinceReferenceDate
        XCTAssertEqual(referenceWholeSecond.rounded(), referenceWholeSecond)

        let justBefore = Date(timeIntervalSinceReferenceDate: referenceWholeSecond.nextDown)
        let expiresAtWholeSecond = try configFixture { object in
            object["expiresAt"] = "2026-08-04T00:01:00Z"
        }
        XCTAssertEqual(
            try manager().update(configData: expiresAtWholeSecond, now: justBefore),
            .enabled(revision: "config-2026-08-04-1", expiresAt: activeNow)
        )

        let justAfter = Date(timeIntervalSinceReferenceDate: referenceWholeSecond.nextUp)
        let expiresBeforeJustAfter = try configFixture { object in
            object["expiresAt"] = "2026-08-04T00:01:00.000000100Z"
        }
        XCTAssertEqual(
            try manager().update(configData: expiresBeforeJustAfter, now: justAfter),
            .expired(revision: "config-2026-08-04-1")
        )
    }

    func testNegativeReferenceClockFractionDoesNotRoundIntoEarlyExpiry() throws {
        let clock = Date(timeIntervalSinceReferenceDate: -0.1)
        let config = try configFixture { object in
            object["issuedAt"] = "2000-12-31T23:59:59Z"
            object["expiresAt"] = "2000-12-31T23:59:59.9Z"
        }

        let result = try manager().update(configData: config, now: clock)
        guard case let .enabled(revision, _) = result else {
            return XCTFail("expected exact negative-reference clock to remain before expiry")
        }
        XCTAssertEqual(revision, "config-2026-08-04-1")
    }

    func testFractionalLeapSecondExpiresAtFollowingMidnight() throws {
        let beforeMidnight = Date(timeIntervalSince1970: 1_483_228_799)
        let midnight = Date(timeIntervalSince1970: 1_483_228_800)
        let config = try configFixture { object in
            object["issuedAt"] = "2016-12-31T23:59:59Z"
            object["expiresAt"] = "2016-12-31T23:59:60.999999999Z"
        }
        let manager = self.manager()

        XCTAssertEqual(
            try manager.update(configData: config, now: beforeMidnight),
            .enabled(
                revision: "config-2026-08-04-1",
                expiresAt: Date(timeIntervalSince1970: 1_483_228_800.999999999)
            )
        )
        XCTAssertThrowsError(
            try manager.authorize(
                effectivePrivacyStateData: try privacyFixture("privacy-allowed.json") { _ in },
                identity: identity(contextRevision: 5),
                now: midnight
            )
        ) { error in
            XCTAssertEqual(error as? EluV1ConfigResolutionError, .missingActiveConfig)
        }
    }

    func testSchemaMajorsAndUnknownOrNullMembersFailClosed() throws {
        let futureConfig = try configFixture { $0["schemaVersion"] = 2 }
        assertUpdateError(.unsupportedConfigSchemaVersion, config: futureConfig)

        let futurePolicy = try configFixture { object in
            var privacy = object["privacy"] as! [String: Any]
            privacy["schemaVersion"] = 2
            object["privacy"] = privacy
        }
        assertUpdateError(.unsupportedPrivacyPolicySchemaVersion, config: futurePolicy)

        let unknownConfig = try configFixture { $0["futureField"] = true }
        assertUpdateError(.malformedConfig, config: unknownConfig)

        let nullOptional = try configFixture { $0["reason"] = NSNull() }
        assertUpdateError(.malformedConfig, config: nullOptional)

        let futurePrivacy = try rawPrivacyFixture("privacy-allowed.json") {
            $0["schemaVersion"] = 2
        }
        var result = try resolve(privacy: futurePrivacy)
        assertBothInvalid(.unsupportedSchemaVersion, result)

        let unknownState = try rawPrivacyFixture("privacy-allowed.json") {
            $0["futureField"] = true
        }
        result = try resolve(privacy: unknownState)
        assertBothInvalid(.malformedState, result)
    }

    func testFeatureGatesCanResolveAnEmptyRoleSet() throws {
        let config = try configFixture { object in
            var features = object["features"] as! [String: Any]
            features["capture"] = false
            features["replay"] = false
            features["flags"] = false
            features["assets"] = false
            object["features"] = features
        }
        let privacy = try privacyFixture("privacy-allowed.json") { object in
            object["captureAllowed"] = false
            object["replayAllowed"] = false
        }

        let result = try resolve(config: config, privacy: privacy)
        XCTAssertTrue(result.endpoints.roles.isEmpty)
        XCTAssertEqual(result.captureAuthorization, .restricted(.featureDisabled))
        XCTAssertEqual(result.replayAuthorization, .restricted(.captureUnavailable))
    }

    func testEveryAdvertisedRoleUsesItsExactOwnedOriginAndPath() throws {
        let cases: [(EluV1EndpointRole, String)] = [
            (.events, "https://ingest.elu.dev/v1/replay"),
            (.replay, "https://ingest.elu.dev/v1/events"),
            (.flags, "https://assets.elu.dev/v1/flags"),
            (.assets, "https://assets.elu.dev/sdk/child"),
            (.events, "https://ingest.elu.dev:444/v1/events"),
            (.events, "https://user@ingest.elu.dev/v1/events"),
            (.events, "https://ingest.elu.dev/v1/events#fragment"),
            (.events, "https://ingest.elu.dev/v1/events?site_key=shadow"),
            (.events, "https://ingest.elu.dev/v1/%65vents"),
        ]

        for (role, endpoint) in cases {
            let config = try configFixture { object in
                var endpoints = object["endpoints"] as! [String: Any]
                endpoints[role.rawValue] = endpoint
                object["endpoints"] = endpoints
            }
            assertUpdateError(.untrustedEndpoint(role), config: config)
        }
    }

    func testRawEndpointsRejectWhitespaceMalformedEscapesAndDotSegmentsBeforeNormalization() throws {
        let values = [
            "https://ingest.elu.dev/v1/events?region=us west",
            "https://ingest.elu.dev/v1/events?region=é",
            "https://ingest.elu.dev/v1/events?region=%ZZ",
            "https://ingest.elu.dev/v1/./events",
            "https://ingest.elu.dev/v1/%2e%2e/events",
            "https://ingest.elu.dev\\v1\\events",
        ]
        for value in values {
            let config = try configFixture { object in
                var endpoints = object["endpoints"] as! [String: Any]
                endpoints["events"] = value
                object["endpoints"] = endpoints
            }
            assertUpdateError(.malformedConfig, config: config)
        }
    }

    func testDefaultHTTPSPortAndNonReservedQueryArePreserved() throws {
        let config = try configFixture { object in
            var endpoints = object["endpoints"] as! [String: Any]
            endpoints["events"] = "https://ingest.elu.dev:443/v1/events?region=us"
            object["endpoints"] = endpoints
        }
        let url = try XCTUnwrap(resolve(config: config).endpoints[.events])
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query, "region=us")
    }

    func testPercentEncodedUTF8QueryIsAcceptedAsURI() throws {
        let config = try configFixture { object in
            var endpoints = object["endpoints"] as! [String: Any]
            endpoints["events"] = "https://ingest.elu.dev/v1/events?region=%C3%A9"
            object["endpoints"] = endpoints
        }
        let url = try XCTUnwrap(resolve(config: config).endpoints[.events])
        XCTAssertEqual(
            url.absoluteString,
            "https://ingest.elu.dev/v1/events?region=%C3%A9"
        )
    }

    func testUntrustedUnusedEndpointInvalidatesTheWholeEnabledConfig() throws {
        let config = try configFixture { object in
            var features = object["features"] as! [String: Any]
            features["assets"] = false
            object["features"] = features
            var endpoints = object["endpoints"] as! [String: Any]
            endpoints["assets"] = "https://example.invalid/sdk/"
            object["endpoints"] = endpoints
        }
        assertUpdateError(.untrustedEndpoint(.assets), config: config)
    }

    func testConditionalReplayAndAssetsRequirementsAreStrict() throws {
        let missingReplay = try configFixture { object in
            var endpoints = object["endpoints"] as! [String: Any]
            endpoints.removeValue(forKey: "replay")
            object["endpoints"] = endpoints
        }
        assertUpdateError(.malformedConfig, config: missingReplay)

        let noCodec = try configFixture { object in
            var capabilities = object["capabilities"] as! [String: Any]
            var replay = capabilities["replay"] as! [String: Any]
            replay["acceptedCodecs"] = []
            capabilities["replay"] = replay
            object["capabilities"] = capabilities
        }
        assertUpdateError(.malformedConfig, config: noCodec)

        let missingAssets = try configFixture { object in
            var endpoints = object["endpoints"] as! [String: Any]
            endpoints.removeValue(forKey: "assets")
            object["endpoints"] = endpoints
        }
        assertUpdateError(.malformedConfig, config: missingAssets)
    }

    func testInactiveConfigCannotSmuggleSiteOrEndpoints() throws {
        let disabledWithRoutes = try jsonFixture("config-disabled.json") { object in
            object["site"] = ["id": "site_demo"]
            object["endpoints"] = [
                "events": "https://ingest.elu.dev/v1/events",
                "flags": "https://ingest.elu.dev/v1/flags",
            ]
        }
        assertUpdateError(.malformedConfig, config: disabledWithRoutes)
    }

    func testPayloadCapsFailBeforeParsingWithoutRemovingFlagsForPrivacyFailure() throws {
        assertUpdateError(
            .configPayloadTooLarge,
            config: Data(repeating: 0x20, count: EluV1ConfigManager.maximumConfigBytes + 1)
        )

        let manager = try installedManager()
        let result = try manager.authorize(
            effectivePrivacyStateData: Data(
                repeating: 0x20,
                count: EluV1ConfigManager.maximumPrivacyStateBytes + 1
            ),
            identity: identity(contextRevision: 5),
            now: activeNow
        )
        assertBothInvalid(.payloadTooLarge, result)
    }

    func testMalformedAndUnsupportedCapabilityValuesFailClosed() throws {
        let duplicateCodec = try configFixture { object in
            var capabilities = object["capabilities"] as! [String: Any]
            var replay = capabilities["replay"] as! [String: Any]
            replay["acceptedCodecs"] = ["elu-ios-native-v1", "elu-ios-native-v1"]
            capabilities["replay"] = replay
            object["capabilities"] = capabilities
        }
        assertUpdateError(.malformedConfig, config: duplicateCodec)

        let invalidDialect = try configFixture { object in
            var privacy = object["privacy"] as! [String: Any]
            var masking = privacy["masking"] as! [String: Any]
            var rules = masking["platformRules"] as! [[String: Any]]
            rules[0]["targetDialect"] = "CSS"
            masking["platformRules"] = rules
            privacy["masking"] = masking
            object["privacy"] = privacy
        }
        assertUpdateError(.malformedConfig, config: invalidDialect)
    }

    func testNewerKillSwitchAndExpiredBoundaryCannotBeUndoneByOlderResponse() throws {
        let oldEnabled = try configFixture { _ in }
        let manager = self.manager()
        _ = try manager.update(configData: oldEnabled, now: activeNow)

        let newerDisabled = try jsonFixture("config-disabled.json") { object in
            object["revision"] = "config-disabled-2"
            object["issuedAt"] = "2026-08-04T00:02:00.000Z"
            object["expiresAt"] = "2026-08-04T00:04:00.000Z"
        }
        XCTAssertEqual(
            try manager.update(configData: newerDisabled, now: activeNow),
            .disabled(revision: "config-disabled-2")
        )
        XCTAssertEqual(
            try manager.update(configData: oldEnabled, now: activeNow),
            .stale(revision: "config-2026-08-04-1")
        )
        assertMissingActiveConfig(manager)

        let expiredManager = self.manager()
        _ = try expiredManager.update(configData: oldEnabled, now: activeNow)
        let newerExpired = try configFixture { object in
            object["revision"] = "config-shorter-2"
            object["issuedAt"] = "2026-08-04T00:02:00.000Z"
            object["expiresAt"] = "2026-08-04T00:03:00.000Z"
        }
        XCTAssertEqual(
            try expiredManager.update(
                configData: newerExpired,
                now: Date(timeIntervalSince1970: 1_785_801_780)
            ),
            .expired(revision: "config-shorter-2")
        )
        XCTAssertEqual(
            try expiredManager.update(configData: oldEnabled, now: activeNow),
            .stale(revision: "config-2026-08-04-1")
        )
        assertMissingActiveConfig(expiredManager)
    }

    func testEqualIssuedAtConflictPoisonsBoundaryUntilStrictlyNewerConfig() throws {
        let original = try configFixture { _ in }
        let manager = self.manager()
        _ = try manager.update(configData: original, now: activeNow)

        let conflict = try configFixture { object in
            object["revision"] = "conflicting-revision"
        }
        XCTAssertThrowsError(try manager.update(configData: conflict, now: activeNow)) { error in
            XCTAssertEqual(
                error as? EluV1ConfigResolutionError,
                .conflictingConfigAtIssuedAt
            )
        }
        XCTAssertThrowsError(try manager.update(configData: original, now: activeNow)) { error in
            XCTAssertEqual(
                error as? EluV1ConfigResolutionError,
                .conflictingConfigAtIssuedAt
            )
        }
        assertMissingActiveConfig(manager)

        let newer = try configFixture { object in
            object["revision"] = "config-recovered-2"
            object["issuedAt"] = "2026-08-04T00:02:00.000Z"
        }
        XCTAssertNoThrow(try manager.update(configData: newer, now: activeNow))
        XCTAssertEqual(
            try manager.authorize(
                effectivePrivacyStateData: try privacyFixture("privacy-allowed.json") { _ in },
                identity: identity(contextRevision: 5),
                now: activeNow
            ).captureAuthorization,
            .authorized
        )
    }

    func testConcurrentAuthorizationIsDeterministicAndSerialized() async throws {
        let manager = try installedManager()
        let privacy = try privacyFixture("privacy-allowed.json") { _ in }
        let snapshot = try identity(contextRevision: 5)
        let now = activeNow

        let count = try await withThrowingTaskGroup(of: EluV1ConfigResolution.self) { group in
            for _ in 0 ..< 64 {
                group.addTask {
                    try manager.authorize(
                        effectivePrivacyStateData: privacy,
                        identity: snapshot,
                        now: now
                    )
                }
            }
            var results: [EluV1ConfigResolution] = []
            for try await result in group {
                results.append(result)
            }
            XCTAssertTrue(results.dropFirst().allSatisfy { $0 == results.first })
            return results.count
        }
        XCTAssertEqual(count, 64)
    }

    private var nativeTransport: EluV1ReplayTransportSelection {
        EluV1ReplayTransportSelection(codec: "elu-ios-native-v1", compression: .gzip)!
    }

    private func manager(
        readbackProven: Set<EluV1ReplayTransportSelection>? = nil
    ) -> EluV1ConfigManager {
        EluV1ConfigManager(
            readbackProvenReplayTransports: readbackProven ?? Set([nativeTransport])
        )
    }

    private func installedManager() throws -> EluV1ConfigManager {
        let manager = self.manager()
        _ = try manager.update(
            configData: try configFixture { _ in },
            now: activeNow
        )
        return manager
    }

    private func resolve(
        config: Data? = nil,
        privacy: Data? = nil,
        identity: EluIdentitySnapshot? = nil,
        now: Date? = nil,
        manager: EluV1ConfigManager? = nil
    ) throws -> EluV1ConfigResolution {
        let manager = manager ?? self.manager()
        _ = try manager.update(
            configData: config ?? configFixture { _ in },
            now: now ?? activeNow
        )
        return try manager.authorize(
            effectivePrivacyStateData: privacy ?? privacyFixture("privacy-allowed.json") { _ in },
            identity: identity ?? self.identity(contextRevision: 5),
            now: now ?? activeNow
        )
    }

    private func assertBothInvalid(
        _ reason: EluV1PrivacyInvalidReason,
        _ result: EluV1ConfigResolution,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.captureAuthorization, .invalid(reason), file: file, line: line)
        XCTAssertEqual(result.replayAuthorization, .invalid(reason), file: file, line: line)
        XCTAssertEqual(result.endpoints.roles, Set([.flags]), file: file, line: line)
    }

    private func assertUpdateError(
        _ expected: EluV1ConfigResolutionError,
        config: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try manager().update(configData: config, now: activeNow),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? EluV1ConfigResolutionError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func assertMissingActiveConfig(
        _ manager: EluV1ConfigManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try manager.authorize(
                effectivePrivacyStateData: fixture("privacy-allowed.json"),
                identity: identity(contextRevision: 5),
                now: activeNow
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? EluV1ConfigResolutionError,
                .missingActiveConfig,
                file: file,
                line: line
            )
        }
    }

    private func identity(contextRevision: Int64, optedOut: Bool = false) throws -> EluIdentitySnapshot {
        let state = try EluIdentityState(
            revision: 0,
            contextRevision: contextRevision,
            anonymousId: "anon-config-test",
            userId: nil,
            groups: [:],
            superProperties: [:],
            session: nil,
            optedOut: optedOut,
            updatedAt: activeNow
        )
        return EluIdentitySnapshot(
            identity: state,
            streamId: "stream-config-test",
            nextSequence: 0,
            flagContext: EluFlagContext()
        )
    }

    private func fixture(_ name: String) -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root
            .appendingPathComponent("Conformance/V1/Fixtures", isDirectory: true)
            .appendingPathComponent(name)
        return try! Data(contentsOf: url)
    }

    private func configFixture(
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        try jsonFixture("config-enabled.json") { object in
            var capabilities = object["capabilities"] as! [String: Any]
            var replay = capabilities["replay"] as! [String: Any]
            replay["acceptedCodecs"] = ["elu-ios-native-v1"]
            capabilities["replay"] = replay
            object["capabilities"] = capabilities
            try mutation(&object)
        }
    }

    private func privacyFixture(
        _ name: String,
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        try rawPrivacyFixture(name) { object in
            if var transport = object["replayTransport"] as? [String: Any] {
                transport["codec"] = "elu-ios-native-v1"
                object["replayTransport"] = transport
            }
            var masking = object["effectiveMasking"] as! [String: Any]
            masking["platformFallbackApplied"] = true
            object["effectiveMasking"] = masking
            try mutation(&object)
        }
    }

    private func rawPrivacyFixture(
        _ name: String,
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var object = try jsonObject(fixture(name))
        try mutation(&object)
        object["effectivePolicyHash"] = "sha256:" + String(repeating: "0", count: 64)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        object["effectivePolicyHash"] = try EluV1ConfigManager.computedEffectivePolicyHash(for: data)
        data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data
    }

    private func jsonFixture(
        _ name: String,
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var object = try jsonObject(fixture(name))
        try mutation(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
