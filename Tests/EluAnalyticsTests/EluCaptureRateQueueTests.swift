import Foundation
import XCTest
@testable import EluAnalytics

final class EluCaptureRateQueueTests: XCTestCase {
    private let key = "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa"
    private let one = EluRateLimitingOptions(eventsPerSecond: 1, eventsBurstLimit: 1)

    private func reopen(_ h: NativeSessionHarness, options: EluRateLimitingOptions,
                        persistence: EluPersistenceMode = .persistent) async throws {
        let clock = h.base.testClock
        h.base.queue = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: h.base.root,
            exactConstructorSiteKey: key, endpointPolicy: h.base.endpointPolicy, persistence: persistence,
            rateLimiting: options, limits: h.base.limits, clock: { clock.read() }, continuousClock: { clock.ticks() },
            continuousBudgetConverter: { clock.convert($0) }, configurationGate: h.base.gate, faultInjector: h.base.fault)
    }
    private func make(options: EluRateLimitingOptions? = nil, limits: EluRuntimeQueueLimits? = nil,
                      fault: DeliveryFault? = nil) async throws -> NativeSessionHarness {
        let h = NativeSessionHarness(try await DeliveryHarness.make(limits: limits, fault: fault))
        await h.queue.close(); try await reopen(h, options: options ?? one); try await h.publish()
        return h
    }
    private func bucket(_ h: NativeSessionHarness) throws -> EluCaptureRateBucket {
        try XCTUnwrap(EluCaptureRateBucket.decode(h.bytes("SELECT metadata FROM capture_rate_limit")))
    }
    private func command(_ h: NativeSessionHarness, name: String = "event") throws -> EluV1CaptureCommand {
        .init(kind: .capture, name: name, occurredAt: h.base.now, properties: [:], versions: try .init(
            runtime: .init(name: "elu-ios", version: "0.2.0"), facade: .init(name: "Elu", version: "1")))
    }
    private func accepted(_ result: EluV1CaptureResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .accepted = result else { return XCTFail("Expected accepted: \(result)", file: file, line: line) }
    }
    private func rejected(_ result: EluV1CaptureResult, _ expected: EluV1CaptureRejection,
                          file: StaticString = #filePath, line: UInt = #line) {
        guard case let .rejected(reason, _) = result else { return XCTFail("Expected rejection", file: file, line: line) }
        XCTAssertEqual(reason, expected, file: file, line: line)
    }
    private func events(_ h: NativeSessionHarness) async throws -> [EluQueuedEvent] {
        try await h.queue.peek(maximumCount: 100, maximumBytes: 1_000_000).compactMap {
            if case let .event(value) = $0 { return value }; return nil
        }
    }

    func testPublicOptionsReachContextAndProductionRuntimeUsesDefaultSelectedLimiter() async throws {
        let box = RateOptionsBox()
        let core = EluCore(backendFactory: .init(make: { _, context in box.save(context.rateLimiting); return nil }))
        var options = EluSetupOptions(); options.rateLimiting = .init(eventsPerSecond: 2, eventsBurstLimit: 3)
        core.setup(siteKey: key, options: options)
        _ = core.isOptedOut()
        XCTAssertEqual(box.read(), options.rateLimiting)
        XCTAssertEqual(EluSetupOptions().rateLimiting, .init())
        XCTAssertEqual(EluSetupOptions(configHost: URL(string: "https://elu.dev")!, apiHost: nil).rateLimiting, .init())

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("elu-rate-runtime-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_785_888_090)
        let runtime = try await EluStandaloneRuntime.make(rootDirectoryURL: root, siteKey: key,
            transport: RateNoNetwork(), backgroundHandoff: EluStandaloneBackgroundHandoff(
                start: { operation in await operation(); return true }, cancel: {}),
            clock: { now }, continuousClock: { 1 },
            continuousBudgetConverter: { $0 }, timeZoneIdentifier: { "America/Los_Angeles" }, rateLimiting: one)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        _ = try await runtime.applyConfiguration(Data(contentsOf: source.appendingPathComponent("Conformance/V2/fixtures/config-enabled.json")))
        accepted(await runtime.capture("first"))
        rejected(await runtime.capture("second"), .rateLimited)
        let snapshot = try await runtime.queueSnapshot(); XCTAssertEqual(snapshot.queuedCount, 2, "Original event plus owned warning")
        await runtime.close()
    }

    func testBurstWarningUsesNormalAuthoritativeEventAndCustomerCannotRequestBypass() async throws {
        let h = try await make(); defer { h.base.remove() }
        let initial = try await h.queue.snapshot()
        XCTAssertNil(initial.identity.session); XCTAssertEqual(initial.nextSequence, 0)
        XCTAssertEqual(try bucket(h).tokens, 1, "Constructor does not consume or create a session")
        accepted(try await h.queue.capture(command(h)))
        for _ in 0..<3 { rejected(try await h.queue.capture(command(h)), .rateLimited) }
        rejected(try await h.queue.capture(command(h, name: EluCaptureRateLimiter.warningEvent)), .rateLimited)
        let rows = try await events(h)
        XCTAssertEqual(rows.map(\.name), ["event", EluCaptureRateLimiter.warningEvent])
        XCTAssertEqual(rows.last?.properties[EluCaptureRateLimiter.warningProperty],
            .string("Analytics SDK client rate limited. Config is set to 1 events per second and 1 events burst limit."))
        XCTAssertNotNil(rows.last?.properties["$device_id"])
        XCTAssertEqual(rows.last?.properties["$is_identified"], .bool(false))
        h.base.testClock.advance(1)
        accepted(try await h.queue.capture(command(h)))
        rejected(try await h.queue.capture(command(h)), .rateLimited)
        let next = try await events(h); XCTAssertEqual(next.filter { $0.name == EluCaptureRateLimiter.warningEvent }.count, 2)
        await h.queue.close()
    }

    func testInvalidEventAndQueueQuotaDoNotRefundDurableConsumption() async throws {
        let h = try await make(options: .init(eventsPerSecond: 1, eventsBurstLimit: 3), limits: .init(maximumCount: 1))
        defer { h.base.remove() }
        rejected(try await h.queue.capture(command(h, name: "")), .invalidEvent)
        XCTAssertEqual(try bucket(h).tokens, 2)
        accepted(try await h.queue.capture(command(h)))
        rejected(try await h.queue.capture(command(h)), .queueLimit)
        XCTAssertEqual(try bucket(h).tokens, 0)
        await h.queue.close(); try await reopen(h, options: .init(eventsPerSecond: 1, eventsBurstLimit: 3)); try await h.publish()
        rejected(try await h.queue.capture(command(h)), .rateLimited)
        let rows = try await events(h); XCTAssertEqual(rows.count, 1, "Reopened empty constructor does not emit a new warning")
        await h.queue.close()
    }

    func testEventRollbackDoesNotRefundButDoesNotConsumeFirstCaptureHistory() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault); defer { h.base.remove() }
        fault.action = { if $0 == .beforeCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        rejected(try await h.queue.capture(command(h)), .storageProvenNotCommitted)
        XCTAssertEqual(try bucket(h).tokens, 0)
        XCTAssertEqual(try EluCaptureSessionHistory.decode(h.bytes("SELECT metadata FROM capture_session_history")), .unseen)
        let before = try await h.queue.snapshot(); XCTAssertNil(before.identity.session); XCTAssertEqual(before.queuedCount, 0)
        fault.action = nil; await h.queue.close(); try await reopen(h, options: one); try await h.publish()
        rejected(try await h.queue.capture(command(h)), .rateLimited)
        let after = try await h.queue.snapshot(); XCTAssertNil(after.identity.session); XCTAssertEqual(after.queuedCount, 0)
        await h.queue.close()
    }

    func testResetIdentifyAndConsentKeepSameSiteBucketWhileDeniedCallsDoNotDebit() async throws {
        let h = try await make(options: .init(eventsPerSecond: 1, eventsBurstLimit: 3)); defer { h.base.remove() }
        accepted(try await h.queue.capture(command(h)))
        let consumed = try bucket(h)
        _ = try await h.queue.applyOwnedMutation(.identify(userId: "person", set: [:], setOnce: [:]),
            versions: command(h).versions, expectedGeneration: h.queue.snapshot().generation)
        XCTAssertEqual(try bucket(h), consumed)
        for rotate in [false, true] {
            _ = try await h.queue.reset(expectedGeneration: h.queue.snapshot().generation, resetDeviceId: rotate)
            XCTAssertEqual(try bucket(h), consumed)
        }
        _ = try await h.queue.setOptedOut(true, expectedGeneration: h.queue.snapshot().generation)
        let denied = try bucket(h)
        _ = try await h.queue.capture(command(h))
        XCTAssertEqual(try bucket(h), denied)
        _ = try await h.queue.setOptedOut(false, expectedGeneration: h.queue.snapshot().generation)
        try await h.publish(); accepted(try await h.queue.capture(command(h)))
        XCTAssertEqual(try bucket(h).tokens, 1)
        await h.queue.close()
    }

    func testDispatchedLedgerQuotaConsumesTokenWhileDuplicateAndStaleReportsRemainFree() async throws {
        let h = try await make(); defer { h.base.remove() }
        let visitor = try await h.queue.snapshot().identity.anonymousId
        let recorded = try EluFlagExposureLedger.digest(key: "recorded", value: .bool(true))
        let newDigest = try EluFlagExposureLedger.digest(key: "new", value: .bool(true))
        var entries = Set((0..<(EluFlagExposureLedger.maximumEntries - 1)).map { String(format: "%064x", $0) })
        entries.insert(recorded)
        XCTAssertEqual(entries.count, EluFlagExposureLedger.maximumEntries)
        XCTAssertFalse(entries.contains(newDigest))
        let full = EluFlagExposureLedger(anonymousId: visitor, digests: entries)
        await h.queue.close()
        let hex = try full.encoded().map { String(format: "%02x", $0) }.joined()
        try h.base.sql("UPDATE flag_exposure_state SET metadata=X'\(hex)'")
        try await reopen(h, options: one); try await h.publish()
        let report = try command(h, name: "$feature_flag_called")
        let newExposure = EluFlagExposureRequest(anonymousId: visitor, digest: newDigest)
        rejected(await h.queue.captureFlagExposure(report, exposure: newExposure, admissionGuard: { false }), .authorityAbsent)
        rejected(await h.queue.captureFlagExposure(report, exposure: .init(anonymousId: visitor, digest: recorded),
            admissionGuard: { true }), .exposureAlreadyRecorded)
        XCTAssertEqual(try bucket(h).tokens, 1)
        rejected(await h.queue.captureFlagExposure(report, exposure: newExposure, admissionGuard: { true }), .exposureLedgerFull)
        XCTAssertEqual(try bucket(h).tokens, 0, "Dispatched quota rejection is not refunded")
        XCTAssertEqual(try EluFlagExposureLedger.decode(h.bytes("SELECT metadata FROM flag_exposure_state")), full)
        let empty = try await events(h); XCTAssertTrue(empty.isEmpty)
        rejected(try await h.queue.capture(command(h)), .rateLimited)
        let warning = try await events(h)
        XCTAssertEqual(warning.map(\.name), [EluCaptureRateLimiter.warningEvent])
        await h.queue.close(); try await reopen(h, options: one); try await h.publish()
        XCTAssertEqual(try bucket(h).tokens, 0, "The debit survives reopening")
        rejected(await h.queue.captureFlagExposure(report, exposure: .init(anonymousId: visitor, digest: recorded),
            admissionGuard: { true }), .exposureAlreadyRecorded)
        let unchanged = try await events(h); XCTAssertEqual(unchanged, warning)
        await h.queue.close()
    }

    func testDuplicateExposureDoesNotDebitAndStalePermissionDoesNotEmitWarning() async throws {
        let h = try await make(); defer { h.base.remove() }
        let visitor = try await h.queue.snapshot().identity.anonymousId
        let exposure = EluFlagExposureRequest(anonymousId: visitor,
            digest: try EluFlagExposureLedger.digest(key: "flag", value: .bool(true)))
        let report = try command(h, name: "$feature_flag_called")
        accepted(await h.queue.captureFlagExposure(report, exposure: exposure, admissionGuard: { true }))
        let after = try bucket(h)
        rejected(await h.queue.captureFlagExposure(report, exposure: exposure, admissionGuard: { true }), .exposureAlreadyRecorded)
        rejected(try await h.queue.capture(command(h), admissionGuard: { false }), .authorityAbsent)
        XCTAssertEqual(try bucket(h), after)
        let rows = try await events(h); XCTAssertEqual(rows.count, 1)
        await h.queue.close()
    }

    func testPassiveNetworkRateWarningCannotExtendOriginalUserActivity() async throws {
        let h = try await make(options: .init(eventsPerSecond: 0.01, eventsBurstLimit: 1)); defer { h.base.remove() }
        accepted(try await h.queue.capture(command(h)))
        let original = try await h.queue.snapshot()
        h.base.testClock.advance(1)
        let context = EluNetworkObservationContext(identityRevision: original.identity.revision,
            contextRevision: original.identity.contextRevision, sessionID: original.identity.session?.id,
            sessionStartedAt: original.identity.session?.startedAt)
        rejected(try await h.queue.captureNetworkObservation(command(h, name: "$network_request"), context: context,
            admissionGuard: { true }), .rateLimited)
        let after = try await h.queue.snapshot()
        XCTAssertEqual(after.identity.session, original.identity.session)
        let rows = try await events(h); XCTAssertEqual(rows.map(\.name), ["event", EluCaptureRateLimiter.warningEvent])
        XCTAssertEqual(rows.last?.sessionId, original.identity.session?.id)
        XCTAssertEqual(rows.last?.occurredAt, h.base.now)
        XCTAssertEqual(after.identity.updatedAt, original.identity.updatedAt)
        await h.queue.close()
        try await reopen(h, options: .init(eventsPerSecond: 0.01, eventsBurstLimit: 1)); try await h.publish()
        let restored = try await events(h), reopened = try await h.queue.snapshot()
        XCTAssertEqual(restored, rows)
        XCTAssertEqual(reopened.identity.session, original.identity.session)
        // The warning cannot extend the old idle boundary across a restart.
        let session = try XCTUnwrap(original.identity.session)
        h.base.testClock.advance(Double(session.timeoutSeconds))
        // The idle boundary exceeds the original configuration lease. Install
        // a genuinely later document, rather than extending its old witness.
        var renewed = try JSONSerialization.jsonObject(with: h.base.config) as! [String: Any]
        renewed["issuedAt"] = EluRFC3339.string(from: h.base.now)
        renewed["expiresAt"] = EluRFC3339.string(from: h.base.now.addingTimeInterval(300))
        h.base.config = try JSONSerialization.data(withJSONObject: renewed)
        try await h.publish()
        accepted(try await h.queue.capture(command(h)))
        let next = try await h.queue.snapshot()
        XCTAssertNotEqual(next.identity.session?.id, session.id)
        await h.queue.close()
    }

    func testPassiveWarningCannotCreateSessionOrOutliveSourceWithdrawal() async throws {
        let absent = try await make(); defer { absent.base.remove() }
        rejected(try await absent.queue.capturePerformanceSample(command(absent, name: "$performance_sample"),
            admissionGuard: { true }), .invalidEvent)
        rejected(try await absent.queue.capturePerformanceSample(command(absent, name: "$performance_sample"),
            admissionGuard: { true }), .rateLimited)
        let empty = try await events(absent), noSession = try await absent.queue.snapshot()
        XCTAssertTrue(empty.isEmpty); XCTAssertNil(noSession.identity.session)
        await absent.queue.close()

        let noNetworkSession = try await make(); defer { noNetworkSession.base.remove() }
        rejected(try await noNetworkSession.queue.capture(command(noNetworkSession, name: "")), .invalidEvent)
        let unstarted = try await noNetworkSession.queue.snapshot()
        let unstartedContext = EluNetworkObservationContext(identityRevision: unstarted.identity.revision,
            contextRevision: unstarted.identity.contextRevision, sessionID: nil, sessionStartedAt: nil)
        rejected(try await noNetworkSession.queue.captureNetworkObservation(command(noNetworkSession, name: "$network_request"),
            context: unstartedContext, admissionGuard: { true }), .rateLimited)
        let noNetworkRows = try await events(noNetworkSession), stillUnstarted = try await noNetworkSession.queue.snapshot()
        XCTAssertTrue(noNetworkRows.isEmpty); XCTAssertNil(stillUnstarted.identity.session)
        await noNetworkSession.queue.close()

        let fault = DeliveryFault(), denied = try await make(options: .init(eventsPerSecond: 0.01, eventsBurstLimit: 1), fault: fault)
        defer { denied.base.remove() }
        accepted(try await denied.queue.capture(command(denied)))
        let before = try await denied.queue.snapshot()
        denied.base.testClock.advance(1)
        let context = EluNetworkObservationContext(identityRevision: before.identity.revision,
            contextRevision: before.identity.contextRevision, sessionID: before.identity.session?.id,
            sessionStartedAt: before.identity.session?.startedAt)
        // Withdraw the actual original source after the limited debit, before
        // recursive warning admission; an always-true caller guard cannot help.
        fault.action = { if $0 == .afterRateLimitCommit { denied.base.gate.close() } }
        rejected(try await denied.queue.captureNetworkObservation(command(denied, name: "$network_request"),
            context: context, admissionGuard: { true }), .rateLimited)
        fault.action = nil
        let retained = try await events(denied), after = try await denied.queue.snapshot()
        XCTAssertEqual(retained.map(\.name), ["event"])
        XCTAssertEqual(after.identity.session, before.identity.session)
        await denied.queue.close()
    }

    func testAmbiguousBucketCommitPoisonsInsteadOfCapturingOrFreshConnectionFallback() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault); defer { h.base.remove() }
        fault.action = { if $0 == .afterRateLimitCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        rejected(try await h.queue.capture(command(h)), .storageOutcomeUnknown)
        do { _ = try await h.queue.snapshot(); XCTFail("Unknown commit stayed live") } catch {}
        fault.action = nil; await h.queue.close(); try await reopen(h, options: one); try await h.publish()
        XCTAssertEqual(try bucket(h).tokens, 0)
        rejected(try await h.queue.capture(command(h)), .rateLimited)
        let rows = try await events(h); XCTAssertTrue(rows.isEmpty)
        await h.queue.close()
    }

    func testKnownBucketReadAndWriteFailuresKeepOriginalHeldBudgetWithoutDisablingEvents() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault); defer { h.base.remove() }
        fault.action = { if $0 == .beforeRateLimitRead || $0 == .beforeRateLimitCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        accepted(try await h.queue.capture(command(h)))
        rejected(try await h.queue.capture(command(h)), .rateLimited)
        rejected(try await h.queue.capture(command(h)), .rateLimited)
        let rows = try await events(h); XCTAssertEqual(rows.map(\.name), ["event", EluCaptureRateLimiter.warningEvent])
        XCTAssertEqual(try bucket(h).tokens, 1, "Known rollback did not alter the durable bucket")
        fault.action = nil; await h.queue.close()
        try await reopen(h, options: one); try await h.publish()
        accepted(try await h.queue.capture(command(h)), file: #filePath, line: #line)
        XCTAssertEqual(try bucket(h).tokens, 0, "Readable durable state resumes precedence after reopening")
        await h.queue.close()
    }

    func testMemoryBucketDisappearsOnCloseWithoutTouchingDormantPersistentBucket() async throws {
        let h = try await make(); defer { h.base.remove() }
        accepted(try await h.queue.capture(command(h)))
        _ = try await h.queue.setOptedOut(false, expectedGeneration: h.queue.snapshot().generation)
        let durable = try bucket(h)
        await h.queue.close(); try await reopen(h, options: one, persistence: .memory); try await h.publish()
        accepted(try await h.queue.capture(command(h)))
        rejected(try await h.queue.capture(command(h)), .rateLimited)
        XCTAssertEqual(try bucket(h), durable, "This independent SQL probe reads only the dormant persistent database")
        await h.queue.close(); try await reopen(h, options: one, persistence: .memory); try await h.publish()
        accepted(try await h.queue.capture(command(h)))
        await h.queue.close(); try await reopen(h, options: one); try await h.publish()
        rejected(try await h.queue.capture(command(h)), .rateLimited)
        XCTAssertEqual(try bucket(h), durable)
        await h.queue.close()
    }

    func testAllFortyPriorSchemaCombinationsRetainActualQueueAndMigrateThenReopen() async throws {
        for version in Array(1...16) + Array(25...48) {
            let base = version > 40 ? version - 40 : version > 32 ? version - 32 : version > 24 ? version - 24 : version > 8 ? version - 8 : version
            let h = NativeSessionHarness(try await DeliveryHarness.make()); defer { h.base.remove() }
            try await h.publish(); accepted(try await h.queue.capture(command(h)))
            if base.isMultiple(of: 2) { try await h.queue.ensureFlagSchema() }
            if base >= 3 { try await h.queue.ensureReplaySchema() }
            if base >= 5 { try await h.queue.ensureReplayDeliverySchema() }
            if base >= 7 { try await h.queue.ensureNativeReplayAuthoritySchema() }
            let before = try await h.queue.snapshot(), records = try await h.queue.peek(maximumCount: 100, maximumBytes: 1_000_000)
            await h.queue.close()
            try h.base.sql("\(version < 41 ? "DROP TABLE flag_exposure_state;" : "") \(version < 33 ? "DROP TABLE person_identity_state;" : "") \(version < 25 ? "DROP TABLE native_diagnostics_state;" : "") \(version <= 8 ? "DROP TABLE capture_session_history;" : "") PRAGMA user_version=\(version)")
            try await reopen(h, options: one)
            XCTAssertEqual(try h.base.schemaVersion(), Int64(base + 48))
            let after = try await h.queue.snapshot(), restored = try await h.queue.peek(maximumCount: 100, maximumBytes: 1_000_000)
            XCTAssertEqual(before, after); XCTAssertEqual(records, restored)
            XCTAssertEqual(try bucket(h).tokens, 1)
            await h.queue.close(); try await reopen(h, options: one)
            XCTAssertEqual(try h.base.schemaVersion(), Int64(base + 48)); await h.queue.close()
        }
    }

    func testMigrationRollbackAndForeignOrMissingBucketAreRefused() async throws {
        let fault = DeliveryFault(), h = NativeSessionHarness(try await DeliveryHarness.make(fault: fault))
        defer { h.base.remove() }; await h.queue.close()
        fault.action = { if $0 == .beforeRateLimitMigrationCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { try await reopen(h, options: one); XCTFail("Migration failure accepted") } catch {}
        XCTAssertEqual(try h.base.schemaVersion(), 41)
        fault.action = nil; try await reopen(h, options: one); await h.queue.close()
        for sql in ["UPDATE capture_rate_limit SET stream_id='foreign'", "DELETE FROM capture_rate_limit",
                    "UPDATE capture_rate_limit SET metadata=CAST('{}' AS BLOB)", "PRAGMA user_version=57", "PRAGMA user_version=17"] {
            let invalid = try await make(); defer { invalid.base.remove() }; await invalid.queue.close()
            try invalid.base.sql(sql)
            do { try await reopen(invalid, options: one); XCTFail("Invalid rate store accepted") } catch {}
        }
    }
}

private struct RateNoNetwork: EluV1BatchHTTPTransport {
    struct UnexpectedNetwork: Error {}
    func send(_ request: EluV1BatchHTTPRequest) async throws -> EluV1BatchHTTPResponse { throw UnexpectedNetwork() }
}
private final class RateOptionsBox: @unchecked Sendable {
    private let lock = NSLock(); private var value: EluRateLimitingOptions?
    func save(_ value: EluRateLimitingOptions) { lock.lock(); self.value = value; lock.unlock() }
    func read() -> EluRateLimitingOptions? { lock.lock(); defer { lock.unlock() }; return value }
}
