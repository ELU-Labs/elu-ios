import Foundation
import XCTest
@testable import EluAnalytics

final class EluNativeReplaySessionStateTests: XCTestCase {
    private typealias State = EluNativeReplaySessionState
    private let start = "2026-09-09T12:00:00.000Z"
    private let epoch = "00000000-0000-4000-8000-000000000001"
    private var key: State.Key { .init(siteId: "site_native_fixture", sessionId: "session_native_a", sessionStartedAt: start) }
    private func empty() throws -> State { try State(namespaceHash: String(repeating: "b", count: 64), streamId: "stream_native_fixture") }
    private func observed(rate: Double = 1, cap: Int = 60) throws -> State {
        var value = try empty()
        try value.observe(key: key, sampleRate: rate, maximumDurationSeconds: cap,
            wall: EluV1Timestamp(start), ownedEpoch: nil, continuousElapsed: nil)
        return value
    }
    private func canonical(_ object: Any) throws -> Data {
        try EluV1StrictCanonicalJSON.parse(JSONSerialization.data(withJSONObject: object)).canonicalData
    }

    func testFrozenSamplingVectorsAndExactThresholds() {
        let vectors = [
            (key, "fef7f57146d6c4fb3fda841531f2d29fde07b21c59a2c30e77a7c53a352365d6", false),
            (State.Key(siteId: key.siteId, sessionId: "session_native_b", sessionStartedAt: start), "f7605ee8379dbae7a12f05ad41aaa543b169fe127dfb60583fb29e3bbb6376d5", false),
            (State.Key(siteId: "site_other_fixture", sessionId: key.sessionId, sessionStartedAt: start), "3da44a1cd80b3510bfcb28b0c8229f2224d9181ea323e711ccbb4c6eca0ecf28", true),
            (State.Key(siteId: key.siteId, sessionId: key.sessionId, sessionStartedAt: "2026-09-09T12:00:00.001Z"), "b62a96922d6de1cd08093b94d72ae544bd3557fb0021ae9fccbcb33f9a6224e1", false),
        ]
        for (key, hex, half) in vectors {
            let hash = State.samplingHash(key)
            XCTAssertEqual(hash, "sha256:" + hex)
            XCTAssertFalse(State.selected(hash: hash, rate: 0))
            XCTAssertEqual(State.selected(hash: hash, rate: 0.5), half)
            XCTAssertTrue(State.selected(hash: hash, rate: 1))
        }
    }

    func testFrozenReplayIDsAndCounterExhaustionPreserveState() throws {
        var value = try empty()
        XCTAssertEqual(try value.allocateReplayID(), "replay_d59e7a6266945113868e6a1fca293d31c9ef321b6f4a0b82737857b28b6f39d3")
        XCTAssertEqual(try value.allocateReplayID(), "replay_2944a569b9f9dc7d37a1e4ac907c51d7f1279238565dc555c93add23059c58f3")
        value.nextReplayOrdinal = State.maximumOrdinal - 1
        XCTAssertEqual(try value.allocateReplayID(), "replay_696d5af91435f44f58f4be365bdd65706f771adb23b42c43f3c64346fc12d72e")
        let before = value
        XCTAssertThrowsError(try value.allocateReplayID()); XCTAssertEqual(value, before)
    }

    func testOriginalFalseNeverReopensButTrueCanBeCurrentlyRestricted() throws {
        var value = try observed(rate: 0)
        try value.observe(key: key, sampleRate: 1, maximumDurationSeconds: 60,
            wall: EluV1Timestamp(start), ownedEpoch: nil, continuousElapsed: nil)
        XCTAssertFalse(try XCTUnwrap(value.session).selected(currentRate: 1))
        XCTAssertFalse(try value.begin(epoch: epoch, wall: EluV1Timestamp(start), currentRate: 1))
        XCTAssertNil(value.session?.firstStartAt)
        let selected = try XCTUnwrap(observed().session)
        XCTAssertFalse(selected.selected(currentRate: 0.5)); XCTAssertTrue(selected.selected(currentRate: 1))
    }

