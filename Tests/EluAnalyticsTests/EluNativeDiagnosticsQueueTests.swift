import Foundation
import XCTest
@testable import EluAnalytics

private final class DiagnosticsPermission: @unchecked Sendable {
    private let lock = NSLock(); private var value = true
    var current: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func withdraw() { lock.lock(); value = false; lock.unlock() }
}

final class EluNativeDiagnosticsQueueTests: XCTestCase {
    private func make(fault: DeliveryFault? = nil) async throws -> NativeSessionHarness {
        let h = NativeSessionHarness(try await DeliveryHarness.make(fault: fault))
        await h.queue.close(); try await h.reopen(); try await h.publish()
        return h
    }
    private func versions() throws -> EluVersionContext {
        try EluVersionContext(runtime: EluVersionComponent(name: "elu-ios", version: "0.2.0"),
            facade: EluVersionComponent(name: "Elu", version: "1"))
    }
    private func open(_ h: NativeSessionHarness) async throws {
        let ready = try await h.queue.reconcileDiagnosticsContinuity(options: .init(enabled: true), admissionGuard: { true })
        XCTAssertTrue(ready)
    }
    private func report(_ h: NativeSessionHarness, begin: Date) throws -> EluNativeDiagnosticSummary {
        try .init(kind: .diagnostic, begin: begin, end: h.base.now, fields: ["$crash_count": .integer(1)])
    }

    func testSummaryCannotCreateSessionAndDoesNotConsumeFirstCaptureHistory() async throws {
        let h = try await make(); defer { h.base.remove() }
        let start = h.base.now; try await open(h); h.base.testClock.advance(1)
        guard case .rejected = try await h.queue.captureNativeDiagnostic(report(h, begin: start), versions: versions(), admissionGuard: { true }) else {
            return XCTFail("Historical receipt created a session")
        }
        let snapshot = try await h.queue.snapshot(), state = try await h.queue.diagnosticsContinuity()
        XCTAssertNil(snapshot.identity.session); XCTAssertNil(state.diagnostic)
        XCTAssertEqual(try EluCaptureSessionHistory.decode(h.bytes("SELECT metadata FROM capture_session_history")), .unseen)
        await h.queue.close()
    }

    func testAtomicDedupReopenPassiveSessionAndNoInheritedContext() async throws {
        let h = try await make(); defer { h.base.remove() }
        _ = try await h.queue.registerStandaloneSuperProperties(["private_context": .string("must-not-copy")])
        _ = try await h.queue.applyOwnedMutation(.associateGroup(groupType: "company", groupKey: "private-group"),
            versions: versions(), expectedGeneration: h.queue.snapshot().generation)
        try await h.publish(); try await open(h)
        let start = h.base.now
        guard case let .accepted(_, initial) = await h.base.capture() else { return XCTFail("Capture failed") }
        h.base.testClock.advance(1)
        let summary = try report(h, begin: start)
        guard case let .accepted(.event(event), after) = try await h.queue.captureNativeDiagnostic(summary,
            versions: versions(), admissionGuard: { true }) else { return XCTFail("Summary rejected") }
        XCTAssertEqual(after.identity.session, initial.identity.session)
        XCTAssertEqual(after.identity.updatedAt, initial.identity.updatedAt)
        XCTAssertTrue(event.groups.isEmpty); XCTAssertNil(event.properties["private_context"])
        XCTAssertEqual(event.properties["$device_id"], .string(initial.identity.anonymousId))
        XCTAssertEqual(event.properties["$is_identified"], .bool(false))
        XCTAssertEqual(event.properties["$process_person_profile"], .bool(true))
        XCTAssertNil(event.properties["$epp"])
        XCTAssertEqual(event.occurredAt, h.base.now); XCTAssertEqual(event.sessionId, initial.identity.session?.id)
        XCTAssertEqual(event.properties["$diagnostic_interval_start"], .string(EluRFC3339.string(from: start)))
        let state = try await h.queue.diagnosticsContinuity()
        await h.queue.close(); try await h.reopen(); try await h.publish()
        let reopened = try await h.queue.diagnosticsContinuity(); XCTAssertEqual(reopened, state)
        guard case .rejected = try await h.queue.captureNativeDiagnostic(summary, versions: versions(), admissionGuard: { true }) else {
            return XCTFail("Duplicate survived restart")
        }
        let final = try await h.queue.snapshot(); XCTAssertEqual(final.queuedCount, after.queuedCount)
        await h.queue.close()
    }

