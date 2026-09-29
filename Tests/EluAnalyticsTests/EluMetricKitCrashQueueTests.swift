import Foundation
import XCTest
@testable import EluAnalytics

final class EluMetricKitCrashQueueTests: XCTestCase {
    private func versions() throws -> EluVersionContext {
        try .init(runtime: .init(name: "elu-ios", version: "0.2.0"), facade: .init(name: "Elu", version: "1"))
    }
    private func reopen(_ h: NativeSessionHarness, selected: Bool = true) async throws {
        let base = h.base, clock = base.testClock
        base.queue = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: base.root,
            exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", rateLimiting: selected ? .init() : nil,
            limits: base.limits, clock: { clock.read() }, continuousClock: { clock.ticks() }, continuousBudgetConverter: { $0 },
            configurationGate: base.gate, faultInjector: base.fault)
    }
    private func make(fault: DeliveryFault? = nil, selected: Bool = true, limits: EluRuntimeQueueLimits? = nil) async throws -> NativeSessionHarness {
        let h = NativeSessionHarness(try await DeliveryHarness.make(limits: limits, fault: fault))
        await h.queue.close(); try await reopen(h, selected: selected); try await grant(h)
        return h
    }
    private func grant(_ h: NativeSessionHarness, value: Any = ["suppressionRules": []]) async throws {
        var config = try XCTUnwrap(JSONSerialization.jsonObject(with: h.base.config) as? [String: Any])
        config["captureExceptions"] = value
        config["issuedAt"] = EluRFC3339.string(from: h.base.now)
        h.base.config = try JSONSerialization.data(withJSONObject: config)
        try await h.publish()
    }
    private func open(_ h: NativeSessionHarness, reports: Bool = true, details: Bool = false) async throws {
        let ready = try await h.queue.reconcileDiagnosticsContinuity(options: .init(enabled: true,
            crashReports: reports, crashReportDetails: details), admissionGuard: { true })
        XCTAssertTrue(ready)
    }
    private func item(_ h: NativeSessionHarness, begin: Date, signal: Int64 = 11, details: Bool = false) throws -> EluMetricKitCrashBatch.Item {
        try EluMetricKitCrashBatch([.init(begin: begin, end: h.base.now, machException: 1, signal: signal,
            detailsPermitted: details, details: details ? .init(name: "Fixture", className: nil, message: "synthetic") : nil)]).items[0]
    }

    func testReportCannotCreateSessionOrConsumeReceiptWithoutOne() async throws {
        let h = try await make(); try await open(h); let begin = h.base.now; h.base.testClock.advance(1)
        guard case .rejected = try await h.queue.captureMetricKitCrashReport(item(h, begin: begin), versions: versions(), admissionGuard: { true }) else {
            return XCTFail("Report created a session")
        }
        let state = try await h.queue.diagnosticsContinuity(), snapshot = try await h.queue.snapshot()
        XCTAssertNil(snapshot.identity.session); XCTAssertNil(state.reports)
        await h.queue.close(); h.base.remove()
    }

    func testOriginalReportEventAndReceiptCommitTogetherReopenAndRemainPassive() async throws {
        let h = try await make()
        _ = try await h.queue.registerStandaloneSuperProperties(["private_context": .string("excluded")])
        _ = try await h.queue.applyOwnedMutation(.associateGroup(groupType: "company", groupKey: "excluded"),
            versions: versions(), expectedGeneration: h.queue.snapshot().generation)
        try await h.publish(); try await open(h); let begin = h.base.now
        guard case let .accepted(_, initial) = await h.base.capture() else { return XCTFail("Actual session missing") }
        h.base.testClock.advance(1); let report = try item(h, begin: begin)
        guard case let .accepted(.event(event), after) = try await h.queue.captureMetricKitCrashReport(report,
            versions: versions(), admissionGuard: { true }) else { return XCTFail("Useful report rejected") }
        XCTAssertEqual(event.kind, .exception); XCTAssertEqual(event.name, "$exception")
        XCTAssertEqual(event.occurredAt, h.base.now); XCTAssertEqual(event.sessionId, initial.identity.session?.id)
        XCTAssertEqual(after.identity.session, initial.identity.session); XCTAssertEqual(after.identity.updatedAt, initial.identity.updatedAt)
        XCTAssertTrue(event.groups.isEmpty); XCTAssertNil(event.properties["private_context"])
        XCTAssertEqual(event.properties["$native_crash_session_attribution"], .string("receipt-only"))
        let state = try await h.queue.diagnosticsContinuity(); XCTAssertEqual(state.reports?.fingerprints.count, 1)
        await h.queue.close(); try await reopen(h); try await h.publish()
        let reopened = try await h.queue.diagnosticsContinuity(); XCTAssertEqual(reopened, state)
        guard case .rejected = try await h.queue.captureMetricKitCrashReport(report, versions: versions(), admissionGuard: { true }) else { return XCTFail("Duplicate survived reopen") }
        let final = try await h.queue.snapshot(); XCTAssertEqual(final.queuedCount, after.queuedCount)
        await h.queue.close(); h.base.remove()
    }

    func testCurrentPolicyAndFinalAdmissionAreRequiredWithoutConsumingReceipt() async throws {
        for withdrawal in [false, true] {
            let fault = DeliveryFault(), h = try await make(fault: fault); try await open(h)
            let begin = h.base.now; _ = await h.base.capture(); h.base.testClock.advance(1)
            let report = try item(h, begin: begin), control = CrashTransactionFault(withdraw: withdrawal)
            fault.action = { try control.hit($0) }
            guard case .rejected = try await h.queue.captureMetricKitCrashReport(report, versions: versions(), admissionGuard: { control.current }) else { return XCTFail("Final refusal lost") }
            fault.action = nil
            let denied = try await h.queue.diagnosticsContinuity(); XCTAssertNil(denied.reports)
            guard case .accepted = try await h.queue.captureMetricKitCrashReport(report, versions: versions(), admissionGuard: { true }) else { return XCTFail("Rollback consumed receipt") }
            h.base.testClock.advance(0.001); try await grant(h, value: false)
            let closed = try await h.queue.diagnosticsContinuity(); XCTAssertNil(closed.reportEpoch); XCTAssertNotNil(closed.epoch)
            h.base.testClock.advance(0.001); try await grant(h, value: ["suppressionRules": [["type": "OR", "values": []]]])
            try await open(h); let suppressed = try await h.queue.diagnosticsContinuity(); XCTAssertNil(suppressed.reportEpoch)
            await h.queue.close(); h.base.remove()
        }
    }

    func testQueueQuotaDoesNotConsumeReportReceipt() async throws {
        let h = try await make(limits: EluRuntimeQueueLimits(maximumCount: 1, maximumBytes: 1_000_000))
        try await open(h); let begin = h.base.now
        guard case let .accepted(record, full) = await h.base.capture() else { return XCTFail("Initial queue record missing") }
        h.base.testClock.advance(1); let report = try item(h, begin: begin)
        guard case .rejected = try await h.queue.captureMetricKitCrashReport(report, versions: versions(), admissionGuard: { true }) else { return XCTFail("Quota ignored") }
        let state = try await h.queue.diagnosticsContinuity(); XCTAssertNil(state.reports)
        _ = try await h.queue.acknowledge([EluQueueAcknowledgementReference(streamId: full.streamId,
            sequence: record.sequence, kind: record.kind, recordId: record.recordId)])
        guard case .accepted = try await h.queue.captureMetricKitCrashReport(report, versions: versions(), admissionGuard: { true }) else { return XCTFail("Quota refusal consumed report") }
        await h.queue.close(); h.base.remove()
    }

    func testConsentIdentityAndOriginalSourceInvalidateOldReport() async throws {
        for change in 0...2 {
            let h = try await make(); try await open(h); let begin = h.base.now
            _ = await h.base.capture(); h.base.testClock.advance(1)
            let report = try item(h, begin: begin)
            switch change {
            case 0: _ = try await h.queue.setOptedOut(false, expectedGeneration: h.queue.snapshot().generation)
            case 1: _ = try await h.queue.reset(expectedGeneration: h.queue.snapshot().generation)
            default: h.base.gate.close()
            }
            guard case .rejected = try await h.queue.captureMetricKitCrashReport(report, versions: versions(), admissionGuard: { true }) else { return XCTFail("Withdrawn report imported") }
            let state = try await h.queue.diagnosticsContinuity(); XCTAssertNil(state.reports)
            if change < 2 { XCTAssertNil(state.reportEpoch) }
            await h.queue.close(); h.base.remove()
        }
    }

    func testUnknownReportCommitRetainsOriginalLeaseAndDurableReceipt() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault); try await open(h)
        let begin = h.base.now; _ = await h.base.capture(); h.base.testClock.advance(1)
        let report = try item(h, begin: begin), control = CrashTransactionFault(unknown: true)
        fault.action = { try control.hit($0) }
        guard case .rejected(.storageOutcomeUnknown, _) = try await h.queue.captureMetricKitCrashReport(report,
            versions: versions(), admissionGuard: { true }) else { return XCTFail("Missing unknown commit") }
        fault.action = nil; await h.queue.close()
        let durable = try EluNativeDiagnosticsState.decode(h.bytes("SELECT metadata FROM native_diagnostics_state"))
        XCTAssertEqual(durable.reports?.fingerprints.count, 1)
        XCTAssertEqual(try h.integer("SELECT COUNT(*) FROM queue_records"), 2)
        do { try await reopen(h); XCTFail("Unresolved original report lease was released") } catch { }
        // Deliberately retain quarantined files/owner; no recursive cleanup claim.
    }

    func testReportConsentAndDetailChangesCannotInheritOldNumericInterval() async throws {
        let h = try await make(); try await open(h, reports: false)
        let old = h.base.now; _ = await h.base.capture(); h.base.testClock.advance(1)
        try await open(h); h.base.testClock.advance(1)
        guard case .rejected = try await h.queue.captureMetricKitCrashReport(item(h, begin: old), versions: versions(), admissionGuard: { true }) else { return XCTFail("Numeric consent became rich consent") }
        let state = try await h.queue.diagnosticsContinuity(), richBegin = h.base.now
        try await open(h, details: true); h.base.testClock.advance(1)
        let changed = try await h.queue.diagnosticsContinuity(); XCTAssertNotEqual(changed.reportEpoch?.id, state.reportEpoch?.id)
        guard case .rejected = try await h.queue.captureMetricKitCrashReport(item(h, begin: richBegin), versions: versions(), admissionGuard: { true }) else { return XCTFail("Old detail selection remained valid") }
        guard case .accepted = try await h.queue.captureMetricKitCrashReport(item(h, begin: richBegin, details: true), versions: versions(), admissionGuard: { true }) else { return XCTFail("Current explicit details rejected") }
        _ = try await h.queue.applyDiagnosticsOptions(.init(enabled: true))
        let closed = try await h.queue.diagnosticsContinuity(); XCTAssertNil(closed.reportEpoch); XCTAssertNotNil(closed.epoch)
        await h.queue.close(); h.base.remove()
    }

    func testEverySelectedPredecessorUpgradesLazilyAndKeepsQueueAndNumericBytes() async throws {
        for base in 1...8 {
            let h = try await make()
            if base.isMultiple(of: 2) { try await h.queue.ensureFlagSchema() }
            if base >= 3 { try await h.queue.ensureReplaySchema() }
            if base >= 5 { try await h.queue.ensureReplayDeliverySchema() }
            if base >= 7 { try await h.queue.ensureNativeReplayAuthoritySchema() }
            try await open(h, reports: false); _ = await h.base.capture()
            let before = try await h.queue.snapshot(), records = try await h.queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
            let numericBytes = try h.bytes("SELECT metadata FROM native_diagnostics_state")
            XCTAssertEqual(try h.base.schemaVersion(), Int64(48 + base))
            try await open(h)
            XCTAssertEqual(try h.base.schemaVersion(), Int64(56 + base))
            let after = try await h.queue.snapshot(), kept = try await h.queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
            XCTAssertEqual(after, before); XCTAssertEqual(kept, records)
            let enriched = try await h.queue.diagnosticsContinuity()
            XCTAssertEqual(enriched.epoch, try EluNativeDiagnosticsState.decode(numericBytes).epoch)
            XCTAssertNotNil(enriched.reportEpoch)
            await h.queue.close(); try await reopen(h)
            let reopened = try await h.queue.diagnosticsContinuity(); XCTAssertEqual(reopened, enriched)
            XCTAssertEqual(try h.base.schemaVersion(), Int64(56 + base))
            await h.queue.close(); h.base.remove()
        }
    }

    func testLazyMigrationRollbackRecoversAndUnknownCommitQuarantines() async throws {
        for unknown in [false, true] {
            let fault = DeliveryFault(), h = try await make(fault: fault)
            try await open(h, reports: false)
            let version = try h.base.schemaVersion(), old = try h.bytes("SELECT metadata FROM native_diagnostics_state")
            fault.action = { point in
                if point == (unknown ? .afterCommit : .beforeDiagnosticsMigrationCommit) { throw EluRuntimeQueueError.faultInjected(point) }
            }
            do { try await open(h); XCTFail("Fault did not stop migration") } catch { }
            fault.action = nil
            XCTAssertEqual(try h.base.schemaVersion(), unknown ? version + 8 : version)
            XCTAssertEqual(try h.bytes("SELECT metadata FROM native_diagnostics_state"), old)
            await h.queue.close()
            if unknown {
                do { try await reopen(h); XCTFail("Unknown migration released original lease") } catch { }
            } else {
                try await reopen(h); try await h.publish(); try await open(h)
                XCTAssertEqual(try h.base.schemaVersion(), version + 8)
                await h.queue.close(); h.base.remove()
            }
        }
    }

    func testUnsupportedOuterVersionsRefuseBothOpenersBeforeAnalyticsFileMutation() async throws {
        // This executes current unsupported-version refusal. Retained prior
        // source proves its 49...56 ceiling; it is not an old-binary execution.
        for version in [17, 24, 65] {
            let h = try await make(); await h.queue.close()
            try h.base.sql("PRAGMA user_version=\(version)")
            let component = try EluV1SiteNamespace.directoryComponent(exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa")
            let directory = h.base.root.appendingPathComponent(component)
            func files() throws -> [String: Data] {
                var result: [String: Data] = [:]
                for suffix in ["", "-wal", "-shm"] {
                    let name = "runtime-state-v1.sqlite3" + suffix, path = directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: path.path) { result[name] = try Data(contentsOf: path) }
                }
                return result
            }
            let original = try files()
            do { try await reopen(h); XCTFail("Capture opener accepted unsupported schema") } catch { }
            XCTAssertEqual(try files(), original)
            do {
                let opened = try await EluSQLiteRuntimeQueue.open(directoryURL: directory, limits: h.base.limits)
                await opened.close(); XCTFail("Raw opener accepted unsupported schema")
            } catch { }
            XCTAssertEqual(try files(), original)
            h.base.remove()
        }
    }

    func testRawUnselectedRuntimeDoesNotMigrateForReportOption() async throws {
        let h = try await make(selected: false), version = try h.base.schemaVersion()
        do { try await open(h); XCTFail("Unselected runtime installed report metadata") } catch { }
        XCTAssertEqual(try h.base.schemaVersion(), version)
        let state = try await h.queue.diagnosticsContinuity(); XCTAssertNil(state.reportEpoch)
        await h.queue.close(); h.base.remove()
    }
}
private final class CrashTransactionFault: @unchecked Sendable {
    private let lock = NSLock(); private var coreWrite = false; private var allowed = true
    private let withdraw: Bool; private let unknown: Bool
    init(withdraw: Bool = false, unknown: Bool = false) { self.withdraw = withdraw; self.unknown = unknown }
    var current: Bool { lock.lock(); defer { lock.unlock() }; return allowed }
    func hit(_ point: EluRuntimeQueueFaultPoint) throws {
        lock.lock(); defer { lock.unlock() }
        if point == .afterBegin { coreWrite = false }
        if point == .beforeStateUpdate { coreWrite = true }
        if coreWrite, point == (unknown ? .afterCommit : .beforeCommit) {
            if withdraw { allowed = false } else { throw EluRuntimeQueueError.faultInjected(point) }
        }
    }
}
