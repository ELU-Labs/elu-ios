import Foundation
import XCTest
@testable import EluAnalytics
#if canImport(UIKit)
import UIKit
#endif

final class EluStandaloneRuntimeTests: XCTestCase {
    private static let siteKey = "elu_pk_test_runtime"
    private let baseDate = Date(timeIntervalSince1970: 1_785_801_660) // 2026-08-04T00:01:00Z

    private struct CheckoutFailure: LocalizedError {
        var errorDescription: String? { "checkout failed" }
    }

    func testEnabledConfigActivatesCaptureAndFlushDrainsOneAuthorizedBatch() async throws {
        try await withTemporaryDirectory { root in
            let transport = RecordingBatchTransport()
            let clock = TestRuntimeClock(wall: baseDate)
            let runtime = try await makeRuntime(root: root, transport: transport, clock: clock)

            let outcome = await runtime.applyConfiguration(fixture("config-enabled.json"))
            guard case let .capturing(authority) = outcome else {
                return XCTFail("Expected capture authority, got \(outcome)")
            }
            XCTAssertEqual(authority.configSiteId, "site_demo")
            let phase = await runtime.currentPhase
            XCTAssertEqual(phase, .capturing)
            let hasDelivery = await runtime.hasDeliveryAuthorization
            XCTAssertTrue(hasDelivery)

            let captured = await runtime.capture("checkout", properties: ["amount": .integer(42)])
            guard case let .accepted(record, snapshot) = captured,
                  case let .event(event) = record
            else {
                return XCTFail("Expected an accepted capture, got \(captured)")
            }
            XCTAssertEqual(event.kind, .capture)
            XCTAssertEqual(event.name, "checkout")
            XCTAssertEqual(event.occurredAt, baseDate)
            XCTAssertEqual(event.properties["amount"], .integer(42))
            XCTAssertEqual(event.properties["$elu_sdk_version"], .string(EluCore.sdkVersion))
            XCTAssertEqual(event.versions.runtime.name, "elu-ios")
            XCTAssertEqual(snapshot.queuedCount, 1)

            let flushed = await runtime.flush()
            XCTAssertEqual(flushed, .triggered(.resolved(delivered: 1, terminallyDiscarded: 0)))
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.url.absoluteString, "https://ingest.elu.dev/v1/events")
            XCTAssertEqual(request.headers["Authorization"], "Bearer \(Self.siteKey)")
            XCTAssertEqual(try batchBody(request)["streamId"] as? String, "stream_runtime")
            XCTAssertEqual(try eventNames(request), ["checkout"])
            let drained = try await runtime.queueSnapshot()
            XCTAssertEqual(drained.queuedCount, 0)
            await runtime.close()
        }
    }

    func testDisabledMalformedAndRegionBlockedConfigsBlockCaptureAndSendNothing() async throws {
        let transport = RecordingBatchTransport()
        let clock = TestRuntimeClock(wall: baseDate)
        let scenarios: [(
            name: String,
            configData: Data,
            timeZoneIdentifier: String?,
            reason: EluV1CaptureAuthorityTerminalReason
        )] = [
            ("disabled", fixture("config-disabled.json"), "America/New_York", .disabled),
            ("malformed", Data("{".utf8), "America/New_York", .malformed),
            ("region", fixture("config-enabled.json"), "Europe/Paris", .privacyBlocked),
        ]

        for scenario in scenarios {
            try await withTemporaryDirectory { root in
                let runtime = try await makeRuntime(
                    root: root,
                    transport: transport,
                    clock: clock,
                    timeZoneIdentifier: scenario.timeZoneIdentifier
                )
                let outcome = await runtime.applyConfiguration(scenario.configData)
                guard case let .blocked(terminal) = outcome else {
                    return XCTFail("\(scenario.name): expected a blocked runtime, got \(outcome)")
                }
                XCTAssertEqual(terminal.reason, scenario.reason, scenario.name)
                let phase = await runtime.currentPhase
                XCTAssertEqual(phase, .blocked(scenario.reason), scenario.name)
                let hasDelivery = await runtime.hasDeliveryAuthorization
                XCTAssertFalse(hasDelivery, scenario.name)

                let captured = await runtime.capture("blocked")
                guard case .rejected(.authorityTerminal, _) = captured else {
                    return XCTFail("\(scenario.name): expected a terminal rejection, got \(captured)")
                }
                let flushed = await runtime.flush()
                XCTAssertEqual(flushed, .unavailable, scenario.name)
                let snapshot = try await runtime.queueSnapshot()
                XCTAssertEqual(snapshot.queuedCount, 0, scenario.name)
                await runtime.close()
            }
        }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testNewerConfigReplacesDeliveryAndRevocationRetiresIt() async throws {
        try await withTemporaryDirectory { root in
            let transport = RecordingBatchTransport()
            let clock = TestRuntimeClock(wall: baseDate)
            let runtime = try await makeRuntime(root: root, transport: transport, clock: clock)
            guard case .capturing = await runtime.applyConfiguration(fixture("config-enabled.json")) else {
                return XCTFail("Expected capture authority")
            }

            let newer = try config { object in
                object["revision"] = "config-2026-08-04-2"
                object["issuedAt"] = "2026-08-04T00:00:30.000Z"
                object["expiresAt"] = "2026-08-04T00:05:30.000Z"
                var limits = try XCTUnwrap(object["limits"] as? [String: Any])
                limits["eventBatchCount"] = 1
                object["limits"] = limits
            }
            guard case .capturing = await runtime.applyConfiguration(newer) else {
                return XCTFail("Expected the newer config to activate")
            }
            guard case .accepted = await runtime.capture("one"),
                  case .accepted = await runtime.capture("two")
            else {
                return XCTFail("Expected two accepted captures")
            }
            let flushed = await runtime.flush()
            XCTAssertEqual(flushed, .triggered(.resolved(delivered: 2, terminallyDiscarded: 0)))
            let requests = await transport.recordedRequests()
            XCTAssertEqual(try requests.map { try eventNames($0) }, [["one"], ["two"]])

            let revoked = try config(from: "config-disabled.json") { object in
                object["revision"] = "config-revoked"
                object["issuedAt"] = "2026-08-04T00:00:45.000Z"
                object["expiresAt"] = "2026-08-04T00:05:45.000Z"
                object["status"] = "revoked"
            }
            let terminated = await runtime.applyConfiguration(revoked)
            guard case let .blocked(terminal) = terminated else {
                return XCTFail("Expected revocation to block the runtime, got \(terminated)")
            }
            XCTAssertEqual(terminal.reason, .revoked)
            let hasDelivery = await runtime.hasDeliveryAuthorization
            XCTAssertFalse(hasDelivery)
            let flushedAfterRevocation = await runtime.flush()
            XCTAssertEqual(flushedAfterRevocation, .unavailable)
            await runtime.close()
        }
    }

    func testExceptionAndScreenCapturesCarryTheirKindsAndDerivedProperties() async throws {
        try await withTemporaryDirectory { root in
            let runtime = try await makeRuntime(
                root: root,
                transport: RecordingBatchTransport(),
                clock: TestRuntimeClock(wall: baseDate)
            )
            guard case .capturing = await runtime.applyConfiguration(fixture("config-enabled.json")) else {
                return XCTFail("Expected capture authority")
            }

            let exception = await runtime.captureException(
                CheckoutFailure(),
                properties: ["screen": .string("Checkout")]
            )
            guard case let .accepted(exceptionRecord, _) = exception,
                  case let .event(exceptionEvent) = exceptionRecord
            else {
                return XCTFail("Expected an accepted exception capture, got \(exception)")
            }
            XCTAssertEqual(exceptionEvent.kind, .exception)
            XCTAssertEqual(exceptionEvent.name, EluExceptionSerializer.eventName)
            XCTAssertEqual(
                exceptionEvent.properties[EluExceptionSerializer.typeProperty],
                .string("CheckoutFailure")
            )
            XCTAssertEqual(
                exceptionEvent.properties[EluExceptionSerializer.messageProperty],
                .string("checkout failed")
            )
            XCTAssertEqual(exceptionEvent.properties["screen"], .string("Checkout"))
            guard case .array? = exceptionEvent.properties[EluExceptionSerializer.listProperty] else {
                return XCTFail("Expected an exception list")
            }

            let screen = await runtime.screen("Checkout", properties: ["tab": .string("cart")])
            guard case let .accepted(screenRecord, _) = screen,
                  case let .event(screenEvent) = screenRecord
            else {
                return XCTFail("Expected an accepted screen capture, got \(screen)")
            }
            XCTAssertEqual(screenEvent.kind, .screen)
            XCTAssertEqual(screenEvent.name, "Checkout")
            XCTAssertEqual(
                screenEvent.properties[EluStandaloneRuntime.screenNameProperty],
                .string("Checkout")
            )
            XCTAssertEqual(screenEvent.properties["tab"], .string("cart"))
            XCTAssertEqual(screenEvent.sessionId, exceptionEvent.sessionId)
            await runtime.close()
        }
    }

    func testLifecycleSinkOrdersApplicationEventsAndBackgroundsTheSession() async throws {
        try await withTemporaryDirectory { root in
            let transport = RecordingBatchTransport()
            let clock = TestRuntimeClock(wall: baseDate)
            let runtime = try await makeRuntime(root: root, transport: transport, clock: clock)
            guard case .capturing = await runtime.applyConfiguration(fixture("config-enabled.json")) else {
                return XCTFail("Expected capture authority")
            }

            let sink = runtime.lifecycleSink()
            sink.applicationForegrounded(at: baseDate, fromBackground: false)
            sink.screenViewed("HomeViewController", at: baseDate)
            sink.applicationBackgrounded(at: baseDate)
            await sink.drain()
            try await awaitCondition { try await runtime.queueSnapshot().queuedCount == 0 }

            // The foreground pass may deliver the first event before the rest
            // are queued, so the records are collected across every request.
            let requests = await transport.recordedRequests()
            let events = try requests.flatMap { try batchEvents($0) }
            XCTAssertEqual(
                try events.map { try XCTUnwrap($0["name"] as? String) },
                [
                    EluStandaloneRuntime.applicationOpenedEvent,
                    "HomeViewController",
                    EluStandaloneRuntime.applicationBackgroundedEvent,
                ]
            )
            XCTAssertEqual(events[0]["kind"] as? String, "capture")
            XCTAssertEqual(
                (events[0]["properties"] as? [String: Any])?[EluStandaloneRuntime.fromBackgroundProperty] as? Bool,
                false
            )
            XCTAssertEqual(events[1]["kind"] as? String, "screen")
            XCTAssertEqual(
                (events[1]["properties"] as? [String: Any])?[EluStandaloneRuntime.screenNameProperty] as? String,
                "HomeViewController"
            )
            XCTAssertEqual(Set(try events.map { try XCTUnwrap($0["sessionId"] as? String) }).count, 1)

            let snapshot = try await runtime.queueSnapshot()
            XCTAssertEqual(snapshot.identity.session?.lifecycle, .background)
            XCTAssertEqual(snapshot.identity.session?.backgroundedAt, baseDate)
            await runtime.close()
        }
    }

    func testConcurrentCapturesAreSerializedIntoOneOrderedStream() async throws {
        try await withTemporaryDirectory { root in
            let transport = RecordingBatchTransport()
            let runtime = try await makeRuntime(
                root: root,
                transport: transport,
                clock: TestRuntimeClock(wall: baseDate)
            )
            guard case .capturing = await runtime.applyConfiguration(fixture("config-enabled.json")) else {
                return XCTFail("Expected capture authority")
            }

            let acceptedCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for index in 0 ..< 40 {
                    group.addTask {
                        if case .accepted = await runtime.capture("event-\(index)") {
                            return true
                        }
                        return false
                    }
                }
                var count = 0
                for await wasAccepted in group where wasAccepted {
                    count += 1
                }
                return count
            }
            XCTAssertEqual(acceptedCount, 40)

            let flushed = await runtime.flush()
            XCTAssertEqual(flushed, .triggered(.resolved(delivered: 40, terminallyDiscarded: 0)))
            let requests = await transport.recordedRequests()
            let sequences = try requests.flatMap { request in
                try batchEvents(request).map { try XCTUnwrap(($0["sequence"] as? NSNumber)?.int64Value) }
            }
            XCTAssertEqual(sequences, (0 ..< 40).map { Int64($0) })
            await runtime.close()
        }
    }

    func testRestartResendsTheIdenticalBatchBytes() async throws {
        try await withTemporaryDirectory { root in
            let clock = TestRuntimeClock(wall: baseDate)
            let failing = RecordingBatchTransport(replies: [.network])
            let first = try await makeRuntime(root: root, transport: failing, clock: clock)
            guard case .capturing = await first.applyConfiguration(fixture("config-enabled.json")) else {
                return XCTFail("Expected capture authority")
            }
            guard case .accepted = await first.capture("durable", properties: ["attempt": .integer(1)]) else {
                return XCTFail("Expected an accepted capture")
            }
            let firstFlush = await first.flush()
            guard case .triggered(.deferred) = firstFlush else {
                return XCTFail("Expected a deferred retry, got \(firstFlush)")
            }
            let preserved = try await first.queueSnapshot()
            XCTAssertEqual(preserved.queuedCount, 1)
            await first.close()

            let accepting = RecordingBatchTransport()
            let second = try await makeRuntime(root: root, transport: accepting, clock: clock)
            guard case .capturing = await second.applyConfiguration(fixture("config-enabled.json")) else {
                return XCTFail("Expected capture authority after restart")
            }
            let secondFlush = await second.flush()
            XCTAssertEqual(secondFlush, .triggered(.resolved(delivered: 1, terminallyDiscarded: 0)))

            let failingRequests = await failing.recordedRequests()
            let acceptingRequests = await accepting.recordedRequests()
            let firstRequest = try XCTUnwrap(failingRequests.first)
            let secondRequest = try XCTUnwrap(acceptingRequests.first)
            XCTAssertEqual(failingRequests.count, 1)
            XCTAssertEqual(acceptingRequests.count, 1)
            XCTAssertEqual(secondRequest.body, firstRequest.body)
            XCTAssertEqual(secondRequest.headers, firstRequest.headers)
            XCTAssertEqual(secondRequest.url, firstRequest.url)
            XCTAssertEqual(try eventNames(secondRequest), ["durable"])
            let drained = try await second.queueSnapshot()
            XCTAssertEqual(drained.queuedCount, 0)
            await second.close()
        }
    }

    func testAcceptedCaptureArmsOneFlushTimerThatDeliversWithoutAnExplicitFlush() async throws {
        try await withTemporaryDirectory { root in
            let transport = RecordingBatchTransport()
            let timer = HeldSleeper()
            let clock = TestRuntimeClock(
                wall: baseDate,
                sleep: { nanoseconds in try await timer.sleep(nanoseconds) }
            )
            let runtime = try await makeRuntime(
                root: root,
                transport: transport,
                clock: clock,
                flushDelayNanoseconds: 20_000_000
            )
            guard case .capturing = await runtime.applyConfiguration(fixture("config-enabled.json")) else {
                return XCTFail("Expected capture authority")
            }
            guard case .accepted = await runtime.capture("timed-one"),
                  case .accepted = await runtime.capture("timed-two")
            else {
                return XCTFail("Expected two accepted captures")
            }

            // The held timer cannot fire until it is released, so both records
            // are queued before the single armed pass runs.
            try await awaitCondition { timer.requestedDelays == [20_000_000] }
            let sentBeforeTheTimerFired = await transport.recordedRequests()
            XCTAssertTrue(sentBeforeTheTimerFired.isEmpty)

            timer.release()
            try await awaitCondition { try await runtime.queueSnapshot().queuedCount == 0 }
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(try eventNames(try XCTUnwrap(requests.first)), ["timed-one", "timed-two"])
            XCTAssertEqual(timer.requestedDelays, [20_000_000])
            await runtime.close()
        }
    }

    func testCloseIsIdempotentAndRejectsFurtherWork() async throws {
        try await withTemporaryDirectory { root in
            let runtime = try await makeRuntime(
                root: root,
                transport: RecordingBatchTransport(),
                clock: TestRuntimeClock(wall: baseDate)
            )
            guard case .capturing = await runtime.applyConfiguration(fixture("config-enabled.json")) else {
                return XCTFail("Expected capture authority")
            }

            await runtime.close()
            await runtime.close()
            let phase = await runtime.currentPhase
            XCTAssertEqual(phase, .closed)
            let hasDelivery = await runtime.hasDeliveryAuthorization
            XCTAssertFalse(hasDelivery)
            let reapplied = await runtime.applyConfiguration(fixture("config-enabled.json"))
            XCTAssertEqual(reapplied, .closed)
            let captured = await runtime.capture("after-close")
            guard case .rejected(.authorityAbsent, _) = captured else {
                return XCTFail("Expected the closed runtime to reject capture, got \(captured)")
            }
            let flushed = await runtime.flush()
            XCTAssertEqual(flushed, .unavailable)
            let backgrounded = await runtime.markBackgrounded()
            XCTAssertNil(backgrounded)

            // The site directory is released for a new owner.
            let reopened = try await makeRuntime(
                root: root,
                transport: RecordingBatchTransport(),
                clock: TestRuntimeClock(wall: baseDate)
            )
            let reopenedPhase = await reopened.currentPhase
            XCTAssertEqual(reopenedPhase, .awaitingConfiguration)
            await reopened.close()
        }
    }

    func testRuntimeRejectsAHeaderUnsafeSiteKey() async throws {
        try await withTemporaryDirectory { root in
            do {
                _ = try await EluStandaloneRuntime.make(
                    rootDirectoryURL: root,
                    siteKey: "elu pk\nbad",
                    transport: RecordingBatchTransport(),
                    backgroundHandoff: .inline
                )
                XCTFail("Expected the site key to be rejected")
            } catch let error as EluStandaloneRuntimeError {
                XCTAssertEqual(error, .invalidSiteKey)
            }
            XCTAssertTrue(EluStandaloneRuntime.isHeaderSafeSiteKey("elu_pk_live_ab.cd~ef-gh"))
            XCTAssertFalse(EluStandaloneRuntime.isHeaderSafeSiteKey(""))
            XCTAssertFalse(EluStandaloneRuntime.isHeaderSafeSiteKey(String(repeating: "a", count: 513)))
        }
    }

    #if canImport(UIKit)
    func testBackgroundHandoffRunsOneBoundedPassAndEndsTheAssertionOnce() async throws {
        try await withTemporaryDirectory { root in
            let transport = RecordingBatchTransport()
            let clock = TestRuntimeClock(wall: baseDate)
            let manager = await MainActor.run { RuntimeBackgroundTaskManager() }
            let handoff = await MainActor.run {
                EluStandaloneBackgroundHandoff.applicationBackgroundTask(manager: manager)
            }
            let runtime = try await makeRuntime(
                root: root,
                transport: transport,
                clock: clock,
                backgroundHandoff: handoff
            )
            guard case .capturing = await runtime.applyConfiguration(fixture("config-enabled.json")) else {
                return XCTFail("Expected capture authority")
            }
            guard case .accepted = await runtime.capture("before-background") else {
                return XCTFail("Expected an accepted capture")
            }

            let backgrounded = await runtime.markBackgrounded(at: baseDate.addingTimeInterval(60))
            guard case let .changed(snapshot)? = backgrounded else {
                return XCTFail("Expected the background transition to persist, got \(String(describing: backgrounded))")
            }
            XCTAssertEqual(snapshot.identity.session?.lifecycle, .background)

            try await awaitCondition { try await runtime.queueSnapshot().queuedCount == 0 }
            try await awaitCondition { await MainActor.run { manager.ended.count == 1 } }
            let began = await MainActor.run { manager.began }
            XCTAssertEqual(began, 1)
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 1)

            await runtime.markForegrounded()
            await runtime.close()
            let endedAfterClose = await MainActor.run { manager.ended.count }
            XCTAssertEqual(endedAfterClose, 1)
        }
    }
    #endif

    // MARK: - Harness

    private func makeRuntime(
        root: URL,
        transport: RecordingBatchTransport,
        clock: TestRuntimeClock,
        timeZoneIdentifier: String? = "America/New_York",
        backgroundHandoff: EluStandaloneBackgroundHandoff? = nil,
        flushDelayNanoseconds: UInt64 = EluStandaloneRuntime.defaultFlushDelayNanoseconds
    ) async throws -> EluStandaloneRuntime {
        try await EluStandaloneRuntime.make(
            rootDirectoryURL: root,
            siteKey: Self.siteKey,
            transport: transport,
            backgroundHandoff: backgroundHandoff ?? .inline,
            clock: { clock.wall() },
            continuousClock: { clock.continuous() },
            continuousBudgetConverter: { $0 },
            time: clock.source,
            randomUnit: { 0 },
            timeZoneIdentifier: { timeZoneIdentifier },
            replaySampleDraw: { 0.1 },
            flushDelayNanoseconds: flushDelayNanoseconds,
            anonymousIdGenerator: { "anon_runtime" },
            streamIdGenerator: { "stream_runtime" },
            sessionIdGenerator: { "session_\(UUID().uuidString.lowercased())" }
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

    private func config(
        from name: String = "config-enabled.json",
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
        try mutation(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func batchBody(_ request: EluV1BatchHTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    private func batchEvents(_ request: EluV1BatchHTTPRequest) throws -> [[String: Any]] {
        let records = try XCTUnwrap(batchBody(request)["records"] as? [[String: Any]])
        return try records.map { try XCTUnwrap($0["event"] as? [String: Any]) }
    }

    private func eventNames(_ request: EluV1BatchHTTPRequest) throws -> [String] {
        try batchEvents(request).map { try XCTUnwrap($0["name"] as? String) }
    }

    private func awaitCondition(
        timeoutSeconds: TimeInterval = 5,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let satisfied = try await condition()
        XCTAssertTrue(satisfied, "condition was not satisfied within \(timeoutSeconds)s")
    }

    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "elu-standalone-runtime-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

private extension EluStandaloneBackgroundHandoff {
    /// Runs the pass on the caller's task; tests that do not exercise the
    /// background window use it so nothing reaches the main actor.
    static var inline: EluStandaloneBackgroundHandoff {
        EluStandaloneBackgroundHandoff(
            start: { operation in
                await operation()
                return true
            },
            cancel: {}
        )
    }
}

private enum RuntimeTransportReply: Sendable {
    case accept
    case network
}

private struct RuntimeTransportError: Error {}

/// Accepts every batch unless a scripted reply is queued for the next request.
private actor RecordingBatchTransport: EluV1BatchHTTPTransport {
    private var replies: [RuntimeTransportReply]
    private var requests: [EluV1BatchHTTPRequest] = []

    init(replies: [RuntimeTransportReply] = []) {
        self.replies = replies
    }

    func send(_ request: EluV1BatchHTTPRequest) async throws -> EluV1BatchHTTPResponse {
        requests.append(request)
        let reply = replies.isEmpty ? RuntimeTransportReply.accept : replies.removeFirst()
        switch reply {
        case .accept:
            return try Self.acceptedResponse(for: request)
        case .network:
            throw RuntimeTransportError()
        }
    }

    func recordedRequests() -> [EluV1BatchHTTPRequest] {
        requests
    }

    private static func acceptedResponse(
        for request: EluV1BatchHTTPRequest
    ) throws -> EluV1BatchHTTPResponse {
        guard let root = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let requestId = root["requestId"] as? String,
              let streamId = root["streamId"] as? String,
              let records = root["records"] as? [[String: Any]]
        else {
            throw RuntimeTransportError()
        }
        var outcomes: [[String: Any]] = []
        var last: Int64?
        for record in records {
            guard let kind = record["kind"] as? String,
                  let payload = record[kind] as? [String: Any],
                  let sequence = (payload["sequence"] as? NSNumber)?.int64Value,
                  let recordId = payload[kind == "event" ? "eventId" : "mutationId"] as? String
            else {
                throw RuntimeTransportError()
            }
            last = sequence
            outcomes.append([
                "sequence": sequence,
                "recordId": recordId,
                "kind": kind,
                "result": "accepted",
            ])
        }
        guard let last else { throw RuntimeTransportError() }
        let acknowledgement: [String: Any] = [
            "schemaVersion": 1,
            "requestId": requestId,
            "streamId": streamId,
            "resolvedThroughSequence": last,
            "retryFromSequence": NSNull(),
            "outcomes": outcomes,
        ]
        return EluV1BatchHTTPResponse(
            status: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: acknowledgement, options: [.sortedKeys])
        )
    }
}

/// Records each requested delay and parks until the test releases it, so a
/// timer fires at a point the test chooses rather than after real time passes.
private final class HeldSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [UInt64] = []
    private var isReleased = false

    var requestedDelays: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func release() {
        lock.lock()
        isReleased = true
        lock.unlock()
    }

    func sleep(_ nanoseconds: UInt64) async throws {
        lock.lock()
        requested.append(nanoseconds)
        lock.unlock()
        while !released {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private var released: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReleased
    }
}

/// Fixed wall and continuous clocks. Sleeps park for an hour unless a test
/// supplies a real sleeper, so armed timers only fire when a test wants them.
private final class TestRuntimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wallValue: Date
    private var continuousValue: UInt64 = 1_000_000_000
    private let sleepImplementation: @Sendable (UInt64) async throws -> Void

    init(
        wall: Date,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { _ in
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    ) {
        wallValue = wall
        sleepImplementation = sleep
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

    func advance(seconds: TimeInterval) {
        lock.lock()
        wallValue = wallValue.addingTimeInterval(seconds)
        continuousValue &+= UInt64(seconds * 1_000_000_000)
        lock.unlock()
    }

    var source: EluV1BatchTimeSource {
        EluV1BatchTimeSource(
            wallNow: { [self] in self.wall() },
            monotonicNow: { [self] in self.continuous() },
            sleep: sleepImplementation
        )
    }
}

#if canImport(UIKit)
@MainActor
private final class RuntimeBackgroundTaskManager: EluV1IOSBackgroundTaskManaging {
    var began = 0
    var ended: [UIBackgroundTaskIdentifier] = []
    private var expiration: (@MainActor @Sendable () -> Void)?

    func begin(
        name _: String,
        expiration: @escaping @MainActor @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier {
        began += 1
        self.expiration = expiration
        return UIBackgroundTaskIdentifier(rawValue: began)
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
    }

    func expire() {
        expiration?()
    }
}
#endif
