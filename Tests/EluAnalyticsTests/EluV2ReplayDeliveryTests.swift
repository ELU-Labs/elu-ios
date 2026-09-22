import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import EluAnalytics

final class EluV2ReplayDeliveryTests: XCTestCase {
    func testExplicitDeliveryMigrationBothFlagOrdersPreservesExactRowsAndReopens() async throws {
        for flagsFirst in [true, false] {
            let h = try await DeliveryHarness.make(); defer { h.remove() }
            try await h.install(); _ = try await h.append()
            let before = try await h.queue.storedReplayChunks()
            if flagsFirst { try await h.queue.ensureFlagSchema() }
            try await h.queue.ensureReplayDeliverySchema()
            if !flagsFirst { XCTAssertEqual(try h.schemaVersion(), 5); try await h.queue.ensureFlagSchema() }
            XCTAssertEqual(try h.schemaVersion(), 6)
            let after = try await h.queue.storedReplayChunks(); XCTAssertEqual(after, before)
            await h.queue.close(); h.queue = try await h.reopen()
            try await h.queue.ensureReplayDeliverySchema()
            let reopened = try await h.queue.storedReplayChunks(); XCTAssertEqual(reopened, before)
            await h.queue.close()
        }
    }

    func testBudgetSessionSamplingDoNotAuthorizeFreshButPermitExactSealedDelivery() async throws {
        let h = try await DeliveryHarness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append(); try await h.queue.ensureReplayDeliverySchema()
        let original = try await h.queue.storedReplayChunks()
        let permission = try await h.deliveryAuthority()
        let transport = DeliveryMockTransport { request in Self.ack(try EluV2ReplayPreparedRequest(request.body, captureProtocolGeneration: h.generation)) }
        let coordinator = EluV2ReplayDeliveryCoordinator(queue: h.queue, transport: transport, wallNow: { h.now })
        let summary = await coordinator.trigger(permission)
        XCTAssertEqual(summary.accepted, 1)
        let sent = await transport.bodies; XCTAssertEqual(sent, original.map { $0.prepared.body })
        let count = try await h.count(); XCTAssertEqual(count, 0)
        await h.queue.close()
    }

    func testRetryUsesIdenticalBytesAfterRenewalAndAnotherReplayCanProgress() async throws {
        let h = try await DeliveryHarness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append(); _ = try await h.append(request: h.request(replayId: "other", chunkId: "other"))
        try await h.queue.ensureReplayDeliverySchema()
        let permission = try await h.deliveryAuthority()
        let first = try await claim(h.queue, permission)
        _ = try await h.queue.finishReplayClaim(first, completion: .networkFailure)
        let second = try await claim(h.queue, permission); XCTAssertEqual(second.row.prepared.replayId, "other")
        _ = try await h.queue.finishReplayClaim(second, completion: .response(.accepted))
        guard case .deferred = try await h.queue.claimNextReplay(permission) else { return XCTFail("retry delay") }
        h.testClock.advance(1)
        try await h.renew(generation: h.generation, issued: "2026-08-05T00:00:01.000Z", support: h.generation)
        let next = try await h.deliveryAuthority()
        XCTAssertEqual(next.authorizationWitness, permission.authorizationWitness)
        let retried = try await claim(h.queue, next); XCTAssertEqual(retried.row.prepared.body, first.row.prepared.body)
        XCTAssertEqual(retried.attemptCount, 2)
        _ = try await h.queue.finishReplayClaim(retried, completion: .response(.accepted))
        await h.queue.close()
    }

    func testPerReplaySequenceHeadBlocksLaterSequenceRegardlessOfEnqueueOrder() async throws {
        let h = try await DeliveryHarness.make(); defer { h.remove() }
        try await h.install()
        _ = try await h.append(request: h.request(chunkId: "later", sequence: 2)); _ = try await h.append()
        try await h.queue.ensureReplayDeliverySchema(); let permission = try await h.deliveryAuthority()
        let first = try await claim(h.queue, permission); XCTAssertEqual(first.row.prepared.sequence, 1)
        _ = try await h.queue.finishReplayClaim(first, completion: .response(.protocolBlocked))
        guard case .idle = try await h.queue.claimNextReplay(permission) else { return XCTFail("blocked head skipped") }
        let count = try await awaitCount(h.queue); XCTAssertEqual(count, 2)
        await h.queue.close()
    }

    func testRefusalPersistsAfterRenewalEndpointChangeAndReopen() async throws {
        for status in [401, 403] {
            let h = try await DeliveryHarness.make(); defer { h.remove() }
            try await h.install(); _ = try await h.append(); try await h.queue.ensureReplayDeliverySchema()
            let first = try await claim(h.queue, h.deliveryAuthority())
            _ = try await h.queue.finishReplayClaim(first, completion: .response(.credentialBlocked(status: status)))
            await h.queue.close(); h.queue = try await h.reopen()
            try await h.renew(generation: h.generation, issued: "2026-08-05T00:00:01.000Z", support: h.generation)
            let next = try await h.deliveryAuthority()
            guard case .idle = try await h.queue.claimNextReplay(next) else { return XCTFail("refused row revived") }
            let rows = try await h.queue.storedReplayChunks(); XCTAssertEqual(rows, [first.row])
            await h.queue.close()
        }
    }

    func testOldRefusalCompletionAfterNewConfigStillBlocksExactRequest() async throws {
        let h = try await DeliveryHarness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append(); try await h.queue.ensureReplayDeliverySchema()
        let old = try await claim(h.queue, h.deliveryAuthority())
        try await h.renew(generation: h.generation, issued: "2026-08-05T00:00:01.000Z", support: h.generation)
        XCTAssertFalse(old.isCurrent())
        _ = try await h.queue.finishReplayClaim(old, completion: .response(.credentialBlocked(status: 401)))
        let next = try await h.deliveryAuthority()
        guard case .idle = try await h.queue.claimNextReplay(next) else { return XCTFail("old refusal lost") }
        await h.queue.close()
    }

