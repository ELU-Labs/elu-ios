import Foundation
import XCTest
@testable import EluAnalytics

final class EluCallbackRegistryTests: XCTestCase {
    func testCallbacksDispatchOnSelectedQueueInRegistrationOrder() {
        var registry = EluCallbackRegistry()
        let queue = DispatchQueue(label: "dev.elu.tests.callbacks")
        let completed = expectation(description: "callbacks")
        completed.expectedFulfillmentCount = 3
        var order: [Int] = []

        for value in 1 ... 3 {
            registry.append {
                order.append(value)
                completed.fulfill()
            }
        }
        registry.dispatch(on: queue)

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(order, [1, 2, 3])
    }

    func testDispatchUsesRegistrationSnapshot() {
        var registry = EluCallbackRegistry()
        let queue = DispatchQueue(label: "dev.elu.tests.callback-snapshot")
        let first = expectation(description: "first")
        let late = expectation(description: "late")
        late.isInverted = true

        registry.append { first.fulfill() }
        registry.dispatch(on: queue)
        registry.append { late.fulfill() }

        wait(for: [first, late], timeout: 0.1)
        XCTAssertEqual(registry.count, 2)
    }
    func testGuardIsRecheckedBeforeEveryCallback() {
        var registry = EluCallbackRegistry()
        let queue = DispatchQueue(label: "dev.elu.tests.callback-guard")
        let current = CallbackPredicate()
        let finished = expectation(description: "first callback")
        let stale = expectation(description: "stale second callback")
        stale.isInverted = true
        registry.append { current.invalidate(); finished.fulfill() }
        registry.append { stale.fulfill() }
        registry.dispatch(on: queue, ifCurrent: { current.isCurrent })
        wait(for: [finished, stale], timeout: 0.1)
    }

    func testQueuedGuardDoesNotBecomeValidAgainAfterReplacement() {
        var registry = EluCallbackRegistry()
        let queue = DispatchQueue(label: "dev.elu.tests.callback-held")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.async { entered.signal(); release.wait() }
        entered.wait()
        let current = CallbackPredicate()
        let stale = expectation(description: "stale queued callback")
        stale.isInverted = true
        registry.append { stale.fulfill() }
        registry.dispatch(on: queue, ifCurrent: { current.isCurrent })
        current.invalidate()
        release.signal()
        wait(for: [stale], timeout: 0.1)
    }

    func testCancelledSubscriptionIsNotRegisteredAndCancelIsIdempotent() {
        var registry = EluFeatureFlagSubscriptionRegistry()
        let cancellation = EluFeatureFlagCancellation()
        var removals = 0
        var token: EluFeatureFlagSubscription? = EluFeatureFlagSubscription(state: cancellation) { removals += 1 }
        token?.cancel(); token?.cancel(); token = nil
        registry.append(.init(id: UUID(), cancellation: cancellation, callback: { _ in XCTFail("cancelled") }))
        XCTAssertEqual(registry.count, 0)
        XCTAssertEqual(removals, 1)
    }

    func testTokenDeinitSuppressesAlreadyQueuedSnapshot() {
        var registry = EluFeatureFlagSubscriptionRegistry()
        let queue = DispatchQueue(label: "dev.elu.tests.subscription-held")
        queue.suspend()
        let cancellation = EluFeatureFlagCancellation()
        var token: EluFeatureFlagSubscription? = EluFeatureFlagSubscription(state: cancellation, remove: {})
        XCTAssertNotNil(token)
        registry.append(.init(id: UUID(), cancellation: cancellation, callback: { _ in XCTFail("released token") }))
        registry.dispatch(.init(snapshot: .init(unavailable: .transport), isCurrent: { true }), on: queue)
        token = nil
        queue.resume(); queue.sync {}
    }

