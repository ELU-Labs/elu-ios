import Foundation
import XCTest
@testable import EluAnalytics

final class EluNativeReplayCaptureOwnerTests: XCTestCase {
    func testCaptureTimestampUsesExactFloorAndValidEpochBounds() throws {
        XCTAssertEqual(try EluNativeReplayCaptureClock.milliseconds(Date(timeIntervalSince1970: 1.5)), 1_500)
        XCTAssertEqual(try EluNativeReplayCaptureClock.milliseconds(Date(timeIntervalSince1970: 1.125)), 1_125)
        XCTAssertEqual(try EluNativeReplayCaptureClock.milliseconds(Date(timeIntervalSince1970: 253_402_300_799.5)), 253_402_300_799_500)
        XCTAssertThrowsError(try EluNativeReplayCaptureClock.milliseconds(Date(timeIntervalSince1970: 0)))
        XCTAssertThrowsError(try EluNativeReplayCaptureClock.milliseconds(Date(timeIntervalSince1970: -1)))
        XCTAssertThrowsError(try EluNativeReplayCaptureClock.milliseconds(Date(timeIntervalSince1970: .infinity)))
    }

    func testCaptureAdmissionAcceptsExactStartBucketAndRejectsPreviousBucket() throws {
        let original = try EluV1Timestamp("2026-09-09T12:00:00.123456789Z")
        let same = try EluV1Timestamp("2026-09-09T12:00:00.123Z")
        let earlier = try EluV1Timestamp("2026-09-09T12:00:00.122Z")
        XCTAssertLessThan(same, original) // Previous direct comparison rejected this lawful precision.
        XCTAssertTrue(try EluNativeReplayCaptureClock.admits(startedAt: same, endedAt: same, after: original))
        XCTAssertFalse(try EluNativeReplayCaptureClock.admits(startedAt: earlier, endedAt: same, after: original))
        XCTAssertEqual(original, try EluV1Timestamp("2026-09-09T12:00:00.123456789Z"))
    }

    func testCaptureAdmissionKeepsSecondAndDayBoundariesExact() throws {
        for start in ["2026-09-09T12:00:00.000000001Z", "2026-09-10T00:00:00.000000001Z"] {
            let exact = try EluV1Timestamp(start), bucket = try EluV1Timestamp(start.replacingOccurrences(of: ".000000001", with: ".000"))
            let previous = try EluV1Timestamp(start.contains("12:00") ? "2026-09-09T11:59:59.999Z" : "2026-09-09T23:59:59.999Z")
            XCTAssertTrue(try EluNativeReplayCaptureClock.admits(startedAt: bucket, endedAt: bucket, after: exact))
            XCTAssertFalse(try EluNativeReplayCaptureClock.admits(startedAt: previous, endedAt: bucket, after: exact))
        }
    }

    func testCaptureAdmissionRejectsSubmillisecondWireEndpoints() throws {
        let start = try EluV1Timestamp("2026-09-09T12:00:00.123Z")
        let fractional = try EluV1Timestamp("2026-09-09T12:00:00.123000001Z")
        let zeroPadded = try EluV1Timestamp("2026-09-09T12:00:00.123000000Z")
        XCTAssertFalse(try EluNativeReplayCaptureClock.admits(startedAt: fractional, endedAt: fractional, after: start))
        XCTAssertFalse(try EluNativeReplayCaptureClock.admits(startedAt: start, endedAt: fractional, after: start))
        XCTAssertTrue(try EluNativeReplayCaptureClock.admits(startedAt: zeroPadded, endedAt: zeroPadded, after: start))
    }

    func testMinimumRetainsOriginalInitialAndOnlyLatestWithoutConsumingDiscardedOrdinals() throws {
        var buffer = try EluNativeReplayFrameBuffer(minimumDurationSeconds: 3)
        let initial = try frame(0, timestamp: 100)
        try buffer.append(initial, continuous: 10)
        XCTAssertFalse(buffer.isReady)
        XCTAssertThrowsError(try buffer.beginSealing())
        for second in 1 ... 2 {
            XCTAssertEqual(buffer.nextFrameOrdinal, 1)
            try buffer.append(frame(1, timestamp: 100 + Int64(second)), continuous: 10 + UInt64(second) * 1_000_000_000)
            XCTAssertFalse(buffer.isReady)
            XCTAssertEqual(buffer.frames.count, 2)
            XCTAssertEqual(buffer.frames[0], initial)
        }
        let latest = try frame(1, timestamp: 500)
        try buffer.append(latest, continuous: 3_000_000_010)
        XCTAssertEqual(try buffer.beginSealing(), [initial, latest])
        try buffer.committed()
        XCTAssertEqual(buffer.nextFrameOrdinal, 2)
        XCTAssertTrue(buffer.frames.isEmpty)
    }

