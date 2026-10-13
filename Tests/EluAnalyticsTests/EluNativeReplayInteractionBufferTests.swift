import Foundation
import XCTest
@testable import EluAnalytics

final class EluNativeReplayInteractionBufferTests: XCTestCase {
    private let identity = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let base: Int64 = 1_785_888_060_000

    func testMinimumKeepsOnlyFirstLatestAndArmsOnlyAfterExactCommit() throws {
        var buffer = try EluNativeReplayInteractionBuffer(minimumDurationSeconds: 2)
        XCTAssertEqual(try buffer.appendGeometry(frame(0, 0), continuous: 0), .appended)
        XCTAssertThrowsError(try buffer.appendInteraction(.start(point(0)))) {
            XCTAssertEqual($0 as? EluNativeInteractionError, .initialCommitRequired)
        }
        XCTAssertNil(try buffer.beginSealing(graceful: true)); XCTAssertFalse(buffer.interactionsArmed)
        _ = try buffer.appendGeometry(frame(1, 1_000), continuous: 1_000_000_000)
        _ = try buffer.appendGeometry(frame(1, 2_000), continuous: 2_000_000_000)
        XCTAssertEqual(buffer.records.count, 2); XCTAssertTrue(buffer.isReady)
        let seal = try XCTUnwrap(buffer.beginSealing())
        XCTAssertEqual(seal.records.map { $0.times[0].timestamp }, [base, base + 2_000])
        XCTAssertFalse(buffer.interactionsArmed)
        XCTAssertThrowsError(try buffer.appendInteraction(.start(point(2_000)))) {
            XCTAssertEqual($0 as? EluNativeInteractionError, .pendingSeal)
        }
        try buffer.committed(seal)
        XCTAssertTrue(buffer.interactionsArmed); XCTAssertEqual(buffer.nextFrameOrdinal, 2)
        XCTAssertTrue(buffer.records.isEmpty)
    }

    func testSealFromAnotherOriginalBufferCannotCommitOrConsumePendingPrefix() throws {
        var a = try initial(), b = try initial()
        let first = try XCTUnwrap(a.beginSealing()), other = try XCTUnwrap(b.beginSealing())
        XCTAssertEqual(first.records, other.records)
        XCTAssertThrowsError(try a.committed(other)) { XCTAssertEqual($0 as? EluNativeInteractionError, .invalidSeal) }
        XCTAssertEqual(a.records, first.records); XCTAssertFalse(a.interactionsArmed)
        XCTAssertThrowsError(try a.beginSealing()) { XCTAssertEqual($0 as? EluNativeInteractionError, .pendingSeal) }
        try a.committed(first)
        XCTAssertThrowsError(try a.committed(first))
    }

    func testCapacityReservesCoordinateFreeTerminalWithoutDroppingTheAcceptedPrefix() throws {
        var buffer = try armed()
        _ = try buffer.appendInteraction(.start(point(100)))
        for index in 0..<62 { _ = try buffer.appendInteraction(.moves([point(200 + Int64(index) * 100)])) }
        let prefix = buffer.records
        XCTAssertEqual(prefix.reduce(0) { $0 + $1.logicalCost }, 63)
        XCTAssertEqual(try buffer.appendInteraction(.moves([point(6_400)])), .sealRequired)
        XCTAssertEqual(buffer.records, prefix); XCTAssertTrue(buffer.isReady)
        // The refused point is never retained; the reserved slot carries no location.
        XCTAssertEqual(try buffer.appendInteraction(.cancel(time(6_400))), .appended)
        XCTAssertEqual(buffer.records.reduce(0) { $0 + $1.logicalCost }, 64)
        let seal = try XCTUnwrap(buffer.beginSealing())
        XCTAssertEqual(seal.records.first, prefix.first); XCTAssertEqual(seal.records.last, .interaction(.cancel(time(6_400))))
        try buffer.committed(seal)
        XCTAssertTrue(buffer.records.isEmpty)
        XCTAssertThrowsError(try buffer.appendInteraction(.moves([point(6_500)])))
    }