    func testPurgeAndPendingIntentInvalidateClaimBeforeDispatchAndStaleACKDeletesNothing() async throws {
        let h = try await DeliveryHarness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append(); try await h.queue.ensureReplayDeliverySchema()
        let permission = try await h.deliveryAuthority(); let original = try await claim(h.queue, permission)
        let intent = h.queue.beginFlagProjectionIntent(); XCTAssertFalse(original.isCurrent())
        h.queue.finishFlagProjectionIntent(intent)
        XCTAssertFalse(original.isCurrent())
        _ = try await h.queue.purgeReplay(expectedConfigWitness: h.configWitness, sourceWitness: h.witness, matching: { _ in true })
        let committed = try await h.queue.finishReplayClaim(original, completion: .response(.accepted)); XCTAssertFalse(committed)
        await h.queue.close()
    }

    func testRetryReopenReappliesFullOriginalDelay() async throws {
        let h = try await DeliveryHarness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append(); try await h.queue.ensureReplayDeliverySchema()
        let first = try await claim(h.queue, h.deliveryAuthority())
        _ = try await h.queue.finishReplayClaim(first, completion: .response(.retry(afterSeconds: 10)))
        h.testClock.advance(9); await h.queue.close(); h.queue = try await h.reopen()
        let next = try await h.deliveryAuthority()
        guard case .deferred = try await h.queue.claimNextReplay(next) else { return XCTFail("restart shortened delay") }
        h.testClock.advance(9)
        guard case .deferred = try await h.queue.claimNextReplay(next) else { return XCTFail("full delay not reapplied") }
        h.testClock.advance(1); _ = try await claim(h.queue, next)
        await h.queue.close()
    }

    func testRollbackPreservesBytesAndBlocksClaims() async throws {
        for delta in [-1.0] {
            let h = try await DeliveryHarness.make(); defer { h.remove() }
            try await h.install(); _ = try await h.append(); try await h.queue.ensureReplayDeliverySchema()
            let permission = try await h.deliveryAuthority(); let first = try await claim(h.queue, permission)
            _ = try await h.queue.finishReplayClaim(first, completion: .released)
            h.testClock.set(h.now.addingTimeInterval(delta))
            do { _ = try await h.queue.claimNextReplay(permission); XCTFail("untrusted clock") } catch {}
            let count = try await h.count(); XCTAssertEqual(count, 1)
            await h.queue.close()
        }
    }

    func testForwardWallRateDifferenceRetainsClaimEnrollmentAndExactACK() async throws {
        let h = try await DeliveryHarness.make(); defer { h.remove() }
        let prior = Date(timeIntervalSinceReferenceDate: 811_235_844.8492679595947265625)
        let later = Date(timeIntervalSinceReferenceDate: 811_235_855.48101794719696044921875)
        h.testClock.useCaptured24MHzTimebase()
        h.testClock.setFrame(wall: prior, ticks: 32_045_206_421_833)
        var config = try JSONSerialization.jsonObject(with: h.config) as! [String: Any]
        config["issuedAt"] = "2026-09-16T07:17:16.789Z"
        config["expiresAt"] = "2026-09-16T07:22:16.789Z"
        h.config = try JSONSerialization.data(withJSONObject: config)
        try await h.install()
        let request = try h.request(startedAt: "2026-09-16T07:17:20.000Z", endedAt: "2026-09-16T07:17:24.000Z")
        _ = try await h.append(request: request)
        try await h.queue.ensureReplayDeliverySchema()
        let permission = try await h.deliveryAuthority()
        let first = try await claim(h.queue, permission)
        _ = try await h.queue.finishReplayClaim(first, completion: .released)
        // Wall and continuous clocks can advance at different rates within a valid lease.
        h.testClock.setFrame(wall: later, ticks: 32_045_461_579_301)
        h.testClock.scriptTicks([32_045_461_579_301, 32_045_461_579_301, 32_045_461_581_219])
        let next: EluV2ReplayClaim
        do { next = try await claim(h.queue, permission) }
        catch {
            XCTAssertEqual(error as? EluRuntimeQueueError, .sourceAuthorityUnavailable)
            XCTFail("forward wall rate claim failed: sourceAuthorityUnavailable")
            await h.queue.close()
            return
        }
        XCTAssertEqual(next.row.prepared.body, request.body)
        XCTAssertEqual(next.attemptCount, 2)
        let enrolled = try await h.queue.enrollReplayDispatch(next, dispatchAllowed: { true })
        let dispatch = try XCTUnwrap(enrolled), use = try XCTUnwrap(dispatch.takePhysicalUse())
        let valid = await use.revalidate(); XCTAssertTrue(valid); XCTAssertTrue(use.beginOnce())
        XCTAssertEqual(use.request.body, request.body)
        use.settle()
        let ack = Self.ack(next.row.prepared)
        let outcome = EluV2ReplayResponse.classify(ack, request: next.row.prepared, now: h.now)
        XCTAssertEqual(outcome, .accepted)
        let accepted = try await h.queue.finishReplayClaim(next, completion: .response(outcome))
        XCTAssertTrue(accepted)
        let count = try await h.count(); XCTAssertEqual(count, 0)
        await h.queue.close()
        h.queue = try await h.reopen()
        let after = try await h.count(); XCTAssertEqual(after, 0)
        let current = try await h.deliveryAuthority(); XCTAssertTrue(current.isCurrent())
        await h.queue.close()
    }

    func testFuturePartialAndMissingDeliveryMetadataPreserveRowsAndRejectOpen() async throws {
        for body in ["{\"schemaVersion\":2,\"attemptCount\":0}", "{\"schemaVersion\":1,\"attemptCount\":0,\"retry\":{}}", ""] {
            let h = try await DeliveryHarness.make(); defer { h.remove() }
            try await h.install(); _ = try await h.append(); try await h.queue.ensureReplayDeliverySchema()
            let before = try await h.queue.storedReplayChunks(); await h.queue.close()
            if body.isEmpty { try h.sql("DELETE FROM replay_delivery WHERE ordinal=0") }
            else { try h.sql("UPDATE replay_delivery SET metadata=CAST('\(body)' AS BLOB) WHERE ordinal=0") }
            do { h.queue = try await h.reopen(); XCTFail("malformed metadata opened") } catch {}
            XCTAssertEqual(try h.storedBodyFromDisk(), before[0].prepared.body)
        }
    }