    func testFinalWithdrawalAndStorageRollbackNeverConsumeDedup() async throws {
        for withdraw in [false, true] {
            let fault = DeliveryFault(), permission = DiagnosticsPermission()
            let h = try await make(fault: fault); defer { h.base.remove() }
            try await open(h); let start = h.base.now
            _ = await h.base.capture(); h.base.testClock.advance(1)
            let summary = try report(h, begin: start), before = try await h.queue.snapshot()
            fault.action = { point in
                if point == .beforeCommit {
                    if withdraw { permission.withdraw() } else { throw EluRuntimeQueueError.faultInjected(point) }
                }
            }
            guard case .rejected = try await h.queue.captureNativeDiagnostic(summary, versions: versions(), admissionGuard: { permission.current }) else {
                return XCTFail("Expected final transaction rejection")
            }
            fault.action = nil
            let after = try await h.queue.snapshot(), state = try await h.queue.diagnosticsContinuity()
            XCTAssertEqual(after, before); XCTAssertNil(state.diagnostic)
            await h.queue.close(); try await h.reopen(); try await h.publish()
            guard case .accepted = try await h.queue.captureNativeDiagnostic(summary, versions: versions(), admissionGuard: { true }) else {
                return XCTFail("Rolled-back receipt consumed dedup")
            }
            await h.queue.close()
        }
    }

