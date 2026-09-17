import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import EluAnalytics

final class EluV2ReplayStorageTests: XCTestCase {
    func testFrozenBrowserEnvelopeIsOpaqueStorageFixtureAndCanonicalBytesAreStable() throws {
        let raw = try fixture("replay-request.json")
        let value = try EluV2ReplayPreparedRequest(raw, captureProtocolGeneration: "fixture-generation")
        XCTAssertEqual(value.requestId, "request_fc8f5188920b236355fba0142235aaffd9eb08073d6d9725bcea42fc85d0e20b")
        XCTAssertEqual(try EluV2ReplayPreparedRequest(value.body, captureProtocolGeneration: "fixture-generation"), value)
        XCTAssertEqual(value.codec, "elu-browser-dom-v1")
    }

    func testDuplicateUnknownSchemaBadBase64AndWrongRequestIdFailClosed() throws {
        let original = try String(decoding: fixture("replay-request.json"), as: UTF8.self)
        for invalid in [original.replacingOccurrences(of: "\"schemaVersion\": 2,", with: "\"schemaVersion\": 2, \"schemaVersion\": 2,", options: [], range: original.startIndex..<original.index(original.startIndex, offsetBy: 30)),
                        original.replacingOccurrences(of: "\"schemaVersion\": 2", with: "\"schemaVersion\": 3"),
                        original.replacingOccurrences(of: "request_fc8", with: "request_000"),
                        original.replacingOccurrences(of: "H4sI", with: "!!!!")] {
            XCTAssertThrowsError(try EluV2ReplayPreparedRequest(Data(invalid.utf8), captureProtocolGeneration: "fixture-generation"))
        }
    }

    func testFlagsAndReplayMigrateInBothOrdersAndReopenExactRows() async throws {
        for flagsFirst in [true, false] {
            let h = try await Harness.make()
            if flagsFirst { try await h.queue.ensureFlagSchema() }
            try await h.install()
            _ = try await h.append()
            if !flagsFirst { try await h.queue.ensureFlagSchema() }
            let before = try await h.queue.storedReplayChunks()
            await h.queue.close()
            let reopened = try await h.reopen()
            let after = try await reopened.storedReplayChunks()
            XCTAssertEqual(before, after)
            XCTAssertEqual(try h.schemaVersion(), 4)
            try await reopened.ensureFlagSchema()
            await reopened.close(); h.remove()
        }
    }

