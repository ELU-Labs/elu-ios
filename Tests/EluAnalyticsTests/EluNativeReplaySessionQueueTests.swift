import Foundation
import SQLite3
import XCTest
@testable import EluAnalytics

final class EluNativeReplaySessionQueueTests: XCTestCase {
    func testBothSchemaOrdersPreserveSealedBytesEventsAndFlagStore() async throws {
        for flagsFirst in [false, true] {
            let h = try await NativeSessionHarness.make(activate: false, seedReplay: true); defer { h.base.remove() }
            let before = try await h.queue.snapshot()
            let rows = try await h.queue.storedReplayChunks()
            if flagsFirst { try await h.queue.ensureFlagSchema() }
            try await h.queue.ensureReplayDeliverySchema()
            try await h.queue.ensureNativeReplayAuthoritySchema()
            XCTAssertEqual(try h.base.schemaVersion(), flagsFirst ? 48 : 47)
            if !flagsFirst { try await h.queue.ensureFlagSchema() }
            XCTAssertEqual(try h.base.schemaVersion(), 48)
            let after = try await h.queue.snapshot(); XCTAssertEqual(before, after)
            let afterRows = try await h.queue.storedReplayChunks(); XCTAssertEqual(afterRows, rows)
            await h.queue.close(); try await h.reopen()
            try await h.queue.ensureNativeReplayAuthoritySchema()
            let reopened = try await h.queue.storedReplayChunks(); XCTAssertEqual(reopened, rows)
            let value = try await h.queue.nativeReplaySessionState(); XCTAssertNil(value.session)
            await h.queue.close()
        }
    }

    func testFalseSamplingAndZeroCapSurviveRenewalAndReopen() async throws {
        let h = try await NativeSessionHarness.make(rate: 0); defer { h.base.remove() }
        let first = try await h.observe(); XCTAssertFalse(first.currentSelected); XCTAssertNil(first.accounting.firstStartAt)
        try await h.update(rate: 1, cap: 60)
        let second = try await h.observe(); XCTAssertFalse(second.currentSelected)
        let rejected = try await h.queue.beginNativeReplayStartAccounting(second); XCTAssertNil(rejected)
        await h.queue.close(); try await h.reopen(); try await h.publish()
        let reopened = try await h.observe(); XCTAssertEqual(reopened.accounting.samplingHash, first.accounting.samplingHash)
        XCTAssertFalse(reopened.currentSelected)
        await h.queue.close()
        let z = try await NativeSessionHarness.make(); defer { z.base.remove() }
        _ = try await z.observe(); try await z.update(rate: 1, cap: 0)
        let zero = try await z.observe(); XCTAssertEqual(zero.accounting.maximumDurationSeconds, 0)
        try await z.update(rate: 1, cap: 60)
        let raised = try await z.observe(); XCTAssertEqual(raised.accounting.maximumDurationSeconds, 0)
        let noStart = try await z.queue.beginNativeReplayStartAccounting(raised); XCTAssertNil(noStart)
        await z.queue.close()
    }