    func testOriginalContinuousTimeControlsThresholdEvenWithStalledWall() throws {
        var buffer = try EluNativeReplayFrameBuffer(minimumDurationSeconds: 1)
        try buffer.append(frame(0, timestamp: 100), continuous: 5)
        try buffer.append(frame(1, timestamp: 100), continuous: 1_000_000_004)
        XCTAssertFalse(buffer.isReady)
        try buffer.append(frame(1, timestamp: 100), continuous: 1_000_000_005)
        XCTAssertTrue(buffer.isReady)
        XCTAssertEqual(try buffer.beginSealing().map(\.timestamp), [100, 100])
    }

    func testZeroMinimumEmitsOnlyInitialAndSuffixFlushKeepsContiguousOrdinals() throws {
        var buffer = try EluNativeReplayFrameBuffer(minimumDurationSeconds: 0)
        try buffer.append(frame(0), continuous: 1)
        XCTAssertEqual(try buffer.beginSealing().map(\.ordinal), [0])
        try buffer.committed()
        for ordinal in 1 ... 10 {
            try buffer.append(frame(Int64(ordinal)), continuous: 1 + UInt64(ordinal) * 1_000_000_000)
            XCTAssertEqual(buffer.isReady, ordinal == 10)
        }
        XCTAssertEqual(try buffer.beginSealing().map(\.ordinal), (1 ... 10).map(Int64.init))
        try buffer.committed()
        XCTAssertEqual(buffer.nextFrameOrdinal, 11)
    }

    func testWithdrawalBeforeThresholdDiscardsUnsealedPrefixPermanently() throws {
        var buffer = try EluNativeReplayFrameBuffer(minimumDurationSeconds: 30)
        try buffer.append(frame(0), continuous: 0)
        try buffer.append(frame(1), continuous: 29_000_000_000)
        buffer.withdraw()
        XCTAssertTrue(buffer.frames.isEmpty)
        XCTAssertThrowsError(try buffer.beginSealing())
        XCTAssertThrowsError(try buffer.append(frame(0), continuous: 60_000_000_000))
    }

    func testClockAndOrdinalFailuresRetireInsteadOfSilentlyDroppingFrames() throws {
        for failure in 0 ... 2 {
            var buffer = try EluNativeReplayFrameBuffer(minimumDurationSeconds: 1)
            try buffer.append(frame(0, timestamp: 100), continuous: 10)
            XCTAssertThrowsError(try buffer.append(frame(failure == 0 ? 2 : 1,
                timestamp: failure == 1 ? 99 : 100), continuous: failure == 2 ? 9 : 11))
            XCTAssertTrue(buffer.frames.isEmpty)
            XCTAssertFalse(buffer.isReady)
            XCTAssertThrowsError(try buffer.append(frame(0), continuous: 20))
        }
    }

    func testNodeAndSnapshotCapacityFailureCannotProduceTruncatedPrefix() throws {
        var nodes = try EluNativeReplayFrameBuffer(minimumDurationSeconds: 30)
        try nodes.append(frame(0, nodeCount: 9_999), continuous: 0)
        XCTAssertThrowsError(try nodes.append(frame(1, nodeCount: 9_999), continuous: 1))
        XCTAssertTrue(nodes.frames.isEmpty)
        var snapshots = try EluNativeReplayFrameBuffer(minimumDurationSeconds: 0)
        try snapshots.append(frame(0), continuous: 0)
        _ = try snapshots.beginSealing(); try snapshots.committed()
        for ordinal in 1 ... 16 { try snapshots.append(frame(Int64(ordinal)), continuous: UInt64(ordinal)) }
        XCTAssertThrowsError(try snapshots.append(frame(17), continuous: 17))
        XCTAssertTrue(snapshots.frames.isEmpty)
    }

    func testPendingSealingCannotAdmitOrCaptureASuffix() throws {
        var buffer = try EluNativeReplayFrameBuffer(minimumDurationSeconds: 0)
        try buffer.append(frame(0), continuous: 0)
        let original = try buffer.beginSealing()
        XCTAssertThrowsError(try buffer.beginSealing())
        XCTAssertThrowsError(try buffer.append(frame(1), continuous: 1))
        XCTAssertThrowsError(try buffer.committed())
        XCTAssertEqual(original.map(\.ordinal), [0])
    }

    private func frame(_ ordinal: Int64, timestamp: Int64 = 100, nodeCount: Int = 0) throws -> EluNativeMaskedSnapshot {
        let rect = try EluNativeRect(x: 0, y: 0, width: 10, height: 10)
        let style = try EluNativeStyle()
        let nodes = (0 ..< nodeCount).map { _ in
            EluNativeMaskedNode(identity: UUID(), kind: .rectangle, bounds: rect, clip: rect, style: style)
        }
        return EluNativeMaskedSnapshot(ordinal: ordinal, timestamp: timestamp,
            viewport: try EluNativeViewport(width: 100, height: 100), nodes: nodes)
    }
}