    func testIndependentGlobalPolicyIsRecomputedAfterContextChangeWithoutRebindingRows() async throws {
        let h = try await DeliveryHarness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append(); try await h.queue.ensureReplayDeliverySchema()
        let old = try await h.deliveryAuthority()
        let stored = try await h.queue.storedReplayChunks()
        _ = try await h.queue.registerStandaloneSuperProperties(["plan":.string("new")])
        XCTAssertFalse(old.isCurrent())
        let next = try await h.deliveryAuthority()
        let actual = try await claim(h.queue,next); XCTAssertEqual(actual.row,stored[0])
        _ = try await h.queue.finishReplayClaim(actual,completion:.response(.accepted))
        await h.queue.close()
    }

    func testSealedResolverRejectsInvalidHashClaimedBooleansMissingProofAndPolicyOff() async throws {
        let h = try await DeliveryHarness.make(); defer { h.remove() }
        try await h.install()
        let privacy = try await h.deliveryPrivacy()
        let snapshot = try await h.queue.snapshot()
        let identity = EluIdentitySnapshot(identity:snapshot.identity,streamId:snapshot.streamId,nextSequence:snapshot.nextSequence,flagContext:snapshot.flagContext)
        let pair = EluV1ReplayTransportSelection(codec:"elu-browser-dom-v1",compression:.gzip)!
        let manager = EluV1ConfigManager(readbackProvenReplayTransports:[pair])
        _ = try manager.update(configData:h.config,now:h.now)
        let fresh = try manager.authorize(effectivePrivacyStateData:privacy,identity:identity,now:h.now)
        if case .authorized = fresh.replayAuthorization { XCTFail("fresh eligibility fabricated") }
        XCTAssertNotNil(try manager.authorizeSealedReplayDelivery(effectivePrivacyStateData:privacy,identity:identity,now:h.now))
        let noProof = EluV1ConfigManager(); _ = try noProof.update(configData:h.config,now:h.now)
        XCTAssertNil(try noProof.authorizeSealedReplayDelivery(effectivePrivacyStateData:privacy,identity:identity,now:h.now))
        var object = try JSONSerialization.jsonObject(with:privacy) as! [String:Any]
        object["effectivePolicyHash"] = "sha256:" + String(repeating:"0",count:64)
        XCTAssertNil(try manager.authorizeSealedReplayDelivery(effectivePrivacyStateData:JSONSerialization.data(withJSONObject:object),identity:identity,now:h.now))
        object["replayAllowed"] = true; object.removeValue(forKey:"effectivePolicyHash")
        object["effectivePolicyHash"] = try EluV1StrictCanonicalJSON.hash(EluV1StrictCanonicalJSON.parse(JSONSerialization.data(withJSONObject:object)).canonicalData)
        XCTAssertNil(try manager.authorizeSealedReplayDelivery(effectivePrivacyStateData:JSONSerialization.data(withJSONObject:object),identity:identity,now:h.now))
        var config = try JSONSerialization.jsonObject(with:h.config) as! [String:Any]
        var features = config["features"] as! [String:Any]; features["replay"] = false; config["features"] = features
        let off = EluV1ConfigManager(readbackProvenReplayTransports:[pair]); _ = try off.update(configData:JSONSerialization.data(withJSONObject:config),now:h.now)
        XCTAssertNil(try off.authorizeSealedReplayDelivery(effectivePrivacyStateData:privacy,identity:identity,now:h.now))
        await h.queue.close()
    }

    func testEndpointCooldownBlocksAllReplaysAndRefreshDoesNotShortenDelay() async throws {
        let h = try await DeliveryHarness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append(); _ = try await h.append(request:h.request(replayId:"second",chunkId:"second"))
        try await h.queue.ensureReplayDeliverySchema(); let first = try await claim(h.queue,h.deliveryAuthority())
        _ = try await h.queue.finishReplayClaim(first,completion:.response(.endpointCooldown(seconds:5)))
        try await h.renew(generation:h.generation,issued:"2026-08-05T00:00:01.000Z",support:h.generation)
        let next = try await h.deliveryAuthority()
        guard case .deferred = try await h.queue.claimNextReplay(next) else { return XCTFail("endpoint limit bypassed") }
        h.testClock.advance(5); let retried = try await claim(h.queue,next)
        XCTAssertEqual(retried.row,first.row)
        _ = try await h.queue.finishReplayClaim(retried,completion:.response(.rejectedTooLarge))
        let second = try await claim(h.queue,next); XCTAssertEqual(second.row.prepared.replayId,"second")
        await h.queue.close()
    }

    func testSourceWithdrawalDuringClaimTransactionRollsBackAttemptAndKeepsBytes() async throws {
        let fault = DeliveryFault(); let h = try await DeliveryHarness.make(fault:fault); defer { h.remove() }
        try await h.install(); _ = try await h.append(); try await h.queue.ensureReplayDeliverySchema()
        let permission = try await h.deliveryAuthority()
        fault.action = { point in if point == .beforeCommit { h.gate.publish(token:EluV2ConfigLifecycleToken(),lease:nil) } }
        do { _ = try await h.queue.claimNextReplay(permission); XCTFail("withdrawn claim") } catch {}
        fault.action = nil
        let rows = try await h.queue.storedReplayChunks(); XCTAssertEqual(rows.count,1)
        try await h.activate(support:h.generation)
        let next = try await claim(h.queue,h.deliveryAuthority()); XCTAssertEqual(next.attemptCount,1)
        await h.queue.close()
    }

    func testLateProfileRevocationAndOptOutCloseFinalClaimGuard() async throws {
        let h = try await DeliveryHarness.make(); defer { h.remove() }
        try await h.install(); _ = try await h.append(); try await h.queue.ensureReplayDeliverySchema()
        let flag = DeliveryProfileFlag()
        let authority = try await h.deliveryAuthority(retain:{ _ in flag.read() })
        let first = try await claim(h.queue,authority)
        let allowed = try await h.queue.revalidateReplayClaim(first); XCTAssertTrue(allowed)
        flag.set(false); XCTAssertFalse(first.isCurrent())
        let snapshot = try await h.queue.snapshot()
        _ = try await h.queue.setOptedOut(true,expectedGeneration:snapshot.generation)
        let completed = try await h.queue.finishReplayClaim(first,completion:.response(.accepted)); XCTAssertFalse(completed)
        let rows = try await h.queue.storedReplayChunks(); XCTAssertTrue(rows.isEmpty)
        await h.queue.close()
    }