    func testObservationDoesNotStartAndFirstWindowNeverRebases() throws {
        var value = try observed()
        XCTAssertNil(value.session?.firstStartAt)
        XCTAssertTrue(try value.begin(epoch: epoch, wall: EluV1Timestamp(start), currentRate: 1))
        XCTAssertFalse(try value.begin(epoch: UUID().uuidString, wall: EluV1Timestamp(start), currentRate: 1))
        XCTAssertTrue(try value.stop(key: key, firstStartAt: start, epoch: epoch,
            wall: EluV1Timestamp("2026-09-09T12:00:01.000Z"), elapsedMicroseconds: 1_000_000))
        XCTAssertTrue(try value.begin(epoch: UUID().uuidString, wall: EluV1Timestamp("2026-09-09T12:00:01.000Z"), currentRate: 1))
        XCTAssertEqual(value.session?.firstStartAt, start)
    }

    func testLowerThenRaisedAndZeroCapsNeverRefill() throws {
        var value = try observed()
        for cap in [30, 60, 0, 60] {
            try value.observe(key: key, sampleRate: 1, maximumDurationSeconds: cap,
                wall: EluV1Timestamp(start), ownedEpoch: nil, continuousElapsed: nil)
            XCTAssertLessThanOrEqual(try XCTUnwrap(value.session).maximumDurationSeconds, cap)
        }
        XCTAssertEqual(value.session?.maximumDurationSeconds, 0)
        XCTAssertFalse(try value.begin(epoch: epoch, wall: EluV1Timestamp(start), currentRate: 1))
    }

    func testOriginalWindowMicrosecondsDoNotRoundPerRefresh() throws {
        let first = try EluV1Timestamp(start)
        for index in 1 ... 10 {
            let value = index == 10 ? "2026-09-09T12:00:01.000Z" : "2026-09-09T12:00:00.\(index)00Z"
            XCTAssertEqual(State.elapsedCeilMicroseconds(from: first, to: try EluV1Timestamp(value)), Int64(index) * 100_000)
        }
        let small = try EluV1Timestamp("2026-09-09T12:00:00.0000000001Z")
        for suffix in ["2", "3"] {
            XCTAssertEqual(State.elapsedCeilMicroseconds(from: small, to: try EluV1Timestamp("2026-09-09T12:00:00.000000000\(suffix)Z")), 1)
        }
        XCTAssertEqual(State.elapsedCeilMicroseconds(from: try EluV1Timestamp("2026-09-09T12:00:00.9999999Z"),
            to: try EluV1Timestamp("2026-09-09T12:00:01.0000001Z")), 1)
        XCTAssertNil(State.elapsedCeilMicroseconds(from: first, to: try EluV1Timestamp("2026-09-09T11:59:59Z")))
        XCTAssertNil(State.elapsedCeilMicroseconds(from: try EluV1Timestamp("2016-12-31T23:59:60Z"), to: first))
        XCTAssertEqual(State.elapsedCeilMicroseconds(from: first, to: try EluV1Timestamp("2026-09-12T12:00:00Z")), State.maximumMicroseconds)
    }

    func testStopIsMaximumIdempotentAndRejectsForeignScopeBeforeClockDenial() throws {
        var value = try observed(); _ = try value.begin(epoch: epoch, wall: EluV1Timestamp(start), currentRate: 1)
        let before = value
        let foreign = State.Key(siteId: "other", sessionId: key.sessionId, sessionStartedAt: start)
        XCTAssertFalse(try value.stop(key: foreign, firstStartAt: start, epoch: epoch, wall: nil, elapsedMicroseconds: nil))
        XCTAssertEqual(value, before)
        XCTAssertTrue(try value.stop(key: key, firstStartAt: start, epoch: epoch, wall: EluV1Timestamp(start), elapsedMicroseconds: 400_000))
        let stopped = value
        XCTAssertFalse(try value.stop(key: key, firstStartAt: start, epoch: epoch, wall: nil, elapsedMicroseconds: nil))
        XCTAssertEqual(value, stopped); XCTAssertEqual(value.session?.elapsedFloorMicroseconds, 400_000)
    }

