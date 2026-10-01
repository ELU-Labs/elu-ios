import Foundation
import XCTest
@testable import EluAnalytics

/// The facade projection onto the ELU-owned runtime: what each `Elu` method
/// records, in what order, what the flag getters report, and what a disabled
/// configuration leaves behind.
final class EluStandaloneFacadeRuntimeTests: XCTestCase {
    private static let siteKey = "elu_pk_test_facade"
    private let baseDate = Date(timeIntervalSince1970: 1_785_801_660) // 2026-08-04T00:01:00Z

    private struct CheckoutFailure: LocalizedError {
        var errorDescription: String? { "checkout failed" }
    }

    func testOriginalFacadeFactoryDefaultsToOneV2Request() async throws {
        try await assertBootstrapRequest(optIn: false, body: Data("{}".utf8), expected: .v2)
    }

    func testOriginalFacadeFactoryOptsIntoV3WithoutFallbackOnInvalidResponse() async throws {
        try await assertBootstrapRequest(optIn: true, body: Data("{}".utf8), expected: .nativeV3)
    }

    func testOriginalFacadeFactoryBaseOnlyV3DoesNotGrantRaster() async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let base: [String: Any] = ["schemaVersion": 2, "revision": "bootstrap-closed",
            "status": "disabled", "reason": "policy",
            "issuedAt": formatter.string(from: now.addingTimeInterval(-1)),
            "expiresAt": formatter.string(from: now.addingTimeInterval(300))]
        let body = try JSONSerialization.data(withJSONObject: ["schemaVersion": 3, "configV2": base], options: [.sortedKeys])
        XCTAssertNil(try EluNativeV3ConfigParser.parse(body).raster)
        try await assertBootstrapRequest(optIn: true, body: body, expected: .nativeV3)
    }

    private func assertBootstrapRequest(optIn: Bool, body: Data, expected: EluV2ConfigRequest.Format) async throws {
        try await withTemporaryDirectory { root in
            let siteKey = "elu_pk_test_" + String(repeating: "b", count: 22)
            let context = EluRuntimeBackendContext(siteKey: siteKey, isNewUser: true,
                flagsDidLoad: {}, declaredRegionReplayEnabled: optIn)
            let transport = BootstrapConfigTransport(body: body)
            let stack = try await EluStandaloneFacadeRuntime.makeStack(context: context,
                rootDirectoryURL: root, configTransport: transport)
            do {
                stack.start(); stack.setForeground(true)
                for _ in 0..<250 {
                    if await transport.requests.count == 1 { break }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                let requests = await transport.requests
                XCTAssertEqual(requests.count, 1)
                let request = try XCTUnwrap(requests.first)
                XCTAssertEqual(request.format, expected)
                XCTAssertEqual(request.url.absoluteString,
                    "https://elu.dev/sdk/\(expected == .v2 ? "v2" : "v3")/\(siteKey)/config")
                XCTAssertFalse(stack.runtime.nativeReplayIsRecording())
                let capture = await stack.runtime.capture("without-permission")
                guard case .rejected = capture else {
                    XCTFail("The implementation option granted capture permission")
                    stack.close(); await stack.settled(); return
                }
                stack.close(); await stack.settled()
                let finalRequests = await transport.requests
                XCTAssertEqual(finalRequests.count, 1, "No second configuration owner or fallback request")
                XCTAssertEqual(finalRequests.map(\.format), [expected])
            } catch {
                stack.close(); await stack.settled(); throw error
            }
        }
    }

    func testNeverModeRejectsPersonIntentBeforeOptimisticGettersAndKeepsForFlagsLocal() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root, personProfiles: .never)
            let original = harness.backend.distinctId()
            let before = try await harness.runtime.queueSnapshot()
            harness.backend.execute(.identify(distinctId: "forbidden-user", userProperties: ["tier": "paid"]))
            XCTAssertEqual(harness.backend.distinctId(), original, "No optimistic forbidden identity")
            harness.backend.execute(.alias("forbidden-alias"))
            harness.backend.execute(.setPersonProperties(["tier": "paid"]))
            await harness.backend.settled()
            let unchanged = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(unchanged, before)
            harness.backend.execute(.setPersonPropertiesForFlags(["tier": "evaluation-only"]))
            harness.backend.execute(.capture(event: "anonymous", properties: ["$device_id": "forged", "$epp": true,
                "$is_identified": true, "$process_person_profile": true]))
            await harness.backend.settled()
            let changed = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(changed.flagContext.personProperties["tier"], .string("evaluation-only"))
            XCTAssertNil(changed.identity.userId)
            _ = await harness.runtime.flush()
            let events = try await harness.transport.recordedEvents()
            let event = try XCTUnwrap(events.first), properties = try XCTUnwrap(event["properties"] as? [String: Any])
            XCTAssertEqual(properties["$device_id"] as? String, before.identity.anonymousId)
            XCTAssertEqual(properties["$is_identified"] as? Bool, false)
            XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
            XCTAssertNil(properties["$epp"])
            await harness.close()
        }
    }

    func testFacadeResetVariantKeepsOrRotatesIndependentDeviceIdentity() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)
            harness.backend.execute(.capture(event: "before", properties: nil))
            await harness.backend.settled()
            harness.backend.execute(.reset)
            harness.backend.execute(.capture(event: "ordinary-reset", properties: nil))
            await harness.backend.settled()
            harness.backend.execute(.resetDeviceIdentity)
            harness.backend.execute(.capture(event: "device-reset", properties: nil))
            await harness.backend.settled()
            _ = await harness.runtime.flush()
            let events = try await harness.transport.recordedEvents()
            XCTAssertEqual(events.compactMap { $0["name"] as? String }, ["before", "ordinary-reset", "device-reset"])
            let devices = events.compactMap { ($0["properties"] as? [String: Any])?["$device_id"] as? String }
            XCTAssertEqual(devices.count, 3)
            guard devices.count == 3 else { await harness.close(); return }
            XCTAssertEqual(devices[0], devices[1]); XCTAssertNotEqual(devices[1], devices[2])
            await harness.close()
        }
    }

    func testRegisterOncePreservesValuesAndUsesExplicitDefaultAtomically() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)
            harness.backend.execute(.register(["tier": "gold", "empty": NSNull(), "sentinel": "None"]))
            harness.backend.execute(.registerOnce(["tier": "silver", "empty": "changed", "new": 42,
                                                  "sentinel": "filled"], defaultValue: "None"))
            await harness.backend.settled()
            var snapshot = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(snapshot.identity.superProperties["tier"], .string("gold"))
            XCTAssertEqual(snapshot.identity.superProperties["empty"], .null)
            XCTAssertEqual(snapshot.identity.superProperties["sentinel"], .string("filled"))
            XCTAssertEqual(snapshot.identity.superProperties["new"], .integer(42))
            harness.backend.execute(.registerOnce(["empty": "present"], defaultValue: NSNull()))
            await harness.backend.settled()
            snapshot = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(snapshot.identity.superProperties["empty"], .string("present"))
            await harness.close()
            let reopened = try await makeHarness(root: root)
            let restored = try await reopened.runtime.queueSnapshot()
            XCTAssertEqual(restored.identity.superProperties, snapshot.identity.superProperties)
            await reopened.close()
        }
    }

    func testFlagResultUsesOneCurrentSnapshotAndClearsOnIdentityIntent() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root, flagTransport: FacadeFlagTransport())
            XCTAssertNil(harness.backend.featureFlagResult("variant"))
            harness.backend.activate()
            await harness.backend.settled()
            let result = try XCTUnwrap(harness.backend.featureFlagResult("variant"))
            XCTAssertEqual(result.key, "variant")
            XCTAssertTrue(result.enabled)
            XCTAssertEqual(result.variant, "variant-a")
            XCTAssertEqual((result.payload as? [String: Any])?["color"] as? String, "violet")
            XCTAssertFalse(try XCTUnwrap(harness.backend.featureFlagResult("enabled")).enabled)
            XCTAssertNil(harness.backend.featureFlagResult("absent"))
            let finish = harness.backend.beginPendingOperation(.reset)
            XCTAssertNil(harness.backend.featureFlagResult("variant"))
            finish?()
            await harness.close()
        }
    }

    func testConsentPersistsAcrossResetAndRestartAndRestoresCaptureExplicitly() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)
            harness.backend.execute(.consent(EluConsentOperation(optedOut: true)))
            XCTAssertTrue(harness.backend.isOptedOut())
            harness.backend.execute(.capture(event: "private", properties: nil))
            harness.backend.execute(.reset)
            await harness.backend.settled()
            let beforeRestart = try await harness.runtime.queueSnapshot()
            XCTAssertTrue(beforeRestart.identity.optedOut)
            XCTAssertNil(beforeRestart.identity.session)
            XCTAssertEqual(beforeRestart.queuedCount, 0)
            await harness.close()
            let reopened = try await makeHarness(root: root)
            XCTAssertTrue(reopened.backend.isOptedOut())
            reopened.backend.execute(.consent(EluConsentOperation(optedOut: false, event: "$opt_in")))
            reopened.backend.execute(.capture(event: "allowed", properties: nil))
            await reopened.backend.settled()
            XCTAssertFalse(reopened.backend.isOptedOut())
            _ = await reopened.runtime.flush()
            let events = try await reopened.transport.recordedEvents()
            XCTAssertEqual(events.compactMap { $0["name"] as? String }, ["$opt_in", "allowed"])
            await reopened.close()
        }
    }

    func testInitialConsentPrecedesInjectedConfigurationAndPreservesSavedChoiceWhenAbsent() async throws {
        try await withTemporaryDirectory { root in
            let denied = try await makeHarness(root: root, initialConsent: EluConsentOperation(optedOut: true))
            denied.backend.execute(.capture(event: "private", properties: nil))
            await denied.backend.settled()
            let saved = try await denied.runtime.queueSnapshot()
            XCTAssertTrue(saved.identity.optedOut)
            XCTAssertEqual(saved.queuedCount, 0)
            await denied.close()
            let reopened = try await makeHarness(root: root)
            XCTAssertTrue(reopened.backend.isOptedOut(), "No pre-setup choice must preserve durable denial")
            await reopened.close()
            let granted = try await makeHarness(root: root, initialConsent: EluConsentOperation(optedOut: false))
            granted.backend.execute(.capture(event: "allowed", properties: nil))
            await granted.backend.settled()
            let allowed = try await granted.runtime.queueSnapshot()
            XCTAssertFalse(allowed.identity.optedOut)
            XCTAssertEqual(allowed.queuedCount, 1)
            await granted.close()
        }
    }

    func testNewOptOutIntentCannotBeReopenedByAnOlderOptInOrConfigRefresh() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)
            let oldOptIn = UUID(), newOptOut = UUID()
            harness.runtime.acceptConsentIntent(oldOptIn, optedOut: false)
            harness.runtime.acceptConsentIntent(newOptOut, optedOut: true)
            _ = await harness.runtime.setOptedOut(true, intent: newOptOut)
            // Simulate a grant accepted before denial but dispatched after it.
            let stale = await harness.runtime.setOptedOut(false, intent: oldOptIn)
            XCTAssertNil(stale)
            let result = await harness.runtime.capture("must-not-capture")
            guard case .rejected = result else { return XCTFail("newer opt-out must fence admission") }
            guard case .unavailable = await harness.runtime.flush() else { return XCTFail("newer opt-out must fence delivery") }
            let snapshot = try await harness.runtime.queueSnapshot()
            XCTAssertTrue(snapshot.identity.optedOut)
            XCTAssertEqual(snapshot.queuedCount, 0)
            await harness.close()
            let reopened = try await makeHarness(root: root)
            XCTAssertTrue(reopened.backend.isOptedOut(), "latest denial must survive process restart")
            await reopened.close()
        }
    }

    func testSetOnceOverloadsGroupsAndLocalFlagContextResetsPersist() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)
            harness.backend.execute(.identify(distinctId: "member", userProperties: ["plan": "pro"], userPropertiesOnce: ["joined": "first"]))
            harness.backend.execute(.setPersonProperties([:], propertiesOnce: ["joined": "second", "source": "native"]))
            harness.backend.execute(.group(type: "company", key: "acme", properties: nil))
            await harness.backend.settled()
            XCTAssertEqual(harness.backend.groups(), ["company": "acme"])
            let before = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(before.flagContext.personProperties["joined"], .string("first"))
            XCTAssertEqual(before.flagContext.personProperties["source"], .string("native"))
            harness.backend.execute(.setPersonPropertiesForFlags(["beta": true]))
            harness.backend.execute(.setGroupPropertiesForFlags(type: "company", properties: ["tier": "test"]))
            harness.backend.execute(.setGroupPropertiesForFlags(type: "project", properties: ["tier": "preview"]))
            harness.backend.execute(.resetPersonPropertiesForFlags)
            harness.backend.execute(.resetGroupPropertiesForFlags("company"))
            await harness.backend.settled()
            let reset = try await harness.runtime.queueSnapshot()
            XCTAssertTrue(reset.flagContext.personProperties.isEmpty)
            XCTAssertNil(reset.flagContext.groupProperties["company"])
            XCTAssertEqual(reset.flagContext.groupProperties["project"], ["tier": .string("preview")])
            XCTAssertEqual(reset.queuedCount, before.queuedCount, "flag context changes must remain local")
            harness.backend.execute(.resetGroupPropertiesForFlags(nil))
            await harness.backend.settled()
            let allGroupsReset = try await harness.runtime.queueSnapshot()
            XCTAssertTrue(allGroupsReset.flagContext.groupProperties.isEmpty)
            XCTAssertEqual(allGroupsReset.identity.groups, ["company": "acme"])
            XCTAssertEqual(allGroupsReset.queuedCount, before.queuedCount)
            harness.backend.execute(.resetGroups)
            await harness.backend.settled()
            XCTAssertTrue(harness.backend.groups().isEmpty)
            await harness.close()
            let reopened = try await makeHarness(root: root)
            let restored = try await reopened.runtime.queueSnapshot()
            XCTAssertTrue(restored.identity.groups.isEmpty)
            XCTAssertTrue(restored.flagContext.personProperties.isEmpty)
            XCTAssertTrue(restored.flagContext.groupProperties.isEmpty)
            await reopened.close()
        }
    }

    func testRegisterOnceDefaultsUseScalarNumericEqualityWithoutDeepObjectComparison() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)
            harness.backend.execute(.register(["numeric": 1, "object": ["a": 1]]))
            harness.backend.execute(.registerOnce(["numeric": 2], defaultValue: 1.0))
            harness.backend.execute(.registerOnce(["object": "wrong"], defaultValue: ["a": 1]))
            await harness.backend.settled()
            let snapshot = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(snapshot.identity.superProperties["numeric"], .integer(2))
            XCTAssertEqual(snapshot.identity.superProperties["object"], .object(["a": .integer(1)]))
            await harness.close()
        }
    }

    func testEveryFacadeMethodRecordsThroughTheOwnedRuntimeInCallOrder() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)

            harness.backend.execute(.capture(event: "checkout", properties: ["amount": 42]))
            harness.backend.execute(.screen(name: "Cart", properties: nil))
            harness.backend.execute(.captureException(CheckoutFailure(), properties: nil))
            harness.backend.execute(
                .identify(distinctId: "user-1", userProperties: ["plan": "pro"])
            )
            harness.backend.execute(.alias("alias-1"))
            harness.backend.execute(.register(["tier": "gold"]))
            harness.backend.execute(.unregister("tier"))
            harness.backend.execute(
                .group(type: "company", key: "acme", properties: ["seats": 12])
            )
            harness.backend.execute(.setPersonProperties(["plan": "enterprise"]))
            harness.backend.execute(.setPersonPropertiesForFlags(["beta": true]))
            harness.backend.execute(
                .setGroupPropertiesForFlags(type: "company", properties: ["tier": "design"])
            )
            harness.backend.execute(.capture(event: "after-identity", properties: nil))
            await harness.backend.settled()

            let snapshot = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(snapshot.identity.userId, "user-1")
            XCTAssertEqual(snapshot.identity.groups["company"], "acme")
            XCTAssertNil(snapshot.identity.superProperties["tier"])
            XCTAssertEqual(snapshot.flagContext.personProperties["plan"], .string("enterprise"))
            XCTAssertEqual(snapshot.flagContext.personProperties["beta"], .bool(true))
            XCTAssertEqual(
                snapshot.flagContext.groupProperties["company"]?["tier"],
                .string("design")
            )

            _ = await harness.runtime.flush()
            let records = try await harness.transport.recordedRecords()
            XCTAssertEqual(
                records.compactMap { $0["event"] as? [String: Any] }
                    .compactMap { $0["name"] as? String },
                ["checkout", "Cart", "$exception", "after-identity"]
            )
            XCTAssertEqual(
                records.compactMap { $0["mutation"] as? [String: Any] }
                    .compactMap { ($0["change"] as? [String: Any])?["type"] as? String },
                [
                    "identify",
                    "linkAlias",
                    "associateGroup",
                    "setGroupProperties",
                    "setPersonProperties",
                ]
            )
            await harness.close()
        }
    }

    func testCapturedPropertiesAreProjectedAndReservedNamesAreStripped() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)

            harness.backend.execute(
                .capture(
                    event: "checkout",
                    properties: [
                        "amount": 42,
                        "ratio": 1.5,
                        "flagged": true,
                        "label": "cart",
                        "missing": NSNull(),
                        "items": ["a", 2],
                        "nested": ["deep": true],
                        "$elu_sdk_version": "9.9.9",
                        "unsupported": Data(),
                    ]
                )
            )
            await harness.backend.settled()
            _ = await harness.runtime.flush()

            let events = try await harness.transport.recordedEvents()
            let properties = try XCTUnwrap(events.first?["properties"] as? [String: Any])
            XCTAssertEqual(properties["amount"] as? Int, 42)
            XCTAssertEqual(properties["ratio"] as? Double, 1.5)
            XCTAssertEqual(properties["flagged"] as? Bool, true)
            XCTAssertEqual(properties["label"] as? String, "cart")
            XCTAssertTrue(properties["missing"] is NSNull)
            XCTAssertEqual((properties["items"] as? [Any])?.count, 2)
            XCTAssertEqual((properties["nested"] as? [String: Any])?["deep"] as? Bool, true)
            XCTAssertNil(properties["unsupported"])
            // The runtime stamps its own version properties; a customer value
            // never shadows them.
            XCTAssertEqual(properties["$elu_sdk_version"] as? String, EluCore.sdkVersion)
            XCTAssertEqual(harness.backend.dropCounts[.reservedProperty], 1)
            XCTAssertEqual(harness.backend.dropCounts[.invalidInput], 1)
            await harness.close()
        }
    }

    func testFlagGettersReportDefaultsUntilFlagsLoadThenReportTheSnapshot() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root, flagTransport: FacadeFlagTransport())

            XCTAssertFalse(harness.backend.flagsAreLoaded)
            XCTAssertNil(harness.backend.featureFlag("variant"))
            XCTAssertNil(harness.backend.featureFlagPayload("variant"))
            XCTAssertFalse(harness.backend.isFeatureEnabled("variant"))

            harness.backend.activate()
            await harness.backend.settled()

            XCTAssertTrue(harness.backend.flagsAreLoaded)
            XCTAssertEqual(harness.loadAnnouncements(), 1)
            XCTAssertEqual(harness.backend.featureFlag("variant") as? String, "variant-a")
            XCTAssertTrue(harness.backend.isFeatureEnabled("variant"))
            // A boolean-false flag is present but disabled; an absent key has
            // no value at all.
            XCTAssertEqual(harness.backend.featureFlag("enabled") as? Bool, false)
            XCTAssertFalse(harness.backend.isFeatureEnabled("enabled"))
            XCTAssertNil(harness.backend.featureFlag("absent"))
            XCTAssertFalse(harness.backend.isFeatureEnabled("absent"))
            // A numeric flag reports its enabled state, like the browser.
            XCTAssertEqual(harness.backend.featureFlag("zero") as? Bool, false)

            let payload = harness.backend.featureFlagPayload("variant") as? [String: Any]
            XCTAssertEqual(payload?["color"] as? String, "violet")
            XCTAssertNil(harness.backend.featureFlagPayload("enabled"))
            await harness.close()
        }
    }

    func testFullFlagPublicationIsQuietAndOriginalIntentRevokesIt() async throws {
        try await withTemporaryDirectory { root in
            let publications = FacadePublications()
            let harness = try await makeHarness(root: root, flagTransport: FacadeFlagTransport(), snapshotObserver: { publications.append($0) })
            XCTAssertNil(harness.backend.featureFlagPublication())
            harness.backend.activate(); await harness.backend.settled()
            let publication = try XCTUnwrap(harness.backend.featureFlagPublication())
            XCTAssertTrue(publication.isCurrent())
            XCTAssertEqual(publication.snapshot.source, .remote)
            XCTAssertEqual(publication.snapshot.entries.count, 3)
            XCTAssertNil(publication.snapshot.error)
            XCTAssertEqual(publications.values().count, 1)
            for _ in 0 ..< 3 { _ = harness.backend.featureFlagPublication() }
            _ = await harness.runtime.flush()
            let exposures = try await harness.transport.recordedEvents().filter { $0["name"] as? String == "$feature_flag_called" }
            XCTAssertTrue(exposures.isEmpty)
            let finish = harness.backend.beginPendingOperation(.reset)
            XCTAssertFalse(publication.isCurrent())
            XCTAssertNil(harness.backend.featureFlagPublication())
            finish?()
            XCTAssertFalse(publication.isCurrent(), "Released intent cannot revive an old publication")
            XCTAssertEqual(publication.snapshot.entries.count, 3, "Detached historical data stays immutable")
            await harness.close()
        }
    }

    func testCachePublicationCarriesOnlyActualReloadFailureAndSuccessClearsIt() async throws {
        try await withTemporaryDirectory { root in
            let transport = FacadeFlagTransport()
            let first = try await makeHarness(root: root, flagTransport: transport)
            first.backend.activate(); await first.backend.settled(); await first.close()
            await transport.setFailing(true)
            let publications = FacadePublications()
            let reopened = try await makeHarness(root: root, flagTransport: transport, snapshotObserver: { publications.append($0) })
            reopened.backend.activate(); await reopened.backend.settled()
            let observed = publications.values()
            XCTAssertEqual(observed.count, 2)
            XCTAssertEqual(observed.first?.snapshot.source, .cache)
            XCTAssertNil(observed.first?.snapshot.error, "Startup cache is not a failed reload")
            XCTAssertEqual(observed.last?.snapshot.error, .transport)
            XCTAssertEqual(observed.last?.snapshot.source, .cache)
            XCTAssertFalse(observed[0].isCurrent(), "Later publication retires queued earlier metadata")
            XCTAssertTrue(observed[1].isCurrent())
            await transport.setFailing(false); await transport.setMalformed(true)
            reopened.backend.reloadFeatureFlags(nil); await reopened.backend.settled()
            XCTAssertEqual(reopened.backend.featureFlagPublication()?.snapshot.error, .invalidResponse)
            XCTAssertEqual(reopened.backend.featureFlagPublication()?.snapshot.source, .cache)
            await transport.setMalformed(false)
            reopened.backend.reloadFeatureFlags(nil); await reopened.backend.settled()
            XCTAssertEqual(reopened.backend.featureFlagPublication()?.snapshot.source, .remote)
            XCTAssertNil(reopened.backend.featureFlagPublication()?.snapshot.error)
            XCTAssertFalse(observed[1].isCurrent())
            await reopened.close()
        }
    }

    func testSupersededPhysicalFailureCannotPublishErrorForNewIdentity() async throws {
        try await withTemporaryDirectory { root in
            let sent = expectation(description: "original send")
            let transport = SnapshotHeldFailureTransport { sent.fulfill() }
            let publications = FacadePublications()
            let harness = try await makeHarness(root: root, flagTransport: transport, snapshotObserver: { publications.append($0) })
            harness.backend.activate()
            await fulfillment(of: [sent], timeout: 5)
            let finish = harness.backend.beginPendingOperation(.reset)
            await transport.release()
            await harness.backend.settled()
            XCTAssertTrue(publications.values().isEmpty)
            XCTAssertNil(harness.backend.featureFlagPublication())
            finish?()
            XCTAssertNil(harness.backend.featureFlagPublication())
            await harness.close()
        }
    }

    func testFailedReloadWithoutCachePublishesUnavailableMetadataOnly() async throws {
        try await withTemporaryDirectory { root in
            let transport = FacadeFlagTransport()
            await transport.setFailing(true)
            let harness = try await makeHarness(root: root, flagTransport: transport)
            harness.backend.activate(); await harness.backend.settled()
            let transportFailure = try XCTUnwrap(harness.backend.featureFlagPublication())
            XCTAssertTrue(transportFailure.isCurrent())
            XCTAssertEqual(transportFailure.snapshot.source, .unavailable)
            XCTAssertEqual(transportFailure.snapshot.error, .transport)
            XCTAssertTrue(transportFailure.snapshot.entries.isEmpty)
            XCTAssertNil(transportFailure.snapshot.requestId)
            await transport.setFailing(false); await transport.setMalformed(true)
            harness.backend.reloadFeatureFlags(nil); await harness.backend.settled()
            XCTAssertEqual(harness.backend.featureFlagPublication()?.snapshot.error, .invalidResponse)
            XCTAssertFalse(transportFailure.isCurrent())
            await harness.close()
        }
    }

    func testFlagReadOptionsSuppressExposureWithoutConsumingItsDurableEntry() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root, flagTransport: FacadeFlagTransport())
            harness.backend.activate()
            await harness.backend.settled()
            let quiet = EluFeatureFlagOptions(sendEvent: false, fresh: true)
            XCTAssertEqual(harness.backend.featureFlag("variant", options: quiet) as? String, "variant-a")
            XCTAssertEqual(harness.backend.featureFlagResult("variant", options: quiet)?.variant, "variant-a")
            XCTAssertEqual(harness.backend.isFeatureEnabled("enabled", options: quiet), false)
            XCTAssertNil(harness.backend.isFeatureEnabled("absent", options: quiet))
            await harness.backend.settled()
            _ = await harness.runtime.flush()
            var exposures = try await harness.transport.recordedEvents().filter { $0["name"] as? String == "$feature_flag_called" }
            XCTAssertTrue(exposures.isEmpty)

            // A quiet read cannot consume the first later requested exposure.
            _ = harness.backend.featureFlagResult("variant", options: .init(fresh: true))
            _ = harness.backend.featureFlag("variant")
            await harness.backend.settled()
            _ = await harness.runtime.flush()
            exposures = try await harness.transport.recordedEvents().filter { $0["name"] as? String == "$feature_flag_called" }
            XCTAssertEqual(exposures.count, 1)
            XCTAssertEqual((exposures.first?["properties"] as? [String: Any])?["$feature_flag"] as? String, "variant")
            await harness.close()
        }
    }

    func testFreshFlagReadRejectsRestoredCacheUntilCurrentRemoteResponse() async throws {
        try await withTemporaryDirectory { root in
            let transport = FacadeFlagTransport()
            let first = try await makeHarness(root: root, flagTransport: transport)
            first.backend.activate()
            await first.backend.settled()
            await first.close()
            await transport.setFailing(true)
            let reopened = try await makeHarness(root: root, flagTransport: transport)
            reopened.backend.activate()
            await reopened.backend.settled()
            XCTAssertEqual(reopened.backend.featureFlag("variant", options: .init(sendEvent: false)) as? String, "variant-a")
            XCTAssertNil(reopened.backend.featureFlag("variant", options: .init(fresh: true)))
            XCTAssertNil(reopened.backend.featureFlagResult("variant", options: .init(fresh: true)))
            XCTAssertNil(reopened.backend.isFeatureEnabled("enabled", options: .init(fresh: true)))
            await reopened.backend.settled()
            _ = await reopened.runtime.flush()
            let rejected = try await reopened.transport.recordedEvents().filter { $0["name"] as? String == "$feature_flag_called" }
            XCTAssertTrue(rejected.isEmpty, "Rejected fresh reads must not consume or emit exposure")

            await transport.setFailing(false)
            let loaded = expectation(description: "remote flags")
            reopened.backend.reloadFeatureFlags { loaded.fulfill() }
            await reopened.backend.settled()
            await fulfillment(of: [loaded], timeout: 5)
            XCTAssertEqual(reopened.backend.featureFlag("variant", options: .init(fresh: true)) as? String, "variant-a")
            XCTAssertEqual(reopened.backend.isFeatureEnabled("enabled", options: .init(sendEvent: false, fresh: true)), false)
            await reopened.backend.settled()
            _ = await reopened.runtime.flush()
            let remote = try await reopened.transport.recordedEvents().filter { $0["name"] as? String == "$feature_flag_called" }
            XCTAssertEqual(remote.count, 1)

            let finish = reopened.backend.beginPendingOperation(.reset)
            XCTAssertNil(reopened.backend.featureFlag("variant", options: .init(sendEvent: false, fresh: true)))
            XCTAssertNil(reopened.backend.featureFlagResult("variant", options: .init(sendEvent: false)))
            finish?()
            await reopened.close()
        }
    }

    func testExposureIsReportedOncePerVisitorKeyAndTypedValueAcrossIdentifyAndReload() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root, flagTransport: FacadeFlagTransport())
            harness.backend.activate()
            await harness.backend.settled()

            _ = harness.backend.featureFlag("variant")
            _ = harness.backend.featureFlag("variant")
            _ = harness.backend.isFeatureEnabled("variant")
            // A payload read never reports an exposure.
            _ = harness.backend.featureFlagPayload("variant")
            // A key with no value reports its own missing-flag exposure, once.
            _ = harness.backend.featureFlag("absent")
            _ = harness.backend.featureFlag("absent")
            await harness.backend.settled()
            _ = await harness.runtime.flush()

            var exposures = try await harness.transport.recordedEvents()
                .filter { $0["name"] as? String == "$feature_flag_called" }
            XCTAssertEqual(exposures.count, 2)
            let reported = try XCTUnwrap(exposures.first?["properties"] as? [String: Any])
            XCTAssertEqual(reported["$feature_flag"] as? String, "variant")
            XCTAssertEqual(reported["$feature_flag_response"] as? String, "variant-a")
            XCTAssertFalse((reported["$feature_flag_request_id"] as? String ?? "").isEmpty)
            XCTAssertEqual(reported["$feature_flag_evaluated_at"] as? Int64, 1_785_801_661_000)
            XCTAssertEqual(reported["$used_bootstrap_value"] as? Bool, false)
            XCTAssertTrue(reported["$feature_flag_bootstrapped_response"] is NSNull)
            XCTAssertTrue(reported["$feature_flag_bootstrapped_payload"] is NSNull)
            XCTAssertEqual(
                (reported["$feature_flag_payload"] as? [String: Any])?["color"] as? String,
                "violet"
            )
            let missing = try XCTUnwrap(exposures.last?["properties"] as? [String: Any])
            XCTAssertEqual(missing["$feature_flag"] as? String, "absent")
            XCTAssertEqual(missing["$feature_flag_error"] as? String, "flag_missing")
            XCTAssertNil(missing["$feature_flag_response"])

            // Identifying this visitor preserves the durable ledger.
            harness.backend.execute(.identify(distinctId: "user-1", userProperties: nil))
            await harness.backend.settled()
            _ = harness.backend.featureFlag("variant")
            await harness.backend.settled()
            _ = await harness.runtime.flush()

            exposures = try await harness.transport.recordedEvents()
                .filter { $0["name"] as? String == "$feature_flag_called" }
            XCTAssertEqual(exposures.count, 2)
            let reloaded = expectation(description: "reload")
            harness.backend.reloadFeatureFlags { reloaded.fulfill() }
            await harness.backend.settled(); await fulfillment(of: [reloaded], timeout: 5)
            _ = harness.backend.featureFlag("variant")
            await harness.backend.settled(); _ = await harness.runtime.flush()
            exposures = try await harness.transport.recordedEvents().filter { $0["name"] as? String == "$feature_flag_called" }
            XCTAssertEqual(exposures.count, 2)
            harness.backend.execute(.reset)
            await harness.backend.settled()
            _ = harness.backend.featureFlag("variant")
            await harness.backend.settled(); _ = await harness.runtime.flush()
            exposures = try await harness.transport.recordedEvents().filter { $0["name"] as? String == "$feature_flag_called" }
            XCTAssertEqual(exposures.count, 3)
            await harness.close()
        }
    }

    func testExposureFloorsExactEvaluationMillisecondsFromRemoteAndReopenedCache() async throws {
        try await withTemporaryDirectory { root in
            let transport = FacadeFlagTransport(evaluatedAt: "2026-08-04T00:01:01.123999999Z")
            let first = try await makeHarness(root: root, flagTransport: transport)
            first.backend.activate()
            await first.backend.settled()
            XCTAssertEqual(first.backend.featureFlag("variant") as? String, "variant-a")
            await first.backend.settled()
            _ = await first.runtime.flush()
            let remoteEvents = try await first.transport.recordedEvents()
                .filter { $0["name"] as? String == "$feature_flag_called" }
            XCTAssertEqual(remoteEvents.count, 1)
            let remote = try XCTUnwrap(remoteEvents.first?["properties"] as? [String: Any])
            XCTAssertEqual(remote["$feature_flag_evaluated_at"] as? Int64, 1_785_801_661_123)
            XCTAssertEqual(remote["$used_bootstrap_value"] as? Bool, false)
            await first.close()

            await transport.setFailing(true)
            let reopened = try await makeHarness(root: root, flagTransport: transport)
            reopened.backend.activate()
            await reopened.backend.settled()
            XCTAssertEqual(reopened.backend.featureFlag("variant") as? String, "variant-a")
            XCTAssertEqual(reopened.backend.featureFlag("enabled") as? Bool, false)
            await reopened.backend.settled()
            _ = await reopened.runtime.flush()
            let cachedEvents = try await reopened.transport.recordedEvents()
                .filter { $0["name"] as? String == "$feature_flag_called" }
            XCTAssertEqual(cachedEvents.count, 1, "The accepted variant exposure stays deduplicated")
            let cached = try XCTUnwrap(cachedEvents.first?["properties"] as? [String: Any])
            XCTAssertEqual(cached["$feature_flag"] as? String, "enabled")
            XCTAssertEqual(cached["$feature_flag_evaluated_at"] as? Int64, 1_785_801_661_123)
            XCTAssertEqual(cached["$used_bootstrap_value"] as? Bool, true)
            await reopened.close()
        }
    }

    func testReopenedRemoteCacheKeepsVisitorLedgerAndReportsExplicitCacheProvenance() async throws {
        try await withTemporaryDirectory { root in
            let first = try await makeHarness(root: root, flagTransport: FacadeFlagTransport())
            first.backend.activate(); await first.backend.settled()
            _ = first.backend.featureFlag("variant")
            await first.backend.settled(); _ = await first.runtime.flush()
            await first.close()
            let transport = FacadeFlagTransport(); await transport.setFailing(true)
            let reopened = try await makeHarness(root: root, flagTransport: transport)
            reopened.backend.activate(); await reopened.backend.settled()
            XCTAssertEqual(reopened.backend.featureFlag("variant") as? String, "variant-a")
            _ = reopened.backend.featureFlag("zero")
            await reopened.backend.settled(); _ = await reopened.runtime.flush()
            var exposures = try await reopened.transport.recordedEvents().filter { $0["name"] as? String == "$feature_flag_called" }
            XCTAssertEqual(exposures.count, 1, "Previously accepted variant is not reported after restart")
            let cached = try XCTUnwrap(exposures.first?["properties"] as? [String: Any])
            XCTAssertEqual(cached["$feature_flag"] as? String, "zero")
            XCTAssertEqual(cached["$used_bootstrap_value"] as? Bool, true)
            XCTAssertEqual(cached["$feature_flag_evaluated_at"] as? Int64, 1_785_801_661_000)
            XCTAssertFalse((cached["$feature_flag_request_id"] as? String ?? "").isEmpty)
            XCTAssertTrue(cached["$feature_flag_bootstrapped_response"] is NSNull)
            await transport.setFailing(false)
            let reloaded = expectation(description: "remote response")
            reopened.backend.reloadFeatureFlags { reloaded.fulfill() }
            await reopened.backend.settled(); await fulfillment(of: [reloaded], timeout: 5)
            _ = reopened.backend.featureFlag("enabled")
            await reopened.backend.settled(); _ = await reopened.runtime.flush()
            exposures = try await reopened.transport.recordedEvents().filter { $0["name"] as? String == "$feature_flag_called" }
            XCTAssertEqual(exposures.count, 2)
            let remote = try XCTUnwrap(exposures.last?["properties"] as? [String: Any])
            XCTAssertEqual(remote["$feature_flag_response"] as? Bool, false)
            XCTAssertEqual(remote["$used_bootstrap_value"] as? Bool, false)
            await reopened.close()
        }
    }

    func testResetEndsTheIdentityAndClearsLoadedFlagsImmediately() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root, flagTransport: FacadeFlagTransport())
            harness.backend.activate()
            harness.backend.execute(.identify(distinctId: "user-1", userProperties: nil))
            harness.backend.execute(.register(["tier": "gold"]))
            await harness.backend.settled()
            XCTAssertEqual(harness.backend.distinctId(), "user-1")
            XCTAssertTrue(harness.backend.flagsAreLoaded)

            harness.backend.execute(.reset)
            // The flags belonged to the identity that is ending, so a read
            // before the queued reset runs must not report them.
            XCTAssertFalse(harness.backend.flagsAreLoaded)
            XCTAssertNil(harness.backend.featureFlag("variant"))

            await harness.backend.settled()
            let snapshot = try await harness.runtime.queueSnapshot()
            XCTAssertNil(snapshot.identity.userId)
            XCTAssertTrue(snapshot.identity.groups.isEmpty)
            XCTAssertTrue(snapshot.identity.superProperties.isEmpty)
            XCTAssertEqual(harness.backend.distinctId(), snapshot.identity.anonymousId)
            await harness.close()
        }
    }

    func testIdentifyIsVisibleToTheSynchronousGetterBeforeItSettles() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)
            let before = harness.backend.distinctId()

            harness.backend.execute(.identify(distinctId: "user-1", userProperties: nil))
            XCTAssertEqual(harness.backend.distinctId(), "user-1")
            XCTAssertNotEqual(before, "user-1")

            await harness.backend.settled()
            XCTAssertEqual(harness.backend.distinctId(), "user-1")
            await harness.close()
        }
    }

    func testDisabledConfigurationRecordsNothingAndSendsNothing() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(
                root: root,
                document: fixture("config-disabled.json")
            )

            harness.backend.execute(.capture(event: "checkout", properties: nil))
            harness.backend.execute(.identify(distinctId: "user-1", userProperties: nil))
            harness.backend.execute(.register(["tier": "gold"]))
            harness.backend.activate()
            await harness.backend.settled()

            let snapshot = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(snapshot.queuedCount, 0)
            // Local identity survives without capture authority; no mutation is backfilled.
            XCTAssertEqual(snapshot.identity.userId, "user-1")
            let flushed = await harness.runtime.flush()
            XCTAssertEqual(flushed, .unavailable)
            let records = try await harness.transport.recordedRecords()
            XCTAssertTrue(records.isEmpty)
            XCTAssertNil(harness.backend.featureFlag("variant"))
            XCTAssertFalse(harness.backend.isFeatureEnabled("variant"))
            await harness.close()
        }
    }

    func testShutDownStopsEveryLaterCallAndStillDeliversAReloadCompletion() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)
            harness.backend.activate()
            await harness.backend.settled()

            harness.backend.shutDown()
            harness.backend.execute(.capture(event: "after-shutdown", properties: nil))

            let completed = expectation(description: "reload completion")
            harness.backend.reloadFeatureFlags {
                XCTAssertTrue(Thread.isMainThread)
                completed.fulfill()
            }
            await harness.backend.settled()
            await fulfillment(of: [completed], timeout: 5)

            XCTAssertNil(harness.backend.featureFlag("variant"))
            let records = try await harness.transport.recordedRecords()
            XCTAssertFalse(
                records.compactMap { ($0["event"] as? [String: Any])?["name"] as? String }
                    .contains("after-shutdown")
            )
        }
    }

    /// The configuration route still serves the document the provider-backed
    /// path decodes, which this runtime does not accept. Until the route
    /// serves a document it validates, the runtime holds no capture authority
    /// and records nothing, which is the fail-closed end of the selection.
    func testTheCurrentlyServedConfigurationDocumentGrantsNoAuthority() async throws {
        try await withTemporaryDirectory { root in
            let served = Data(
                """
                {"v":1,"enabled":true,"publicToken":"t","host":"https://ingest.example.test"}
                """.utf8
            )
            let harness = try await makeHarness(root: root, document: served)

            let phase = await harness.runtime.currentPhase
            XCTAssertEqual(phase, .blocked(.malformed))

            harness.backend.execute(.capture(event: "checkout", properties: nil))
            harness.backend.execute(.identify(distinctId: "user-1", userProperties: nil))
            await harness.backend.settled()

            let snapshot = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(snapshot.queuedCount, 0)
            // Local identity survives without capture authority; no mutation is backfilled.
            XCTAssertEqual(snapshot.identity.userId, "user-1")
            let records = try await harness.transport.recordedRecords()
            XCTAssertTrue(records.isEmpty)
            await harness.close()
        }
    }

    func testReloadCompletionStillRunsWhenTheStoreCannotBeOpened() async throws {
        let context = EluRuntimeBackendContext(
            siteKey: Self.siteKey,
            config: try TestConfigFactory.make(),
            configDocument: fixture("config-enabled.json"),
            isNewUser: true,
            flagsDidLoad: {}
        )
        let backend = EluStandaloneFacadeRuntime(
            context: context,
            open: { throw FacadeTransportError.malformedRequest }
        )

        let completed = expectation(description: "reload completion")
        backend.reloadFeatureFlags {
            XCTAssertTrue(Thread.isMainThread)
            completed.fulfill()
        }
        await backend.settled()
        await fulfillment(of: [completed], timeout: 5)

        // Nothing else the facade can be asked for reports a value it does
        // not have.
        XCTAssertNil(backend.distinctId())
        XCTAssertNil(backend.featureFlag("variant"))
        XCTAssertFalse(backend.isFeatureEnabled("variant"))
    }

    func testAliasWithoutAnIdentityIsDiscardedRatherThanRecorded() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)

            harness.backend.execute(.alias("alias-1"))
            await harness.backend.settled()

            let snapshot = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(snapshot.queuedCount, 0)
            XCTAssertEqual(harness.backend.dropCounts[.unauthorized], 1)
            await harness.close()
        }
    }

    // MARK: - Harness

    func testExplicitCaptureTimeIsPersistedAndDeliveredAfterReopen() async throws {
        try await withTemporaryDirectory { root in
            let timestamp = baseDate.addingTimeInterval(1.125)
            let harness = try await makeHarness(root: root)
            harness.backend.execute(.capture(event: "explicit-time", properties: ["amount": 42], timestamp: timestamp))
            await harness.backend.settled()
            let saved = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(saved.queuedCount, 1)
            XCTAssertEqual(saved.identity.updatedAt, timestamp)
            XCTAssertEqual(saved.identity.session?.lastActivityAt, timestamp)
            let beforeSend = try await harness.transport.recordedEvents()
            XCTAssertTrue(beforeSend.isEmpty)
            await harness.close()

            // Configuration can automatically drain a reopened backlog. Hold
            // its original transport until the durable restoration is observed.
            let transport = FacadeBatchTransport(held: true)
            let reopened = try await makeHarness(root: root, batchTransport: transport)
            do {
                let restored = try await reopened.runtime.queueSnapshot()
                XCTAssertEqual(restored.queuedCount, 1)
                XCTAssertEqual(restored.identity, saved.identity)
                await transport.release()
                _ = await reopened.runtime.flush() // May lawfully coalesce with the automatic pass.
                let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
                var drained = false
                while DispatchTime.now().uptimeNanoseconds < deadline {
                    if try await reopened.runtime.queueSnapshot().queuedCount == 0 { drained = true; break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertTrue(drained, "Join actual accepted-prefix retirement before examining delivery")
                let events = try await reopened.transport.recordedEvents()
                XCTAssertEqual(events.count, 1)
                let event = try XCTUnwrap(events.first)
                XCTAssertEqual(event["name"] as? String, "explicit-time")
                XCTAssertEqual(event["occurredAt"] as? String, EluRFC3339.string(from: timestamp))
                XCTAssertEqual((event["properties"] as? [String: Any])?["amount"] as? Int, 42)
                await reopened.close()
            } catch {
                await transport.release()
                await reopened.close()
                throw error
            }
        }
    }

    func testExplicitCaptureTimeRejectsInvalidAndOlderActivityWithoutReordering() async throws {
        try await withTemporaryDirectory { root in
            let harness = try await makeHarness(root: root)
            for timestamp in [Date(timeIntervalSince1970: .nan),
                              Date(timeIntervalSince1970: .infinity), baseDate.addingTimeInterval(-1)] {
                harness.backend.execute(.capture(event: "invalid-time", properties: nil, timestamp: timestamp))
            }
            await harness.backend.settled()
            let before = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(before.queuedCount, 0)
            XCTAssertNil(before.identity.session)

            harness.backend.execute(.capture(event: "ordinary-time", properties: nil))
            harness.backend.execute(.capture(event: "later-time", properties: nil, timestamp: baseDate.addingTimeInterval(2)))
            harness.backend.execute(.capture(event: "out-of-order", properties: nil, timestamp: baseDate.addingTimeInterval(1)))
            await harness.backend.settled()
            let saved = try await harness.runtime.queueSnapshot()
            XCTAssertEqual(saved.queuedCount, 2)
            XCTAssertEqual(saved.identity.updatedAt, baseDate.addingTimeInterval(2))
            _ = await harness.runtime.flush()
            let events = try await harness.transport.recordedEvents()
            XCTAssertEqual(events.compactMap { $0["name"] as? String }, ["ordinary-time", "later-time"])
            XCTAssertEqual(events.compactMap { $0["occurredAt"] as? String },
                           [EluRFC3339.string(from: baseDate), EluRFC3339.string(from: baseDate.addingTimeInterval(2))])
            await harness.close()
        }
    }

    private struct Harness {
        let runtime: EluStandaloneRuntime
        let backend: EluStandaloneFacadeRuntime
        let transport: FacadeBatchTransport
        let announcements: FacadeCounter

        func loadAnnouncements() -> Int { announcements.value() }

        func close() async {
            backend.shutDown()
            await backend.settled()
            await runtime.close()
        }
    }

    private func makeHarness(
        root: URL,
        document: Data? = nil,
        flagTransport: (any EluV1FlagTransport)? = nil,
        initialConsent: EluConsentOperation? = nil,
        personProfiles: EluPersonProfilesMode = .identifiedOnly,
        snapshotObserver: @escaping @Sendable (EluFeatureFlagPublication) -> Void = { _ in },
        batchTransport: FacadeBatchTransport? = nil
    ) async throws -> Harness {
        let transport = batchTransport ?? FacadeBatchTransport()
        let clock = FacadeClock(wall: baseDate)
        let identifiers = FacadeCounter()
        let runtime = try await EluStandaloneRuntime.make(
            rootDirectoryURL: root,
            siteKey: Self.siteKey,
            transport: transport,
            backgroundHandoff: EluStandaloneBackgroundHandoff(
                start: { operation in
                    await operation()
                    return true
                },
                cancel: {}
            ),
            clock: { clock.wall() },
            continuousClock: { clock.continuous() },
            continuousBudgetConverter: { $0 },
            time: clock.source,
            randomUnit: { 0 },
            timeZoneIdentifier: { "America/New_York" },
            replaySampleDraw: { 0.1 },
            anonymousIdGenerator: { "anon_facade_\(identifiers.next())" },
            streamIdGenerator: { "stream_facade" },
            sessionIdGenerator: { "session_facade_\(identifiers.next())" },
            personProfiles: personProfiles
        )
        let announcements = FacadeCounter()
        let context = EluRuntimeBackendContext(
            siteKey: Self.siteKey,
            config: try TestConfigFactory.make(),
            configDocument: document ?? fixture("config-enabled.json"),
            isNewUser: true,
            flagsDidLoad: { _ = announcements.next() },
            personProfiles: personProfiles,
            initialConsent: initialConsent,
            flagSnapshotDidLoad: snapshotObserver
        )
        let backend = EluStandaloneFacadeRuntime(
            context: context,
            open: { runtime },
            flagTransport: flagTransport
        )
        // The runtime opens on the same ordered chain every call joins, so a
        // settled chain means the configuration decision has been applied.
        await backend.settled()
        return Harness(
            runtime: runtime,
            backend: backend,
            transport: transport,
            announcements: announcements
        )
    }

    private func fixture(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Conformance/V1/Fixtures", isDirectory: true)
            .appendingPathComponent(name)
        return try! Data(contentsOf: url)
    }

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "elu-standalone-facade-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

private actor BootstrapConfigTransport: EluV2ConfigTransport {
    private let body: Data
    private(set) var requests: [EluV2ConfigRequest] = []
    init(body: Data) { self.body = body }
    func fetch(_ request: EluV2ConfigRequest) async throws -> Data {
        requests.append(request)
        return body
    }
}

/// Accepts every batch and keeps the records it was handed.
actor FacadeBatchTransport: EluV1BatchHTTPTransport {
    private var requests: [EluV1BatchHTTPRequest] = []
    private var held: Bool
    private var waiting: CheckedContinuation<Void, Never>?
    init(held: Bool = false) { self.held = held }
    func release() { held = false; let original = waiting; waiting = nil; original?.resume() }

    func send(_ request: EluV1BatchHTTPRequest) async throws -> EluV1BatchHTTPResponse {
        if held { await withCheckedContinuation { waiting = $0 } }
        requests.append(request)
        guard let root = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let requestId = root["requestId"] as? String,
              let streamId = root["streamId"] as? String,
              let records = root["records"] as? [[String: Any]]
        else {
            throw FacadeTransportError.malformedRequest
        }
        var outcomes: [[String: Any]] = []
        var last: Int64?
        for record in records {
            guard let kind = record["kind"] as? String,
                  let payload = record[kind] as? [String: Any],
                  let sequence = (payload["sequence"] as? NSNumber)?.int64Value,
                  let recordId = payload[kind == "event" ? "eventId" : "mutationId"] as? String
            else {
                throw FacadeTransportError.malformedRequest
            }
            last = sequence
            outcomes.append([
                "sequence": sequence,
                "recordId": recordId,
                "kind": kind,
                "result": "accepted",
            ])
        }
        guard let resolved = last else { throw FacadeTransportError.malformedRequest }
        let acknowledgement: [String: Any] = [
            "schemaVersion": 1,
            "requestId": requestId,
            "streamId": streamId,
            "resolvedThroughSequence": resolved,
            "retryFromSequence": NSNull(),
            "outcomes": outcomes,
        ]
        return EluV1BatchHTTPResponse(
            status: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: acknowledgement, options: [.sortedKeys])
        )
    }

    func recordedRecords() throws -> [[String: Any]] {
        try requests.flatMap { request -> [[String: Any]] in
            let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            return (body?["records"] as? [[String: Any]]) ?? []
        }
    }

    func recordedEvents() throws -> [[String: Any]] {
        try recordedRecords().compactMap { $0["event"] as? [String: Any] }
    }
}

/// Answers every flag request from the identity witness it was sent.
actor FacadeFlagTransport: EluV1FlagTransport {
    private var calls = 0
    private var failing = false
    private var malformed = false
    private let evaluatedAt: String

    init(evaluatedAt: String = "2026-08-04T00:01:01.000Z") {
        self.evaluatedAt = evaluatedAt
    }

    func setFailing(_ value: Bool) { failing = value }
    func setMalformed(_ value: Bool) { malformed = value }

    func send(endpoint: URL, requestBody: Data) async throws -> Data {
        calls += 1
        if failing { throw URLError(.notConnectedToInternet) }
        if malformed { return Data("not valid JSON".utf8) }
        guard let request = try JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
              let identity = request["identity"] as? [String: Any]
        else {
            throw FacadeFlagTransportError.malformedRequest
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "requestId": request["requestId"] ?? "",
                "contextRevision": request["contextRevision"] ?? 0,
                "identityRevision": identity["revision"] ?? 0,
                "flagsRevision": "flags-facade-1",
                "evaluatedAt": evaluatedAt,
                "expiresAt": "2026-08-04T00:04:00.000Z",
                "flags": [
                    "variant": "variant-a",
                    "enabled": false,
                    "zero": 0,
                ],
                "payloads": ["variant": ["color": "violet"]],
            ],
            options: [.sortedKeys]
        )
    }

    func callCount() -> Int { calls }
}