    func testDeliveryMigrationCommitFaultPreservesExistingPoisonPolicyAndRows() async throws {
        for point in [EluRuntimeQueueFaultPoint.beforeCommit,.afterCommit] {
            let fault = DeliveryFault(); let h = try await DeliveryHarness.make(fault:fault); defer { h.remove() }
            try await h.install(); _ = try await h.append()
            let rows = try await h.queue.storedReplayChunks()
            fault.action = { actual in if actual == point { throw EluRuntimeQueueError.faultInjected(actual) } }
            do { try await h.queue.ensureReplayDeliverySchema(); XCTFail("fault ignored") }
            catch { XCTAssertEqual(error as? EluRuntimeQueueError,point == .beforeCommit ? .provenNotCommitted : .ambiguousCommit) }
            fault.action = nil; await h.queue.close(); h.queue = try await h.reopen()
            let reopened = try await h.queue.storedReplayChunks(); XCTAssertEqual(reopened,rows)
            XCTAssertEqual(try h.schemaVersion(),point == .beforeCommit ? 3 : 5)
            await h.queue.close()
        }
    }

    func testLate401AfterClosePersistsBeforePhysicalAndReceiptLeaseRelease() async throws {
        let h=try await DeliveryHarness.make();defer{h.remove()}
        try await h.install();_ = try await h.append();try await h.queue.ensureReplayDeliverySchema()
        let permission=try await h.deliveryAuthority(), began=expectation(description:"physical started")
        let transport=HeldReplayTransport{began.fulfill()}
        let driver=EluV2ReplayDeliveryCoordinator(queue:h.queue,transport:transport,wallNow:{h.now})
        let work=Task{await driver.trigger(permission)}
        await fulfillment(of:[began],timeout:2)
        await driver.withdraw();await h.queue.close()
        do{let next=try await h.reopen();await next.close();XCTFail("Physical owner overlap")}
        catch{XCTAssertEqual(error as? EluRuntimeQueueError,.ownershipConflict)}
        await transport.complete(EluV1BatchHTTPResponse(status:401,headers:[:],body:Data([255])))
        let result=await work.value;XCTAssertEqual(result.blocked,1)
        h.queue=try await h.reopen()
        let current=try await h.deliveryAuthority()
        guard case .idle=try await h.queue.claimNextReplay(current) else{return XCTFail("Late refusal lost")}
        let rows=try await h.queue.storedReplayChunks();XCTAssertEqual(rows.count,1)
        await h.queue.close()
    }

    func testFailedPermanentReceiptQuarantinesOwnerEvenAfterPhysicalSettlement() async throws {
        let fault=DeliveryFault(),h=try await DeliveryHarness.make(fault:fault);defer{h.remove()}
        try await h.install();_ = try await h.append();try await h.queue.ensureReplayDeliverySchema()
        let original=try await claim(h.queue,h.deliveryAuthority())
        let enrolled=try await h.queue.enrollReplayDispatch(original,dispatchAllowed:{true});let dispatch=try XCTUnwrap(enrolled)
        let use=try XCTUnwrap(dispatch.takePhysicalUse());XCTAssertTrue(use.beginOnce());XCTAssertFalse(use.beginOnce())
        fault.action={point in if point == .beforeCommit{throw EluRuntimeQueueError.faultInjected(point)}}
        do{_ = try await h.queue.finishReplayClaim(original,completion:.response(.credentialBlocked(status:403)));XCTFail("Refusal fault ignored")}
        catch{XCTAssertEqual(error as? EluRuntimeQueueError,.provenNotCommitted)}
        fault.action=nil;use.settle();await h.queue.close()
        do{let next=try await h.reopen();await next.close();XCTFail("Unrecorded refusal released")}
        catch{XCTAssertEqual(error as? EluRuntimeQueueError,.ownershipConflict)}
    }

    func testPoisonDuringEnrolledDispatchRetainsPhysicalOwnerAndForbidsReceiptWrite() async throws {
        let fault=DeliveryFault(),h=try await DeliveryHarness.make(fault:fault);defer{h.remove()}
        try await h.install();_ = try await h.append();try await h.queue.ensureReplayDeliverySchema()
        let original=try await claim(h.queue,h.deliveryAuthority())
        let enrolled=try await h.queue.enrollReplayDispatch(original,dispatchAllowed:{true});let dispatch=try XCTUnwrap(enrolled),use=try XCTUnwrap(dispatch.takePhysicalUse())
        XCTAssertTrue(use.beginOnce())
        fault.action={point in if point == .afterCommit{throw EluRuntimeQueueError.faultInjected(point)}}
        do{_ = try await h.queue.reconcileReplayConfiguration(configData:h.config,expectedConfigWitness:h.configWitness,sourceWitness:h.witness,supportedProtocolGeneration:h.generation,mayRetainProfile:{_ in true});XCTFail("Poison fault ignored")}
        catch{XCTAssertEqual(error as? EluRuntimeQueueError,.ambiguousCommit)}
        fault.action=nil;use.settle()
        do{_ = try await h.queue.finishReplayClaim(original,completion:.response(.credentialBlocked(status:401)));XCTFail("Poisoned receipt write")}
        catch{XCTAssertEqual(error as? EluRuntimeQueueError,.poisoned)}
        do{let next=try await h.reopen();await next.close();XCTFail("Poisoned physical lease released")}
        catch{XCTAssertEqual(error as? EluRuntimeQueueError,.ownershipConflict)}
    }

    func testUnusedCancellationIsTerminalBeforeAndAfterReceiptFinalization() async throws {
        let h=try await DeliveryHarness.make();defer{h.remove()}
        try await h.install();_ = try await h.append();try await h.queue.ensureReplayDeliverySchema()
        let original=try await claim(h.queue,h.deliveryAuthority())
        let enrolled=try await h.queue.enrollReplayDispatch(original,dispatchAllowed:{true}),dispatch=try XCTUnwrap(enrolled)
        dispatch.cancelUnused()
        XCTAssertNil(dispatch.takePhysicalUse())
        await h.queue.close()
        do{let next=try await h.reopen();await next.close();XCTFail("Receipt still pending")}
        catch{XCTAssertEqual(error as? EluRuntimeQueueError,.ownershipConflict)}
        _ = try await h.queue.finishReplayClaim(original,completion:.released)
        XCTAssertNil(dispatch.takePhysicalUse())
        let next=try await h.reopen();await next.close()
    }

