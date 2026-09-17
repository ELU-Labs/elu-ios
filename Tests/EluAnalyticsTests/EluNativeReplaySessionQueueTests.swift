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
            XCTAssertEqual(try h.base.schemaVersion(), flagsFirst ? 8 : 7)
            if !flagsFirst { try await h.queue.ensureFlagSchema() }
            XCTAssertEqual(try h.base.schemaVersion(), 8)
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

    func testEveryStartedReopenDeniesWithoutOriginalClockEvenAfterCleanStop() async throws {
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
                let reopened = try await h.observe()
                XCTAssertTrue(reopened.accounting.interrupted)
                XCTAssertEqual(reopened.accounting.firstStartAt, first.firstStartAt)
                XCTAssertEqual(reopened.accounting.activeEpoch == nil, clean)
                let second = try await h.queue.beginNativeReplayStartAccounting(reopened)
                XCTAssertNil(second)
                let retained = try await h.queue.storedReplayChunks(); XCTAssertEqual(retained, rows)
                if clean { XCTAssertEqual(reopened.accounting.elapsedFloorMicroseconds, 400_000) }
                await h.queue.close()
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