    func testRollbackAndInterruptedEpochAreSessionLocal() throws {
        var value = try observed(); _ = try value.begin(epoch: epoch, wall: EluV1Timestamp(start), currentRate: 1)
        try value.observe(key: key, sampleRate: 1, maximumDurationSeconds: 60,
            wall: EluV1Timestamp("2026-09-09T12:00:05Z"), ownedEpoch: nil, continuousElapsed: nil)
        XCTAssertEqual(value.session?.interrupted, true)
        try value.observe(key: key, sampleRate: 1, maximumDurationSeconds: 60,
            wall: EluV1Timestamp("2026-09-09T12:00:04Z"), ownedEpoch: nil, continuousElapsed: nil)
        XCTAssertEqual(value.session?.clockDenied, true)
        let next = State.Key(siteId: key.siteId, sessionId: "new-session", sessionStartedAt: "2026-09-09T12:00:06Z")
        try value.observe(key: next, sampleRate: 1, maximumDurationSeconds: 60,
            wall: EluV1Timestamp(next.sessionStartedAt), ownedEpoch: nil, continuousElapsed: nil)
        XCTAssertEqual(value.session?.clockDenied, false); XCTAssertEqual(value.session?.interrupted, false)
        XCTAssertNil(value.session?.firstStartAt)
    }

    /// A recording that started at `start` and stopped at `stoppedAt` with a continuous-clock floor.
    private func stopped(cap: Int = 60, floor: Int64, stoppedAt: String? = nil) throws -> State {
        var value = try observed(cap: cap)
        XCTAssertTrue(try value.begin(epoch: epoch, wall: EluV1Timestamp(start), currentRate: 1))
        XCTAssertTrue(try value.stop(key: key, firstStartAt: start, epoch: epoch,
            wall: EluV1Timestamp(stoppedAt ?? start), elapsedMicroseconds: floor))
        return value
    }

    func testOwnerGapChargesWallGapOnTopOfRetainedFloorWithoutRebasing() throws {
        var value = try stopped(floor: 400_000)
        let before = try XCTUnwrap(value.session), ordinal = value.nextReplayOrdinal
        XCTAssertEqual(try value.settleOwnerGap(wall: EluV1Timestamp("2026-09-09T12:00:10.000Z"), highWater: nil), .resumed)
        let after = try XCTUnwrap(value.session)
        XCTAssertEqual(after.elapsedFloorMicroseconds, 10_400_000)
        XCTAssertEqual(after.firstStartAt, before.firstStartAt); XCTAssertEqual(after.samplingHash, before.samplingHash)
        XCTAssertEqual(after.originalSampleRate, before.originalSampleRate); XCTAssertEqual(after.originalSelected, before.originalSelected)
        XCTAssertEqual(after.maximumDurationSeconds, before.maximumDurationSeconds); XCTAssertEqual(value.nextReplayOrdinal, ordinal)
        XCTAssertEqual(after.observedWallAt, "2026-09-09T12:00:10.000Z")
        XCTAssertNil(after.activeEpoch); XCTAssertFalse(after.interrupted); XCTAssertFalse(after.clockDenied)
        XCTAssertTrue(try value.begin(epoch: UUID().uuidString, wall: EluV1Timestamp("2026-09-09T12:00:10.000Z"), currentRate: 1))
        XCTAssertEqual(value.session?.firstStartAt, start); XCTAssertEqual(value.session?.elapsedFloorMicroseconds, 10_400_000)

        // A recording the previous owner never stopped is settled the same way.
        var orphan = try observed()
        XCTAssertTrue(try orphan.begin(epoch: epoch, wall: EluV1Timestamp(start), currentRate: 1))
        XCTAssertEqual(try orphan.settleOwnerGap(wall: EluV1Timestamp("2026-09-09T12:00:03.000Z"), highWater: EluV1Timestamp("2026-09-09T12:00:02.000Z")), .resumed)
        XCTAssertNil(orphan.session?.activeEpoch); XCTAssertEqual(orphan.session?.elapsedFloorMicroseconds, 3_000_000)
    }