    func testReplayOrdinalCounterStopsAtSafeIntegerWithoutLosingExistingBytes() async throws {
        let h=try await DeliveryHarness.make();defer{h.remove()}
        try await h.install();try await h.queue.ensureReplayDeliverySchema()
        try h.sql("UPDATE replay_state SET next_ordinal=9007199254740990 WHERE singleton=1")
        guard case let .inserted(row)=try await h.append() else{return XCTFail("last safe ordinal")}
        XCTAssertEqual(row.ordinal,9_007_199_254_740_990)
        do{_ = try await h.append(request:h.request(chunkId:"next",sequence:2));XCTFail("counter overflow")}
        catch{XCTAssertEqual(error as? EluRuntimeQueueError,.counterExhausted)}
        let rows=try await h.queue.storedReplayChunks();XCTAssertEqual(rows,[row])
        await h.queue.close();h.queue=try await h.reopen();await h.queue.close()
        try h.sql("UPDATE replay_state SET next_ordinal=9007199254740992 WHERE singleton=1")
        do{h.queue=try await h.reopen();XCTFail("unsafe future counter")}
        catch{XCTAssertEqual(error as? EluRuntimeQueueError,.corruptStorage)}
        XCTAssertEqual(try h.storedBodyFromDisk(),row.prepared.body)
    }

    func testWithdrawDuringEnrollmentPreventsSourceUnchangedDispatch() async throws {
        let fault=DeliveryFault(),h=try await DeliveryHarness.make(fault:fault);defer{h.remove()}
        try await h.install();_ = try await h.append();try await h.queue.ensureReplayDeliverySchema()
        let permission=try await h.deliveryAuthority(),entered=expectation(description:"enrollment transaction")
        let release=DispatchSemaphore(value:0)
        var transactions=0
        fault.action={point in
            if point == .afterBegin{transactions += 1}
            if point == .beforeCommit,transactions == 2{entered.fulfill();XCTAssertEqual(release.wait(timeout:.now()+3),.success)}
        }
        let transport=DeliveryMockTransport{_ in XCTFail("Withdrawn enrollment sent");throw CancellationError()}
        let driver=EluV2ReplayDeliveryCoordinator(queue:h.queue,transport:transport,wallNow:{h.now})
        let work=Task{await driver.trigger(permission)}
        await fulfillment(of:[entered],timeout:2)
        await driver.withdraw();release.signal()
        let result=await work.value;XCTAssertEqual(result.stopped,.withdrawn)
        fault.action=nil;let sent=await transport.bodies;XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(permission.isCurrent())
        await h.queue.close()
    }

    func testFinalDispatchPredicateDeniesAfterSuccessfulEnrollment() async throws {
        let h=try await DeliveryHarness.make();defer{h.remove()}
        try await h.install();_ = try await h.append();try await h.queue.ensureReplayDeliverySchema()
        let original=try await claim(h.queue,h.deliveryAuthority()),flag=DeliveryProfileFlag()
        let enrolled=try await h.queue.enrollReplayDispatch(original,dispatchAllowed:{flag.read()}),dispatch=try XCTUnwrap(enrolled)
        let use=try XCTUnwrap(dispatch.takePhysicalUse())
        let validated=await use.revalidate();XCTAssertTrue(validated)
        flag.set(false);XCTAssertFalse(use.beginOnce());use.settle()
        _ = try await h.queue.finishReplayClaim(original,completion:.released)
        await h.queue.close()
    }

    func testSeventeenthReadyRowContinuesAfterBoundedPassWithoutExternalTrigger() async throws {
        let h=try await DeliveryHarness.make();defer{h.remove()}
        try await h.install()
        for sequence in 1...17{_ = try await h.append(request:h.request(chunkId:"chunk-\(sequence)",sequence:sequence))}
        try await h.queue.ensureReplayDeliverySchema()
        let sent=expectation(description:"all rows sent");sent.expectedFulfillmentCount=17
        let transport=DeliveryMockTransport{request in
            sent.fulfill();return Self.ack(try EluV2ReplayPreparedRequest(request.body,captureProtocolGeneration:h.generation))
        }
        let driver=EluV2ReplayDeliveryCoordinator(queue:h.queue,transport:transport,wallNow:{h.now})
        let result=await driver.trigger(try await h.deliveryAuthority())
        XCTAssertEqual(result.attempted,16);XCTAssertEqual(result.stopped,.bounded)
        await fulfillment(of:[sent],timeout:3)
        for _ in 0..<300{if try await h.count() == 0{break};try await Task.sleep(nanoseconds:1_000_000)}
        let remaining=try await h.count();XCTAssertEqual(remaining,0)
        await driver.close();await h.queue.close()
    }

    func testCanceledOlderRetryWakeCannotReplaceNewerWake() async throws {
        let h=try await DeliveryHarness.make();defer{h.remove()}
        try await h.install();_ = try await h.append();try await h.queue.ensureReplayDeliverySchema()
        let sleeper=HeldRetrySleeper(),counter=DeliveryAttemptCounter(),sent=expectation(description:"third attempt")
        let transport=DeliveryMockTransport{request in
            if counter.next() < 3{throw URLError(.networkConnectionLost)}
            sent.fulfill();return Self.ack(try EluV2ReplayPreparedRequest(request.body,captureProtocolGeneration:h.generation))
        }
        let driver=EluV2ReplayDeliveryCoordinator(queue:h.queue,transport:transport,wallNow:{h.now},sleep:{delay in await sleeper.sleep(delay)})
        let authority=try await h.deliveryAuthority()
        _ = await driver.trigger(authority);await sleeper.waitForCount(1)
        h.testClock.advance(1)
        _ = await driver.trigger(authority);await sleeper.waitForCount(2)
        await sleeper.resume(0)
        h.testClock.advance(2);await sleeper.resume(1)
        await fulfillment(of:[sent],timeout:3)
        await driver.close();await h.queue.close()
    }

