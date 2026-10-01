import Foundation
import XCTest
@testable import EluAnalytics

final class EluNativeReplayInteractionMailboxTests: XCTestCase {
    private let identity = UUID()
    private func point(_ value: Int64) -> EluNativeInteractionPoint {
        .init(identity: identity, geometryOrdinal: 0,
            time: .init(timestamp: 1_000 + value, continuous: UInt64(value) * 1_000_000), x: 1, y: 2)
    }

    func testOrderedDrainPreservesGestureAndClockAcrossTransfers() {
        let box = EluNativeReplayInteractionMailbox()
        XCTAssertEqual(box.offer(.start(point(0))), .retained)
        XCTAssertEqual(box.offer(.moves([point(100), point(200)])), .retained)
        XCTAssertEqual(box.drain(), [.start(point(0)), .moves([point(100), point(200)])])
        XCTAssertEqual(box.offer(.moves([point(150)])), .refused)
        XCTAssertEqual(box.offer(.end(point(300))), .retained)
        XCTAssertEqual(box.drain(), [.end(point(300))])
        XCTAssertEqual(box.offer(.end(point(400))), .refused)
    }

    func testFullNonterminalBudgetRetainsReservedCoordinateFreeCancel() {
        let box = EluNativeReplayInteractionMailbox()
        XCTAssertEqual(box.offer(.start(point(0))), .retained)
        for index in 1 ... 62 { XCTAssertEqual(box.offer(.moves([point(Int64(index) * 100)])), .retained) }
        XCTAssertEqual(box.offer(.moves([point(6_300)])), .cancelled)
        let values = box.drain()
        XCTAssertEqual(values.reduce(0) { $0 + $1.logicalCost }, 64)
        XCTAssertEqual(values.last, .cancel(point(6_300).time))
        XCTAssertFalse(values.contains(.moves([point(6_300)])))
        XCTAssertEqual(box.offer(.moves([point(6_400)])), .refused)
    }

    func testTerminalAtCapacityAndWithdrawalDoNotRevive() {
        let box = EluNativeReplayInteractionMailbox()
        XCTAssertEqual(box.offer(.start(point(0))), .retained)
        for index in 1 ... 62 { XCTAssertEqual(box.offer(.moves([point(Int64(index) * 100)])), .retained) }
        XCTAssertEqual(box.offer(.end(point(6_300))), .retained)
        XCTAssertEqual(box.drain().reduce(0) { $0 + $1.logicalCost }, 64)
        XCTAssertEqual(box.offer(.start(point(6_400))), .retained)
        box.withdraw()
        XCTAssertEqual(box.drain(), [])
        XCTAssertEqual(box.offer(.start(point(6_500))), .refused)
    }

    func testMovesCoalesceOnlyWithinOriginalOrdinalAndTimeWindow() {
        let box = EluNativeReplayInteractionMailbox()
        XCTAssertEqual(box.offer(.start(point(0))), .retained)
        XCTAssertEqual(box.offer(.moves([point(100)])), .retained)
        XCTAssertEqual(box.offer(.moves([point(200)])), .retained)
        XCTAssertEqual(box.drain(), [.start(point(0)), .moves([point(100), point(200)])])
        XCTAssertEqual(box.offer(.moves([point(300)])), .retained)
        let changed = EluNativeInteractionPoint(identity: identity, geometryOrdinal: 1,
            time: point(400).time, x: 1, y: 2)
        XCTAssertEqual(box.offer(.moves([changed])), .retained)
        XCTAssertEqual(box.drain(), [.moves([point(300)]), .moves([changed])])
    }

    func testInvalidBatchAndClockConsumeNoMailboxCapacity() {
        let box = EluNativeReplayInteractionMailbox()
        XCTAssertEqual(box.offer(.start(point(100))), .retained)
        XCTAssertEqual(box.offer(.moves([])), .refused)
        XCTAssertEqual(box.offer(.moves((0 ... 10).map { point(Int64($0 + 2) * 100) })), .refused)
        XCTAssertEqual(box.offer(.moves([point(0)])), .refused)
        let otherOrdinal = EluNativeInteractionPoint(identity: identity, geometryOrdinal: 1,
            time: point(200).time, x: 1, y: 2)
        XCTAssertEqual(box.offer(.moves([point(100), otherOrdinal])), .refused)
        XCTAssertEqual(box.offer(.moves([point(100), point(100)])), .refused)
        XCTAssertEqual(box.offer(.end(point(200))), .retained)
        XCTAssertEqual(box.drain(), [.start(point(100)), .end(point(200))])
    }
}