    func testEstimatedByteCapacityReservesTerminalWithoutIncreasingTheCeiling() throws {
        var buffer = try armed()
        _ = try buffer.appendInteraction(.start(point(100)))
        let firstNodes = try (0..<8_190).map { _ in try node(UUID()) }
        var secondNodes = try (0..<8_190).map { _ in try node(UUID()) }
        let bounds = try EluNativeRect(x: 0, y: 0, width: 100, height: 40)
        secondNodes.append(.init(identity: UUID(), kind: .ordinaryText(String(repeating: "x", count: 512)),
                                 bounds: bounds, clip: bounds, style: try .init()))
        // Start + two frame headers + 16,381 nodes + 512 text bytes leave exactly
        // 256 bytes of the unchanged 8 MiB estimate for the terminal record.
        XCTAssertEqual(256 + 2 * 256 + 16_381 * 512 + 512,
                       EluNativeReplayFrameBuffer.maximumEstimatedBytes - 256)
        _ = try buffer.appendGeometry(frame(1, 200, nodes: firstNodes), continuous: 200_000_000)
        _ = try buffer.appendGeometry(frame(2, 400, nodes: secondNodes), continuous: 400_000_000)
        let prefix = buffer.records
        XCTAssertEqual(prefix.reduce(0) { $0 + $1.logicalCost }, 3)
        XCTAssertEqual(try buffer.appendInteraction(.moves([point(400, ordinal: 2)])), .sealRequired)
        XCTAssertEqual(buffer.records, prefix)
        XCTAssertEqual(try buffer.appendInteraction(.cancel(time(400))), .appended)
        let seal = try XCTUnwrap(buffer.beginSealing())
        XCTAssertEqual(seal.records.dropLast(), prefix[...])
        XCTAssertEqual(seal.records.last, .interaction(.cancel(time(400))))
        try buffer.committed(seal)
        XCTAssertTrue(buffer.records.isEmpty)
    }

    func testInitialPairEnforcesGeometryFloorBeforeMinimumBecomesReady() throws {
        var buffer = try EluNativeReplayInteractionBuffer(minimumDurationSeconds: 2)
        _ = try buffer.appendGeometry(frame(0, 0), continuous: 0)
        let original = buffer.records
        XCTAssertThrowsError(try buffer.appendGeometry(frame(1, 199), continuous: 2_000_000_000)) {
            XCTAssertEqual($0 as? EluNativeInteractionError, .invalidOrder)
        }
        XCTAssertEqual(buffer.records, original); XCTAssertFalse(buffer.isReady)
        XCTAssertThrowsError(try buffer.appendGeometry(frame(1, 2_000), continuous: 199_000_000)) {
            XCTAssertEqual($0 as? EluNativeInteractionError, .invalidOrder)
        }
        XCTAssertEqual(buffer.records, original); XCTAssertFalse(buffer.isReady)
        _ = try buffer.appendGeometry(frame(1, 200), continuous: 2_000_000_000)
        XCTAssertTrue(buffer.isReady)
        let seal = try XCTUnwrap(buffer.beginSealing())
        var encoder = try EluNativeWireframeV2Encoder(profile: .sensitiveMask())
        XCTAssertNoThrow(try encoder.encode(seal.records))
        try buffer.committed(seal)
        XCTAssertTrue(buffer.interactionsArmed)
    }

    func testCapacitySealRetainsGestureAndRejectedUnitCanRetryInOriginalOrder() throws {
        var buffer = try armed()
        _ = try buffer.appendInteraction(.start(point(100)))
        for index in 0..<62 { _ = try buffer.appendInteraction(.moves([point(200 + Int64(index) * 100)])) }
        let next = EluNativeInteraction.moves([point(6_400)])
        XCTAssertEqual(try buffer.appendInteraction(next), .sealRequired)
        let seal = try XCTUnwrap(buffer.beginSealing()); try buffer.committed(seal)
        XCTAssertEqual(try buffer.appendInteraction(next), .appended)
        XCTAssertEqual(buffer.records, [.interaction(next)])
    }

    func testSixteenGeometryFrameCapSealsEarlyWithinTheTenSecondInterval() throws {
        var buffer = try armed()
        _ = try buffer.appendInteraction(.start(point(100)))
        for ordinal in 1...16 {
            XCTAssertEqual(try buffer.appendGeometry(frame(Int64(ordinal), Int64(ordinal) * 200),
                continuous: UInt64(ordinal) * 200_000_000), .appended)
        }
        XCTAssertFalse(buffer.isReady)
        let next = try frame(17, 3_400)
        XCTAssertEqual(try buffer.appendGeometry(next, continuous: 3_400_000_000), .sealRequired)
        XCTAssertEqual(buffer.nextFrameOrdinal, 17)
        let seal = try XCTUnwrap(buffer.beginSealing()); XCTAssertEqual(seal.records.count, 17)
        try buffer.committed(seal)
        XCTAssertEqual(try buffer.appendGeometry(next, continuous: 3_400_000_000), .appended)
        XCTAssertEqual(buffer.nextFrameOrdinal, 18)
    }