    func testCloseAndWaitJoinsPhysicalWorkAndLateReceiptDespiteCallerCancellation() async throws {
        let fault = DeliveryFault(), h = try await DeliveryHarness.make(fault: fault)
        defer { h.remove() }
        try await h.install(); _ = try await h.append(); try await h.queue.ensureReplayDeliverySchema()
        let authority = try await h.deliveryAuthority()
        let began = expectation(description: "physical request started")
        let transport = HeldReplayTransport { began.fulfill() }
        let driver = EluV2ReplayDeliveryCoordinator(queue: h.queue, transport: transport, wallNow: { h.now })
        let work = Task { await driver.trigger(authority) }
        await fulfillment(of: [began], timeout: 2)
        await driver.close()
        let completed = DeliveryProfileFlag(); completed.set(false)
        let closing = Task { let result = await driver.closeAndWait(); completed.set(true); return result }
        closing.cancel()
        let duplicate = Task { await driver.closeAndWait() }
        await waitForRegisteredCloseWaiters(2, driver: driver)
        let refused = await driver.trigger(authority)
        XCTAssertEqual(refused.stopped, .closed)
        XCTAssertFalse(completed.read())

        let receiptEntered = expectation(description: "original receipt transaction")
        let releaseReceipt = DispatchSemaphore(value: 0)
        fault.action = { point in
            if point == .beforeCommit {
                receiptEntered.fulfill()
                XCTAssertEqual(releaseReceipt.wait(timeout: .now() + 3), .success)
            }
        }
        await transport.complete(EluV1BatchHTTPResponse(status: 403, headers: [:], body: Data()))
        await fulfillment(of: [receiptEntered], timeout: 2)
        let receiptWaiters = await driver.registeredCloseWaiterCountForTesting()
        XCTAssertEqual(receiptWaiters, 2, "Both exact close waiters remain registered through receipt finalization")
        XCTAssertFalse(completed.read(), "Physical completion alone is not durable settlement")
        fault.action = nil
        releaseReceipt.signal()
        let result = await work.value
        XCTAssertEqual(result.blocked, 1)
        let closed = await closing.value, alsoClosed = await duplicate.value
        XCTAssertEqual(closed, .settled); XCTAssertEqual(alsoClosed, .settled)
        XCTAssertTrue(completed.read())
        await h.queue.close(); h.queue = try await h.reopen()
        let next = try await h.deliveryAuthority()
        guard case .idle = try await h.queue.claimNextReplay(next) else { return XCTFail("Late refusal was lost") }
        await h.queue.close()
    }

    func testCloseAndWaitReportsPermanentReceiptQuarantineAndPreservesOwnership() async throws {
        let fault = DeliveryFault(), h = try await DeliveryHarness.make(fault: fault)
        defer { h.remove() }
        try await h.install(); _ = try await h.append(); try await h.queue.ensureReplayDeliverySchema()
        let authority = try await h.deliveryAuthority()
        let transport = DeliveryMockTransport { _ in
            fault.action = { point in
                if point == .beforeCommit { throw EluRuntimeQueueError.faultInjected(point) }
            }
            return EluV1BatchHTTPResponse(status: 403, headers: [:], body: Data())
        }
        let driver = EluV2ReplayDeliveryCoordinator(queue: h.queue, transport: transport, wallNow: { h.now })
        let result = await driver.trigger(authority)
        XCTAssertEqual(result.stopped, .storageFailure)
        fault.action = nil
        let closed = await driver.closeAndWait(), repeated = await driver.closeAndWait()
        XCTAssertEqual(closed, .quarantined); XCTAssertEqual(repeated, .quarantined)
        await h.queue.close()
        do { let next = try await h.reopen(); await next.close(); XCTFail("Unrecorded refusal released ownership") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict) }
    }

    func testCloseAndWaitJoinsTimerOriginPassAfterBoundedBacklog() async throws {
        let h = try await DeliveryHarness.make(); defer { h.remove() }
        try await h.install()
        for sequence in 1...17 { _ = try await h.append(request: h.request(chunkId: "close-\(sequence)", sequence: sequence)) }
        try await h.queue.ensureReplayDeliverySchema()
        let began = expectation(description: "timer-origin seventeenth request")
        let held = HeldReplayTransport { began.fulfill() }
        let transport = BacklogHeldReplayTransport(held: held) { request in
            Self.ack(try EluV2ReplayPreparedRequest(request.body, captureProtocolGeneration: h.generation))
        }
        let driver = EluV2ReplayDeliveryCoordinator(queue: h.queue, transport: transport, wallNow: { h.now })
        let first = await driver.trigger(try await h.deliveryAuthority())
        XCTAssertEqual(first.attempted, 16); XCTAssertEqual(first.stopped, .bounded)
        await fulfillment(of: [began], timeout: 3)
        await driver.close()
        let completed = DeliveryProfileFlag(); completed.set(false)
        let closing = Task { let outcome = await driver.closeAndWait(); completed.set(true); return outcome }
        await waitForRegisteredCloseWaiters(1, driver: driver)
        XCTAssertFalse(completed.read())
        await held.complete(EluV1BatchHTTPResponse(status: 401, headers: [:], body: Data()))
        let closed = await closing.value
        XCTAssertEqual(closed, .settled); XCTAssertTrue(completed.read())
        let rows = try await h.queue.storedReplayChunks()
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.prepared.sequence, 17)
        let authority = try await h.deliveryAuthority()
        guard case .idle = try await h.queue.claimNextReplay(authority) else { return XCTFail("Timer-origin refusal was lost") }
        await h.queue.close()
    }

    private func waitForRegisteredCloseWaiters(_ expected: Int,
        driver: EluV2ReplayDeliveryCoordinator, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(2)
        var observed = await driver.registeredCloseWaiterCountForTesting()
        while observed != expected && Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
            observed = await driver.registeredCloseWaiterCountForTesting()
        }
        XCTAssertEqual(observed, expected, "The exact close calls must register before their physical gate is released", file: file, line: line)
    }

    private func claim(_ queue: EluSQLiteRuntimeQueue, _ authority: EluV2ReplayDeliveryAuthority) async throws -> EluV2ReplayClaim {
        guard case let .claimed(value) = try await queue.claimNextReplay(authority) else { throw EluRuntimeQueueError.invalidState }; return value
    }
    private func awaitCount(_ queue: EluSQLiteRuntimeQueue) async throws -> Int64 { try await queue.replayInventory().replayCount }
    private static func ack(_ request: EluV2ReplayPreparedRequest) -> EluV1BatchHTTPResponse {
        EluV1BatchHTTPResponse(status: 200, headers: [:], body: Data("{\"schemaVersion\":2,\"requestId\":\"\(request.requestId)\",\"replayId\":\"\(request.replayId)\",\"chunkId\":\"\(request.chunkId)\",\"sequence\":\(request.sequence),\"result\":\"accepted\"}".utf8))
    }
}

