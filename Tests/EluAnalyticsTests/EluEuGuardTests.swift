import XCTest
@testable import EluAnalytics

final class EluEuGuardTests: XCTestCase {
    func testFailsClosedForMissingTimezone() {
        XCTAssertTrue(EluEuGuard.isEuTimezone(nil))
        XCTAssertTrue(EluEuGuard.isEuTimezone(""))
    }

    func testEuropePrefixAndExplicitTerritoriesAreBlocked() {
        XCTAssertTrue(EluEuGuard.isEuTimezone("Europe/Paris"))
        for identifier in EluEuGuard.euTzExtras {
            XCTAssertTrue(EluEuGuard.isEuTimezone(identifier), identifier)
        }
    }

    func testNonEuTimezoneIsAllowed() {
        XCTAssertFalse(EluEuGuard.isEuTimezone("America/Los_Angeles"))
        XCTAssertFalse(EluEuGuard.isEuTimezone("Asia/Tokyo"))
        XCTAssertFalse(EluEuGuard.isEuTimezone("Europe"))
    }
}