    func testOwnerGapAdditiveTermChargesStalledWallRecording() throws {
        var value = try stopped(floor: 30_000_000, stoppedAt: "2026-09-09T12:00:10.000Z")
        XCTAssertEqual(value.session?.elapsedFloorMicroseconds, 30_000_000)
        XCTAssertEqual(try value.settleOwnerGap(wall: EluV1Timestamp("2026-09-09T12:00:15.000Z"), highWater: nil), .resumed)
        XCTAssertEqual(value.session?.elapsedFloorMicroseconds, 35_000_000, "the gap is added to the floor, not max(30 s, 15 s)")
    }

    func testOwnerGapDeniesBelowEitherMarkAndNeverClearsDenial() throws {
        let stoppedAt = "2026-09-09T12:00:10.000Z"
        let cases: [(String?, String?)] = [("2026-09-09T12:00:09.999Z", nil),
            ("2026-09-09T12:00:11.000Z", "2026-09-09T12:00:12.000Z"), (nil, nil)]
        for (wall, mark) in cases {
            var value = try stopped(floor: 400_000, stoppedAt: stoppedAt)
            let before = try XCTUnwrap(value.session)
            XCTAssertEqual(try value.settleOwnerGap(wall: wall.map { try EluV1Timestamp($0) },
                highWater: mark.map { try EluV1Timestamp($0) }), .denied)
            let denied = try XCTUnwrap(value.session)
            XCTAssertTrue(denied.clockDenied); XCTAssertTrue(denied.interrupted)
            XCTAssertEqual(denied.elapsedFloorMicroseconds, before.elapsedFloorMicroseconds)
            XCTAssertEqual(denied.observedWallAt, stoppedAt)
            XCTAssertEqual(try value.settleOwnerGap(wall: EluV1Timestamp("2026-09-09T12:01:00.000Z"), highWater: nil), .denied)
            XCTAssertEqual(value.session?.clockDenied, true)
            XCTAssertFalse(try value.begin(epoch: UUID().uuidString, wall: EluV1Timestamp("2026-09-09T12:01:00.000Z"), currentRate: 1))
        }
        // Denial leaves an orphaned recording exactly as fail-closed as before.
        var orphan = try observed()
        XCTAssertTrue(try orphan.begin(epoch: epoch, wall: EluV1Timestamp("2026-09-09T12:00:05.000Z"), currentRate: 1))
        XCTAssertEqual(try orphan.settleOwnerGap(wall: EluV1Timestamp("2026-09-09T12:00:04.000Z"), highWater: nil), .denied)
        XCTAssertEqual(orphan.session?.activeEpoch, epoch); XCTAssertEqual(orphan.session?.elapsedFloorMicroseconds, 0)
    }

    func testOwnerGapUnmovedWallIsUnprovenNotDenied() throws {
        var value = try stopped(floor: 400_000, stoppedAt: "2026-09-09T12:00:10.000Z")
        let before = try XCTUnwrap(value.session)
        XCTAssertEqual(try value.settleOwnerGap(wall: EluV1Timestamp("2026-09-09T12:00:10.0009Z"),
            highWater: EluV1Timestamp("2026-09-09T12:00:10.000Z")), .unproven)
        let unproven = try XCTUnwrap(value.session)
        XCTAssertTrue(unproven.interrupted); XCTAssertFalse(unproven.clockDenied)
        XCTAssertEqual(unproven.elapsedFloorMicroseconds, before.elapsedFloorMicroseconds)
        XCTAssertEqual(unproven.observedWallAt, before.observedWallAt)
        XCTAssertFalse(try value.begin(epoch: UUID().uuidString, wall: EluV1Timestamp("2026-09-09T12:00:10.0009Z"), currentRate: 1))
        XCTAssertEqual(try value.settleOwnerGap(wall: EluV1Timestamp("2026-09-09T12:00:10.001Z"), highWater: nil), .resumed)
        XCTAssertEqual(value.session?.interrupted, false); XCTAssertEqual(value.session?.elapsedFloorMicroseconds, 10_001_000)
    }

