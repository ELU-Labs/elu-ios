import Foundation
import SQLite3
import XCTest
@testable import EluAnalytics

final class EluNativeDiagnosticsRuntimeTests: XCTestCase {
    func testLocalOptInAndCurrentLaunchGrantAreIndependent() async throws {
        for enabled in [false, true] {
            let h = try await DiagnosticsRuntimeHarness.make(options: .init(enabled: enabled, launchSummaries: true))
            defer { h.remove() }
            _ = await h.runtime.applyConfiguration(h.config(launch: false))
            _ = await h.runtime.capture("session-start")
            if enabled { try await h.awaitEpoch() }
            let begin = h.clock.wall(); h.clock.advance(1)
            let diagnostic = try h.summary(begin: begin), launch = try h.summary(begin: begin, launch: true)
            let before = try await h.runtime.queueSnapshot()
            await h.runtime.captureNativeDiagnostic(launch, isCurrent: { true })
            let deniedLaunch = try await h.runtime.queueSnapshot(); XCTAssertEqual(deniedLaunch.queuedCount, before.queuedCount)
            await h.runtime.captureNativeDiagnostic(diagnostic, isCurrent: { true })
            let after = try await h.runtime.queueSnapshot()
            XCTAssertEqual(after.queuedCount, before.queuedCount + (enabled ? 1 : 0))
            XCTAssertEqual(after.identity.session, before.identity.session)
            if enabled {
                _ = await h.runtime.applyConfiguration(h.config(launch: true)); try await h.awaitEpoch()
                await h.runtime.captureNativeDiagnostic(launch, isCurrent: { true })
                let accepted = try await h.runtime.queueSnapshot(); XCTAssertEqual(accepted.queuedCount, after.queuedCount + 1)
            } else { XCTAssertNil(try h.state().epoch) }
            await h.runtime.close()
        }
    }

    func testSupersededConsentIntentStillClosesHistoricalInterval() async throws {
        let h = try await DiagnosticsRuntimeHarness.make(); defer { h.remove() }
        _ = await h.runtime.applyConfiguration(h.config()); _ = await h.runtime.capture("session-start")
        try await h.awaitEpoch(); let original = try XCTUnwrap(h.state().epoch), begin = h.clock.wall()
        h.clock.advance(1)
        let denial = UUID(), grant = UUID()
        h.runtime.acceptConsentIntent(denial, optedOut: true)
        h.runtime.acceptConsentIntent(grant, optedOut: false)
        _ = await h.runtime.setOptedOut(false, intent: grant)
        let staleWrite = await h.runtime.setOptedOut(true, intent: denial); XCTAssertNil(staleWrite)
        _ = await h.runtime.applyConfiguration(h.config())
        try await h.awaitEpoch(excluding: original.id)
        let before = try await h.runtime.queueSnapshot()
        try await h.runtime.captureNativeDiagnostic(h.summary(begin: begin), isCurrent: { true })
        let after = try await h.runtime.queueSnapshot(); XCTAssertEqual(after.queuedCount, before.queuedCount)
        XCTAssertFalse(after.identity.optedOut)
        await h.runtime.close(); XCTAssertNil(try h.state().epoch)
    }

    func testRoutineConfigExpiryPreservesCoverageButObservedTerminalDenialClosesIt() async throws {
        let h = try await DiagnosticsRuntimeHarness.make(); defer { h.remove() }
        _ = await h.runtime.applyConfiguration(h.config()); _ = await h.runtime.capture("session-start")
        try await h.awaitEpoch(); let original = try XCTUnwrap(h.state().epoch), begin = h.clock.wall()
        h.clock.advance(301)
        await h.runtime.withdrawConfiguration()
        XCTAssertEqual(try h.state().epoch, original)
        let before = try await h.runtime.queueSnapshot()
        try await h.runtime.captureNativeDiagnostic(h.summary(begin: begin), isCurrent: { true })
        let expired = try await h.runtime.queueSnapshot(); XCTAssertEqual(expired.queuedCount, before.queuedCount)
        _ = await h.runtime.applyConfiguration(h.config()); try await h.awaitEpoch()
        XCTAssertEqual(try h.state().epoch, original)
        try await h.runtime.captureNativeDiagnostic(h.summary(begin: begin), isCurrent: { true })
        let renewed = try await h.runtime.queueSnapshot(); XCTAssertEqual(renewed.queuedCount, before.queuedCount + 1)
        _ = await h.runtime.applyConfiguration(Data("{".utf8))
        XCTAssertNil(try h.state().epoch)
        await h.runtime.close()
    }

