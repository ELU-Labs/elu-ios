import Foundation
import XCTest
@testable import EluAnalytics

final class EluFacadeConcurrencyTests: XCTestCase {
    private struct FixtureError: Error {}

    func testFacadeDefaultsAreSafeBeforeSetup() {
        XCTAssertNil(Elu.distinctId())
        XCTAssertNil(Elu.getFeatureFlag("missing"))
        XCTAssertNil(Elu.getFeatureFlagPayload("missing"))
        XCTAssertFalse(Elu.isFeatureEnabled("missing"))
    }

    func testPreSetupCallsFromConcurrentQueuesDoNotThrowOrBlock() {
        let completed = expectation(description: "concurrent facade calls")
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: 100) { index in
                Elu.capture("event-\(index)", properties: ["index": index])
                Elu.identify("user-\(index)")
                Elu.screen("screen-\(index)")
                Elu.alias("alias-\(index)")
                Elu.register(["index": index])
                Elu.unregister("index")
                Elu.group("company", key: "company-\(index)")
                Elu.setPersonProperties(["index": index])
                Elu.setPersonPropertiesForFlags(["index": index])
                Elu.setGroupPropertiesForFlags("company", properties: ["index": index])
                Elu.captureException(FixtureError())
                Elu.reset()
                Elu.flush()
            }
            completed.fulfill()
        }

        wait(for: [completed], timeout: 5)
        XCTAssertNil(Elu.distinctId())
    }

    func testReloadCompletionBeforeSetupIsDeliveredOnceOnMainQueue() {
        let completed = expectation(description: "reload completion")
        var callCount = 0

        Elu.reloadFeatureFlags {
            XCTAssertTrue(Thread.isMainThread)
            callCount += 1
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(callCount, 1)
    }
}