    func testAggregateNodeAndEstimatedByteCapsReturnEarlySealWithoutAdvancingOrdinal() throws {
        var buffer = try armed()
        let nodes = try (0..<8_192).map { _ in try node(UUID()) }
        _ = try buffer.appendGeometry(frame(1, 1_000, nodes: nodes), continuous: 1_000_000_000)
        let before = buffer.records
        XCTAssertEqual(try buffer.appendGeometry(frame(2, 2_000, nodes: nodes), continuous: 2_000_000_000), .sealRequired)
        XCTAssertEqual(buffer.records, before); XCTAssertEqual(buffer.nextFrameOrdinal, 2)
        // Geometry estimate includes per-frame overhead, so the unchanged 8MiB
        // budget can win before the 16,384 aggregate-node ceiling.
        XCTAssertTrue(buffer.isReady)
    }

    func testOversizedSingleFrameOrMoveBatchCannotDisplaceAcceptedData() throws {
        var buffer = try armed()
        _ = try buffer.appendInteraction(.start(point(100)))
        let before = buffer.records
        let tooMany = try (0..<10_000).map { _ in try node(UUID()) }
        XCTAssertThrowsError(try buffer.appendGeometry(frame(1, 1_000, nodes: tooMany), continuous: 1_000_000_000)) {
            XCTAssertEqual($0 as? EluNativeInteractionError, .bufferLimit)
        }
        XCTAssertThrowsError(try buffer.appendInteraction(.moves((0..<11).map { point(200 + Int64($0) * 100) }))) {
            XCTAssertEqual($0 as? EluNativeInteractionError, .invalidBatch)
        }
        XCTAssertEqual(buffer.records, before)
        XCTAssertNoThrow(try buffer.appendInteraction(.cancel(time(100))))
    }

    func testActiveAndObservedScrollingGeometryCapsAtFiveHzIdleAtOneHz() throws {
        var idle = try armed()
        XCTAssertThrowsError(try idle.appendGeometry(frame(1, 999), continuous: 999_000_000))
        XCTAssertEqual(idle.nextFrameOrdinal, 1)
        _ = try idle.appendGeometry(frame(1, 1_000), continuous: 1_000_000_000)
        var active = try armed()
        _ = try active.appendInteraction(.start(point(100)))
        XCTAssertThrowsError(try active.appendGeometry(frame(1, 199), continuous: 199_000_000))
        _ = try active.appendGeometry(frame(1, 200), continuous: 200_000_000)
        _ = try active.appendInteraction(.cancel(time(200)))
        XCTAssertThrowsError(try active.appendGeometry(frame(2, 400), continuous: 400_000_000))
        _ = try active.appendGeometry(frame(2, 400), continuous: 400_000_000, scrolling: true)
        XCTAssertThrowsError(try active.appendGeometry(frame(3, 599), continuous: 599_000_000, scrolling: true))
    }

    func testIdleFlushStillUsesOriginalTenSecondContinuousBoundary() throws {
        var buffer = try armed()
        _ = try buffer.appendGeometry(frame(1, 9_999), continuous: 9_999_000_000)
        XCTAssertFalse(buffer.isReady); XCTAssertNil(try buffer.beginSealing())
        _ = try buffer.appendGeometry(frame(2, 10_999), continuous: 10_999_000_000)
        XCTAssertTrue(buffer.isReady)
        let seal = try XCTUnwrap(buffer.beginSealing()); try buffer.committed(seal)
        XCTAssertFalse(buffer.isReady)
    }

    func testBackwardClockEmptyBatchAndWrongOrdinalDoNotChangeAcceptedPrefix() throws {
        var buffer = try armed()
        _ = try buffer.appendInteraction(.start(point(100)))
        let before = buffer.records
        XCTAssertThrowsError(try buffer.appendInteraction(.moves([])))
        XCTAssertThrowsError(try buffer.appendInteraction(.end(point(99))))
        let reversed = EluNativeInteractionPoint(identity: identity, geometryOrdinal: 0,
            time: .init(timestamp: base + 200, continuous: 99_000_000), x: 10, y: 10)
        XCTAssertThrowsError(try buffer.appendInteraction(.moves([reversed])))
        XCTAssertThrowsError(try buffer.appendGeometry(frame(2, 200), continuous: 200_000_000))
        XCTAssertEqual(buffer.records, before)
    }