    func testShutdownRetriesOnlyKnownRollbackAndReportsUnresolvedStorageWithoutReleasingLease() async throws {
        let points: [EluRuntimeQueueFaultPoint] = [.beforeBegin, .beforeCommit, .afterCommit]
        for point in points {
            for temporary in [false, true] {
                if point == .afterCommit && temporary { continue }
                let fault = DeliveryFault(), h = try await DiagnosticsRuntimeHarness.make(fault: fault)
                defer { h.remove() }
                _ = await h.runtime.applyConfiguration(h.config()); try await h.awaitEpoch()
                let injected = DiagnosticsFailureCounter()
                fault.action = { actual in
                    if actual == point, !temporary || injected.first() { throw EluRuntimeQueueError.faultInjected(actual) }
                }
                await h.runtime.close()
                let outcome = await h.runtime.diagnosticsCloseSettlement
                XCTAssertEqual(outcome, temporary ? .settled : .unresolvedStorage)
                fault.action = nil
                do {
                    let replacement = try await EluStandaloneRuntime.make(rootDirectoryURL: h.root,
                        siteKey: DiagnosticsRuntimeHarness.siteKey, transport: DiagnosticsNoDelivery(),
                        clock: { h.clock.wall() }, diagnostics: .init(enabled: true))
                    if !temporary { XCTFail("Unresolved close released its original installation lease") }
                    XCTAssertNil(try h.state().epoch)
                    await replacement.close()
                } catch {
                    if temporary { throw error }
                }
            }
        }
    }

    func testOptionalMetadataFailureCannotPrecedeChangedDurableConsent() async throws {
        let fault = DeliveryFault(), h = try await DiagnosticsRuntimeHarness.make(fault: fault)
        defer { h.remove() }
        _ = await h.runtime.applyConfiguration(h.config()); try await h.awaitEpoch()
        let control = DiagnosticsMetadataFailure()
        fault.action = { try control.hit($0) }
        let denial = UUID()
        h.runtime.acceptConsentIntent(denial, optedOut: true)
        // Let any independently scheduled observer closure reach its own queue.
        // The current path fences synchronously and emits no metadata operation.
        try await Task.sleep(nanoseconds: 30_000_000)
        let denied = await h.runtime.setOptedOut(true, intent: denial)
        XCTAssertEqual(denied?.identity.optedOut, true)
        XCTAssertEqual(control.metadataFailures, 0)
        XCTAssertNil(try h.state().epoch)
        fault.action = nil
        await h.runtime.close()
        let replacement = try await EluStandaloneRuntime.make(rootDirectoryURL: h.root,
            siteKey: DiagnosticsRuntimeHarness.siteKey, transport: DiagnosticsNoDelivery(),
            clock: { h.clock.wall() }, diagnostics: .init(enabled: true))
        let reopened = try await replacement.queueSnapshot(); XCTAssertTrue(reopened.identity.optedOut)
        await replacement.close()
    }

