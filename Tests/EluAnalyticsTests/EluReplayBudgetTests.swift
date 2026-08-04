import Foundation
import XCTest
@testable import EluAnalytics

final class EluReplayBudgetTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "dev.elu.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFirstLaunchMarkerIsCreatedOnceAtInjectedTime() {
        let first = Date(timeIntervalSince1970: 123)

        XCTAssertTrue(EluDeviceMarkers.recordFirstLaunchIfNeeded(defaults: defaults, now: first))
        XCTAssertFalse(
            EluDeviceMarkers.recordFirstLaunchIfNeeded(
                defaults: defaults,
                now: Date(timeIntervalSince1970: 999)
            )
        )
        XCTAssertEqual(defaults.double(forKey: EluDeviceMarkers.firstLaunchKey), 123_000)
    }

    func testBudgetStampIsStableWithinSession() {
        let initial = EluDeviceMarkers.budgetStamp(
            sessionId: "session-a",
            defaults: defaults,
            now: Date(timeIntervalSince1970: 10)
        )
        let repeated = EluDeviceMarkers.budgetStamp(
            sessionId: "session-a",
            defaults: defaults,
            now: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(initial, 10_000)
        XCTAssertEqual(repeated, initial)
    }

    func testBudgetStampPrunesOldestSessions() {
        for index in 0 ..< 7 {
            _ = EluDeviceMarkers.budgetStamp(
                sessionId: "session-\(index)",
                defaults: defaults,
                now: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let stored = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(EluDeviceMarkers.budgetKeyPrefix)
        }
        XCTAssertEqual(stored.count, EluDeviceMarkers.budgetStampLimit)
        XCTAssertFalse(stored.contains(EluDeviceMarkers.budgetKeyPrefix + "session-0"))
        XCTAssertFalse(stored.contains(EluDeviceMarkers.budgetKeyPrefix + "session-1"))
        XCTAssertTrue(stored.contains(EluDeviceMarkers.budgetKeyPrefix + "session-6"))
    }
}