private actor DeliveryMockTransport: EluV2ReplayHTTPTransport {
    var bodies: [Data] = []
    let response: @Sendable (EluV1BatchHTTPRequest) throws -> EluV1BatchHTTPResponse
    init(_ response: @escaping @Sendable (EluV1BatchHTTPRequest) throws -> EluV1BatchHTTPResponse) { self.response = response }
    func send(_ dispatch: EluV2ReplayDispatch) async throws -> EluV1BatchHTTPResponse {
        guard let use = dispatch.takePhysicalUse() else { throw EluV1BoundTransportError.occupied }
        defer { use.settle() }
        guard await use.revalidate(), use.beginOnce() else { throw EluV1BoundTransportError.staleAuthority }
        bodies.append(use.request.body); return try response(use.request)
    }
}

private func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("Conformance/V2/fixtures/" + name))
}

final class DeliveryFault: EluRuntimeQueueFaultInjecting, @unchecked Sendable {
    var action: ((EluRuntimeQueueFaultPoint) throws -> Void)?
    func hit(_ point: EluRuntimeQueueFaultPoint) throws { try action?(point) }
}

final class DeliveryHarness: @unchecked Sendable {
    let root: URL
    var queue: EluSQLiteRuntimeQueue
    let gate: EluV2ConfigAuthorityGate
    let limits: EluRuntimeQueueLimits
    let testClock: DeliveryClock
    let fault: DeliveryFault?
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
    init(root: URL, queue: EluSQLiteRuntimeQueue, gate: EluV2ConfigAuthorityGate, limits: EluRuntimeQueueLimits, config: Data, testClock: DeliveryClock, fault: DeliveryFault?) {
        self.root = root; self.queue = queue; self.gate = gate; self.limits = limits; self.config = config; self.testClock = testClock; self.fault = fault
    }
    static func make(limits: EluRuntimeQueueLimits? = nil, fault: DeliveryFault? = nil) async throws -> DeliveryHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("elu-replay-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let testClock = DeliveryClock()
        let gate = EluV2ConfigAuthorityGate(siteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", clock: EluV2ConfigClock(wallNow: { testClock.read() }, continuousNow: { testClock.ticks() }, floorTicks: { testClock.convert($0) }, floorNanoseconds: { $0 }))
        let limits = try limits ?? EluRuntimeQueueLimits()
        let queue = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: root, exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", limits: limits,
            clock: { testClock.read() }, continuousClock: { testClock.ticks() }, continuousBudgetConverter: { testClock.convert($0) }, anonymousIdGenerator: { "anon-storage" }, sessionIdGenerator: { "session-storage" }, configurationGate: gate, faultInjector: fault)
        return DeliveryHarness(root: root, queue: queue, gate: gate, limits: limits, config: try fixture("config-enabled.json"), testClock: testClock, fault: fault)
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
        gate.publish(token: token, lease: EluV2ConfigLease(data: config, expiresAt: document.expiresAt, continuousDeadline: testClock.ticks() + testClock.convert(600_000_000_000)!))
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
    func request(replayId: String? = nil, chunkId: String = "chunk_000001", sequence: Int = 1, startedAt: String = "2026-08-05T00:01:00.000Z", sessionId: String = "session-storage", policyRevision: String? = nil, effectivePolicyHash: String? = nil, maskingProfile: Data? = nil, endedAt: String? = nil) throws -> EluV2ReplayPreparedRequest {
        var root = try JSONSerialization.jsonObject(with: fixture("replay-request.json")) as! [String: Any]
        var chunk = root["chunk"] as! [String: Any]
        chunk["identity"] = ["anonymousId": "anon-storage", "userId": NSNull(), "revision": 0]
        chunk["sessionId"] = sessionId
        if let replayId { chunk["replayId"] = replayId }
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
        return try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: root, exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", limits: limits, clock: { clock.read() }, continuousClock: { clock.ticks() }, continuousBudgetConverter: { clock.convert($0) }, configurationGate: gate, faultInjector: fault)
    }
    func seedSessionForReopen(_ transform: (inout EluSessionState) -> Void) async throws {
        var identity = try await queue.snapshot().identity
        var session = try XCTUnwrap(identity.session)
        transform(&session); identity.session = session
        let data = try EluStateCoding.encoder().encode(identity)
        await queue.close()
        let namespace = try EluV1SiteNamespace.directoryComponent(exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa")
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
    func deliveryPrivacy(budget: Int = 0, eligible: Bool = false, sampled: Double = 0.99) async throws -> Data {
        let pair = EluV1ReplayTransportSelection(codec: "elu-browser-dom-v1", compression: .gzip)!
        let manager = EluV1ConfigManager(readbackProvenReplayTransports: [pair])
        _ = try manager.update(configData: config, now: now)
        let snapshot = try await queue.snapshot()
        let input = EluPrivacyProjectionInput(contextRevision: snapshot.identity.contextRevision, identityOptedOut: snapshot.identity.optedOut,
            timeZoneIdentifier: "America/Los_Angeles", evaluatedAt: now,
            appliedMasking: EluPrivacyMaskingCapability(text: .all, inputs: .all, images: .block),
            replaySampleDraw: sampled, replaySessionEligible: eligible, replayBudgetRemainingSeconds: budget,
            localReplayTransports: [EluV1ReplayTransportPair(codec: pair.codec, compression: pair.compression)])
        let projected = try EluPrivacyStateProjector.project(context: manager.activePrivacyProjectionContext(now: now), input: input)
        return projected.stateData
    }
    func deliveryAuthority(budget: Int = 0, eligible: Bool = false, sampled: Double = 0.99,
        retain: @escaping @Sendable (Data) -> Bool = { _ in true }) async throws -> EluV2ReplayDeliveryAuthority {
        let pair = EluV1ReplayTransportSelection(codec: "elu-browser-dom-v1", compression: .gzip)!
        let privacy = try await deliveryPrivacy(budget: budget, eligible: eligible, sampled: sampled)
        let value = try await queue.authorizeSealedReplayDelivery(configData: config, effectivePrivacyStateData: privacy,
            sourceWitness: XCTUnwrap(witness), readbackProvenTransports: [pair], supportedProtocolGeneration: generation, mayRetainProfile: retain)
        return try XCTUnwrap(value)
    }
    func sql(_ query: String) throws {
        let namespace = try EluV1SiteNamespace.directoryComponent(exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa")
        let path = root.appendingPathComponent(namespace).appendingPathComponent("runtime-state-v1.sqlite3").path
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, query, nil, nil, nil), SQLITE_OK)
    }
    func storedBodyFromDisk() throws -> Data {
        let namespace = try EluV1SiteNamespace.directoryComponent(exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa")
        let path = root.appendingPathComponent(namespace).appendingPathComponent("runtime-state-v1.sqlite3").path
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db,"SELECT body FROM replay_chunks ORDER BY ordinal",-1,&statement,nil),SQLITE_OK)
        defer { sqlite3_finalize(statement) }; XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW)
        let size = Int(sqlite3_column_bytes(statement,0)); XCTAssertTrue((1...5_242_880).contains(size))
        let bytes = try XCTUnwrap(sqlite3_column_blob(statement,0)); let data = Data(bytes:bytes,count:size)
        XCTAssertEqual(sqlite3_step(statement),SQLITE_DONE); return data
    }
    func schemaVersion() throws -> Int64 {
        let namespace = try EluV1SiteNamespace.directoryComponent(exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa")
        let path = root.appendingPathComponent(namespace).appendingPathComponent("runtime-state-v1.sqlite3").path
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }; XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

final class DeliveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now = Date(timeIntervalSince1970: 1_785_888_090)
    private var continuous: UInt64 = 1
    private var captured24MHz = false
    private var pendingTicks: [UInt64] = []
    func ticks() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        if !pendingTicks.isEmpty { continuous = pendingTicks.removeFirst() }
        return continuous
    }
    func convert(_ nanoseconds: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return converted(nanoseconds)
    }
    private func converted(_ nanoseconds: UInt64) -> UInt64 {
        guard captured24MHz else { return nanoseconds }
        return (nanoseconds / 125) * 3 + ((nanoseconds % 125) * 3) / 125
    }
    func useCaptured24MHzTimebase() { lock.lock(); captured24MHz = true; lock.unlock() }
    func setFrame(wall: Date, ticks: UInt64) { lock.lock(); now = wall; continuous = ticks; pendingTicks = []; lock.unlock() }
    func scriptTicks(_ values: [UInt64]) { lock.lock(); pendingTicks = values; lock.unlock() }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return now }
    func set(_ value: Date) { lock.lock(); now = value; lock.unlock() }
    func advance(_ seconds: TimeInterval) { lock.lock(); now = now.addingTimeInterval(seconds); continuous += converted(UInt64(max(0, seconds) * 1_000_000_000)); lock.unlock() }
}