    func testStalledWallTenRefreshesAndDuplicateStopDoNotRefill() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let first = try await h.observe(); XCTAssertNil(first.accounting.firstStartAt)
        let receipt = try await h.start()
        let wall = h.base.now
        for index in 1 ... 10 {
            h.base.testClock.advance(0.1); h.base.testClock.set(wall)
            let observation = try await h.observe()
            XCTAssertEqual(observation.accounting.elapsedFloorMicroseconds, Int64(index) * 100_000)
            XCTAssertEqual(observation.accounting.firstStartAt, receipt.firstStartAt)
        }
        let asyncValue1 = try await h.stop(receipt); XCTAssertTrue(asyncValue1)
        let stopped = try await h.queue.nativeReplaySessionState()
        let asyncValue2 = try await h.stop(receipt); XCTAssertFalse(asyncValue2)
        let repeated = try await h.queue.nativeReplaySessionState(); XCTAssertEqual(repeated, stopped)
        let next = try await h.start(); XCTAssertNotEqual(receipt.replayId, next.replayId)
        XCTAssertEqual(receipt.firstStartAt, next.firstStartAt)
        _ = try await h.stop(next); await h.queue.close()
    }

    func testWallLeadDoesNotRebaseOriginalContinuousWindowDuringCatchup() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let receipt = try await h.start()
        let ahead = h.base.now.addingTimeInterval(0.25)
        h.base.testClock.set(ahead)
        let lead = try await h.observe()
        XCTAssertEqual(lead.accounting.elapsedFloorMicroseconds, 250_000)
        for index in 1 ... 4 {
            h.base.testClock.advance(0.1); h.base.testClock.set(ahead)
            let current = try await h.observe()
            XCTAssertEqual(current.accounting.elapsedFloorMicroseconds, max(250_000, Int64(index) * 100_000))
        }
        _ = try await h.stop(receipt)
        let stopped = try await h.queue.nativeReplaySessionState()
        XCTAssertEqual(stopped.session?.elapsedFloorMicroseconds, 400_000)
        await h.queue.close()
    }

    func testSubmicrosecondRefreshesQuantizeAbsoluteContinuousOriginOnce() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let receipt = try await h.start(); let wall = h.base.now
        let original = h.base.testClock.ticks() / 1_000
        for _ in 1 ... 25 {
            h.base.testClock.advance(0.0000001); h.base.testClock.set(wall)
            let current = try await h.observe()
            XCTAssertEqual(current.accounting.elapsedFloorMicroseconds,
                           Int64(h.base.testClock.ticks() / 1_000 - original))
        }
        _ = try await h.stop(receipt)
        let stopped = try await h.queue.nativeReplaySessionState()
        XCTAssertEqual(stopped.session?.elapsedFloorMicroseconds, 2)
        await h.queue.close()
    }

    func testRepeatedSchemaActivationRejectsUnexpectedObjectsWithoutHealing() async throws {
        let h = try await NativeSessionHarness.make(seedReplay: true); defer { h.base.remove() }
        let metadata = try h.bytes("SELECT metadata FROM native_replay_authority")
        let count = try h.integer("SELECT count(*) FROM replay_chunks")
        try h.base.sql("CREATE TABLE unexpected_native_metadata(value INTEGER)")
        do { try await h.queue.ensureNativeReplayAuthoritySchema(); XCTFail("closed schema accepted extra table") } catch {}
        XCTAssertEqual(try h.bytes("SELECT metadata FROM native_replay_authority"), metadata)
        XCTAssertEqual(try h.integer("SELECT count(*) FROM replay_chunks"), count)
        await h.queue.close()
    }

    func testOldEpochReceiptRejectsBeforeNativeClockSampling() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        await h.queue.close()
        let samples = NativeSampleCounter()
        try await h.reopen(nanoseconds: { samples.sample($0) }); try await h.publish()
        let old = try await h.start(); _ = try await h.stop(old)
        let current = try await h.start()
        let before = try await h.queue.nativeReplaySessionState(); let count = samples.count
        let ignored = try await h.stop(old); XCTAssertFalse(ignored)
        XCTAssertEqual(samples.count, count)
        let after = try await h.queue.nativeReplaySessionState(); XCTAssertEqual(after, before)
        _ = try await h.stop(current); await h.queue.close()
    }

    func testFrozenWallReopenStaysUnprovenThenWallAdvanceResumes() async throws {
        for clean in [false, true] {
            for activate in [false, true] {
                let h = try await NativeSessionHarness.make(seedReplay: true); defer { h.base.remove() }
                let rows = try await h.queue.storedReplayChunks()
                let first = try await h.start()
                let wall = h.base.now; h.base.testClock.advance(0.4); h.base.testClock.set(wall)
                if clean { _ = try await h.stop(first) }
                await h.queue.close()
                h.base.testClock.advance(10); h.base.testClock.set(wall)
                try await h.reopen(); try await h.publish()
                if activate { try await h.queue.ensureNativeReplayAuthoritySchema() }
                // A wall clock that did not move cannot prove the gap: unproven, not denied.
                let reopened = try await h.observe()
                XCTAssertTrue(reopened.accounting.interrupted); XCTAssertFalse(reopened.accounting.clockDenied)
                XCTAssertEqual(reopened.accounting.firstStartAt, first.firstStartAt)
                XCTAssertEqual(reopened.accounting.activeEpoch == nil, clean)
                let second = try await h.queue.beginNativeReplayStartAccounting(reopened)
                XCTAssertNil(second)
                let retained = try await h.queue.storedReplayChunks(); XCTAssertEqual(retained, rows)
                if clean { XCTAssertEqual(reopened.accounting.elapsedFloorMicroseconds, 400_000) }
                // Once the wall moves, the next touch charges the gap on top of the floor and resumes.
                let ordinal = try await h.queue.nativeReplaySessionState().nextReplayOrdinal
                h.base.testClock.set(wall.addingTimeInterval(10))
                try await h.queue.ensureNativeReplayAuthoritySchema()
                let settled = try await h.ledger()
                XCTAssertFalse(settled.interrupted); XCTAssertFalse(settled.clockDenied); XCTAssertNil(settled.activeEpoch)
                XCTAssertEqual(settled.elapsedFloorMicroseconds, clean ? 10_400_000 : 10_000_000)
                let next = try await h.start()
                XCTAssertNotEqual(next.replayId, first.replayId); XCTAssertEqual(next.firstStartAt, first.firstStartAt)
                let after = try await h.queue.nativeReplaySessionState(); XCTAssertEqual(after.nextReplayOrdinal, ordinal + 1)
                let unchanged = try await h.queue.storedReplayChunks(); XCTAssertEqual(unchanged, rows)
                _ = try await h.stop(next); await h.queue.close()
            }
        }
    }

    func testSameLiveOwnerRetainsOriginalAnchorAcrossSchemaChecksAndPausedTime() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let first = try await h.start(); let wall = h.base.now
        h.base.testClock.advance(0.4); h.base.testClock.set(wall)
        try await h.queue.ensureNativeReplayAuthoritySchema()
        let active = try await h.observe(); XCTAssertFalse(active.accounting.interrupted)
        _ = try await h.stop(first)
        h.base.testClock.advance(0.6); h.base.testClock.set(wall)
        try await h.queue.ensureNativeReplayAuthoritySchema()
        let paused = try await h.observe()
        XCTAssertFalse(paused.accounting.interrupted)
        XCTAssertEqual(paused.accounting.elapsedFloorMicroseconds, 1_000_000)
        let next = try await h.start()
        XCTAssertNotEqual(next.replayId, first.replayId)
        XCTAssertEqual(next.firstStartAt, first.firstStartAt)
        _ = try await h.stop(next); await h.queue.close()
    }

    func testUnstartedSelectedSessionRemainsAvailableAfterNewOwner() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let original = try await h.observe(); XCTAssertTrue(original.currentSelected)
        XCTAssertNil(original.accounting.firstStartAt)
        await h.queue.close(); try await h.reopen(); try await h.publish()
        try await h.queue.ensureNativeReplayAuthoritySchema()
        let restored = try await h.observe()
        XCTAssertFalse(restored.accounting.interrupted)
        XCTAssertEqual(restored.accounting.samplingHash, original.accounting.samplingHash)
        let receipt = try await h.start(); _ = try await h.stop(receipt)
        await h.queue.close()
    }

    func testNewRealSessionCanRecoverInterruptedLedgerWithoutClearingAgeBarrier() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let old = try await h.start()
        await h.queue.close(); try await h.reopen(); try await h.publish()
        try await h.queue.ensureNativeReplayAuthoritySchema()
        let oldState = try await h.observe(); XCTAssertTrue(oldState.accounting.interrupted)
        let snapshot = try await h.queue.snapshot()
        _ = try await h.queue.reset(expectedGeneration: snapshot.generation)
        try await h.publish()
        guard case .accepted = await h.base.capture() else { return XCTFail("real capture must establish new session") }
        // The separate storage-age barrier stays sticky even though a budget-local session changes.
        try h.base.sql("UPDATE replay_state SET clock_denied=1,admission_enabled=0")
        let current = try await h.observe()
        XCTAssertNotEqual(current.accounting.sessionId, oldState.accounting.sessionId)
        XCTAssertFalse(current.accounting.interrupted); XCTAssertFalse(current.accounting.clockDenied)
        let pending = try await h.queue.beginNativeReplayStartAccounting(current)
        let receipt = try XCTUnwrap(pending)
        XCTAssertNotEqual(receipt.replayId, old.replayId)
        XCTAssertEqual(try h.integer("SELECT clock_denied FROM replay_state"), 1)
        _ = try await h.stop(receipt); await h.queue.close()
    }

    func testForeignOriginalReceiptsWithEqualSessionTimesCauseZeroWrites() async throws {
        let a = try await NativeSessionHarness.make(); defer { a.base.remove() }
        let b = try await NativeSessionHarness.make(); defer { b.base.remove() }
        let one = try await a.start(); let two = try await b.start()
        XCTAssertEqual(one.firstStartAt, two.firstStartAt)
        let before = try await b.queue.nativeReplaySessionState()
        a.base.gate.close()
        let result = try await b.queue.stopNativeReplayAccounting(one); XCTAssertFalse(result)
        let after = try await b.queue.nativeReplaySessionState(); XCTAssertEqual(before, after)
        _ = try await b.stop(two); _ = try await a.stop(one)
        await a.queue.close(); await b.queue.close()
    }

    func testSourceWithdrawalAndOriginalContinuousExpiryDenyStartButAllowStop() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let observation = try await h.observe(); let receipt = try await h.start()
        let wall = h.base.now; h.base.testClock.advance(600); h.base.testClock.set(wall)
        do { _ = try await h.queue.beginNativeReplayStartAccounting(observation); XCTFail("expired original source") } catch {}
        do { _ = try await h.observe(); XCTFail("expired source refreshed") } catch {}
        let asyncValue3 = try await h.stop(receipt); XCTAssertTrue(asyncValue3)
        let state = try await h.queue.nativeReplaySessionState(); XCTAssertEqual(state.session?.elapsedFloorMicroseconds, 600_000_000)
        await h.queue.close()
    }

    func testFinalTransactionSourceAndSessionBoundaryChecksRejectAdmission() async throws {
        for revoke in [false, true] {
            let fault = DeliveryFault(); let h = try await NativeSessionHarness.make(fault: fault); defer { h.base.remove() }
            let observation = try await h.observe(); let before = try await h.queue.nativeReplaySessionState()
            fault.action = { point in
                if point == .beforeCommit {
                    if revoke { h.base.gate.close() } else { h.base.testClock.advance(1_800) }
                }
            }
            do { _ = try await h.queue.beginNativeReplayStartAccounting(observation); XCTFail("late authority changed") } catch {}
            fault.action = nil
            let after = try await h.queue.nativeReplaySessionState(); XCTAssertEqual(before, after)
            await h.queue.close()
        }
    }

    func testStopSamplesAfterDelayedBeforeCommitAndKeepsClockDenialLocal() async throws {
        let fault = DeliveryFault(); let h = try await NativeSessionHarness.make(fault: fault); defer { h.base.remove() }
        let receipt = try await h.start(); let wall = h.base.now
        fault.action = { point in if point == .beforeCommit { h.base.testClock.advance(0.5); h.base.testClock.set(wall) } }
        let asyncValue4 = try await h.stop(receipt); XCTAssertTrue(asyncValue4); fault.action = nil
        let state = try await h.queue.nativeReplaySessionState(); XCTAssertEqual(state.session?.elapsedFloorMicroseconds, 500_000)
        XCTAssertEqual(try h.integer("SELECT clock_denied FROM replay_state"), 0)
        let next = try await h.start()
        h.base.testClock.set(wall.addingTimeInterval(-1))
        let asyncValue5 = try await h.stop(next); XCTAssertTrue(asyncValue5)
        let denied = try await h.queue.nativeReplaySessionState(); XCTAssertEqual(denied.session?.clockDenied, true)
        XCTAssertEqual(try h.integer("SELECT clock_denied FROM replay_state"), 0)
        await h.queue.close()
    }

    func testProvenNoncommitAndAmbiguousCommitPreserveOriginalPolicy() async throws {
        for point in [EluRuntimeQueueFaultPoint.afterBegin, .afterStateRead, .beforeCommit, .afterCommit] {
            let fault = DeliveryFault(); let h = try await NativeSessionHarness.make(fault: fault); defer { h.base.remove() }
            let before = try await h.queue.nativeReplaySessionState()
            fault.action = { if $0 == point { throw EluRuntimeQueueError.faultInjected(point) } }
            do { _ = try await h.observe(); XCTFail("fault did not fire") }
            catch { XCTAssertEqual(error as? EluRuntimeQueueError, point == .afterCommit ? .ambiguousCommit : .provenNotCommitted) }
            fault.action = nil
            if point == .afterCommit {
                do { _ = try await h.queue.nativeReplaySessionState(); XCTFail("poisoned owner") } catch {}
            } else {
                let current = try await h.queue.nativeReplaySessionState(); XCTAssertEqual(current, before)
                _ = try await h.observe()
            }
            await h.queue.close()
        }
    }

    func testMissingForeignAndFutureMetadataRejectReopenWithoutDeletingReplay() async throws {
        for kind in 0 ... 3 {
            let h = try await NativeSessionHarness.make(seedReplay: true); defer { h.base.remove() }
            _ = try await h.observe()
            let original = try h.base.storedBodyFromDisk(); await h.queue.close()
            switch kind {
            case 0: try h.base.sql("DELETE FROM native_replay_authority")
            case 1: try h.base.sql("UPDATE native_replay_authority SET metadata=CAST('{\"schemaVersion\":2}' AS BLOB)")
            case 2: try h.base.sql("PRAGMA user_version=9")
            default:
                var metadata = try JSONSerialization.jsonObject(with: h.bytes("SELECT metadata FROM native_replay_authority")) as! [String: Any]
                metadata["namespaceHash"] = String(repeating: "c", count: 64)
                try h.replaceMetadata(EluV1StrictCanonicalJSON.parse(JSONSerialization.data(withJSONObject: metadata)).canonicalData)
            }
            do { try await h.reopen(); XCTFail("invalid native storage reopened") } catch {}
            XCTAssertEqual(try h.base.storedBodyFromDisk(), original)
        }
    }

    func testOrdinalExhaustionRollsBackFirstStart() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let observation = try await h.observe()
        var metadata = try await h.queue.nativeReplaySessionState()
        metadata.nextReplayOrdinal = EluNativeReplaySessionState.maximumOrdinal
        try h.replaceMetadata(metadata.encoded())
        do { _ = try await h.queue.beginNativeReplayStartAccounting(observation); XCTFail("exhausted ordinal") } catch {}
        let after = try await h.queue.nativeReplaySessionState(); XCTAssertEqual(after, metadata)
        XCTAssertNil(after.session?.firstStartAt); await h.queue.close()
    }

    func testLiveOldSessionReceiptSettlesBeforeNewLedgerReplacement() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let old = try await h.start()
        let snapshot = try await h.queue.snapshot()
        _ = try await h.queue.reset(expectedGeneration: snapshot.generation)
        try await h.publish()
        guard case .accepted = await h.base.capture() else { return XCTFail("actual new session") }
        do { _ = try await h.observe(); XCTFail("unsettled live epoch replaced") } catch {}
        let settled = try await h.stop(old); XCTAssertTrue(settled)
        let next = try await h.start(); XCTAssertNotEqual(next.replayId, old.replayId)
        _ = try await h.stop(next); await h.queue.close()
    }

    func testPostcommitWithdrawalReturnsNoStartAndAccountsOriginalCommittedWindow() async throws {
        let fault = DeliveryFault(); let h = try await NativeSessionHarness.make(fault: fault); defer { h.base.remove() }
        let observation = try await h.observe()
        fault.action = { point in if point == .afterCommit { h.base.gate.close() } }
        do { _ = try await h.queue.beginNativeReplayStartAccounting(observation); XCTFail("withdrawn start returned") } catch {}
        fault.action = nil
        let state = try await h.queue.nativeReplaySessionState()
        XCTAssertNotNil(state.session?.firstStartAt); XCTAssertNil(state.session?.activeEpoch)
        XCTAssertEqual(state.nextReplayOrdinal, 1)
        await h.queue.close()
    }

    func testFailedStopRollbackPoisonsAndLeavesInterruptedEpochForReopen() async throws {
        let fault = DeliveryFault(); let h = try await NativeSessionHarness.make(fault: fault); defer { h.base.remove() }
        let receipt = try await h.start()
        fault.action = { point in
            if point == .beforeCommit || point == .beforeRollback { throw EluRuntimeQueueError.faultInjected(point) }
        }
        do { _ = try await h.stop(receipt); XCTFail("failed rollback accepted") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .databaseUnavailable) }
        fault.action = nil
        do { _ = try await h.queue.nativeReplaySessionState(); XCTFail("poisoned owner") } catch {}
        try await h.reopen(); try await h.publish(); try await h.queue.ensureNativeReplayAuthoritySchema()
        let state = try await h.observe(); XCTAssertTrue(state.accounting.interrupted)
        await h.queue.close()
    }

    func testNonUnitMachTimebaseIsConvertedBeforeMicrosecondAccounting() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        await h.queue.close(); try await h.reopen(nanoseconds: { $0 / 2 }); try await h.publish()
        let receipt = try await h.start(); let wall = h.base.now
        h.base.testClock.advance(0.4); h.base.testClock.set(wall)
        let observation = try await h.observe(); XCTAssertEqual(observation.accounting.elapsedFloorMicroseconds, 200_000)
        _ = try await h.stop(receipt); await h.queue.close()
    }

    func testBudgetExhaustingDuringStartTransactionReturnsNoReceiptAndDoesNotRefill() async throws {
        let fault = DeliveryFault(); let h = try await NativeSessionHarness.make(cap: 1, fault: fault); defer { h.base.remove() }
        let observation = try await h.observe(); let wall = h.base.now
        var delayed = false
        fault.action = { point in
            if point == .beforeCommit, !delayed { delayed = true; h.base.testClock.advance(2); h.base.testClock.set(wall) }
        }
        let receipt = try await h.queue.beginNativeReplayStartAccounting(observation); XCTAssertNil(receipt)
        fault.action = nil
        let state = try await h.queue.nativeReplaySessionState()
        XCTAssertNotNil(state.session?.firstStartAt); XCTAssertNil(state.session?.activeEpoch)
        XCTAssertEqual(state.session?.remainingMicroseconds, 0)
        try await h.update(rate: 1, cap: 60)
        let next = try await h.observe(); XCTAssertEqual(next.accounting.maximumDurationSeconds, 1)
        await h.queue.close()
    }

    func testNextOwnerSettlesEpochLeftByFailedStopOnceWallAdvances() async throws {
        let fault = DeliveryFault(); let h = try await NativeSessionHarness.make(fault: fault); defer { h.base.remove() }
        let receipt = try await h.start()
        fault.action = { point in
            if point == .beforeCommit || point == .beforeRollback { throw EluRuntimeQueueError.faultInjected(point) }
        }
        do { _ = try await h.stop(receipt); XCTFail("failed rollback accepted") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .databaseUnavailable) }
        fault.action = nil
        h.base.testClock.advance(5)
        try await h.reopen(); try await h.publish(); try await h.queue.ensureNativeReplayAuthoritySchema()
        let state = try await h.observe()
        XCTAssertFalse(state.accounting.interrupted); XCTAssertFalse(state.accounting.clockDenied)
        XCTAssertNil(state.accounting.activeEpoch)
        XCTAssertGreaterThanOrEqual(state.accounting.elapsedFloorMicroseconds, 5_000_000)
        let next = try await h.start(); XCTAssertNotEqual(next.replayId, receipt.replayId)
        _ = try await h.stop(next); await h.queue.close()
    }

    func testRelaunchAfterKillMidCaptureSettlesOrphanedEpoch() async throws {
        let h = try await NativeSessionHarness.make(seedReplay: true); defer { h.base.remove() }
        let old = try await h.start()
        h.base.testClock.advance(2); try await h.base.refresh()
        let end = h.base.now
        let chunk = try h.base.request(chunkId: "chunk_000002", sequence: 2,
            startedAt: EluRFC3339.string(from: end.addingTimeInterval(-1)), endedAt: EluRFC3339.string(from: end))
        guard case .inserted = try await h.base.append(request: chunk) else { return XCTFail("sealed chunk") }
        let rows = try await h.queue.storedReplayChunks(); XCTAssertEqual(rows.count, 2)
        let killed = try await h.ledger(); XCTAssertNotNil(killed.activeEpoch)
        // The process ends mid-capture: no stop, and the unsealed tail never reached storage.
        await h.queue.close()
        h.base.testClock.advance(30)
        try await h.reopen(); try await h.publish()
        try await h.queue.ensureNativeReplayAuthoritySchema()
        let settled = try await h.ledger()
        XCTAssertNil(settled.activeEpoch); XCTAssertFalse(settled.interrupted); XCTAssertFalse(settled.clockDenied)
        XCTAssertEqual(settled.firstStartAt, old.firstStartAt)
        let elapsed = try XCTUnwrap(EluNativeReplaySessionState.elapsedCeilMicroseconds(
            from: EluV1Timestamp(old.firstStartAt), to: EluV1Timestamp.exactClock(h.base.now)))
        XCTAssertGreaterThanOrEqual(settled.elapsedFloorMicroseconds, elapsed)
        // The ended owner's receipt cannot act through the new owner.
        let before = try h.bytes("SELECT metadata FROM native_replay_authority")
        let ignored = try await h.stop(old); XCTAssertFalse(ignored)
        XCTAssertEqual(try h.bytes("SELECT metadata FROM native_replay_authority"), before)
        let next = try await h.start()
        XCTAssertNotEqual(next.replayId, old.replayId); XCTAssertEqual(next.firstStartAt, old.firstStartAt)
        let stored = try await h.queue.storedReplayChunks(); XCTAssertEqual(stored, rows)
        guard case let .claimed(claim) = try await h.queue.claimNextReplay(h.base.deliveryAuthority()) else {
            return XCTFail("sealed row from the ended process")
        }
        XCTAssertEqual(claim.row, .wireframe(rows[0]))
        _ = try await h.queue.finishReplayClaim(claim, completion: .released)
        _ = try await h.stop(next); await h.queue.close()
    }

    func testRelaunchWallBelowReplayHighWaterDenies() async throws {
        let h = try await NativeSessionHarness.make(seedReplay: true); defer { h.base.remove() }
        let old = try await h.start(); let begun = h.base.now
        h.base.testClock.advance(5)
        // Delivery in the ended process raised the replay store's observed wall past the ledger's.
        guard case let .claimed(claim) = try await h.queue.claimNextReplay(h.base.deliveryAuthority()) else { return XCTFail("claim") }
        _ = try await h.queue.finishReplayClaim(claim, completion: .released)
        await h.queue.close()
        h.base.testClock.set(begun.addingTimeInterval(2))
        let r = try await h.relaunched()
        try await r.queue.ensureNativeReplayAuthoritySchema()
        let denied = try await r.ledger()
        XCTAssertTrue(denied.clockDenied); XCTAssertTrue(denied.interrupted); XCTAssertNotNil(denied.activeEpoch)
        let observation = try await r.observe(); XCTAssertTrue(observation.accounting.clockDenied)
        let refused = try await r.queue.beginNativeReplayStartAccounting(observation); XCTAssertNil(refused)
        await r.queue.close()
        // A later wall well ahead of both marks never clears the session's denial.
        h.base.testClock.set(begun.addingTimeInterval(60))
        let later = try await r.relaunched(); try await later.queue.ensureNativeReplayAuthoritySchema()
        let again = try await later.observe(); XCTAssertTrue(again.accounting.clockDenied)
        XCTAssertEqual(again.accounting.firstStartAt, old.firstStartAt)
        let stillRefused = try await later.queue.beginNativeReplayStartAccounting(again); XCTAssertNil(stillRefused)
        guard case .accepted = await later.base.capture() else { return XCTFail("analytics capture stays available") }
        await later.queue.close()
    }

    func testDeliveryClaimInSameMillisecondDoesNotBlockResume() async throws {
        let h = try await NativeSessionHarness.make(seedReplay: true); defer { h.base.remove() }
        let old = try await h.start(); h.base.testClock.advance(1); _ = try await h.stop(old)
        await h.queue.close()
        h.base.testClock.advance(10)
        try await h.reopen(); try await h.publish()
        // The new owner's first delivery raises the replay store mark to this exact wall.
        guard case let .claimed(claim) = try await h.queue.claimNextReplay(h.base.deliveryAuthority()) else { return XCTFail("claim") }
        _ = try await h.queue.finishReplayClaim(claim, completion: .released)
        let mark = try h.bytes("SELECT observed_wall FROM replay_state")
        XCTAssertEqual(String(decoding: mark, as: UTF8.self), try EluV1Timestamp.exactClock(h.base.now).source)
        try await h.queue.ensureNativeReplayAuthoritySchema()
        let settled = try await h.ledger(); XCTAssertFalse(settled.interrupted); XCTAssertFalse(settled.clockDenied)
        let next = try await h.start(); XCTAssertNotEqual(next.replayId, old.replayId)
        _ = try await h.stop(next); await h.queue.close()
    }

    func testRelaunchWallRollbackAcrossCleanGapDeniesSessionButNewSessionStartsClean() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let old = try await h.start(); let begun = h.base.now
        h.base.testClock.advance(1); _ = try await h.stop(old)
        let stopped = try await h.ledger()
        await h.queue.close()
        h.base.testClock.set(begun.addingTimeInterval(0.5))
        try await h.reopen(); try await h.publish(); try await h.queue.ensureNativeReplayAuthoritySchema()
        let denied = try await h.observe()
        XCTAssertTrue(denied.accounting.clockDenied)
        XCTAssertEqual(denied.accounting.elapsedFloorMicroseconds, stopped.elapsedFloorMicroseconds)
        let refused = try await h.queue.beginNativeReplayStartAccounting(denied); XCTAssertNil(refused)
        let snapshot = try await h.queue.snapshot()
        _ = try await h.queue.reset(expectedGeneration: snapshot.generation)
        try await h.publish()
        guard case .accepted = await h.base.capture() else { return XCTFail("real new session") }
        let fresh = try await h.observe()
        XCTAssertNotEqual(fresh.accounting.key, denied.accounting.key)
        XCTAssertNotEqual(fresh.accounting.samplingHash, denied.accounting.samplingHash)
        XCTAssertFalse(fresh.accounting.clockDenied); XCTAssertFalse(fresh.accounting.interrupted)
        XCTAssertNil(fresh.accounting.firstStartAt)
        let next = try await h.start(); XCTAssertNotEqual(next.replayId, old.replayId)
        _ = try await h.stop(next); await h.queue.close()
    }

    func testRelaunchClockForwardJumpOnlyShrinksBudget() async throws {
        let h = try await NativeSessionHarness.make(cap: 60); defer { h.base.remove() }
        let old = try await h.start(); h.base.testClock.advance(1); _ = try await h.stop(old)
        await h.queue.close()
        h.base.testClock.advance(120)
        try await h.reopen(); try await h.publish(); try await h.queue.ensureNativeReplayAuthoritySchema()
        let jumped = try await h.observe()
        XCTAssertFalse(jumped.accounting.clockDenied); XCTAssertFalse(jumped.accounting.interrupted)
        XCTAssertGreaterThanOrEqual(jumped.accounting.elapsedFloorMicroseconds, 121_000_000)
        XCTAssertEqual(jumped.accounting.remainingMicroseconds, 0)
        let refused = try await h.queue.beginNativeReplayStartAccounting(jumped); XCTAssertNil(refused)
        await h.queue.close()
    }

    func testRelaunchDoesNotRerollSamplingOrRenewCap() async throws {
        let unselected = try await NativeSessionHarness.make(rate: 0); defer { unselected.base.remove() }
        let original = try await unselected.observe(); XCTAssertFalse(original.accounting.originalSelected)
        await unselected.queue.close(); unselected.base.testClock.advance(10)
        try await unselected.reopen(); try await unselected.update(rate: 1, cap: 60)
        try await unselected.queue.ensureNativeReplayAuthoritySchema()
        let reopened = try await unselected.observe()
        XCTAssertEqual(reopened.accounting.samplingHash, original.accounting.samplingHash)
        XCTAssertFalse(reopened.currentSelected)
        let none = try await unselected.queue.beginNativeReplayStartAccounting(reopened); XCTAssertNil(none)
        await unselected.queue.close()

        let h = try await NativeSessionHarness.make(rate: 1, cap: 60); defer { h.base.remove() }
        let old = try await h.start(); h.base.testClock.advance(1); _ = try await h.stop(old)
        let before = try await h.ledger()
        await h.queue.close(); h.base.testClock.advance(10)
        try await h.reopen(); try await h.update(rate: 0, cap: 30)
        try await h.queue.ensureNativeReplayAuthoritySchema()
        let restricted = try await h.observe()
        XCTAssertFalse(restricted.currentSelected); XCTAssertFalse(restricted.accounting.interrupted)
        let refused = try await h.queue.beginNativeReplayStartAccounting(restricted); XCTAssertNil(refused)
        try await h.update(rate: 1, cap: 120)
        let restored = try await h.observe()
        XCTAssertTrue(restored.currentSelected)
        XCTAssertEqual(restored.accounting.samplingHash, before.samplingHash)
        XCTAssertEqual(restored.accounting.originalSampleRate, before.originalSampleRate)
        XCTAssertEqual(restored.accounting.firstStartAt, before.firstStartAt)
        XCTAssertEqual(restored.accounting.maximumDurationSeconds, 30)
        let next = try await h.start(); XCTAssertNotEqual(next.replayId, old.replayId)
        _ = try await h.stop(next); await h.queue.close()
    }

    func testObserveBeforeEnsureStillSettlesWithAdditiveCharge() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let old = try await h.start(); let wall = h.base.now
        h.base.testClock.advance(0.4); h.base.testClock.set(wall)
        _ = try await h.stop(old); await h.queue.close()
        h.base.testClock.set(wall.addingTimeInterval(10))
        try await h.reopen(); try await h.publish()
        // Observation before any schema setup still charges the whole gap on top of the floor.
        let first = try await h.observe()
        XCTAssertFalse(first.accounting.interrupted); XCTAssertFalse(first.accounting.clockDenied)
        XCTAssertEqual(first.accounting.elapsedFloorMicroseconds, 10_400_000)
        try await h.queue.ensureNativeReplayAuthoritySchema()
        let after = try await h.ledger()
        XCTAssertEqual(after.elapsedFloorMicroseconds, 10_400_000); XCTAssertFalse(after.interrupted)
        let next = try await h.start(); XCTAssertNotEqual(next.replayId, old.replayId)
        _ = try await h.stop(next); await h.queue.close()
    }

    func testLegacyInterruptedLedgerResumesUnlessDenied() async throws {
        for variant in ["clean", "orphan", "denied"] {
            let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
            let old = try await h.start(); h.base.testClock.advance(1)
            if variant != "orphan" { _ = try await h.stop(old) }
            var legacy = try await h.queue.nativeReplaySessionState()
            await h.queue.close()
            // The ledger as an earlier release left it after its own relaunch.
            legacy.session?.interrupted = true
            if variant == "denied" { legacy.session?.clockDenied = true }
            try h.replaceMetadata(legacy.encoded())
            h.base.testClock.advance(10)
            try await h.reopen(); try await h.publish(); try await h.queue.ensureNativeReplayAuthoritySchema()
            let current = try await h.observe()
            if variant == "denied" {
                XCTAssertTrue(current.accounting.clockDenied); XCTAssertTrue(current.accounting.interrupted)
                let refused = try await h.queue.beginNativeReplayStartAccounting(current); XCTAssertNil(refused)
            } else {
                XCTAssertFalse(current.accounting.interrupted, variant); XCTAssertFalse(current.accounting.clockDenied, variant)
                XCTAssertNil(current.accounting.activeEpoch, variant)
                let next = try await h.start()
                XCTAssertNotEqual(next.replayId, old.replayId); XCTAssertEqual(next.firstStartAt, old.firstStartAt)
                _ = try await h.stop(next)
            }
            await h.queue.close()
        }
    }

    func testResumedLedgerKeepsClosedMetadataShape() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let old = try await h.start(); h.base.testClock.advance(1); _ = try await h.stop(old)
        let version = try h.base.schemaVersion()
        await h.queue.close(); h.base.testClock.advance(10)
        try await h.reopen(); try await h.publish(); try await h.queue.ensureNativeReplayAuthoritySchema()
        let bytes = try h.bytes("SELECT metadata FROM native_replay_authority")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["schemaVersion", "namespaceHash", "streamId", "nextReplayOrdinal", "session"])
        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        let session = try XCTUnwrap(root["session"] as? [String: Any])
        XCTAssertEqual(Set(session.keys), ["siteId", "sessionId", "sessionStartedAt", "samplingHash", "originalSampleRate",
            "originalSelected", "firstStartAt", "maximumDurationSeconds", "elapsedFloorMicroseconds", "observedWallAt",
            "clockDenied", "interrupted", "activeEpoch"])
        XCTAssertEqual(session["interrupted"] as? Bool, false)
        XCTAssertEqual(try EluNativeReplaySessionState.decode(bytes).session?.interrupted, false)
        XCTAssertEqual(try h.base.schemaVersion(), version)
        // A wall pinned across a later relaunch proves nothing, which is also what an older reader concludes.
        let next = try await h.start(); _ = try await h.stop(next)
        await h.queue.close()
        try await h.reopen(); try await h.publish()
        let pinned = try await h.observe(); XCTAssertTrue(pinned.accounting.interrupted)
        await h.queue.close()
    }

    func testRelaunchMissingContinuousClockDenies() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let old = try await h.start(); h.base.testClock.advance(1); _ = try await h.stop(old)
        await h.queue.close(); h.base.testClock.advance(10)
        try await h.reopen(nanoseconds: { _ in nil }); try await h.publish()
        try await h.queue.ensureNativeReplayAuthoritySchema()
        let denied = try await h.ledger(); XCTAssertTrue(denied.clockDenied)
        let observation = try await h.observe(); XCTAssertTrue(observation.accounting.clockDenied)
        let refused = try await h.queue.beginNativeReplayStartAccounting(observation); XCTAssertNil(refused)
        await h.queue.close()
    }

    func testOptOutDuringGapNeverResumes() async throws {
        for pending in [false, true] {
            let fault = DeliveryFault(); let h = try await NativeSessionHarness.make(fault: fault)
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("elu-replay-storage-\(UUID().uuidString)")
            defer { h.base.remove(); try? FileManager.default.removeItem(at: copy) }
            let before = try await h.observe()
            let old = try await h.start(); h.base.testClock.advance(1); _ = try await h.stop(old)
            let r: NativeSessionHarness
            if pending {
                // The process ends after the opt-out intent is stored and before it settles.
                fault.action = { if $0 == .afterConsentIntentWrite { throw EluRuntimeQueueError.faultInjected($0) } }
                do { _ = try await h.queue.setOptedOut(true, expectedGeneration: h.queue.snapshot().generation); XCTFail("opt-out settled") }
                catch {}
                fault.action = nil; await h.queue.close()
                // That failure keeps this store closed for the rest of this process; the
                // next process opens the files it left.
                try FileManager.default.copyItem(at: h.base.root, to: copy)
                h.base.testClock.advance(10)
                r = try await h.relaunched(root: copy, publish: false)
            } else {
                _ = try await h.queue.setOptedOut(true, expectedGeneration: h.queue.snapshot().generation)
                await h.queue.close(); h.base.testClock.advance(10)
                r = try await h.relaunched(publish: false)
            }
            try? await r.publish()
            let snapshot = try await r.queue.snapshot()
            XCTAssertTrue(snapshot.identity.optedOut, "pending=\(pending)"); XCTAssertNil(snapshot.identity.session)
            try await r.queue.ensureNativeReplayAuthoritySchema()
            do { _ = try await r.observe(); XCTFail("opted-out session observed") } catch {}
            _ = try await r.queue.setOptedOut(false, expectedGeneration: r.queue.snapshot().generation)
            try await r.publish()
            guard case .accepted = await r.base.capture() else { return XCTFail("capture after opt-in") }
            let current = try await r.observe()
            XCTAssertNotEqual(current.accounting.key, before.accounting.key)
            XCTAssertNil(current.accounting.firstStartAt)
            let next = try await r.start(); XCTAssertNotEqual(next.replayId, old.replayId)
            _ = try await r.stop(next); await r.queue.close()
        }
    }

    func testRelaunchAfterIdleTimeoutUsesNewLedger() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        var root = try JSONSerialization.jsonObject(with: h.base.config) as! [String: Any]
        var session = root["session"] as! [String: Any]; session["idleTimeoutSeconds"] = 60; root["session"] = session
        h.base.testClock.advance(0.001); root["issuedAt"] = EluRFC3339.string(from: h.base.now)
        h.base.config = try JSONSerialization.data(withJSONObject: root); try await h.publish()
        let old = try await h.start(); h.base.testClock.advance(1); _ = try await h.stop(old)
        let previous = try await h.queue.nativeReplaySessionState()
        await h.queue.close(); h.base.testClock.advance(61)
        try await h.reopen(); try await h.publish()
        guard case .accepted = await h.base.capture() else { return XCTFail("capture after the idle timeout") }
        let fresh = try await h.observe()
        XCTAssertNotEqual(fresh.accounting.sessionId, previous.session?.sessionId)
        XCTAssertNotEqual(fresh.accounting.samplingHash, previous.session?.samplingHash)
        XCTAssertNil(fresh.accounting.firstStartAt); XCTAssertFalse(fresh.accounting.interrupted)
        let next = try await h.start()
        XCTAssertNotEqual(next.replayId, old.replayId); XCTAssertNotEqual(next.firstStartAt, old.firstStartAt)
        let after = try await h.queue.nativeReplaySessionState()
        XCTAssertEqual(after.nextReplayOrdinal, previous.nextReplayOrdinal + 1)
        _ = try await h.stop(next); await h.queue.close()
    }

    func testActualSessionIdleBoundaryDeniesBeforeSourceExpiry() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        var root = try JSONSerialization.jsonObject(with: h.base.config) as! [String: Any]
        var session = root["session"] as! [String: Any]; session["idleTimeoutSeconds"] = 60; root["session"] = session
        h.base.testClock.advance(0.001); root["issuedAt"] = EluRFC3339.string(from: h.base.now)
        h.base.config = try JSONSerialization.data(withJSONObject: root); try await h.publish()
        h.base.testClock.advance(60)
        XCTAssertTrue(h.base.gate.isCurrent(h.base.witness))
        do { _ = try await h.observe(); XCTFail("idle session admitted") } catch {}
        await h.queue.close()
    }
}

