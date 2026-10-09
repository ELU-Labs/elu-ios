import Foundation
import XCTest
@testable import EluAnalytics

final class EluEventFilterQueueTests: XCTestCase {
    private func make(_ filter: EluEventFilter, fault: DeliveryFault? = nil,
                      eventContext: [String: EluJSONValue] = [:]) async throws -> NativeSessionHarness {
        let h = NativeSessionHarness(try await DeliveryHarness.make(fault: fault))
        await h.queue.close()
        let clock = h.base.testClock
        h.base.queue = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: h.base.root,
            exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", endpointPolicy: h.base.endpointPolicy,
            eventFilter: filter, eventContext: eventContext, limits: h.base.limits, clock: { clock.read() }, continuousClock: { clock.ticks() },
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

    func testEventContextSitsUnderSuperAndCallPropertiesWithOrWithoutAFilter() async throws {
        let context: [String: EluJSONValue] = ["$os": .string("iOS"), "$app_version": .string("1.0"), "$lib": .string("elu-ios")]
        for filter in [EluEventFilter(), EluEventFilter(beforeSend: { event in
            XCTAssertEqual(event.properties["$os"] as? String, "iOS"); return event
        })] {
            let h = try await make(filter, eventContext: context); defer { h.base.remove() }
            _ = try await h.queue.registerStandaloneSuperProperties(["$app_version": .string("super")])
            try await h.publish()
            let result = try await h.queue.capture(command(h, properties: ["$lib": .string("call")]))
            let event = try XCTUnwrap(accepted(result))
            XCTAssertEqual(event.properties["$os"], .string("iOS"))
            XCTAssertEqual(event.properties["$app_version"], .string("super"))
            XCTAssertEqual(event.properties["$lib"], .string("call"))
            await h.queue.close()
        }
    }

    func testEventFilterCanRemoveEventContext() async throws {
        let h = try await make(.init(propertyDenylist: ["$timezone"], beforeSend: { event in
            var event = event; event.properties.removeValue(forKey: "$locale"); return event
        }), eventContext: ["$timezone": .string("UTC"), "$locale": .string("en-US"), "$os": .string("iOS")])
        defer { h.base.remove() }
        let result = try await h.queue.capture(command(h))
        let event = try XCTUnwrap(accepted(result))
        XCTAssertNil(event.properties["$timezone"]); XCTAssertNil(event.properties["$locale"])
        XCTAssertEqual(event.properties["$os"], .string("iOS"))
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
            rejected(try await h.queue.capture(command(h)), .eventFilterWithdrawn)
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

    func testMutationHookWithdrawalCannotUseLocalFallbackOrConsumeASequence() async throws {
        for boundary in ["callback-intent", "callback-source", "precommit-intent"] {
            let held = EventFilterQueueOwner(), calls = EventFilterCounter(), fault = DeliveryFault()
            let h = try await make(.init(beforeSend: { event in calls.hit(); held.action?(); return event }), fault: fault)
            defer { h.base.remove() }
            let before = try await h.queue.snapshot(), queue = h.queue, gate = h.base.gate
            if boundary == "callback-intent" { held.action = { queue.finishFlagProjectionIntent(queue.beginFlagProjectionIntent()) } }
            else if boundary == "callback-source" { held.action = { gate.close() } }
            else { fault.action = { point in
                if point == .beforeCommit { queue.finishFlagProjectionIntent(queue.beginFlagProjectionIntent()) }
            } }
            do {
                _ = try await queue.applyOwnedMutation(.identify(userId: "must-not-appear", set: ["secret": .bool(true)], setOnce: [:]),
                    versions: command(h).versions, expectedGeneration: before.generation, filterMutation: true)
                XCTFail("Withdrawn mutation must fail: \(boundary)")
            } catch { }
            let after = try await queue.snapshot()
            XCTAssertEqual(after.identity, before.identity, boundary)
            XCTAssertEqual(after.flagContext, before.flagContext, boundary)
            XCTAssertEqual(after.nextSequence, before.nextSequence, boundary)
            XCTAssertEqual(calls.count, 1)
            fault.action = nil; await queue.close()
        }
    }

    func testMutationProjectionRunsBeforeSQLAndNeverRepeatsForLocalFallback() async throws {
        let calls = EventFilterCounter(), wire = EventFilterCounter(), fault = DeliveryFault()
        let h = try await make(.init(beforeSend: { event in
            calls.hit(); var event = event; event.set = ["safe": true]; return event
        }), fault: fault); defer { h.base.remove() }
        let before = try await h.queue.snapshot()
        fault.action = { point in if point == .afterRecordInsert(0) { wire.withdraw() } }
        let after = try await h.queue.applyOwnedMutation(.identify(userId: "original", set: [:], setOnce: [:]),
            versions: command(h).versions, expectedGeneration: before.generation,
            wireGuard: { wire.current }, filterMutation: true)
        XCTAssertEqual(after.identity.userId, "original")
        XCTAssertEqual(after.flagContext.personProperties["safe"], .bool(true))
        XCTAssertEqual(after.queuedCount, 0, "Ordinary local fallback does not backfill a wire mutation")
        XCTAssertEqual(after.nextSequence, before.nextSequence); XCTAssertEqual(calls.count, 1)
        fault.action = nil; await h.queue.close()
    }

    func testAcceptedFilterContinuationRetainsSourceAndIntentButNotItsOwnProjectionGeneration() async throws {
        let h = try await make(.init(beforeSend: { event in var event = event; event.set = ["accepted": true]; return event }))
        defer { h.base.remove() }
        let attempt = EluEventFilterAttempt(allowsPersonChanges: true)
        let result = try await h.queue.capture(command(h), filterAttempt: attempt)
        guard case let .accepted(_, accepted) = result else { XCTFail("Expected accepted event"); await h.queue.close(); return }
        XCTAssertTrue(attempt.mayContinuePersonMutation())
        let after = try await h.queue.applyOwnedMutation(.setPersonProperties(set: ["accepted": .bool(true)], setOnce: [:], unset: []),
            versions: command(h).versions, expectedGeneration: accepted.generation,
            admissionGuard: { attempt.mayContinuePersonMutation() }, minimumOccurredAt: accepted.identity.updatedAt)
        XCTAssertEqual(after.queuedCount, 2)
        XCTAssertTrue(attempt.mayContinuePersonMutation(), "Own projection invalidation is not a new external intent")
        h.queue.finishFlagProjectionIntent(h.queue.beginFlagProjectionIntent())
        XCTAssertFalse(attempt.mayContinuePersonMutation())
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