private final class DeliveryProfileFlag: @unchecked Sendable {
    private let lock=NSLock(); private var value=true
    func read()->Bool { lock.lock();defer{lock.unlock()};return value }
    func set(_ next:Bool) { lock.lock();value=next;lock.unlock() }
}

private actor HeldReplayTransport:EluV2ReplayHTTPTransport {
    private let began:@Sendable()->Void
    private var continuation:CheckedContinuation<EluV1BatchHTTPResponse,Never>?
    init(_ began:@escaping @Sendable()->Void){self.began=began}
    func send(_ dispatch:EluV2ReplayDispatch) async throws -> EluV1BatchHTTPResponse {
        guard let use=dispatch.takePhysicalUse() else{throw EluV1BoundTransportError.occupied}
        defer{use.settle()}
        guard await use.revalidate(),use.beginOnce() else{throw EluV1BoundTransportError.staleAuthority}
        return await withCheckedContinuation{continuation in self.continuation=continuation;began()}
    }
    func complete(_ response:EluV1BatchHTTPResponse){let value=continuation;continuation=nil;value?.resume(returning:response)}
}

private actor BacklogHeldReplayTransport: EluV2ReplayHTTPTransport {
    let held: HeldReplayTransport
    let response: @Sendable (EluV1BatchHTTPRequest) throws -> EluV1BatchHTTPResponse
    private var attempts = 0
    init(held: HeldReplayTransport, response: @escaping @Sendable (EluV1BatchHTTPRequest) throws -> EluV1BatchHTTPResponse) {
        self.held = held; self.response = response
    }
    func send(_ dispatch: EluV2ReplayDispatch) async throws -> EluV1BatchHTTPResponse {
        attempts += 1
        if attempts == 17 { return try await held.send(dispatch) }
        guard let use = dispatch.takePhysicalUse() else { throw EluV1BoundTransportError.occupied }
        defer { use.settle() }
        guard await use.revalidate(), use.beginOnce() else { throw EluV1BoundTransportError.staleAuthority }
        return try response(use.request)
    }
}

private final class DeliveryAttemptCounter:@unchecked Sendable {
    private let lock=NSLock();private var count=0
    func next()->Int{lock.lock();defer{lock.unlock()};count += 1;return count}
}
private actor HeldRetrySleeper {
    private var sleepers:[CheckedContinuation<Void,Never>?]=[]
    func sleep(_ delay:UInt64) async{await withCheckedContinuation{sleepers.append($0)}}
    func waitForCount(_ count:Int) async{while sleepers.count<count{await Task.yield()}}
    func resume(_ index:Int){guard index<sleepers.count else{return};let value=sleepers[index];sleepers[index]=nil;value?.resume()}
}