    func testAmbiguousCommittedReceiptRetainsLeaseAndDurableDedup() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault); defer { h.base.remove() }
        try await open(h); let start = h.base.now
        _ = await h.base.capture(); h.base.testClock.advance(1); let summary = try report(h, begin: start)
        fault.action = { if $0 == .afterCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        guard case .rejected(.storageOutcomeUnknown, _) = try await h.queue.captureNativeDiagnostic(summary, versions: versions(), admissionGuard: { true }) else {
            return XCTFail("Expected original ambiguous outcome")
        }
        fault.action = nil; await h.queue.close()
        do { try await h.reopen(); XCTFail("Ambiguous active coverage released its original lease") }
        catch { /* The original quarantine prevents another live owner. */ }
        let state = try EluNativeDiagnosticsState.decode(h.bytes("SELECT metadata FROM native_diagnostics_state"))
        XCTAssertEqual(state.diagnostic?.fingerprints, [try summary.fingerprint()])
        XCTAssertEqual(try h.integer("SELECT COUNT(*) FROM queue_records"), 2)
    }

    func testAmbiguousInitialCoverageWriteRetainsOriginalLease() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault); defer { h.base.remove() }
        let before = try await h.queue.diagnosticsContinuity(); XCTAssertNil(before.epoch)
        fault.action = { if $0 == .afterCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { try await open(h); XCTFail("Expected unknown initial coverage outcome") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ambiguousCommit) }
        fault.action = nil
        let durable = try EluNativeDiagnosticsState.decode(h.bytes("SELECT metadata FROM native_diagnostics_state"))
        XCTAssertNotNil(durable.epoch)
        do { _ = try await h.queue.closeDiagnosticsContinuity(); XCTFail("Unknown opening reported settled closure") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .poisoned) }
        await h.queue.close()
        do { try await h.reopen(); XCTFail("Unknown coverage opening released its original lease") }
        catch { /* The original quarantine remains occupied until process exit. */ }
    }

    func testSameConsentIdentityResetAndLocalDisableCloseContinuity() async throws {
        for action in 0...4 {
            let h = try await make(); defer { h.base.remove() }
            try await open(h); let start = h.base.now
            _ = await h.base.capture(); h.base.testClock.advance(1)
            switch action {
            case 0: _ = try await h.queue.setOptedOut(false, expectedGeneration: h.queue.snapshot().generation)
            case 1: _ = try await h.queue.setOptedOut(true, expectedGeneration: h.queue.snapshot().generation)
            case 2: _ = try await h.queue.reset(expectedGeneration: h.queue.snapshot().generation)
            case 3: _ = try await h.queue.applyOwnedMutation(.identify(userId: "new-user", set: [:], setOnce: [:]),
                versions: versions(), expectedGeneration: h.queue.snapshot().generation)
            default: _ = try await h.queue.reconcileDiagnosticsContinuity(options: .init(), admissionGuard: { true })
            }
            let state = try await h.queue.diagnosticsContinuity(); XCTAssertNil(state.epoch)
            guard case .rejected = try await h.queue.captureNativeDiagnostic(report(h, begin: start), versions: versions(), admissionGuard: { true }) else {
                return XCTFail("Old OS interval escaped withdrawal")
            }
            await h.queue.close(); try await h.reopen()
            let reopened = try await h.queue.diagnosticsContinuity(); XCTAssertNil(reopened.epoch)
            await h.queue.close()
        }
    }

    func testObserverMetadataCannotInvalidatePendingConsentOrIdentityGeneration() async throws {
        let h = try await make(); defer { h.base.remove() }
        let original = try await h.queue.snapshot()
        try await open(h)
        h.base.testClock.advance(1)
        _ = try await h.queue.reconcileDiagnosticsContinuity(options: .init(enabled: true), admissionGuard: { true })
        _ = try await h.queue.closeDiagnosticsContinuity()
        let afterObservation = try await h.queue.snapshot(); XCTAssertEqual(afterObservation, original)
        let denied = try await h.queue.setOptedOut(true, expectedGeneration: original.generation)
        XCTAssertTrue(denied.identity.optedOut)
        _ = try await h.queue.setOptedOut(false, expectedGeneration: denied.generation)
        try await h.publish()
        let pendingIdentity = try await h.queue.snapshot()
        try await open(h)
        let identified = try await h.queue.applyOwnedMutation(.identify(userId: "user-after-observation", set: [:], setOnce: [:]),
            versions: versions(), expectedGeneration: pendingIdentity.generation)
        XCTAssertEqual(identified.identity.userId, "user-after-observation")
        await h.queue.close()
    }

    func testStartupOptionsCloseCoverageBeforeAnyConfigurationOrNewGrant() async throws {
        for disableAll in [false, true] {
            let h = try await make(); defer { h.base.remove() }
            let opened = try await h.queue.reconcileDiagnosticsContinuity(options: .init(enabled: true, launchSummaries: true), admissionGuard: { true })
            XCTAssertTrue(opened)
            let old = try await h.queue.diagnosticsContinuity(); XCTAssertNotNil(old.epoch)
            await h.queue.close(); try await h.reopen() // Intentionally no config grant.
            _ = try await h.queue.applyDiagnosticsOptions(.init(enabled: !disableAll, launchSummaries: false))
            let closed = try await h.queue.diagnosticsContinuity(); XCTAssertNil(closed.epoch)
            await h.queue.close(); try await h.reopen()
            _ = try await h.queue.applyDiagnosticsOptions(.init(enabled: true, launchSummaries: true))
            let stillClosed = try await h.queue.diagnosticsContinuity(); XCTAssertNil(stillClosed.epoch)
            await h.queue.close()
        }
    }

    func testClockRollbackClosesCoverageDurablyAndCannotReuseOldInterval() async throws {
        let h = try await make(); defer { h.base.remove() }
        try await open(h); let begin = h.base.now
        _ = await h.base.capture(); h.base.testClock.advance(10)
        _ = try await h.queue.reconcileDiagnosticsContinuity(options: .init(enabled: true), admissionGuard: { true })
        let summary = try report(h, begin: begin)
        h.base.testClock.set(begin.addingTimeInterval(5))
        guard case .rejected = try await h.queue.captureNativeDiagnostic(summary, versions: versions(), admissionGuard: { true }) else {
            return XCTFail("Regressed clock accepted historical interval")
        }
        let closed = try await h.queue.diagnosticsContinuity(); XCTAssertNil(closed.epoch)
        await h.queue.close()
        let clock = h.base.testClock; clock.set(begin.addingTimeInterval(11))
        // A process restart creates a new source gate; the original correctly
        // remains poisoned after seeing clock rollback.
        let gate = EluV2ConfigAuthorityGate(siteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", clock: .init(
            wallNow: { clock.read() }, continuousNow: { clock.ticks() }, floorTicks: { clock.convert($0) }, floorNanoseconds: { $0 }))
        let queue = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: h.base.root,
            exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", limits: h.base.limits,
            clock: { clock.read() }, continuousClock: { clock.ticks() }, continuousBudgetConverter: { $0 }, configurationGate: gate)
        let reopened = NativeSessionHarness(DeliveryHarness(root: h.base.root, queue: queue, gate: gate,
            limits: h.base.limits, config: h.base.config, testClock: clock, fault: nil))
        try await reopened.publish(); try await open(reopened)
        guard case .rejected = try await queue.captureNativeDiagnostic(summary, versions: versions(), admissionGuard: { true }) else {
            return XCTFail("Reopened owner imported the invalidated interval")
        }
        await queue.close()
    }

    func testLaunchOptionChangeCannotImportPreviouslyDisabledCoverage() async throws {
        let h = try await make(); defer { h.base.remove() }
        try await open(h); let begin = h.base.now
        _ = await h.base.capture(); h.base.testClock.advance(1)
        let before = try await h.queue.diagnosticsContinuity()
        let enabled = try await h.queue.reconcileDiagnosticsContinuity(options: .init(enabled: true, launchSummaries: true), admissionGuard: { true })
        XCTAssertTrue(enabled)
        let changed = try await h.queue.diagnosticsContinuity(); XCTAssertNotEqual(changed.epoch?.id, before.epoch?.id)
        h.base.testClock.advance(1)
        let summary = try EluNativeDiagnosticSummary(kind: .launch, begin: begin, end: h.base.now,
            fields: ["$launch_first_draw_count": .integer(1), "$launch_first_draw_lower_bound_ms": .number(1), "$launch_first_draw_upper_bound_ms": .number(2)])
        guard case .rejected = try await h.queue.captureNativeDiagnostic(summary, versions: versions(), admissionGuard: { true }) else {
            return XCTFail("Enabled option imported previously disabled interval")
        }
        await h.queue.close(); try await h.reopen(); try await h.publish()
        let reopened = try await h.queue.diagnosticsContinuity(); XCTAssertEqual(reopened, changed)
        await h.queue.close()
    }

    func testAllPriorOwnedSchemasUpgradeClosedWithoutChangingExistingQueue() async throws {
        for version in 1...16 {
            let base = version > 8 ? version - 8 : version
            let h = try await make(); defer { h.base.remove() }
            _ = await h.base.capture()
            if base.isMultiple(of: 2) { try await h.queue.ensureFlagSchema() }
            if base >= 3 { try await h.queue.ensureReplaySchema() }
            if base >= 5 { try await h.queue.ensureReplayDeliverySchema() }
            if base >= 7 { try await h.queue.ensureNativeReplayAuthoritySchema() }
            let before = try await h.queue.snapshot(), records = try await h.queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
            await h.queue.close()
            try h.base.sql("DROP TABLE person_identity_state; DROP TABLE native_diagnostics_state; \(version <= 8 ? "DROP TABLE capture_session_history;" : "") PRAGMA user_version=\(version)")
            try await h.reopen()
            XCTAssertEqual(try h.base.schemaVersion(), Int64(base + 32))
            let after = try await h.queue.snapshot(), afterRecords = try await h.queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
            let state = try await h.queue.diagnosticsContinuity()
            XCTAssertEqual(before, after); XCTAssertEqual(records, afterRecords); XCTAssertEqual(state, .closed)
            await h.queue.close()
        }
    }

    func testDiagnosticsMigrationFailureRollsBackAndReopenRecovers() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault); defer { h.base.remove() }
        _ = await h.base.capture(); let before = try await h.queue.snapshot()
        await h.queue.close(); try h.base.sql("DROP TABLE person_identity_state; DROP TABLE native_diagnostics_state; PRAGMA user_version=9")
        fault.action = { if $0 == .beforeDiagnosticsMigrationCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { try await h.reopen(); XCTFail("Migration failure was ignored") } catch {}
        XCTAssertEqual(try h.base.schemaVersion(), 9)
        XCTAssertEqual(try h.integer("SELECT count(*) FROM sqlite_master WHERE name='native_diagnostics_state'"), 0)
        fault.action = nil; try await h.reopen()
        let after = try await h.queue.snapshot(); XCTAssertEqual(before, after)
        XCTAssertEqual(try h.base.schemaVersion(), 33)
        await h.queue.close()
    }
}