enum FacadeFlagTransportError: Error {
    case malformedRequest
}

enum FacadeTransportError: Error {
    case malformedRequest
}

/// A wall and continuous clock a test advances explicitly.
final class FacadeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wallValue: Date
    private var continuousValue: UInt64 = 1_000_000_000

    init(wall: Date) {
        wallValue = wall
    }

    func wall() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return wallValue
    }

    func continuous() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return continuousValue
    }

    var source: EluV1BatchTimeSource {
        EluV1BatchTimeSource(
            wallNow: { [self] in self.wall() },
            monotonicNow: { [self] in self.continuous() },
            sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) }
        )
    }
}

/// A monotonic counter for unique test identifiers.
final class FacadeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class FacadePublications: @unchecked Sendable {
    private let lock = NSLock()
    private var retained: [EluFeatureFlagPublication] = []
    func append(_ value: EluFeatureFlagPublication) { lock.lock(); retained.append(value); lock.unlock() }
    func values() -> [EluFeatureFlagPublication] { lock.lock(); defer { lock.unlock() }; return retained }
}

private actor SnapshotHeldFailureTransport: EluV1FlagTransport {
    private let sent: @Sendable () -> Void
    private var held: CheckedContinuation<Void, Never>?
    private var released = false
    init(sent: @escaping @Sendable () -> Void) { self.sent = sent }
    func send(endpoint: URL, requestBody: Data) async throws -> Data {
        if !released {
            await withCheckedContinuation { continuation in
                held = continuation
                sent()
            }
        }
        throw URLError(.notConnectedToInternet)
    }
    func release() { released = true; let value = held; held = nil; value?.resume() }
}