    func testUnrelatedAmbiguousEventCannotReleaseCoverageBeforeShutdown() async throws {
        let fault = DeliveryFault(), h = try await DiagnosticsRuntimeHarness.make(fault: fault)
        defer { h.remove() }
        _ = await h.runtime.applyConfiguration(h.config()); try await h.awaitEpoch()
        let original = try XCTUnwrap(h.state().epoch)
        fault.action = { if $0 == .afterCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        _ = await h.runtime.capture("ambiguous-user-event")
        fault.action = nil
        await h.runtime.close()
        let outcome = await h.runtime.diagnosticsCloseSettlement
        XCTAssertEqual(outcome, .unresolvedStorage)
        XCTAssertEqual(try h.state().epoch, original)
        do {
            let replacement = try await EluStandaloneRuntime.make(rootDirectoryURL: h.root,
                siteKey: DiagnosticsRuntimeHarness.siteKey, transport: DiagnosticsNoDelivery(),
                clock: { h.clock.wall() }, diagnostics: .init(enabled: true))
            await replacement.close()
            XCTFail("Unrelated poison released historical coverage before explicit shutdown")
        } catch { /* The original owner remains quarantined after logical close. */ }
    }

    func testCrashReportPathRequiresParentOptionAndExactCurrentExceptionGrant() async throws {
        for choice in 0...3 {
            let enabled = choice != 0, selected = choice != 1
            let h = try await DiagnosticsRuntimeHarness.make(options: .init(enabled: enabled, crashReports: selected))
            let policy: Any = choice == 2 ? false : ["suppressionRules": []]
            _ = await h.runtime.applyConfiguration(h.config(exceptionPolicy: policy))
            _ = await h.runtime.capture("actual-receipt-session")
            if choice == 3 { try await h.awaitReportEpoch() }
            else if enabled { try await h.awaitEpoch() }
            let begin = h.clock.wall(); h.clock.advance(1)
            let batch = try EluMetricKitCrashBatch([.init(begin: begin, end: h.clock.wall(), machException: 1,
                signal: 11, detailsPermitted: false)])
            let before = try await h.runtime.queueSnapshot()
            await h.runtime.captureMetricKitCrashBatch(batch, isCurrent: { true })
            let after = try await h.runtime.queueSnapshot()
            XCTAssertEqual(after.queuedCount, before.queuedCount + (choice == 3 ? 1 : 0))
            XCTAssertEqual(after.identity.session, before.identity.session)
            XCTAssertEqual(try h.state().reports?.fingerprints.count, choice == 3 ? 1 : nil)
            await h.runtime.close(); h.remove()
        }
    }

    func testBatchUsesCurrentRemotePermissionAtReceiptNotHistoricalRemoteContinuity() async throws {
        let h = try await DiagnosticsRuntimeHarness.make(options: .init(enabled: true, crashReports: true))
        _ = await h.runtime.applyConfiguration(h.config(exceptionPolicy: ["suppressionRules": []]))
        _ = await h.runtime.capture("actual-session"); try await h.awaitReportEpoch()
        let begin = h.clock.wall(), original = try XCTUnwrap(h.state().reportEpoch)
        h.clock.advance(301); await h.runtime.withdrawConfiguration()
        XCTAssertEqual(try h.state().reportEpoch, original, "Routine expiry is not a local consent withdrawal")
        let batch = try EluMetricKitCrashBatch([.init(begin: begin, end: h.clock.wall(), machException: 1, signal: 11, detailsPermitted: false)])
        let before = try await h.runtime.queueSnapshot()
        await h.runtime.captureMetricKitCrashBatch(batch, isCurrent: { true })
        let denied = try await h.runtime.queueSnapshot(); XCTAssertEqual(denied.queuedCount, before.queuedCount)
        _ = await h.runtime.applyConfiguration(h.config(exceptionPolicy: ["suppressionRules": []])); try await h.awaitReportEpoch()
        XCTAssertEqual(try h.state().reportEpoch, original)
        await h.runtime.captureMetricKitCrashBatch(batch, isCurrent: { true })
        let after = try await h.runtime.queueSnapshot(); XCTAssertEqual(after.queuedCount, before.queuedCount + 1)
        h.clock.advance(0.001)
        _ = await h.runtime.applyConfiguration(h.config(exceptionPolicy: false)); try await h.awaitEpoch()
        XCTAssertNil(try h.state().reportEpoch)
        await h.runtime.close(); h.remove()
    }

    func testInvalidClockAndExplicitShutdownCloseDurableCoverage() async throws {
        for invalidClock in [false, true] {
            let h = try await DiagnosticsRuntimeHarness.make(); defer { h.remove() }
            _ = await h.runtime.applyConfiguration(h.config()); try await h.awaitEpoch()
            if invalidClock { await h.runtime.closeDiagnosticsForInvalidClock(); XCTAssertNil(try h.state().epoch) }
            await h.runtime.close(); XCTAssertNil(try h.state().epoch)
        }
    }
}

private final class DiagnosticsRuntimeHarness {
    let root: URL, clock: DiagnosticsRuntimeClock, runtime: EluStandaloneRuntime
    static let siteKey = "elu_pk_test_diagnostics"
    init(root: URL, clock: DiagnosticsRuntimeClock, runtime: EluStandaloneRuntime) { self.root = root; self.clock = clock; self.runtime = runtime }
    static func make(options: EluDiagnosticsOptions = .init(enabled: true), fault: DeliveryFault? = nil) async throws -> DiagnosticsRuntimeHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("elu-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let clock = DiagnosticsRuntimeClock()
        let runtime = try await EluStandaloneRuntime.make(rootDirectoryURL: root, siteKey: siteKey,
            transport: DiagnosticsNoDelivery(), clock: { clock.wall() }, continuousClock: { clock.monotonic() },
            continuousBudgetConverter: { $0 }, time: clock.source, timeZoneIdentifier: { "America/New_York" },
            diagnostics: options, faultInjector: fault)
        return .init(root: root, clock: clock, runtime: runtime)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func config(launch: Bool = true, exceptionPolicy: Any? = nil) -> Data {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Conformance/V2/fixtures/config-enabled.json")
        var value = try! JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        value["issuedAt"] = EluRFC3339.string(from: clock.wall().addingTimeInterval(-1))
        value["expiresAt"] = EluRFC3339.string(from: clock.wall().addingTimeInterval(300))
        value["revision"] = UUID().uuidString
        value["capturePerformance"] = ["memory": false, "long_tasks": launch, "sample_interval_ms": 30_000]
        if let exceptionPolicy { value["captureExceptions"] = exceptionPolicy }
        return try! JSONSerialization.data(withJSONObject: value)
    }
    func summary(begin: Date, launch: Bool = false) throws -> EluNativeDiagnosticSummary {
        try .init(kind: launch ? .launch : .diagnostic, begin: begin, end: clock.wall(), fields: launch
            ? ["$launch_first_draw_count": .integer(1), "$launch_first_draw_lower_bound_ms": .number(10), "$launch_first_draw_upper_bound_ms": .number(20)]
            : ["$crash_count": .integer(1)])
    }
    func state() throws -> EluNativeDiagnosticsState {
        let hash = try EluV1SiteNamespace.digest(exactConstructorSiteKey: Self.siteKey)
        let path = root.appendingPathComponent("site-\(hash)/runtime-state-v1.sqlite3")
        var database: OpaquePointer?
        // SQLite may need WAL/SHM coordination even for a reader when the
        // original owner has just checkpointed. Never CREATE or write SQL data.
        guard sqlite3_open_v2(path.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else { throw DiagnosticsReadError.failed }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)
        guard sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else { throw DiagnosticsReadError.failed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT metadata FROM native_diagnostics_state WHERE singleton=1", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw DiagnosticsReadError.sqlite(sqlite3_extended_errcode(database), String(cString: sqlite3_errmsg(database))) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw DiagnosticsReadError.failed }
        return try .decode(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }
    func awaitReportEpoch() async throws {
        for _ in 0..<200 {
            if try state().reportEpoch != nil { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Expected durable report consent epoch"); throw DiagnosticsReadError.failed
    }
    func awaitEpoch(excluding oldID: String? = nil) async throws {
        for _ in 0..<200 {
            if let epoch = try state().epoch, epoch.id != oldID { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Expected durable diagnostics epoch"); throw DiagnosticsReadError.failed
    }
}
private enum DiagnosticsReadError: Error { case failed, sqlite(Int32, String) }
private struct DiagnosticsNoDelivery: EluV1BatchHTTPTransport {
    func send(_ request: EluV1BatchHTTPRequest) async throws -> EluV1BatchHTTPResponse { throw DiagnosticsReadError.failed }
}
private final class DiagnosticsRuntimeClock: @unchecked Sendable {
    private let lock = NSLock(); private var now = Date(timeIntervalSince1970: 1_785_888_090); private var ticks: UInt64 = 1_000_000_000
    func wall() -> Date { lock.lock(); defer { lock.unlock() }; return now }
    func monotonic() -> UInt64 { lock.lock(); defer { lock.unlock() }; return ticks }
    func advance(_ seconds: TimeInterval) { lock.lock(); now.addTimeInterval(seconds); ticks += UInt64(seconds * 1_000_000_000); lock.unlock() }
    var source: EluV1BatchTimeSource { .init(wallNow: { self.wall() }, monotonicNow: { self.monotonic() }, sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) }) }
}

private final class DiagnosticsFailureCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; count += 1; return count == 1 }
}

private final class DiagnosticsMetadataFailure: @unchecked Sendable {
    private let lock = NSLock(); private var coreWrite = false; private var failures = 0
    var metadataFailures: Int { lock.lock(); defer { lock.unlock() }; return failures }
    func hit(_ point: EluRuntimeQueueFaultPoint) throws {
        lock.lock(); defer { lock.unlock() }
        if point == .afterBegin { coreWrite = false }
        if point == .beforeStateUpdate { coreWrite = true }
        if point == .beforeCommit && !coreWrite {
            failures += 1
            throw EluRuntimeQueueError.faultInjected(point)
        }
    }
}