    func testExactDuplicatesPreserveOrdinalAndConflictingSequenceDoesNotReplaceBytes() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install()
        let first = try await h.append()
        guard case let .inserted(row) = first else { return XCTFail("insert") }
        guard case let .duplicate(duplicate) = try await h.append() else { return XCTFail("duplicate") }
        XCTAssertEqual(row, duplicate)
        do { _ = try await h.append(request: h.request(chunkId: "other")); XCTFail("conflicting sequence") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .acknowledgementMismatch) }
        let rows = try await h.queue.storedReplayChunks(); XCTAssertEqual(rows, [row])
        await h.queue.close()
    }

    func testGenerationRotationPurgesEvenSameCodecAndUnsupportedGenerationStaysClosed() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append()
        try await h.renew(generation: "next", issued: "2026-08-05T00:00:01.000Z", support: "next")
        let actual1 = try await h.count()
        XCTAssertEqual(actual1, 0)
        _ = try await h.append()
        try await h.renew(generation: "future", issued: "2026-08-05T00:00:02.000Z", support: nil)
        let actual2 = try await h.count()
        XCTAssertEqual(actual2, 0)
        do { _ = try await h.append(); XCTFail("unsupported") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .generationMismatch) }
        await h.queue.close()
    }

    func testSameGenerationRefreshPreservesSealedIdentityAndStricterProfilePurges() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append()
        let old = try await h.queue.storedReplayChunks()
        try await h.renew(generation: h.generation, issued: "2026-08-05T00:00:01.000Z", support: h.generation)
        let actual3 = try await h.queue.storedReplayChunks()
        XCTAssertEqual(actual3, old)
        _ = try await h.queue.registerStandaloneSuperProperties(["plan": .string("changed")])
        let actual4 = try await h.queue.storedReplayChunks()
        XCTAssertEqual(actual4, old)
        _ = try await h.queue.reconcileReplayConfiguration(configData: h.config, expectedConfigWitness: h.configWitness,
            sourceWitness: h.witness, supportedProtocolGeneration: h.generation, mayRetainProfile: { _ in false })
        let actual5 = try await h.count()
        XCTAssertEqual(actual5, 0)
        await h.queue.close()
    }

    func testStaleSourceAndConfigCannotAppendOrPurgeNewerRows() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install()
        let oldConfig = h.config, oldWitness = h.witness, oldBoundary = h.configWitness
        try await h.renew(generation: h.generation, issued: "2026-08-05T00:00:01.000Z", support: h.generation)
        _ = try await h.append()
        do { _ = try await h.queue.reconcileReplayConfiguration(configData: oldConfig, expectedConfigWitness: oldBoundary,
            sourceWitness: oldWitness, supportedProtocolGeneration: h.generation, mayRetainProfile: { _ in false }); XCTFail("stale") } catch {}
        do { _ = try await h.queue.purgeReplay(expectedConfigWitness: oldBoundary, sourceWitness: oldWitness, matching: { _ in true }); XCTFail("stale purge") } catch {}
        let actual6 = try await h.count()
        XCTAssertEqual(actual6, 1)
        await h.queue.close()
    }

    func testOptOutPurgesAtomicallyWhileOrdinaryContextMutationPreservesRows() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append()
        let snapshot = try await h.queue.snapshot()
        _ = try await h.queue.setOptedOut(true, expectedGeneration: snapshot.generation)
        let actual7 = try await h.count()
        XCTAssertEqual(actual7, 0)
        await h.queue.close()
    }

    func testReplayConsumesEventQueueCountAndEventConsumesReplayCount() async throws {
        for replayFirst in [true, false] {
            let h = try await Harness.make(limits: EluRuntimeQueueLimits(maximumCount: 1)); defer { h.remove() }
            try await h.install()
            if replayFirst {
                _ = try await h.append()
                guard case .rejected(.queueLimit, _) = await h.capture() else { return XCTFail("aggregate event count") }
            } else {
                guard case .accepted = await h.capture() else { return XCTFail("event") }
                do { _ = try await h.append(); XCTFail("aggregate replay count") }
                catch { XCTAssertEqual(error as? EluRuntimeQueueError, .queueCountLimitExceeded) }
            }
            let actual8 = try await h.queue.replayInventory().aggregateCount
            XCTAssertEqual(actual8, 1)
            await h.queue.close()
        }
    }

    func testWithdrawalAtBeforeCommitRollsBackAndAmbiguousCommitPoisonsUntilReopen() async throws {
        for ambiguous in [false, true] {
            let fault = ReplayFault()
            let h = try await Harness.make(fault: fault); defer { h.remove() }
            try await h.install()
            if ambiguous { fault.action = { point in if point == .afterCommit { throw EluRuntimeQueueError.faultInjected(point) } } }
            else { fault.action = { point in if point == .beforeCommit { h.gate.publish(token: EluV2ConfigLifecycleToken(), lease: nil) } } }
            do { _ = try await h.append(); XCTFail("must reject") }
            catch { XCTAssertEqual(error as? EluRuntimeQueueError, ambiguous ? .ambiguousCommit : .sourceAuthorityUnavailable) }
            fault.action = nil
            if ambiguous {
                do { _ = try await h.queue.snapshot(); XCTFail("poison") } catch {}
                let reopened = try await h.reopen()
                let actual9 = try await reopened.storedReplayChunks().count
                XCTAssertEqual(actual9, 1)
                await reopened.close()
            } else { let count = try await h.count(); XCTAssertEqual(count, 0); await h.queue.close() }
        }
    }
    func testAggregateByteLimitAppliesInBothAdmissionOrders() async throws {
        let probe = try await Harness.make()
        try await probe.install()
        guard case let .accepted(_, snapshot) = await probe.capture() else { return XCTFail("probe capture") }
        let limit = Int(snapshot.queuedBytes) + (try probe.request().body.count) - 1
        await probe.queue.close(); probe.remove()
        for replayFirst in [true, false] {
            let h = try await Harness.make(limits: EluRuntimeQueueLimits(maximumBytes: limit)); defer { h.remove() }
            try await h.install()
            if replayFirst {
                _ = try await h.append()
                guard case .rejected(.queueLimit, _) = await h.capture() else { return XCTFail("event byte budget") }
            } else {
                guard case .accepted = await h.capture() else { return XCTFail("capture") }
                do { _ = try await h.append(); XCTFail("replay byte budget") }
                catch { XCTAssertEqual(error as? EluRuntimeQueueError, .queueByteLimitExceeded) }
            }
            await h.queue.close()
        }
    }

    func testExactSevenDayBoundaryRejectsButSubnanosecondYoungerRequestRemainsEligible() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install()
        do { _ = try await h.append(request: h.request(startedAt: "2026-07-29T00:01:30.000Z")); XCTFail("seven days") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .invalidRecord) }
        _ = try await h.append(request: h.request(startedAt: "2026-07-29T00:01:30.0000000001Z"))
        let count = try await h.count(); XCTAssertEqual(count, 1)
        await h.queue.close()
    }

    func testCanonicalEquivalentProtocolStringsAreDifferentWireGenerations() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install()
        try await h.renew(generation: "caf\u{00e9}", issued: "2026-08-05T00:00:01.000Z", support: "caf\u{00e9}")
        _ = try await h.append()
        try await h.renew(generation: "cafe\u{0301}", issued: "2026-08-05T00:00:02.000Z", support: "cafe\u{0301}")
        let count = try await h.count(); XCTAssertEqual(count, 0)
        await h.queue.close()
    }

    func testNulIdentityKeyRoundTripsWithoutSQLiteTextTruncation() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install()
        _ = try await h.append(request: h.request(chunkId: "chunk\u{0}tail"))
        await h.queue.close()
        let reopened = try await h.reopen()
        let chunks = try await reopened.storedReplayChunks()
        XCTAssertEqual(chunks.first?.prepared.chunkId.utf8.map { $0 }, Array("chunk\u{0}tail".utf8))
        await reopened.close()
    }

    func testSchemaMigrationProvenAbortAndAmbiguousCommitFollowPoisonPolicy() async throws {
        for ambiguous in [false, true] {
            let fault = ReplayFault()
            let h = try await Harness.make(fault: fault); defer { h.remove() }
            fault.action = { point in if point == (ambiguous ? .afterCommit : .beforeCommit) { throw EluRuntimeQueueError.faultInjected(point) } }
            do { try await h.queue.ensureReplaySchema(); XCTFail("fault") }
            catch { XCTAssertEqual(error as? EluRuntimeQueueError, ambiguous ? .ambiguousCommit : .provenNotCommitted) }
            fault.action = nil
            if !ambiguous { await h.queue.close() }
            XCTAssertEqual(try h.schemaVersion(), ambiguous ? 3 : 1)
            let reopened = try await h.reopen(); try await reopened.ensureReplaySchema(); await reopened.close()
        }
    }

    func testExpiredRowsPurgeWithoutRenewingAnExpiredSourceLease() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append()
        h.testClock.advance(604_800)
        XCTAssertFalse(h.gate.isCurrent(h.witness))
        let removed = try await h.queue.expireReplay(expectedConfigWitness: h.configWitness)
        XCTAssertEqual(removed, 1)
        let count = try await h.count(); XCTAssertEqual(count, 0)
        do { _ = try await h.append(); XCTFail("expired authority") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .sourceAuthorityUnavailable) }
        await h.queue.close()
    }

    func testNewSourceCannotBeJoinedToPreviousResolutionBeforeQueueConfigApplication() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install()
        var document = try JSONSerialization.jsonObject(with: h.config) as! [String: Any]
        document["issuedAt"] = "2026-08-05T00:00:01.000Z"
        let data = try JSONSerialization.data(withJSONObject: document)
        let token = EluV2ConfigLifecycleToken()
        h.gate.publish(token: token, lease: EluV2ConfigLease(data: data, expiresAt: try EluV1Timestamp("2026-08-05T00:05:00.000Z"), continuousDeadline: 100_000_000_000))
        let witness = try XCTUnwrap(h.gate.witness(for: token))
        do { _ = try await h.queue.appendReplay(h.request(), maskingProfile: h.profile, authorization: h.authorization, sourceWitness: witness, isCurrentProfile: { $0 == h.profile }); XCTFail("mixed source/resolution") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .sourceAuthorityUnavailable) }
        let count = try await h.count(); XCTAssertEqual(count, 0)
        await h.queue.close()
    }

    func testPreparedValueCannotBeRestampedByAProtocolRefreshBeforeAppend() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install(); let prepared = try h.request()
        try await h.renew(generation: "next", issued: "2026-08-05T00:00:01.000Z", support: "next")
        do { _ = try await h.append(request: prepared); XCTFail("old prepared generation") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .invalidState) }
        XCTAssertThrowsError(try EluV2ReplayPreparedRequest(prepared.body, captureProtocolGeneration: ""))
        let count = try await h.count(); XCTAssertEqual(count, 0)
        await h.queue.close()
    }

    func testBoundedInspectionPagesPreserveExactOrdinalAndByteOrder() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install()
        for index in 1...3 { _ = try await h.append(request: h.request(chunkId: "chunk_\(index)", sequence: index)) }
        let first = try await h.queue.storedReplayChunks(maximumCount: 1)
        let second = try await h.queue.storedReplayChunks(afterOrdinal: first[0].ordinal, maximumCount: 1)
        XCTAssertEqual(first[0].prepared.sequence, 1); XCTAssertEqual(second[0].prepared.sequence, 2)
        do { _ = try await h.queue.storedReplayChunks(maximumBytes: 1); XCTFail("explicit oversize head") }
        catch { guard case .headRecordExceedsPeekLimit = error as? EluRuntimeQueueError else { return XCTFail("wrong error") } }
        await h.queue.close()
    }

    func testLowerAdvertisedQueueCeilingCountsExistingReplayAgainstNewEvents() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append()
        var config = try JSONSerialization.jsonObject(with: h.config) as! [String: Any]
        var limits = config["limits"] as! [String: Any]; limits["queueBytes"] = 1024; config["limits"] = limits
        h.config = try JSONSerialization.data(withJSONObject: config)
        try await h.renew(generation: h.generation, issued: "2026-08-05T00:00:01.000Z", support: h.generation)
        guard case .rejected(.queueLimit, _) = await h.capture() else { return XCTFail("advertised aggregate ceiling") }
        let count = try await h.count(); XCTAssertEqual(count, 1)
        await h.queue.close()
    }

    func testFutureStoredRowAndMissingGenerationOrClockFloorRejectReopenWithoutRewritingBytes() async throws {
        for sql in ["PRAGMA ignore_check_constraints=ON; UPDATE replay_chunks SET storage_schema=2", "UPDATE replay_chunks SET capture_generation='' ", "UPDATE replay_state SET observed_wall=NULL"] {
            let h = try await Harness.make(); defer { h.remove() }
            try await h.install(); _ = try await h.append(); await h.queue.close()
            let namespace = try EluV1SiteNamespace.directoryComponent(exactConstructorSiteKey: "replay-fixture")
            let database = h.root.appendingPathComponent(namespace).appendingPathComponent("runtime-state-v1.sqlite3")
            var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
            let before = try Data(contentsOf: database)
            do { let reopened = try await h.reopen(); await reopened.close(); XCTFail("unknown stored row must fail closed") } catch {}
            XCTAssertEqual(try Data(contentsOf: database), before)
        }
    }

    func testAdmissionRequiresOriginalSessionPolicyAndFullPrivacyWitness() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install()
        for request in [try h.request(sessionId: "stale-session"),
                        try h.request(policyRevision: "other-policy"),
                        try h.request(effectivePolicyHash: "sha256:" + String(repeating: "0", count: 64))] {
            do { _ = try await h.append(request: request); XCTFail("foreign capture witness") }
            catch { XCTAssertEqual(error as? EluRuntimeQueueError, .sourceAuthorityUnavailable) }
        }
        let count = try await h.count(); XCTAssertEqual(count, 0)
        _ = try await h.append()
        await h.queue.close()
    }

    func testSelfHashedWeakerProfileNeedsTrustedCurrentProfileAtFinalAdmission() async throws {
        let fault = ReplayFault()
        let h = try await Harness.make(fault: fault); defer { h.remove() }
        try await h.install()
        let weak = Data(String(decoding: h.profile, as: UTF8.self).replacingOccurrences(of: "\"textRule\":\"all\"", with: "\"textRule\":\"sensitive\"").utf8)
        let request = try h.request(maskingProfile: weak)
        do { _ = try await h.queue.appendReplay(request, maskingProfile: weak, authorization: h.authorization,
                sourceWitness: h.witness, isCurrentProfile: { $0 == h.profile }); XCTFail("self hash is not privacy authority") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .sourceAuthorityUnavailable) }
        var allowed = true
        fault.action = { if $0 == .beforeCommit { allowed = false } }
        do { _ = try await h.queue.appendReplay(h.request(), maskingProfile: h.profile, authorization: h.authorization,
                sourceWitness: h.witness, isCurrentProfile: { $0 == h.profile && allowed }); XCTFail("late profile withdrawal") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .sourceAuthorityUnavailable) }
        fault.action = nil
        let count = try await h.count(); XCTAssertEqual(count, 0)
        await h.queue.close()
    }

    func testRollbackAfterLastObservationPreservesBytesAndDenialSurvivesReopen() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append()
        let bytes = try await h.queue.storedReplayChunks()
        h.testClock.advance(20)
        let firstExpiry = try await h.queue.expireReplay(expectedConfigWitness: h.configWitness)
        XCTAssertEqual(firstExpiry, 0)
        await h.queue.close()
        h.testClock.advance(-10) // Still later than startedAt; the durable observation proves rollback.
        let reopened = try await h.reopen()
        do { _ = try await reopened.expireReplay(expectedConfigWitness: h.configWitness); XCTFail("rollback") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .sourceAuthorityUnavailable) }
        let preserved = try await reopened.storedReplayChunks(); XCTAssertEqual(preserved, bytes)
        _ = try await reopened.registerStandaloneSuperProperties(["local": .bool(true)])
        await reopened.close()
        h.testClock.advance(604_800)
        let again = try await h.reopen()
        do { _ = try await again.expireReplay(expectedConfigWitness: h.configWitness); XCTFail("durable clock denial") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .sourceAuthorityUnavailable) }
        let retained = try await again.storedReplayChunks(); XCTAssertEqual(retained, bytes)
        await again.close()
    }

    func testInvalidClockAndClockBeforeStartPreserveSealedBytes() async throws {
        for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: 1_785_888_000)] {
            let h = try await Harness.make(); defer { h.remove() }
            try await h.install(); _ = try await h.append()
            let bytes = try await h.queue.storedReplayChunks()
            h.testClock.set(date)
            do { _ = try await h.queue.expireReplay(expectedConfigWitness: h.configWitness); XCTFail("untrusted clock") }
            catch { XCTAssertEqual(error as? EluRuntimeQueueError, .sourceAuthorityUnavailable) }
            let retained = try await h.queue.storedReplayChunks(); XCTAssertEqual(retained, bytes)
            await h.queue.close()
        }
    }

    func testClockRollbackAtCommitRollsBackAppendAndBlocksLaterReplay() async throws {
        let fault = ReplayFault()
        let h = try await Harness.make(fault: fault); defer { h.remove() }
        try await h.install()
        fault.action = { if $0 == .beforeCommit { h.testClock.advance(-1) } }
        do { _ = try await h.append(); XCTFail("rollback at commit") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .sourceAuthorityUnavailable) }
        fault.action = nil
        let count = try await h.count(); XCTAssertEqual(count, 0)
        h.testClock.advance(2)
        do { _ = try await h.queue.expireReplay(expectedConfigWitness: h.configWitness); XCTFail("latched clock denial") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .sourceAuthorityUnavailable) }
        await h.queue.close()
    }

    func testInvalidFuturePreparedTimestampDoesNotPoisonReplayClock() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install()
        // A malformed request is rejected before it can become a trusted stored observation.
        do { _ = try await h.append(request: h.request(startedAt: "2026-08-05T00:02:00.000Z", endedAt: "2026-08-05T00:02:01.000Z")); XCTFail("future request") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .invalidRecord) }
        _ = try await h.append()
        let count = try await h.count(); XCTAssertEqual(count, 1)
        await h.queue.close()
    }

    func testBackgroundSessionCannotAdmitReplayButRetainsSealedRows() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append()
        let sealed = try await h.queue.storedReplayChunks()
        _ = try await h.queue.markStandaloneBackgrounded()
        do { _ = try await h.append(request: h.request(chunkId: "next", sequence: 2)); XCTFail("background session") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .sourceAuthorityUnavailable) }
        let retained = try await h.queue.storedReplayChunks(); XCTAssertEqual(retained, sealed)
        let expired = try await h.queue.expireReplay(expectedConfigWitness: h.configWitness); XCTAssertEqual(expired, 0)
        await h.queue.close()
    }

    func testReplayAdmissionUsesNarrowerSessionIdleBoundIncludingAtCommit() async throws {
        for storedIsNarrower in [true, false] {
            for atCommit in [false, true] {
                let fault = ReplayFault()
                let h = try await Harness.make(fault: fault); defer { h.remove() }
                if !storedIsNarrower {
                    var config = try JSONSerialization.jsonObject(with: h.config) as! [String: Any]
                    var session = config["session"] as! [String: Any]; session["idleTimeoutSeconds"] = 60; config["session"] = session
                    h.config = try JSONSerialization.data(withJSONObject: config)
                }
                try await h.install()
                try await h.seedSessionForReopen { $0.timeoutSeconds = storedIsNarrower ? 60 : 1800 }
                if atCommit { fault.action = { if $0 == .beforeCommit { h.testClock.advance(60) } } }
                else { h.testClock.advance(60) }
                do { _ = try await h.append(); XCTFail("idle session") }
                catch { XCTAssertEqual(error as? EluRuntimeQueueError, .sourceAuthorityUnavailable) }
                fault.action = nil
                let count = try await h.count(); XCTAssertEqual(count, 0)
                await h.queue.close()
            }
        }
    }

    func testMaximumSessionDurationRejectsFreshReplayWithoutPurgingSealedRows() async throws {
        let h = try await Harness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append()
        let sealed = try await h.queue.storedReplayChunks()
        try await h.seedSessionForReopen { $0.startedAt = h.now.addingTimeInterval(-86_399) }
        h.testClock.advance(1)
        do { _ = try await h.append(request: h.request(chunkId: "next", sequence: 2)); XCTFail("maximum session duration") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .sourceAuthorityUnavailable) }
        let retained = try await h.queue.storedReplayChunks(); XCTAssertEqual(retained, sealed)
        let expired = try await h.queue.expireReplay(expectedConfigWitness: h.configWitness); XCTAssertEqual(expired, 0)
        await h.queue.close()
    }

}