    func testSubscriptionChecksCancellationAndOriginalPredicateBeforeEveryCallback() {
        var registry = EluFeatureFlagSubscriptionRegistry()
        let queue = DispatchQueue(label: "dev.elu.tests.subscription-order")
        let current = CallbackPredicate()
        let first = EluFeatureFlagCancellation(), second = EluFeatureFlagCancellation(), third = EluFeatureFlagCancellation()
        var order: [Int] = []
        registry.append(.init(id: UUID(), cancellation: first, callback: { _ in
            order.append(1); _ = second.cancel(); current.invalidate()
        }))
        registry.append(.init(id: UUID(), cancellation: second, callback: { _ in XCTFail("cancelled second") }))
        registry.append(.init(id: UUID(), cancellation: third, callback: { _ in XCTFail("stale third") }))
        registry.dispatch(.init(snapshot: .init(unavailable: nil), isCurrent: { current.isCurrent }), on: queue)
        queue.sync {}
        XCTAssertEqual(order, [1])
    }

    func testSnapshotPreservesCompleteValuesPayloadsAndExactUnicodeKeys() throws {
        let composed = "é", decomposed = "e\u{301}"
        let response = EluV1FlagResponse(requestId: "request_snapshot", contextRevision: 1, identityRevision: 1,
            flagsRevision: "revision_snapshot", evaluatedAt: EluV1StoredTimestamp(try EluV1Timestamp("2026-08-04T00:01:01.123Z")),
            expiresAt: EluV1StoredTimestamp(try EluV1Timestamp("2026-08-04T00:04:00.000Z")),
            flags: [.init(name: composed, value: .bool(false)), .init(name: decomposed, value: .string(Array("variant".utf16))),
                    .init(name: "number", value: .number(0.5)), .init(name: "null", value: .null)],
            payloads: [.init(name: composed, value: .null), .init(name: decomposed, value: .object([
                .init(name: composed, value: .number(1)), .init(name: decomposed, value: .number(2))])),
                .init(name: "payload-only", value: .array([.bool(true)]))])
        let value = try EluFeatureFlagSnapshot(response: response, source: .remote, error: nil)
        XCTAssertTrue(value.isAvailable)
        XCTAssertEqual(value.entries.count, 4)
        guard case .bool(false)? = value.entry(forKey: composed)?.value,
              case .string("variant")? = value.entry(forKey: decomposed)?.value,
              case .number(0.5)? = value.entry(forKey: "number")?.value,
              case .null? = value.entry(forKey: "null")?.value else { return XCTFail("typed values changed") }
        XCTAssertEqual(value.entry(forKey: composed)?.payloadJSON, Data("null".utf8))
        XCTAssertNil(value.entry(forKey: "null")?.payloadJSON)
        XCTAssertNil(value.entry(forKey: "missing"))
        XCTAssertEqual(try EluV1FlagJSON.parse(value.flagsJSON), .object(response.flags.sorted { $0.name.lexicographicallyPrecedes($1.name) }))
        XCTAssertEqual(try EluV1FlagJSON.parse(value.payloadsJSON).property("payload-only"), .array([.bool(true)]))
        XCTAssertEqual(try EluV1FlagJSON.parse(XCTUnwrap(value.entry(forKey: decomposed)?.payloadJSON)).objectMembers?.count, 2)
        XCTAssertEqual(value.evaluatedAt?.timeIntervalSince1970, 1_785_801_661.123)
        XCTAssertEqual(value.requestId, "request_snapshot")
        XCTAssertEqual(value.flagsRevision, "revision_snapshot")
    }

    func testValidEmptySnapshotIsDistinctFromUnavailable() throws {
        let response = EluV1FlagResponse(requestId: "empty_request", contextRevision: 1, identityRevision: 1,
            flagsRevision: "empty_revision", evaluatedAt: EluV1StoredTimestamp(try EluV1Timestamp("2026-08-04T00:01:01Z")),
            expiresAt: EluV1StoredTimestamp(try EluV1Timestamp("2026-08-04T00:04:00Z")), flags: [], payloads: [])
        let empty = try EluFeatureFlagSnapshot(response: response, source: .remote, error: nil)
        let unavailable = EluFeatureFlagSnapshot(unavailable: .invalidResponse)
        XCTAssertTrue(empty.isAvailable); XCTAssertTrue(empty.entries.isEmpty); XCTAssertNil(empty.error)
        XCTAssertFalse(unavailable.isAvailable); XCTAssertEqual(unavailable.error, .invalidResponse)
        XCTAssertNil(unavailable.requestId); XCTAssertNil(unavailable.expiresAt)
    }

}

private final class CallbackPredicate: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
}