    func testWithdrawClearsPendingPrefixAndCannotBeReopenedByLateCommit() throws {
        var buffer = try initial()
        let seal = try XCTUnwrap(buffer.beginSealing()); buffer.withdraw()
        XCTAssertTrue(buffer.records.isEmpty); XCTAssertFalse(buffer.interactionsArmed); XCTAssertFalse(buffer.isReady)
        XCTAssertThrowsError(try buffer.committed(seal))
        XCTAssertThrowsError(try buffer.appendGeometry(frame(0, 0), continuous: 0))
        XCTAssertThrowsError(try buffer.beginSealing(graceful: true))
    }

    func testOrderedGeometryFlushesMoveBatchBeforeChangingTheTargetEpoch() throws {
        var buffer = try initial(), encoder = try EluNativeWireframeV2Encoder(profile: .sensitiveMask())
        let first = try XCTUnwrap(buffer.beginSealing())
        _ = try encoder.encode(first.records); try buffer.committed(first)
        _ = try buffer.appendInteraction(.start(point(100)))
        _ = try buffer.appendInteraction(.moves([point(200), point(300)]))
        _ = try buffer.appendGeometry(frame(1, 400), continuous: 400_000_000)
        _ = try buffer.appendInteraction(.end(point(400, ordinal: 1)))
        let seal = try XCTUnwrap(buffer.beginSealing(graceful: true))
        let chunk = try encoder.encode(seal.records)
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: chunk.data) as? [[String: Any]])
        XCTAssertEqual(objects.compactMap { ($0["timestamp"] as? NSNumber)?.int64Value },
                       [base + 100, base + 300, base + 400, base + 400])
        XCTAssertEqual(chunk.eventCount, 4); XCTAssertNil(encoder.state.activeIdentity)
        try buffer.committed(seal)
    }

    func testGeometryWithElapsedMonotonicTimeButInsufficientWireTimeIsNotRetained() throws {
        var buffer = try armed()
        _ = try buffer.appendInteraction(.start(point(100)))
        let before = buffer.records
        XCTAssertThrowsError(try buffer.appendGeometry(frame(1, 199), continuous: 200_000_000)) {
            XCTAssertEqual($0 as? EluNativeInteractionError, .invalidOrder)
        }
        XCTAssertEqual(buffer.records, before); XCTAssertEqual(buffer.nextFrameOrdinal, 1)
        _ = try buffer.appendGeometry(frame(1, 200), continuous: 200_000_000)
        XCTAssertEqual(buffer.nextFrameOrdinal, 2)
    }

    private func initial() throws -> EluNativeReplayInteractionBuffer {
        var buffer = try EluNativeReplayInteractionBuffer(minimumDurationSeconds: 0)
        _ = try buffer.appendGeometry(frame(0, 0), continuous: 0)
        return buffer
    }
    private func armed() throws -> EluNativeReplayInteractionBuffer {
        var buffer = try initial(); let seal = try XCTUnwrap(buffer.beginSealing()); try buffer.committed(seal)
        return buffer
    }
    private func time(_ offset: Int64) -> EluNativeInteractionTime {
        .init(timestamp: base + offset, continuous: UInt64(offset) * 1_000_000)
    }
    private func point(_ offset: Int64, ordinal: Int64 = 0) -> EluNativeInteractionPoint {
        .init(identity: identity, geometryOrdinal: ordinal, time: time(offset), x: 10, y: 10)
    }
    private func node(_ id: UUID) throws -> EluNativeMaskedNode {
        let bounds = try EluNativeRect(x: 0, y: 0, width: 100, height: 40)
        return .init(identity: id, kind: .rectangle, bounds: bounds, clip: bounds, style: try .init())
    }
    private func frame(_ ordinal: Int64, _ offset: Int64, nodes: [EluNativeMaskedNode]? = nil) throws -> EluNativeMaskedSnapshot {
        .init(ordinal: ordinal, timestamp: base + offset, viewport: try .init(width: 100, height: 100), nodes: try nodes ?? [node(identity)])
    }
}