private func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("Conformance/V2/fixtures/" + name))
}

private final class ReplayFault: EluRuntimeQueueFaultInjecting, @unchecked Sendable {
    var action: ((EluRuntimeQueueFaultPoint) throws -> Void)?
    func hit(_ point: EluRuntimeQueueFaultPoint) throws { try action?(point) }
}

private final class Harness: @unchecked Sendable {
    let root: URL
    var queue: EluSQLiteRuntimeQueue
    let gate: EluV2ConfigAuthorityGate
    let limits: EluRuntimeQueueLimits
    let testClock: ReplayClock
    let fault: ReplayFault?
    var now: Date { testClock.read() }
    var config: Data
    var witness: EluV2ConfigAuthorityWitness?
    var authorization: EluV1ConfigResolution!
    var generation = "replay-v2-1"
    var configWitness: EluV2ReplayConfigWitness {
        let document = try! EluV1StrictCanonicalJSON.parse(config)
        let parsed = try! JSONDecoder().decode(EluV1ConfigDocument.self, from: config)
        return EluV2ReplayConfigWitness(issuedAt: parsed.issuedAt, semanticHash: EluV1StrictCanonicalJSON.hash(document.canonicalData))
    }
    let profile = Data("{\"imageRule\":\"block\",\"inputRule\":\"all\",\"platformFallbackApplied\":false,\"resolvedBlockSelectors\":[],\"resolvedMaskSelectors\":[],\"schemaVersion\":1,\"secureInputsMasked\":true,\"targetDialect\":\"elu-css-selector-v1\",\"textRule\":\"all\"}".utf8)
    init(root: URL, queue: EluSQLiteRuntimeQueue, gate: EluV2ConfigAuthorityGate, limits: EluRuntimeQueueLimits, config: Data, testClock: ReplayClock, fault: ReplayFault?) {
        self.root = root; self.queue = queue; self.gate = gate; self.limits = limits; self.config = config; self.testClock = testClock; self.fault = fault
    }
    static func make(limits: EluRuntimeQueueLimits? = nil, fault: ReplayFault? = nil) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("elu-replay-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let testClock = ReplayClock()
        let gate = EluV2ConfigAuthorityGate(siteKey: "replay-fixture", clock: EluV2ConfigClock(wallNow: { testClock.read() }, continuousNow: { 1 }, floorTicks: { $0 }, floorNanoseconds: { $0 }))
        let limits = try limits ?? EluRuntimeQueueLimits()
        let queue = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: root, exactConstructorSiteKey: "replay-fixture", limits: limits,
            clock: { testClock.read() }, continuousClock: { 1 }, continuousBudgetConverter: { $0 }, anonymousIdGenerator: { "anon-storage" }, sessionIdGenerator: { "session-storage" }, configurationGate: gate, faultInjector: fault)
        return Harness(root: root, queue: queue, gate: gate, limits: limits, config: try fixture("config-enabled.json"), testClock: testClock, fault: fault)
    }
    func install() async throws {
        try await queue.ensureReplaySchema()
        let document = try JSONDecoder().decode(EluV1ConfigDocument.self, from: config)
        generation = try XCTUnwrap(document.capabilities?.replay.replayProtocolGeneration)
        try await activate(support: generation)
    }
    func activate(support: String?) async throws {
        let document = try JSONDecoder().decode(EluV1ConfigDocument.self, from: config)
        let token = EluV2ConfigLifecycleToken()
        gate.publish(token: token, lease: EluV2ConfigLease(data: config, expiresAt: document.expiresAt, continuousDeadline: 100_000_000_000))
        witness = try XCTUnwrap(gate.witness(for: token))
        let pair = EluV1ReplayTransportSelection(codec: "elu-browser-dom-v1", compression: .gzip)!
        let manager = EluV1ConfigManager(readbackProvenReplayTransports: [pair])
        _ = try manager.update(configData: config, now: now)
        let snapshot = try await queue.snapshot()
        let input = EluPrivacyProjectionInput(contextRevision: snapshot.identity.contextRevision, identityOptedOut: snapshot.identity.optedOut,
            timeZoneIdentifier: "America/Los_Angeles", evaluatedAt: now,
            appliedMasking: EluPrivacyMaskingCapability(text: .all, inputs: .all, images: .block),
            replaySampleDraw: 0, replaySessionEligible: true, replayBudgetRemainingSeconds: 100,
            localReplayTransports: [EluV1ReplayTransportPair(codec: pair.codec, compression: pair.compression)])
        let projected = try EluPrivacyStateProjector.project(context: manager.activePrivacyProjectionContext(now: now), input: input)
        let active = await queue.submitCaptureAuthority(configData: config, effectivePrivacyStateData: projected.stateData, sourceWitness: witness)
        guard case .activated = active else { throw EluRuntimeQueueError.invalidState }
        let identity = EluIdentitySnapshot(identity: snapshot.identity, streamId: snapshot.streamId, nextSequence: snapshot.nextSequence, flagContext: snapshot.flagContext)
        authorization = try manager.authorize(effectivePrivacyStateData: projected.stateData, identity: identity, now: now)
        guard case .authorized = authorization.replayAuthorization else { throw EluRuntimeQueueError.invalidState }
        if snapshot.identity.session == nil {
            guard case let .accepted(record, captured) = await capture() else { throw EluRuntimeQueueError.invalidState }
            _ = try await queue.acknowledge([EluQueueAcknowledgementReference(streamId: captured.streamId,
                sequence: record.sequence, kind: record.kind, recordId: record.recordId)])
        }
        _ = try await queue.reconcileReplayConfiguration(configData: config, expectedConfigWitness: configWitness,
            sourceWitness: witness, supportedProtocolGeneration: support, mayRetainProfile: { _ in true })
    }
    func renew(generation: String, issued: String, support: String?) async throws {
        var root = try JSONSerialization.jsonObject(with: config) as! [String: Any]
        var capabilities = root["capabilities"] as! [String: Any]
        var replay = capabilities["replay"] as! [String: Any]
        replay["replayProtocolGeneration"] = generation; capabilities["replay"] = replay
        root["capabilities"] = capabilities; root["issuedAt"] = issued
        config = try JSONSerialization.data(withJSONObject: root)
        self.generation = generation
        try await activate(support: support)
    }
    func request(chunkId: String = "chunk_000001", sequence: Int = 1, startedAt: String = "2026-08-05T00:01:00.000Z", sessionId: String = "session-storage", policyRevision: String? = nil, effectivePolicyHash: String? = nil, maskingProfile: Data? = nil, endedAt: String? = nil) throws -> EluV2ReplayPreparedRequest {
        var root = try JSONSerialization.jsonObject(with: fixture("replay-request.json")) as! [String: Any]
        var chunk = root["chunk"] as! [String: Any]
        chunk["identity"] = ["anonymousId": "anon-storage", "userId": NSNull(), "revision": 0]
        chunk["sessionId"] = sessionId
        if let endedAt { chunk["endedAt"] = endedAt }
        chunk["contextRevision"] = 0; chunk["chunkId"] = chunkId; chunk["sequence"] = sequence; chunk["startedAt"] = startedAt
        var privacy = chunk["privacy"] as! [String: Any]
        privacy["maskingProfileHash"] = EluV1StrictCanonicalJSON.hash(maskingProfile ?? profile)
        privacy["policyRevision"] = try policyRevision ?? JSONDecoder().decode(EluV1ConfigDocument.self, from: config).privacy!.revision
        privacy["effectivePolicyHash"] = effectivePolicyHash ?? authorization.decisionHash!
        chunk["privacy"] = privacy
        let canonical = try EluV1StrictCanonicalJSON.parse(JSONSerialization.data(withJSONObject: chunk)).canonicalData
        var material = Data("elu-sdk-replay-request-v2".utf8); material.append(0)
        var length = UInt32(canonical.count).bigEndian
        withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }; material.append(canonical)
        root["chunk"] = chunk
        root["requestId"] = "request_" + SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return try EluV2ReplayPreparedRequest(JSONSerialization.data(withJSONObject: root), captureProtocolGeneration: generation)
    }
    func append(request: EluV2ReplayPreparedRequest? = nil) async throws -> EluV2ReplayAppendResult {
        try await queue.appendReplay(request ?? self.request(), maskingProfile: profile, authorization: authorization, sourceWitness: witness, isCurrentProfile: { $0 == self.profile })
    }
    func capture() async -> EluV1CaptureResult {
        let versions = try! EluVersionContext(runtime: EluVersionComponent(name: "elu-ios", version: "0.1.0"), facade: EluVersionComponent(name: "elu-ios", version: "0.1.0"))
        return await queue.capture(EluV1CaptureCommand(kind: .capture, name: "fixture", occurredAt: now, properties: [:], versions: versions))
    }
    func count() async throws -> Int64 { try await queue.replayInventory().replayCount }
    func reopen() async throws -> EluSQLiteRuntimeQueue {
        let clock = testClock
        return try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: root, exactConstructorSiteKey: "replay-fixture", limits: limits, clock: { clock.read() }, continuousClock: { 1 }, continuousBudgetConverter: { $0 }, configurationGate: gate, faultInjector: fault)
    }
    func seedSessionForReopen(_ transform: (inout EluSessionState) -> Void) async throws {
        var identity = try await queue.snapshot().identity
        var session = try XCTUnwrap(identity.session)
        transform(&session); identity.session = session
        let data = try EluStateCoding.encoder().encode(identity)
        await queue.close()
        let namespace = try EluV1SiteNamespace.directoryComponent(exactConstructorSiteKey: "replay-fixture")
        let path = root.appendingPathComponent(namespace).appendingPathComponent("runtime-state-v1.sqlite3").path
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, "UPDATE runtime_state SET identity_json=? WHERE singleton=1", -1, &statement, nil), SQLITE_OK)
        let result = data.withUnsafeBytes { buffer -> Int32 in
            sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(data.count), nil)
            return sqlite3_step(statement)
        }
        XCTAssertEqual(result, SQLITE_DONE); sqlite3_finalize(statement); sqlite3_close(db)
        queue = try await reopen()
        try await activate(support: generation)
    }
    func schemaVersion() throws -> Int64 {
        let namespace = try EluV1SiteNamespace.directoryComponent(exactConstructorSiteKey: "replay-fixture")
        let path = root.appendingPathComponent(namespace).appendingPathComponent("runtime-state-v1.sqlite3").path
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }; XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class ReplayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now = Date(timeIntervalSince1970: 1_785_888_090)
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return now }
    func set(_ value: Date) { lock.lock(); now = value; lock.unlock() }
    func advance(_ seconds: TimeInterval) { lock.lock(); now = now.addingTimeInterval(seconds); lock.unlock() }
}
