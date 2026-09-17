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

}

private final class CallbackPredicate: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
}
