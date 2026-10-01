import Foundation
import XCTest
@testable import EluAnalytics

final class EluMetricKitCrashReportTests: XCTestCase {
    private let begin = Date(timeIntervalSince1970: 1_785_888_000)
    private func report(signal: Int64 = 11, details: Bool = false) throws -> EluMetricKitCrashReport {
        try .init(begin: begin, end: begin.addingTimeInterval(10), machException: 1, signal: signal,
            detailsPermitted: details, details: details ? .init(name: "FixtureException", className: "Fixture", message: "synthetic-only") : nil)
    }

    func testReportHasOSFieldsButNoStackOrInventedCrashInstant() throws {
        let value = try report(), properties = value.properties
        XCTAssertEqual(properties["$native_crash_mach_exception"], .integer(1))
        XCTAssertEqual(properties["$native_crash_signal"], .integer(11))
        XCTAssertEqual(properties["$native_crash_exact_time_available"], .bool(false))
        XCTAssertEqual(properties["$native_crash_session_attribution"], .string("receipt-only"))
        XCTAssertEqual(properties["$exception_message"], .null)
        XCTAssertEqual(properties["$native_crash_details_available"], .bool(false))
        guard case let .array(entries)? = properties["$exception_list"], case let .object(entry) = entries[0] else {
            return XCTFail("Missing actual per-report exception")
        }
        XCTAssertNil(entry["stacktrace"]); XCTAssertNil(entry["frames"])
        XCTAssertEqual(entry["mechanism"], .object(["type": .string("metrickit"), "handled": .bool(false)]))
        XCTAssertThrowsError(try EluMetricKitCrashReport(begin: begin, end: begin.addingTimeInterval(10),
            machException: 1, signal: 11, detailsPermitted: false, details: .init(name: "private", className: nil, message: nil)))
    }

