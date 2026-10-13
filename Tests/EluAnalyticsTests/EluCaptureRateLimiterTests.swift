import Foundation
import XCTest
@testable import EluAnalytics

final class EluCaptureRateLimiterTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_785_888_090)

    func testSettingsDefaultsValidationFractionalRateAndBurstClamp() {
        XCTAssertEqual(EluRateLimitingOptions().eventsPerSecond, 10)
        XCTAssertEqual(EluRateLimitingOptions().eventsBurstLimit, 100)
        for invalid in [0, -1, Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(EluRateLimitingOptions(eventsPerSecond: invalid), .init())
            XCTAssertEqual(EluRateLimitingOptions(eventsPerSecond: 2, eventsBurstLimit: invalid).eventsBurstLimit, 20)
        }
        XCTAssertEqual(EluRateLimitingOptions(eventsPerSecond: 2.5, eventsBurstLimit: 1).eventsBurstLimit, 2.5)
        var mutable = EluRateLimitingOptions(); mutable.eventsPerSecond = .nan; mutable.eventsBurstLimit = -1
        XCTAssertEqual(mutable.normalized, .init())
    }

    func testConstructorRefillsWithoutConsumingAndOneWarningPerLimitedTransition() throws {
        var limiter = EluCaptureRateLimiter(settings: .init(eventsPerSecond: 1, eventsBurstLimit: 2))
        let initial = try limiter.context(stored: nil, at: origin, checkOnly: true)
        XCTAssertFalse(initial.limited); XCTAssertNil(initial.warning); XCTAssertEqual(limiter.held?.tokens, 2)
        for _ in 0..<2 { XCTAssertFalse(try limiter.context(stored: nil, at: origin, checkOnly: false).limited) }
        let first = try limiter.context(stored: nil, at: origin, checkOnly: false)
        XCTAssertTrue(first.limited)
        XCTAssertEqual(first.warning, "Analytics SDK client rate limited. Config is set to 1 events per second and 2 events burst limit.")
        XCTAssertNil(try limiter.context(stored: nil, at: origin, checkOnly: false).warning)
        XCTAssertFalse(try limiter.context(stored: nil, at: origin.addingTimeInterval(1), checkOnly: false).limited)
        XCTAssertNotNil(try limiter.context(stored: nil, at: origin.addingTimeInterval(1), checkOnly: false).warning)
    }

    func testReopenedEmptyBucketIsAlreadyLimitedAndHasNoDuplicateWarning() throws {
        var limiter = EluCaptureRateLimiter(settings: .init(eventsPerSecond: 1, eventsBurstLimit: 1))
        let stored = EluCaptureRateBucket(tokens: 0, last: origin.timeIntervalSince1970 * 1_000)
        let check = try limiter.context(stored: stored, at: origin, checkOnly: true)
        XCTAssertTrue(check.limited); XCTAssertNil(check.warning)
        XCTAssertNil(try limiter.context(stored: stored, at: origin, checkOnly: false).warning)
        XCTAssertFalse(try limiter.context(stored: stored, at: origin.addingTimeInterval(10), checkOnly: false).limited)
        XCTAssertEqual(limiter.held?.tokens, 0, "Forward refill clamps to burst before consumption")
    }

    func testBackwardWallClockCreatesDebtAndFractionalRefillDoesNotForgiveIt() throws {
        var limiter = EluCaptureRateLimiter(settings: .init(eventsPerSecond: 2.5, eventsBurstLimit: 5))
        _ = try limiter.context(stored: nil, at: origin, checkOnly: true)
        let debt = try limiter.context(stored: nil, at: origin.addingTimeInterval(-4), checkOnly: false)
        XCTAssertTrue(debt.limited); XCTAssertEqual(limiter.held?.tokens, -5)
        XCTAssertTrue(try limiter.context(stored: nil, at: origin.addingTimeInterval(-2), checkOnly: false).limited)
        XCTAssertEqual(limiter.held?.tokens, 0)
        XCTAssertFalse(try limiter.context(stored: nil, at: origin.addingTimeInterval(-1.5), checkOnly: false).limited)
        XCTAssertEqual(try XCTUnwrap(limiter.held).tokens, 0.25, accuracy: 0.00001)
    }

    func testFallbackKeepsBucketWhenStorageCannotBeReadOrWritten() throws {
        var limiter = EluCaptureRateLimiter(settings: .init(eventsPerSecond: 1, eventsBurstLimit: 1))
        _ = try limiter.context(stored: nil, at: origin, checkOnly: true)
        XCTAssertFalse(try limiter.context(stored: nil, at: origin, checkOnly: false).limited)
        XCTAssertTrue(try limiter.context(stored: nil, at: origin, checkOnly: false).limited)
        // A successful durable read has the same precedence as the browser store.
        XCTAssertFalse(try limiter.context(stored: .init(tokens: 1, last: origin.timeIntervalSince1970 * 1_000),
            at: origin, checkOnly: false).limited)
    }

    func testStoredBucketCodecRejectsForeignNoncanonicalAndNonfiniteState() throws {
        for value in [EluCaptureRateBucket(tokens: -10.5, last: 100), .init(tokens: 0, last: -5)] {
            XCTAssertEqual(try EluCaptureRateBucket.decode(value.encoded()), value)
        }
        XCTAssertNil(try EluCaptureRateBucket.decode(Data("null".utf8)))
        for invalid in ["{}", "{\"tokens\":1,\"last\":2,\"extra\":0}", "{\"tokens\":1,\"tokens\":2,\"last\":2}",
                        "{\"last\":2,\"tokens\":true}", "{\"last\":2,\"tokens\":1e999}"] {
            XCTAssertThrowsError(try EluCaptureRateBucket.decode(Data(invalid.utf8)))
        }
        XCTAssertThrowsError(try EluCaptureRateBucket(tokens: .infinity, last: 1).encoded())
    }
}
