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
}