    func testDetailsAreSeparateAndBoundRetainedOutputNotOSGetterWork() throws {
        let detail = EluMetricKitCrashReport.Details(name: String(repeating: "😀", count: 300),
            className: String(repeating: "c", count: 300), message: String(repeating: "x", count: 2_000))
        XCTAssertEqual(detail.name?.unicodeScalars.count, 256)
        XCTAssertEqual(detail.className?.unicodeScalars.count, 256)
        XCTAssertEqual(detail.message?.unicodeScalars.count, 1_024)
        let value = try EluMetricKitCrashReport(begin: begin, end: begin.addingTimeInterval(10),
            machException: nil, signal: nil, detailsPermitted: true, details: detail)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(value.properties).count, EluMetricKitCrashReport.maximumBytes)
        XCTAssertThrowsError(try EluMetricKitCrashReport(begin: begin, end: begin, machException: 1, signal: 11, detailsPermitted: false))
        XCTAssertThrowsError(try report(signal: 256))
        XCTAssertThrowsError(try EluMetricKitCrashReport(begin: begin, end: begin.addingTimeInterval(1), machException: nil, signal: nil, detailsPermitted: false))
    }

    func testWholeBatchBoundAndOrderIndependentMultisetReceipts() throws {
        let a = try report(), b = try report(signal: 6)
        XCTAssertThrowsError(try EluMetricKitCrashBatch([]))
        XCTAssertThrowsError(try EluMetricKitCrashBatch([a, a, a, a, a]))
        let first = try EluMetricKitCrashBatch([a, b, a]), second = try EluMetricKitCrashBatch([b, a, a])
        XCTAssertEqual(first.items.map { $0.receiptFingerprint(epochID: "original") }, second.items.map { $0.receiptFingerprint(epochID: "original") })
        XCTAssertEqual(Set(first.items.map { $0.receiptFingerprint(epochID: "original") }).count, 3)
        XCTAssertNotEqual(first.items[0].receiptFingerprint(epochID: "original"), first.items[0].receiptFingerprint(epochID: "replacement"))
    }

    func testLocalReportEpochNeverInheritsPriorNumericCoverage() throws {
        let numeric = EluNativeDiagnosticsState.closed.reconciled(at: begin, identityRevision: 1, mayOpen: true, launchSummaries: false)
        let oldBytes = try numeric.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: oldBytes) as? [String: Any])
        XCTAssertNil(object["reportEpoch"]); XCTAssertNil(object["reports"])
        let selected = numeric.reconciledReports(at: begin.addingTimeInterval(5), identityRevision: 1, allowed: true, details: false)
        let old = try EluMetricKitCrashBatch([report()]).items[0]
        XCTAssertNil(try selected.acceptingReport(old, at: begin.addingTimeInterval(20), identityRevision: 1))
        XCTAssertEqual(selected.closingReports().epoch, numeric.epoch)
        let launchOnlyChange = selected.reconciled(at: begin.addingTimeInterval(6), identityRevision: 1, mayOpen: true, launchSummaries: true)
        XCTAssertEqual(launchOnlyChange.reportEpoch, selected.reportEpoch)
        XCTAssertNotEqual(launchOnlyChange.epoch, selected.epoch)
        XCTAssertNil(selected.closing().reportEpoch)
        XCTAssertEqual(try EluNativeDiagnosticsState.decode(oldBytes).encoded(), oldBytes)
    }

    func testReportReceiptsAreIndependentAtomicCandidatesAndBoundedWithNumericState() throws {
        var state = EluNativeDiagnosticsState.closed.reconciled(at: begin, identityRevision: 1, mayOpen: true, launchSummaries: true)
            .reconciledReports(at: begin, identityRevision: 1, allowed: true, details: false)
        let end = begin.addingTimeInterval(10)
        for number in 1...32 {
            let item = try EluMetricKitCrashBatch([report(signal: Int64(number))]).items[0]
            state = try XCTUnwrap(state.acceptingReport(item, at: end, identityRevision: 1))
            let numeric = try EluNativeDiagnosticSummary(kind: .diagnostic, begin: begin, end: end, fields: ["$crash_count": .integer(Int64(number))])
            state = try XCTUnwrap(state.accepting(numeric, at: end, identityRevision: 1))
            let launch = try EluNativeDiagnosticSummary(kind: .launch, begin: begin, end: end, fields: ["$launch_diagnostic_count": .integer(Int64(number)), "$launch_diagnostic_duration_max_ms": .number(1), "$launch_diagnostic_duration_total_ms": .number(2)])
            state = try XCTUnwrap(state.accepting(launch, at: end, identityRevision: 1))
        }
        XCTAssertEqual(state.reports?.fingerprints.count, 32)
        XCTAssertLessThanOrEqual(try state.encoded().count, 8_192)
        XCTAssertEqual(try EluNativeDiagnosticsState.decode(state.encoded()), state)
        let full = try EluMetricKitCrashBatch([report(signal: 33)]).items[0]
        XCTAssertNil(try state.acceptingReport(full, at: end, identityRevision: 1))
        let changed = state.reconciledReports(at: end, identityRevision: 1, allowed: true, details: true)
        XCTAssertNil(changed.reports); XCTAssertNotEqual(changed.reportEpoch?.id, state.reportEpoch?.id)
        XCTAssertEqual(changed.diagnostic, state.diagnostic)
        XCTAssertNil(state.reconciledReports(at: begin.addingTimeInterval(-1), identityRevision: 1, allowed: true, details: false).reportEpoch)
    }

    func testClosedPolicyNeverIgnoresSuppression() throws {
        func decode(_ text: String) throws -> EluCaptureExceptionsPolicy { try JSONDecoder().decode(EluCaptureExceptionsPolicy.self, from: Data(text.utf8)) }
        XCTAssertTrue(try decode("{\"suppressionRules\":[]}").allowsMetricKitReports)
        XCTAssertFalse(try decode("false").allowsMetricKitReports)
        XCTAssertFalse(try decode("{\"suppressionRules\":[{\"type\":\"AND\",\"values\":[{\"key\":\"$exception_types\",\"operator\":\"regex\",\"value\":\".*\"}]}]}").allowsMetricKitReports)
        for raw in ["true", "null", "{}", "{\"suppressionRules\":[],\"extra\":true}", "{\"suppressionRules\":[{\"type\":\"X\",\"values\":[]}]}", "{\"suppressionRules\":[{\"type\":\"OR\",\"values\":[{\"key\":\"unknown\",\"operator\":\"exact\",\"value\":\"x\"}]}]}"] {
            XCTAssertThrowsError(try decode(raw), raw)
        }
    }

    func testOriginalIntakeRemainsHeldAcrossBatchAwaitAndCloseJoinsIt() async throws {
        let monitor = EluNativeDiagnosticsMonitor(), latch = CrashReportLatch(), reads = CrashReportReads()
        let batch = try EluMetricKitCrashBatch([report(), report(signal: 6)])
        let consent = EluNativeDiagnosticsState.closed.reconciledReports(at: begin, identityRevision: 1, allowed: true, details: false)
        let projection = try XCTUnwrap(EluMetricKitCrashProjection(state: consent, identityRevision: 1, optedOut: false, details: false))
        let now = begin.addingTimeInterval(20)
        let entered = expectation(description: "original batch entered"), closed = expectation(description: "close joined original batch")
        let receiver = try XCTUnwrap(monitor.publish(includeLaunch: false, includeCrashReports: true,
            reportProjection: projection, reportClock: { now }, receiveReports: { received, current in
                XCTAssertEqual(received.items.count, 2); XCTAssertTrue(current()); entered.fulfill()
                await latch.wait()
                XCTAssertFalse(current(), "Close must revoke original admission before joining")
            }, current: { true }, receive: { _ in }))
        monitor.receiveCrashReports(receiverID: receiver) { _, _ in reads.increment(); return batch }
        await fulfillment(of: [entered], timeout: 2)
        monitor.receiveCrashReports(receiverID: receiver) { _, _ in reads.increment(); return batch }
        let replacement = try XCTUnwrap(monitor.publish(includeLaunch: false, includeCrashReports: true,
            reportProjection: projection, reportClock: { now }, current: { true }, receive: { _ in }))
        monitor.receiveCrashReports(receiverID: replacement) { _, _ in reads.increment(); return batch }
        XCTAssertEqual(reads.count, 1, "A replacement subscriber cannot evade the original held slot")
        let closeTask = Task { await monitor.closeAndWait(); reads.closeFinished(); closed.fulfill() }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(reads.closed)
        await latch.release()
        await fulfillment(of: [closed], timeout: 2); await closeTask.value
        monitor.receiveCrashReports(receiverID: receiver) { _, _ in reads.increment(); return batch }
        XCTAssertEqual(reads.count, 1)
    }

    func testOriginalIntervalEligibilityPrecedesAllDetailGetterCanaries() throws {
        let state = EluNativeDiagnosticsState.closed.reconciledReports(at: begin.addingTimeInterval(5),
            identityRevision: 1, allowed: true, details: true)
        let projection = try XCTUnwrap(EluMetricKitCrashProjection(state: state, identityRevision: 1, optedOut: false, details: true))
        // Pre-consent, future, reversed, zero interval and reversed receipt clock.
        for (start, end, now) in [(0.0, 10.0, 20.0), (6, 30, 20), (10, 6, 20), (6, 6, 20), (5, 6, 4)] {
            let codes = CrashReportReads(), details = CrashReportReads()
            XCTAssertThrowsError(try projection.project(begin: begin.addingTimeInterval(start), end: begin.addingTimeInterval(end),
                clock: { self.begin.addingTimeInterval(now) }, current: { true },
                readCodes: { codes.increment(); return (1, 11) },
                readDetails: { _ in details.increment(); return .init(name: "never-read", className: nil, message: nil) }))
            XCTAssertEqual(codes.count, 0); XCTAssertEqual(details.count, 0)
        }
        let details = CrashReportReads()
        let admitted = try projection.project(begin: begin.addingTimeInterval(5), end: begin.addingTimeInterval(10),
            clock: { self.begin.addingTimeInterval(20) }, current: { true }, readCodes: { (1, 11) },
            readDetails: { permitted in XCTAssertTrue(permitted()); details.increment(); return .init(name: "LawfulSynthetic", className: nil, message: nil) })
        XCTAssertEqual(details.count, 1); XCTAssertEqual(admitted.details?.name, "LawfulSynthetic")
        XCTAssertNil(EluMetricKitCrashProjection(state: state, identityRevision: 2, optedOut: false, details: true))
        XCTAssertNil(EluMetricKitCrashProjection(state: state, identityRevision: 1, optedOut: true, details: true))
        XCTAssertNil(EluMetricKitCrashProjection(state: state, identityRevision: 1, optedOut: false, details: false))
    }

    func testDefaultReportConsentNeverInvokesOptionalDetailGetter() throws {
        let state = EluNativeDiagnosticsState.closed.reconciledReports(at: begin, identityRevision: 1, allowed: true, details: false)
        let projection = try XCTUnwrap(EluMetricKitCrashProjection(state: state, identityRevision: 1, optedOut: false, details: false))
        let details = CrashReportReads()
        let report = try projection.project(begin: begin, end: begin.addingTimeInterval(10), clock: { self.begin.addingTimeInterval(20) },
            current: { true }, readCodes: { (1, 11) },
            readDetails: { _ in details.increment(); return .init(name: "never-read", className: nil, message: nil) })
        XCTAssertEqual(details.count, 0); XCTAssertNil(report.details); XCTAssertFalse(report.detailsPermitted)
    }

    func testRevokedOriginalIdentitySourceAndDetailSelectionNeverInvokeGetter() async throws {
        for change in 0...2 {
            let monitor = EluNativeDiagnosticsMonitor(), local = EluNativeDiagnosticsGate(), details = CrashReportReads()
            let now = begin.addingTimeInterval(20), end = begin.addingTimeInterval(10)
            let consent = EluNativeDiagnosticsState.closed.reconciledReports(at: begin, identityRevision: 1, allowed: true, details: true)
            let projection = try XCTUnwrap(EluMetricKitCrashProjection(state: consent, identityRevision: 1, optedOut: false, details: true))
            let localToken = try XCTUnwrap(local.token())
            let source = EluV2ConfigAuthorityGate(siteKey: "synthetic-original-source", clock: .init(wallNow: { now }, continuousNow: { 1 }, floorTicks: { $0 }))
            let token = EluV2ConfigLifecycleToken(), data = Data("synthetic-source".utf8)
            source.publish(token: token, lease: .init(data: data,
                expiresAt: try EluV1Timestamp(EluRFC3339.string(from: now.addingTimeInterval(60))), continuousDeadline: 100))
            let witness = try XCTUnwrap(source.witness(for: token))
            let current: @Sendable () -> Bool = { local.isCurrent(localToken) && source.isCurrent(witness, data: data) }
            let id = try XCTUnwrap(monitor.publish(includeLaunch: false, includeCrashReports: true, crashReportDetails: true,
                reportProjection: projection, reportClock: { now }, current: current, receive: { _ in }))
            monitor.receiveCrashReports(receiverID: id) { original, admitted in
                let report = try original.project(begin: self.begin, end: end, clock: { now }, current: admitted, readCodes: {
                    // These are the same original in-memory fences used by runtime publication.
                    if change == 0 { _ = local.begin() } // identity mutation intent
                    else if change == 1 { source.publish(token: EluV2ConfigLifecycleToken(), lease: nil) }
                    else {
                        let changed = consent.reconciledReports(at: now, identityRevision: 1, allowed: true, details: false)
                        let replacement = EluMetricKitCrashProjection(state: changed, identityRevision: 1, optedOut: false, details: false)
                        _ = monitor.publish(includeLaunch: false, includeCrashReports: true, reportProjection: replacement,
                            reportClock: { now }, current: current, receive: { _ in })
                    }
                    return (1, 11)
                }, readDetails: { _ in details.increment(); return .init(name: "never-read", className: nil, message: nil) })
                return try EluMetricKitCrashBatch([report])
            }
            XCTAssertEqual(details.count, 0, "Revocation must stop acquisition, not just SQL admission")
            await monitor.closeAndWait(); source.close(); local.close()
        }
    }

    func testNumericOnlySelectionNeverReadsReportProjection() async throws {
        let monitor = EluNativeDiagnosticsMonitor(), reads = CrashReportReads()
        let id = try XCTUnwrap(monitor.publish(includeLaunch: false, current: { true }, receive: { _ in }))
        monitor.receiveCrashReports(receiverID: id) { _, _ in reads.increment(); throw EluRuntimeQueueError.invalidRecord }
        XCTAssertEqual(reads.count, 0); await monitor.closeAndWait()
    }
}
private actor CrashReportLatch {
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async { if released { return }; await withCheckedContinuation { waiting = $0 } }
    func release() { released = true; waiting?.resume(); waiting = nil }
}
private final class CrashReportReads: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0; private var completed = false
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return completed }
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func closeFinished() { lock.lock(); completed = true; lock.unlock() }
}
