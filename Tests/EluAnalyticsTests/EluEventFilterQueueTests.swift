import Foundation
import XCTest
@testable import EluAnalytics

final class EluEventFilterQueueTests: XCTestCase {
    private func make(_ filter: EluEventFilter, fault: DeliveryFault? = nil) async throws -> NativeSessionHarness {
        let h = NativeSessionHarness(try await DeliveryHarness.make(fault: fault))
        await h.queue.close()
        let clock = h.base.testClock
        h.base.queue = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: h.base.root,
            exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", endpointPolicy: h.base.endpointPolicy,
            eventFilter: filter, limits: h.base.limits, clock: { clock.read() }, continuousClock: { clock.ticks() },
            continuousBudgetConverter: { clock.convert($0) }, configurationGate: h.base.gate, faultInjector: h.base.fault)
        try await h.publish()
        return h
    }
    private func command(_ h: NativeSessionHarness, name: String = "original", kind: EluEventKind = .capture,
                         properties: [String: EluJSONValue] = [:]) throws -> EluV1CaptureCommand {
        .init(kind: kind, name: name, occurredAt: h.base.now, properties: properties, versions: try .init(
            runtime: .init(name: "elu-ios", version: "0.2.0"), facade: .init(name: "Elu", version: "1")))
    }
    private func accepted(_ result: EluV1CaptureResult, file: StaticString = #filePath, line: UInt = #line) -> EluQueuedEvent? {
        guard case let .accepted(.event(event), _) = result else { XCTFail("Expected event: \(result)", file: file, line: line); return nil }
        return event
    }
    private func rejected(_ result: EluV1CaptureResult, _ reason: EluV1CaptureRejection,
                          file: StaticString = #filePath, line: UInt = #line) {
        guard case let .rejected(actual, _) = result else { return XCTFail("Unexpected acceptance", file: file, line: line) }
        XCTAssertEqual(actual, reason, file: file, line: line)
    }

    func testMergedPropertiesAreFilteredOnceAndDoNotReappearDuringRecordConstruction() async throws {
        let box = EventFilterCounter()
        let h = try await make(.init(propertyDenylist: ["secret"], beforeSend: { event in
            box.hit(); XCTAssertEqual(event.properties["shared"] as? String, "event")
            XCTAssertNil(event.properties["secret"])
            var event = event; event.event = "renamed"; event.properties.removeValue(forKey: "onlySuper")
            event.properties["$device_id"] = "forged"; return event
        })); defer { h.base.remove() }
        _ = try await h.queue.registerStandaloneSuperProperties(["secret": .string("hidden"), "onlySuper": .bool(true), "shared": .string("super")])
        try await h.publish()
        let result = try await h.queue.capture(command(h, properties: ["shared": .string("event")]))
        let event = try XCTUnwrap(accepted(result))
        XCTAssertEqual(event.name, "renamed"); XCTAssertEqual(box.count, 1)
        XCTAssertNil(event.properties["secret"]); XCTAssertNil(event.properties["onlySuper"])
        XCTAssertNotEqual(event.properties["$device_id"], .string("forged"))
        XCTAssertEqual(event.properties["$elu_sdk_version"], .string("0.2.0"))
        await h.queue.close()
    }

    func testDroppedFlagReportDoesNotConsumeLedgerOrSessionAndLaterReportCanSucceed() async throws {
        let box = EventFilterCounter()
        let h = try await make(.init(beforeSend: { event in box.hit(); return box.count == 1 ? nil : event })); defer { h.base.remove() }
        let initial = try await h.queue.snapshot(), report = try command(h, name: "$feature_flag_called")
        let exposure = EluFlagExposureRequest(anonymousId: initial.identity.anonymousId,
            digest: try EluFlagExposureLedger.digest(key: "flag", value: .bool(true)))
        rejected(await h.queue.captureFlagExposure(report, exposure: exposure, admissionGuard: { true }), .eventFiltered)
        let after = try await h.queue.snapshot()
        XCTAssertEqual(after.nextSequence, initial.nextSequence); XCTAssertEqual(after.identity, initial.identity)
        XCTAssertTrue(try EluFlagExposureLedger.decode(h.bytes("SELECT metadata FROM flag_exposure_state")).digests.isEmpty)
        _ = accepted(await h.queue.captureFlagExposure(report, exposure: exposure, admissionGuard: { true }))
        XCTAssertEqual(try EluFlagExposureLedger.decode(h.bytes("SELECT metadata FROM flag_exposure_state")).digests.count, 1)
        await h.queue.close()
    }

    func testStorageRollbackRetryDoesNotInvokeCustomerTwice() async throws {
        let box = EventFilterCounter(), writes = EventFilterCounter(), fault = DeliveryFault()
        let h = try await make(.init(beforeSend: { event in box.hit(); return event }), fault: fault); defer { h.base.remove() }
        fault.action = { point in
            if point == .beforeCommit { writes.hit(); if writes.count == 1 { throw EluRuntimeQueueError.faultInjected(point) } }
        }
        _ = accepted(try await h.queue.capture(command(h)))
        XCTAssertEqual(box.count, 1); XCTAssertEqual(writes.count, 2)
        let snapshot = try await h.queue.snapshot(); XCTAssertEqual(snapshot.queuedCount, 1)
        await h.queue.close()
    }

    func testOriginalIntentAndAdmissionWithdrawalDuringHookRefuseBeforeEventWrites() async throws {
        let box = EventFilterCounter()
        let h = try await make(.init(beforeSend: { event in box.withdraw(); return event })); defer { h.base.remove() }
        let initial = try await h.queue.snapshot()
        rejected(try await h.queue.capture(command(h), admissionGuard: { box.current }), .eventFilterWithdrawn)
        let after = try await h.queue.snapshot(); XCTAssertEqual(after, initial)
        await h.queue.close()
    }

    func testOriginalSourceClosureOrExpiryDuringHookCannotPersistReplacement() async throws {
        for closeSource in [true, false] {
            let held = EventFilterQueueOwner()
            let h = try await make(.init(beforeSend: { event in held.action?(); return event })); defer { h.base.remove() }
            let before = try await h.queue.snapshot()
            let gate = h.base.gate, clock = h.base.testClock
            held.action = { if closeSource { gate.close() } else { clock.advance(3_600) } }
            rejected(try await h.queue.capture(command(h)), closeSource ? .eventFilterWithdrawn : .authorityExpired)
            let after = try await h.queue.snapshot()
            XCTAssertEqual(after.identity, before.identity)
            XCTAssertEqual(after.nextSequence, before.nextSequence)
            XCTAssertEqual(after.queuedCount, 0)
            await h.queue.close()
        }
    }

    func testAutomaticExceptionAndLifecycleEventsUseSameFilterAndPersonOutputFailsClosed() async throws {
        let box = EventFilterCounter()
        let h = try await make(.init(beforeSend: { event in
            box.hit(); var event = event
            if event.event == "unsupported" { event.set = ["tier": "paid"] } else { event.properties.removeValue(forKey: "secret") }
            return event
        })); defer { h.base.remove() }
        for (kind, name) in [(EluEventKind.exception, "$exception"), (.capture, "$application_opened")] {
            let result = try await h.queue.capture(command(h, name: name, kind: kind, properties: ["secret": .string("hidden")]))
            let event = try XCTUnwrap(accepted(result))
            XCTAssertNil(event.properties["secret"])
        }
        rejected(try await h.queue.capture(command(h, name: "unsupported")), .eventFilterUnsupportedPersonChanges)
        XCTAssertEqual(box.count, 3)
        let snapshot = try await h.queue.snapshot(); XCTAssertEqual(snapshot.queuedCount, 2)
        await h.queue.close()
    }

    func testNewOriginalIntentInvalidatesHookButFinishingExistingIntentDoesNot() async throws {
        let held = EventFilterQueueOwner()
        let h = try await make(.init(beforeSend: { event in
            guard let queue = held.queue else { XCTFail("Original queue missing"); return nil }
            if event.event == "finish-existing" { held.finish() }
            else { queue.finishFlagProjectionIntent(queue.beginFlagProjectionIntent()) }
            return event
        })); defer { h.base.remove() }
        held.queue = h.queue
        held.intent = h.queue.beginFlagProjectionIntent()
        _ = accepted(try await h.queue.capture(command(h, name: "finish-existing")))
        rejected(try await h.queue.capture(command(h, name: "new-intent")), .eventFilterWithdrawn)
        let state = try await h.queue.snapshot(); XCTAssertEqual(state.queuedCount, 1)
        await h.queue.close()
    }

    func testPassiveNativeEventsCanBeDroppedButCannotBecomeActivityThroughTransform() async throws {
        let calls = EventFilterCounter()
        let h = try await make(.init(beforeSend: { event in
            if event.event == "$performance_sample" {
                calls.hit()
                if calls.count == 1 { return nil }
                var event = event; event.event = "forged-activity"; return event
            }
            return event
        })); defer { h.base.remove() }
        _ = accepted(try await h.queue.capture(command(h)))
        let before = try await h.queue.snapshot()
        rejected(try await h.queue.capturePerformanceSample(command(h, name: "$performance_sample"), admissionGuard: { true }), .eventFiltered)
        rejected(try await h.queue.capturePerformanceSample(command(h, name: "$performance_sample"), admissionGuard: { true }), .invalidEvent)
        let after = try await h.queue.snapshot()
        XCTAssertEqual(after.identity, before.identity); XCTAssertEqual(after.queuedCount, before.queuedCount)
        XCTAssertEqual(calls.count, 2)
        // The producer's passive kind/name checks remain in the original queue;
        // a filter cannot turn its draft into a session-extending manual event.
        await h.queue.close()
    }
}

private final class EventFilterQueueOwner: @unchecked Sendable {
    // Installed before capture; accessed only by the original synchronous hook.
    var queue: EluSQLiteRuntimeQueue?
    var intent: EluV1FlagProjectionIntent?
    var action: (@Sendable () -> Void)?
    func finish() { if let intent { queue?.finishFlagProjectionIntent(intent); self.intent = nil } }
}