final class NativeSessionHarness: @unchecked Sendable {
    let base: DeliveryHarness
    var queue: EluSQLiteRuntimeQueue { base.queue }
    init(_ base: DeliveryHarness) { self.base = base }
    static func make(rate: Double = 1, cap: Int = 60, activate: Bool = true, seedReplay: Bool = false,
                     fault: DeliveryFault? = nil) async throws -> NativeSessionHarness {
        let base = try await DeliveryHarness.make(fault: fault)
        try await base.install()
        if seedReplay { _ = try await base.append() }
        await base.queue.close()
        let h = NativeSessionHarness(base); try await h.reopen()
        try await h.update(rate: rate, cap: cap)
        if activate {
            try await h.queue.ensureReplayDeliverySchema()
            try await h.queue.ensureNativeReplayAuthoritySchema()
        }
        return h
    }
    func reopen(nanoseconds: @escaping @Sendable (UInt64) -> UInt64? = { $0 }) async throws {
        let clock = base.testClock
        base.queue = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: base.root,
            exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", limits: base.limits,
            clock: { clock.read() }, continuousClock: { clock.ticks() }, continuousBudgetConverter: { $0 },
            nativeContinuousNanoseconds: nanoseconds, configurationGate: base.gate, faultInjector: base.fault)
    }
    func update(rate: Double, cap: Int) async throws {
        base.testClock.advance(0.001)
        var root = try JSONSerialization.jsonObject(with: base.config) as! [String: Any]
        var privacy = root["privacy"] as! [String: Any]; var replay = privacy["replay"] as! [String: Any]
        replay["sampleRate"] = rate; replay["maximumDurationSeconds"] = cap; privacy["replay"] = replay; root["privacy"] = privacy
        root["issuedAt"] = EluRFC3339.string(from: base.now)
        base.config = try JSONSerialization.data(withJSONObject: root)
        try await publish()
    }
    func publish() async throws {
        let document = try JSONDecoder().decode(EluV1ConfigDocument.self, from: base.config)
        let token = EluV2ConfigLifecycleToken()
        base.gate.publish(token: token, lease: EluV2ConfigLease(data: base.config, expiresAt: document.expiresAt,
            continuousDeadline: base.testClock.ticks() + 600_000_000_000))
        base.witness = try XCTUnwrap(base.gate.witness(for: token))
        let manager = EluV1ConfigManager(); _ = try manager.update(configData: base.config, now: base.now)
        let snapshot = try await queue.snapshot()
        let input = EluPrivacyProjectionInput(contextRevision: snapshot.identity.contextRevision, identityOptedOut: snapshot.identity.optedOut,
            timeZoneIdentifier: "America/Los_Angeles", evaluatedAt: base.now,
            appliedMasking: EluPrivacyMaskingCapability(text: .all, inputs: .all, images: .block),
            replaySampleDraw: 0, replaySessionEligible: false, replayBudgetRemainingSeconds: 0, localReplayTransports: [])
        let projection = try EluPrivacyStateProjector.project(context: manager.activePrivacyProjectionContext(now: base.now), input: input)
        let result = await queue.submitCaptureAuthority(configData: base.config, effectivePrivacyStateData: projection.stateData, sourceWitness: base.witness)
        guard case .activated = result else { throw EluRuntimeQueueError.invalidState }
    }
    func observe() async throws -> EluNativeReplaySessionObservation {
        try await queue.observeNativeReplaySession(source: XCTUnwrap(base.witness))
    }
    func start() async throws -> EluNativeReplayStartReceipt {
        let observation = try await observe()
        let receipt = try await queue.beginNativeReplayStartAccounting(observation)
        return try XCTUnwrap(receipt)
    }
    func stop(_ receipt: EluNativeReplayStartReceipt) async throws -> Bool { try await queue.stopNativeReplayAccounting(receipt) }
    /// The next process on this store, or on a copy of the files a process left:
    /// the same clock and configuration, with a new configuration gate and queue owner.
    func relaunched(root: URL? = nil, publish: Bool = true,
                    nanoseconds: @escaping @Sendable (UInt64) -> UInt64? = { $0 }) async throws -> NativeSessionHarness {
        let clock = base.testClock
        let gate = EluV2ConfigAuthorityGate(siteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", clock: EluV2ConfigClock(
            wallNow: { clock.read() }, continuousNow: { clock.ticks() }, floorTicks: { clock.convert($0) }, floorNanoseconds: { $0 }))
        let next = DeliveryHarness(root: root ?? base.root, queue: base.queue, gate: gate, limits: base.limits,
            config: base.config, testClock: clock, fault: base.fault)
        next.generation = base.generation; next.authorization = base.authorization
        let value = NativeSessionHarness(next)
        try await value.reopen(nanoseconds: nanoseconds)
        if publish { try await value.publish() }
        return value
    }
    func ledger() async throws -> EluNativeReplaySessionState.Session {
        let value = try await queue.nativeReplaySessionState()
        return try XCTUnwrap(value.session)
    }
    private var path: String {
        get throws { try base.root.appendingPathComponent(EluV1SiteNamespace.directoryComponent(exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa")).appendingPathComponent("runtime-state-v1.sqlite3").path }
    }
    func integer(_ query: String) throws -> Int64 {
        var db: OpaquePointer?; XCTAssertEqual(try sqlite3_open(path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, query, -1, &statement, nil), SQLITE_OK); defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW); return sqlite3_column_int64(statement, 0)
    }
    func bytes(_ query: String) throws -> Data {
        var db: OpaquePointer?; XCTAssertEqual(try sqlite3_open(path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, query, -1, &statement, nil), SQLITE_OK); defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Data(bytes: try XCTUnwrap(sqlite3_column_blob(statement, 0)), count: Int(sqlite3_column_bytes(statement, 0)))
    }
    func replaceMetadata(_ data: Data) throws {
        var db: OpaquePointer?; XCTAssertEqual(try sqlite3_open(path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, "UPDATE native_replay_authority SET metadata=?", -1, &statement, nil), SQLITE_OK); defer { sqlite3_finalize(statement) }
        let result = data.withUnsafeBytes { bytes -> Int32 in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(data.count), nil); return sqlite3_step(statement)
        }
        XCTAssertEqual(result, SQLITE_DONE)
    }
}

private final class NativeSampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func sample(_ ticks: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }; value += 1; return ticks
    }
}