    func testOwnerGapNoOpForUnstartedOrUnselected() throws {
        var none = try empty(); let emptyBytes = try none.encoded()
        XCTAssertEqual(try none.settleOwnerGap(wall: nil, highWater: nil), .none)
        XCTAssertEqual(try none.encoded(), emptyBytes)
        for rate in [1.0, 0.0] {
            var value = try observed(rate: rate); let bytes = try value.encoded()
            XCTAssertEqual(value.session?.originalSelected, rate == 1)
            XCTAssertEqual(try value.settleOwnerGap(wall: nil, highWater: EluV1Timestamp("2026-09-09T13:00:00Z")), .none)
            XCTAssertEqual(try value.settleOwnerGap(wall: EluV1Timestamp("2026-09-09T12:30:00Z"), highWater: nil), .none)
            XCTAssertEqual(try value.encoded(), bytes)
        }
    }

    func testOwnerGapExhaustsBudgetWithoutRefill() throws {
        var value = try stopped(floor: 40_000_000, stoppedAt: "2026-09-09T12:00:40.000Z")
        XCTAssertEqual(try value.settleOwnerGap(wall: EluV1Timestamp("2026-09-09T12:01:10.000Z"), highWater: nil), .resumed)
        XCTAssertEqual(value.session?.remainingMicroseconds, 0)
        XCTAssertFalse(try value.begin(epoch: UUID().uuidString, wall: EluV1Timestamp("2026-09-09T12:01:10.000Z"), currentRate: 1))
        try value.observe(key: key, sampleRate: 1, maximumDurationSeconds: 120,
            wall: EluV1Timestamp("2026-09-09T12:01:11.000Z"), ownedEpoch: nil, continuousElapsed: nil)
        XCTAssertEqual(value.session?.maximumDurationSeconds, 60); XCTAssertEqual(value.session?.remainingMicroseconds, 0)
        XCTAssertFalse(try value.begin(epoch: UUID().uuidString, wall: EluV1Timestamp("2026-09-09T12:01:11.000Z"), currentRate: 1))
    }

    func testClosedCanonicalMetadataRejectsMissingExtraFutureAndImpossibleFields() throws {
        let value = try observed()
        let data = try value.encoded()
        XCTAssertEqual(try State.decode(data), value)
        var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for name in root.keys { var next = root; next.removeValue(forKey: name); XCTAssertThrowsError(try State.decode(canonical(next))) }
        let session = root["session"] as! [String: Any]
        for name in session.keys { var next = session; next.removeValue(forKey: name); var all = root; all["session"] = next; XCTAssertThrowsError(try State.decode(canonical(all))) }
        for (name, replacement) in [("clockDenied", "false" as Any), ("elapsedFloorSeconds", 1), ("originalSelected", false), ("firstStartAt", "2026-09-09T11:00:00Z")] {
            var next = session; next[name] = replacement; var all = root; all["session"] = next
            XCTAssertThrowsError(try State.decode(canonical(all)))
        }
        root["schemaVersion"] = 2; XCTAssertThrowsError(try State.decode(canonical(root)))
        XCTAssertThrowsError(try State.decode(data + Data(" ".utf8)))
        XCTAssertThrowsError(try State.decode(Data(repeating: 32, count: State.maximumBytes + 1)))
        var duplicate = String(decoding: data, as: UTF8.self); duplicate.removeLast(); duplicate += ",\"schemaVersion\":1}"
        XCTAssertThrowsError(try State.decode(Data(duplicate.utf8)))
    }

    func testByteDistinctIdentifiersDoNotAlias() {
        let a = State.Key(siteId: "site-é", sessionId: "s", sessionStartedAt: start)
        let b = State.Key(siteId: "site-e\u{301}", sessionId: "s", sessionStartedAt: start)
        XCTAssertNotEqual(a, b); XCTAssertNotEqual(State.samplingHash(a), State.samplingHash(b))
    }
}
