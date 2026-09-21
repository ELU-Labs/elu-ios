import Foundation
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import EluAnalytics

final class EluNativeReplayAuthorityTests: XCTestCase {
    private var capability: EluNativeReplayCapabilities {
        .init(readbackProvenTransports: [EluV1ReplayTransportSelection(codec: "elu-native-wireframe-v1", compression: .gzip)!])
    }

    func testViewPrivacyStrengtheningRetiresPreparedAuthority() async throws {
        let h = try await make(); defer { h.base.remove() }
        let owner = EluNativeReplayAuthority(queue: h.queue, clock: { h.base.now })
        let source = try XCTUnwrap(h.base.witness)
        let original = try await owner.prepare(source: source, capabilities: capability, timeZoneIdentifier: "America/Los_Angeles")
        XCTAssertTrue(original.isCurrent())
        EluNativeViewPrivacy.shared.strengthen()
        XCTAssertFalse(original.isCurrent())
        let fresh = try await owner.prepare(source: source, capabilities: capability, timeZoneIdentifier: "America/Los_Angeles")
        XCTAssertTrue(fresh.isCurrent())
        await owner.close(); await h.queue.close()
    }

    func testDurableFalseRemainsFalseWhenCurrentRateBecomesOne() async throws {
        let h = try await make(rate: 0); defer { h.base.remove() }
        _ = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        try await h.update(rate: 1, cap: 60)
        let input = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        let privacy = try project(input, now: h.base.now)
        let body = try JSONSerialization.jsonObject(with: privacy.stateData) as! [String: Any]
        XCTAssertEqual(body["replaySampled"] as? Bool, false)
        XCTAssertEqual(body["replayAllowed"] as? Bool, false)
        XCTAssertTrue(input.sessionEligible)
        await h.queue.close()
    }

    func testFullHashInstallReplacesOldObservationAndPrecedesStartReceipt() async throws {
        let h = try await make(); defer { h.base.remove() }
        let before = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        let privacy = try project(before, now: h.base.now)
        let installed = try await h.queue.installNativeReplayPrivacy(before, privacy: privacy)
        XCTAssertFalse(before.isCurrent()); XCTAssertTrue(installed.isCurrent())
        let oldStart = try await h.queue.beginNativeReplayStartAccounting(before); XCTAssertNil(oldStart)
        let capture = await h.queue.captureAuthorityForTesting()
        guard case let .authorized(value) = capture else { return XCTFail("full capture proof required") }
        XCTAssertEqual(value.decisionHash, privacy.effectivePolicyHash)
        let pendingReceipt = try await h.queue.beginNativeReplayStartAccounting(installed)
        let receipt = try XCTUnwrap(pendingReceipt)
        _ = try await h.queue.stopNativeReplayAccounting(receipt); await h.queue.close()
    }

    func testSameSessionActivityAndAckKeepOriginalFullPrivacyAndGuard() async throws {
        let h = try await make(); defer { h.base.remove() }
        let owner = EluNativeReplayAuthority(queue: h.queue, clock: { h.base.now })
        let source = try XCTUnwrap(h.base.witness)
        let before = try await owner.prepare(source: source, capabilities: capability, timeZoneIdentifier: "America/Los_Angeles")
        h.base.testClock.advance(0.25)
        guard case let .accepted(record, snapshot) = await h.base.capture() else { return XCTFail("activity failed") }
        _ = try await h.queue.acknowledge([EluQueueAcknowledgementReference(streamId: snapshot.streamId,
            sequence: record.sequence, kind: record.kind, recordId: record.recordId)])
        XCTAssertTrue(before.isCurrent())
        let after = try await owner.prepare(source: source, capabilities: capability, timeZoneIdentifier: "America/Los_Angeles")
        XCTAssertEqual(after.privacy.stateData, before.privacy.stateData)
        await owner.close(); await h.queue.close()
    }

    func testOpaqueStartRetainsOriginalProofAcrossSameSessionAppendAndAck() async throws {
        let h = try await make(); defer { h.base.remove() }
        let original = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        let privacy = try project(original, now: h.base.now)
        let input = try await h.queue.installNativeReplayPrivacy(original, privacy: privacy)
        let before = try await h.queue.snapshot()
        h.base.testClock.advance(0.25)
        guard case let .accepted(record, snapshot) = await h.base.capture() else { return XCTFail("same-session activity") }
        _ = try await h.queue.acknowledge([.init(streamId: snapshot.streamId, sequence: record.sequence, kind: record.kind, recordId: record.recordId)])
        let after = try await h.queue.snapshot()
        XCTAssertGreaterThan(after.generation, before.generation)
        XCTAssertEqual(after.identity.revision, before.identity.revision)
        XCTAssertEqual(after.identity.contextRevision, before.identity.contextRevision)
        XCTAssertEqual(after.identity.session?.id, before.identity.session?.id)
        XCTAssertTrue(input.isCurrent())
        let started = try await h.queue.beginNativeReplayStartAccounting(input)
        let receipt = try XCTUnwrap(started, "generic queue changes cannot strand the original current proof")
        let capture = await h.queue.captureAuthorityForTesting()
        guard case let .authorized(authority) = capture else { return XCTFail("original capture authority") }
        XCTAssertEqual(authority.decisionHash, privacy.effectivePolicyHash)
        _ = try await h.queue.stopNativeReplayAccounting(receipt); await h.queue.close()
    }

    func testOpaqueStartStillRejectsChangedIdentityContextSessionAndSource() async throws {
        for change in ["identity", "context", "session", "source"] {
            let h = try await make(); defer { h.base.remove() }
            let original = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
            let privacy = try project(original, now: h.base.now)
            let input = try await h.queue.installNativeReplayPrivacy(original, privacy: privacy)
            let before = try await h.queue.nativeReplaySessionState()
            switch change {
            case "identity":
                let snapshot = try await h.queue.snapshot()
                let versions = try EluVersionContext(runtime: .init(name: "elu-ios", version: "0.1.0"), facade: .init(name: "elu-ios", version: "0.1.0"))
                _ = try await h.queue.applyOwnedMutation(.identify(userId: "native-next", set: [:], setOnce: [:]), versions: versions, expectedGeneration: snapshot.generation)
            case "context": _ = try await h.queue.registerStandaloneSuperProperties(["fixture": .string("next")])
            case "session": _ = try await h.queue.markStandaloneBackgrounded()
            default: try await h.publish()
            }
            XCTAssertFalse(input.isCurrent(), change)
            let start = try await h.queue.beginNativeReplayStartAccounting(input); XCTAssertNil(start, change)
            let after = try await h.queue.nativeReplaySessionState()
            XCTAssertEqual(after.nextReplayOrdinal, before.nextReplayOrdinal, change)
            XCTAssertNil(after.session?.firstStartAt, change); XCTAssertNil(after.session?.activeEpoch, change)
            await h.queue.close()
        }
    }

    func testSameDocumentRenewalCannotRebindCapturedProjection() async throws {
        let h = try await make(); defer { h.base.remove() }
        let original = try XCTUnwrap(h.base.witness)
        let input = try await h.queue.nativeReplayProjection(source: original)
        let privacy = try project(input, now: h.base.now)
        try await h.publish()
        XCTAssertFalse(input.isCurrent()); XCTAssertNotEqual(original, h.base.witness)
        do { _ = try await h.queue.installNativeReplayPrivacy(input, privacy: privacy); XCTFail("renewed source adopted") } catch {}
        do { _ = try await h.queue.nativeReplayProjection(source: original); XCTFail("old source revived") } catch {}
        await h.queue.close()
    }

    func testPendingIntentImmediatelyRevokesRetainedProjectionAndFinishingDoesNotReviveIt() async throws {
        let h = try await make(); defer { h.base.remove() }
        let input = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        let pending = h.queue.beginNativeProjectionIntent()
        XCTAssertFalse(input.isCurrent())
        do { _ = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness)); XCTFail("pending intent ignored") } catch {}
        h.queue.finishNativeProjectionIntent(pending)
        XCTAssertFalse(input.isCurrent())
        let fresh = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness)); XCTAssertTrue(fresh.isCurrent())
        await h.queue.close()
    }

    func testQueuePermitGuardExpiresAgainstOriginalMicrosecondWindowAndStopRevokes() async throws {
        let h = try await make(cap: 1); defer { h.base.remove() }
        let source = try XCTUnwrap(h.base.witness)
        let first = try await h.queue.nativeReplayProjection(source: source)
        let privacy = try project(first, now: h.base.now)
        let input = try await h.queue.installNativeReplayPrivacy(first, privacy: privacy)
        let manager = EluV1ConfigManager(readbackProvenReplayTransports: capability.transports)
        _ = try manager.update(configData: source.data, now: h.base.now)
        let resolution = try manager.authorize(effectivePrivacyStateData: privacy.stateData, identity: input.identity, now: h.base.now)
        let pendingReceipt = try await h.queue.beginNativeReplayStartAccounting(input)
        let receipt = try XCTUnwrap(pendingReceipt)
        let pendingGuard = try await h.queue.nativeReplayPermitGuard(input: input, receipt: receipt, resolution: resolution)
        let guardValue = try XCTUnwrap(pendingGuard)
        let wall = h.base.now
        h.base.testClock.advance(0.9); h.base.testClock.set(wall); XCTAssertTrue(guardValue.isCurrent())
        h.base.testClock.advance(0.1); h.base.testClock.set(wall); XCTAssertFalse(guardValue.isCurrent())
        _ = try await h.queue.stopNativeReplayAccounting(receipt); XCTAssertFalse(guardValue.isCurrent())
        await h.queue.close()
    }

    func testProfileCompatibilityAndAdvertisementWithoutLocalProofCannotPreparePermission() async throws {
        let h = try await make(); defer { h.base.remove() }
        let owner = EluNativeReplayAuthority(queue: h.queue, clock: { h.base.now })
        do { _ = try await owner.prepare(source: XCTUnwrap(h.base.witness), capabilities: .init(), timeZoneIdentifier: "America/Los_Angeles"); XCTFail("missing proof accepted") } catch {}
        let metadata = try await h.queue.nativeReplaySessionState(); XCTAssertNil(metadata.session)
        await owner.close(); await h.queue.close()
    }

    func testSourceWithdrawnDuringObservationTransactionCannotPublish() async throws {
        let fault = DeliveryFault(); let h = try await make(fault: fault); defer { h.base.remove() }
        fault.action = { if $0 == .beforeCommit { h.base.gate.close() } }
        do { _ = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness)); XCTFail("late source withdrawal ignored") } catch {}
        fault.action = nil; await h.queue.close()
    }

    func testOriginalSourceDeadlineDeniesWhenWallStalls() async throws {
        let h = try await make(); defer { h.base.remove() }
        let input = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        let wall = h.base.now; h.base.testClock.advance(600); h.base.testClock.set(wall)
        XCTAssertFalse(input.isCurrent())
        XCTAssertThrowsError(try project(input, now: wall))
        await h.queue.close()
    }

    func testRuntimeFacadeFirstHopIntentRevokesBeforeQueuedIdentityChange() async throws {
        let h = try await make(); defer { h.base.remove() }
        let runtime = try await openRuntime(h)
        let backend = EluStandaloneFacadeRuntime(context: .init(siteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa",
            isNewUser: false, flagsDidLoad: {}), open: { runtime })
        await backend.settled()
        let prepared = try await runtime.prepareNativeReplay(capabilities: capability)
        XCTAssertTrue(prepared.isCurrent())
        let operation = EluBufferedOp.identify(distinctId: "native-next-person", userProperties: nil)
        let finish = try XCTUnwrap(backend.beginPendingOperation(operation))
        XCTAssertFalse(prepared.isCurrent())
        backend.execute(operation); finish(); await backend.settled()
        XCTAssertFalse(prepared.isCurrent())
        XCTAssertEqual(backend.distinctId(), "native-next-person")
        XCTAssertNil(backend.replayControl)
        await runtime.close()
    }

    func testFacadePendingIntentReceivedDuringOpenCannotPublishNativeProof() async throws {
        let h = try await make(); defer { h.base.remove() }
        let runtime = try await openRuntime(h), opening = NativeAuthorityOpenGate()
        let backend = EluStandaloneFacadeRuntime(context: .init(siteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa",
            isNewUser: false, flagsDidLoad: {}), open: { await opening.wait(); return runtime })
        let finish = try XCTUnwrap(backend.beginPendingOperation(.reset))
        await opening.release(); await backend.settled()
        do { _ = try await runtime.prepareNativeReplay(capabilities: capability); XCTFail("pending startup intent ignored") } catch {}
        finish()
        let fresh = try await runtime.prepareNativeReplay(capabilities: capability)
        XCTAssertTrue(fresh.isCurrent())
        await runtime.close(); XCTAssertFalse(fresh.isCurrent())
    }

    func testIdentityTransitionInvalidatesCapturedNativeProjection() async throws {
        let h = try await make(); defer { h.base.remove() }
        let input = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        let snapshot = try await h.queue.snapshot()
        _ = try await h.queue.reset(expectedGeneration: snapshot.generation)
        XCTAssertFalse(input.isCurrent())
        XCTAssertThrowsError(try project(input, now: h.base.now))
        await h.queue.close()
    }

    func testApplicableUnknownNativeBlockRuleDeniesEvenWithBlanketMaskAndLocalPair() async throws {
        let h = try await make(); defer { h.base.remove() }
        var body = try JSONSerialization.jsonObject(with: h.base.config) as! [String: Any]
        var privacy = body["privacy"] as! [String: Any], masking = privacy["masking"] as! [String: Any]
        masking["platformRules"] = [["platform": "ios", "action": "block", "targetDialect": "elu-unknown-native-v9", "target": "private-target"]]
        privacy["masking"] = masking; body["privacy"] = privacy
        h.base.testClock.advance(0.001); body["issuedAt"] = EluRFC3339.string(from: h.base.now)
        h.base.config = try JSONSerialization.data(withJSONObject: body); try await h.publish()
        let owner = EluNativeReplayAuthority(queue: h.queue, clock: { h.base.now })
        do { _ = try await owner.prepare(source: XCTUnwrap(h.base.witness), capabilities: capability, timeZoneIdentifier: "America/Los_Angeles"); XCTFail("unresolved block ignored") } catch {}
        await owner.close(); await h.queue.close()
    }

    func testSourceRenewalDuringFullPrivacyInstallCannotAdoptNewLease() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault); defer { h.base.remove() }
        let original = try XCTUnwrap(h.base.witness)
        let input = try await h.queue.nativeReplayProjection(source: original), privacy = try project(input, now: h.base.now)
        let document = try JSONDecoder().decode(EluV1ConfigDocument.self, from: original.data)
        fault.action = { point in
            if point == .beforeCommit {
                let token = EluV2ConfigLifecycleToken()
                h.base.gate.publish(token: token, lease: .init(data: original.data, expiresAt: document.expiresAt,
                    continuousDeadline: h.base.testClock.ticks() + 600_000_000_000))
            }
        }
        do { _ = try await h.queue.installNativeReplayPrivacy(input, privacy: privacy); XCTFail("new source adopted") } catch {}
        XCTAssertFalse(input.isCurrent()); XCTAssertFalse(h.base.gate.isCurrent(original))
        fault.action = nil; await h.queue.close()
    }

    func testGuardOnlyRollbackPersistsThroughExactStopAndReopen() async throws {
        let h = try await make(); defer { h.base.remove() }
        let source = try XCTUnwrap(h.base.witness), original = try await h.queue.nativeReplayProjection(source: source)
        let privacy = try project(original, now: h.base.now)
        let installed = try await h.queue.installNativeReplayPrivacy(original, privacy: privacy)
        let manager = EluV1ConfigManager(readbackProvenReplayTransports: capability.transports)
        _ = try manager.update(configData: source.data, now: h.base.now)
        let resolution = try manager.authorize(effectivePrivacyStateData: privacy.stateData, identity: installed.identity, now: h.base.now)
        let started = try await h.queue.beginNativeReplayStartAccounting(installed), receipt = try XCTUnwrap(started)
        let exported = try await h.queue.nativeReplayPermitGuard(input: installed, receipt: receipt, resolution: resolution)
        let guardValue = try XCTUnwrap(exported), wall = h.base.now
        h.base.testClock.advance(0.3); XCTAssertTrue(guardValue.isCurrent())
        h.base.testClock.set(wall.addingTimeInterval(0.2)); XCTAssertFalse(guardValue.isCurrent())
        _ = try await h.queue.stopNativeReplayAccounting(receipt)
        let stopped = try await h.queue.nativeReplaySessionState(); XCTAssertEqual(stopped.session?.clockDenied, true)
        let replacement = try await make(); defer { replacement.base.remove() }
        weak var oldQueue = h.queue
        h.base.queue = replacement.queue; XCTAssertNil(oldQueue)
        h.base.testClock.set(wall.addingTimeInterval(0.4)); try await h.reopen(); try await h.publish()
        await replacement.queue.close()
        let reopened = try await h.queue.nativeReplaySessionState(); XCTAssertEqual(reopened.session?.clockDenied, true)
        do { _ = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness)); XCTFail("original session reopened") } catch {}
        await h.queue.close()
    }

    func testPreparedOnlyRollbackCleanClosePersistsButNewSessionDoesNotInheritDenial() async throws {
        let h = try await make(); defer { h.base.remove() }
        let input = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness)), wall = h.base.now
        h.base.testClock.advance(0.3); XCTAssertTrue(input.isCurrent())
        h.base.testClock.set(wall.addingTimeInterval(0.2)); XCTAssertFalse(input.isCurrent())
        await h.queue.close(); h.base.testClock.set(wall.addingTimeInterval(0.4)); try await h.reopen(); try await h.publish()
        let original = try await h.queue.nativeReplaySessionState(); XCTAssertEqual(original.session?.clockDenied, true)
        let snapshot = try await h.queue.snapshot(); _ = try await h.queue.reset(expectedGeneration: snapshot.generation)
        try await h.publish(); guard case .accepted = await h.base.capture() else { return XCTFail("real new session") }
        let next = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        XCTAssertFalse(next.accounting.clockDenied); XCTAssertTrue(next.isCurrent())
        XCTAssertNotEqual(next.accounting.key, original.session?.key)
        await h.queue.close()
    }

    func testRetainedOldDenialCannotWriteOrQuarantineRealNewSession() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault); defer { h.base.remove() }
        let old = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness)), wall = h.base.now
        h.base.testClock.advance(0.3); XCTAssertTrue(old.isCurrent())
        h.base.testClock.set(wall.addingTimeInterval(0.2)); XCTAssertFalse(old.isCurrent())
        h.base.testClock.set(wall.addingTimeInterval(0.4))
        let snapshot = try await h.queue.snapshot(); _ = try await h.queue.reset(expectedGeneration: snapshot.generation)
        try await h.publish(); guard case .accepted = await h.base.capture() else { return XCTFail("real new session") }
        let next = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        XCTAssertNotEqual(next.accounting.key, old.accounting.key); XCTAssertFalse(next.accounting.clockDenied)
        fault.action = { if $0 == .beforeBegin { throw EluRuntimeQueueError.faultInjected(.beforeBegin) } }
        try await h.queue.persistNativeReplayClockDenial() // no transaction for a foreign old key
        await h.queue.close(); fault.action = nil
        try await h.reopen(); try await h.publish()
        let reopened = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness)); XCTAssertTrue(reopened.isCurrent())
        await h.queue.close()
    }

    func testCleanCloseWithoutGuardDenialReopensSameSessionNormally() async throws {
        let h = try await make(); defer { h.base.remove() }
        let input = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        await h.queue.close(); XCTAssertFalse(input.isCurrent())
        try await h.reopen(); try await h.publish()
        let next = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        XCTAssertEqual(next.accounting.key, input.accounting.key)
        XCTAssertFalse(next.accounting.clockDenied); XCTAssertTrue(next.isCurrent())
        await h.queue.close()
    }

    func testQueueDestructionInvalidatesRetainedProjectionWithoutExplicitClose() async throws {
        let h = try await make(), replacement = try await make()
        defer { h.base.remove(); replacement.base.remove() }
        let input = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        XCTAssertTrue(input.isCurrent())
        weak var oldQueue = h.queue
        h.base.queue = replacement.queue
        XCTAssertNil(oldQueue, "retained guard must not retain its queue owner")
        XCTAssertFalse(input.isCurrent(), "guard outlived its original queue")
        try await h.reopen(); try await h.publish()
        let next = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        XCTAssertTrue(next.isCurrent())
        await h.queue.close(); await replacement.queue.close()
    }

    func testPreparedOnlyDenialOnQueueDestructionKeepsInstallationOccupied() async throws {
        let h = try await make(), replacement = try await make()
        defer { replacement.base.remove() }
        let input = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness)), wall = h.base.now
        h.base.testClock.advance(0.3); XCTAssertTrue(input.isCurrent())
        h.base.testClock.set(wall.addingTimeInterval(0.2)); XCTAssertFalse(input.isCurrent())
        weak var oldQueue = h.queue
        h.base.queue = replacement.queue
        XCTAssertNil(oldQueue, "quarantine may retain resources only")
        h.base.testClock.set(wall.addingTimeInterval(0.4))
        do { try await h.reopen(); XCTFail("destruction lost unresolved original denial") } catch {
            XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict)
        }
        await h.queue.close(); await replacement.queue.close()
        // The unresolved original directory remains occupied until process exit.
    }

    func testResolvedDenialDoesNotQuarantineDestructionAfterDurableProof() async throws {
        for newSession in [false, true] {
            let h = try await make(), replacement = try await make()
            defer { h.base.remove(); replacement.base.remove() }
            let old = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness)), wall = h.base.now
            h.base.testClock.advance(0.3); XCTAssertTrue(old.isCurrent())
            h.base.testClock.set(wall.addingTimeInterval(0.2)); XCTAssertFalse(old.isCurrent())
            h.base.testClock.set(wall.addingTimeInterval(0.4))
            if newSession {
                let snapshot = try await h.queue.snapshot(); _ = try await h.queue.reset(expectedGeneration: snapshot.generation)
                try await h.publish(); guard case .accepted = await h.base.capture() else { return XCTFail("real new session") }
                let next = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
                XCTAssertNotEqual(next.accounting.key, old.accounting.key)
                XCTAssertTrue(next.isCurrent())
            } else {
                try await h.queue.persistNativeReplayClockDenial()
                let durable = try await h.queue.nativeReplaySessionState(); XCTAssertEqual(durable.session?.clockDenied, true)
            }
            weak var oldQueue = h.queue
            h.base.queue = replacement.queue; XCTAssertNil(oldQueue)
            XCTAssertFalse(old.isCurrent())
            try await h.reopen(); try await h.publish()
            let readback = try await h.queue.nativeReplaySessionState()
            XCTAssertEqual(readback.session?.clockDenied, !newSession)
            await h.queue.close(); await replacement.queue.close()
        }
    }

    func testInitialPreparedDenialReadFailureKeepsInstallationOccupied() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault)
        let input = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness)), wall = h.base.now
        h.base.testClock.advance(0.3); XCTAssertTrue(input.isCurrent())
        h.base.testClock.set(wall.addingTimeInterval(0.2)); XCTAssertFalse(input.isCurrent())
        var readAttempts = 0
        fault.action = { if $0 == .beforeNativeDenialRead {
            readAttempts += 1
            throw EluRuntimeQueueError.databaseUnavailable
        } }
        await h.queue.close(); fault.action = nil
        XCTAssertEqual(readAttempts, 1)
        h.base.testClock.set(wall.addingTimeInterval(0.4))
        do { try await h.reopen(); XCTFail("initial read uncertainty released installation") } catch {
            XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict)
        }
        // An unreadable ledger cannot prove that the retained denial is foreign.
        // The private directory stays alive with the quarantined process lease.
        await h.queue.close()
    }

    func testFailedPreparedDenialFlushKeepsInstallationOccupiedWithoutActiveEpoch() async throws {
        for point in [EluRuntimeQueueFaultPoint.beforeCommit, .afterCommit] {
            let fault = DeliveryFault(), h = try await make(fault: fault)
            let input = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness)), wall = h.base.now
            h.base.testClock.advance(0.3); XCTAssertTrue(input.isCurrent())
            h.base.testClock.set(wall.addingTimeInterval(0.2)); XCTAssertFalse(input.isCurrent())
            fault.action = { if $0 == point { throw EluRuntimeQueueError.faultInjected(point) } }
            await h.queue.close(); fault.action = nil; h.base.testClock.set(wall.addingTimeInterval(0.4))
            do { try await h.reopen(); XCTFail("unresolved denial released installation") } catch {}
            // Quarantined handles deliberately live until process exit; leave their
            // private temporary directories intact as failure-policy evidence.
        }
    }

    #if canImport(UIKit)
    @MainActor func testUIKitPermitUsesOriginalSelectedWindowSourceAndBudget() async throws {
        let h = try await make(cap: 1); defer { h.base.remove() }
        let lifecycle = EluNativeReplayLifecycle(), owner = EluNativeReplayAuthority(queue: h.queue, clock: { h.base.now })
        lifecycle.observeWithdrawal { owner.withdraw() }; lifecycle.attached(UUID())
        let window = try selectedWindow(), root = UIView(frame: window.bounds)
        window.addSubview(root); defer { root.removeFromSuperview() }
        let selection = try XCTUnwrap(lifecycle.select(root: root, window: window))
        let source = try XCTUnwrap(h.base.witness)
        let prepared = try await owner.prepare(source: source, capabilities: capability, timeZoneIdentifier: "America/Los_Angeles")
        h.base.testClock.advance(0.1)
        guard case let .accepted(beforeRecord, beforeSnapshot) = await h.base.capture() else { return XCTFail("pre-start same-session activity") }
        _ = try await h.queue.acknowledge([.init(streamId: beforeSnapshot.streamId, sequence: beforeRecord.sequence, kind: beforeRecord.kind, recordId: beforeRecord.recordId)])
        let cached = try await owner.prepare(source: source, capabilities: capability, timeZoneIdentifier: "America/Los_Angeles")
        XCTAssertEqual(cached.privacy.stateData, prepared.privacy.stateData)
        let started = try await owner.start(cached, selection: selection)
        let permit = try XCTUnwrap(started)
        XCTAssertTrue(permit.isCurrentForCollection()); XCTAssertEqual(permit.privacy.stateData, prepared.privacy.stateData)
        h.base.testClock.advance(0.25)
        guard case let .accepted(record, snapshot) = await h.base.capture() else { return XCTFail("same-session activity") }
        _ = try await h.queue.acknowledge([.init(streamId: snapshot.streamId, sequence: record.sequence, kind: record.kind, recordId: record.recordId)])
        XCTAssertTrue(permit.isCurrentForCollection()); XCTAssertEqual(permit.privacy.stateData, prepared.privacy.stateData)
        let wall = h.base.now; h.base.testClock.advance(0.75); h.base.testClock.set(wall)
        XCTAssertFalse(permit.isCurrentForCollection())
        try await owner.stop(); let metadata = try await h.queue.nativeReplaySessionState()
        XCTAssertNil(metadata.session?.activeEpoch); XCTAssertEqual(metadata.session?.remainingMicroseconds, 0)
        await owner.close(); await h.queue.close()
    }

    @MainActor func testUIKitWithdrawalDuringStartCommitPublishesNoPermitAndSettlesEpoch() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault); defer { h.base.remove() }
        let lifecycle = EluNativeReplayLifecycle(), owner = EluNativeReplayAuthority(queue: h.queue, clock: { h.base.now })
        lifecycle.observeWithdrawal { owner.withdraw() }; lifecycle.attached(UUID())
        let window = try selectedWindow(), root = UIView(frame: window.bounds)
        window.addSubview(root); defer { root.removeFromSuperview() }
        let selection = try XCTUnwrap(lifecycle.select(root: root, window: window))
        let prepared = try await owner.prepare(source: XCTUnwrap(h.base.witness), capabilities: capability, timeZoneIdentifier: "America/Los_Angeles")
        fault.action = { if $0 == .afterCommit { lifecycle.withdraw() } }
        do { let permit = try await owner.start(prepared, selection: selection); XCTAssertNil(permit) } catch {}
        fault.action = nil; try await owner.stop()
        let metadata = try await h.queue.nativeReplaySessionState(); XCTAssertNil(metadata.session?.activeEpoch)
        XCTAssertFalse(prepared.isCurrent())
        await owner.close(); await h.queue.close()
    }

    @MainActor func testUIKitRenewedSourceStartsNewReplayWithoutRefillingSessionWindow() async throws {
        let h = try await make(); defer { h.base.remove() }
        let lifecycle = EluNativeReplayLifecycle(), owner = EluNativeReplayAuthority(queue: h.queue, clock: { h.base.now })
        lifecycle.observeWithdrawal { owner.withdraw() }; lifecycle.attached(UUID())
        let window = try selectedWindow(), root = UIView(frame: window.bounds)
        window.addSubview(root); defer { root.removeFromSuperview() }
        let selection = try XCTUnwrap(lifecycle.select(root: root, window: window))
        let first = try await owner.prepare(source: XCTUnwrap(h.base.witness), capabilities: capability, timeZoneIdentifier: "America/Los_Angeles")
        let started = try await owner.start(first, selection: selection), permit = try XCTUnwrap(started)
        let before = try await h.queue.nativeReplaySessionState()
        h.base.testClock.advance(0.25); try await h.publish()
        XCTAssertFalse(permit.isCurrentForCollection()); XCTAssertFalse(first.isCurrent())
        let next = try await owner.prepare(source: XCTUnwrap(h.base.witness), capabilities: capability, timeZoneIdentifier: "America/Los_Angeles")
        let restarted = try await owner.start(next, selection: selection), replacement = try XCTUnwrap(restarted)
        let after = try await h.queue.nativeReplaySessionState()
        XCTAssertNotEqual(permit.replayId, replacement.replayId)
        XCTAssertEqual(before.session?.firstStartAt, after.session?.firstStartAt)
        XCTAssertGreaterThanOrEqual(after.session?.elapsedFloorMicroseconds ?? 0, 250_000)
        XCTAssertFalse(permit.isCurrent()); XCTAssertTrue(replacement.isCurrentForCollection())
        try await owner.stop(); await owner.close(); await h.queue.close()
    }

    @MainActor private func selectedWindow() throws -> UIWindow {
        try EluUIKitTestHost.window()
    }
    #endif

    private func openRuntime(_ h: NativeSessionHarness) async throws -> EluStandaloneRuntime {
        await h.queue.close()
        let runtime = try await EluStandaloneRuntime.make(rootDirectoryURL: h.base.root,
            siteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", limits: h.base.limits,
            transport: NativeAuthorityNoNetworkTransport(), configurationGate: h.base.gate,
            clock: { h.base.now }, continuousClock: { h.base.testClock.ticks() },
            continuousBudgetConverter: { $0 }, nativeContinuousNanoseconds: { $0 },
            timeZoneIdentifier: { "America/Los_Angeles" }, flushDelayNanoseconds: UInt64.max)
        _ = await runtime.applyConfiguration(h.base.config, sourceWitness: h.base.witness)
        return runtime
    }

    private func project(_ input: EluNativeReplayProjectionInput, now: Date) throws -> EluProjectedPrivacyState {
        try EluPrivacyStateProjector.projectNative(observation: input, profile: .blanketMask(), capabilities: capability,
            evaluatedAt: now, timeZoneIdentifier: "America/Los_Angeles")
    }
    private func make(rate: Double = 1, cap: Int = 60, fault: DeliveryFault? = nil) async throws -> NativeSessionHarness {
        let h = try await NativeSessionHarness.make(rate: rate, cap: cap, fault: fault)
        h.base.testClock.advance(0.001)
        var body = try JSONSerialization.jsonObject(with: h.base.config) as! [String: Any]
        var caps = body["capabilities"] as! [String: Any]; var replay = caps["replay"] as! [String: Any]
        replay["transports"] = [["codec": "elu-native-wireframe-v1", "compression": "gzip"]]
        caps["replay"] = replay; body["capabilities"] = caps
        body["issuedAt"] = EluRFC3339.string(from: h.base.now)
        h.base.config = try JSONSerialization.data(withJSONObject: body); try await h.publish()
        return h
    }
}

private struct NativeAuthorityNoNetworkTransport: EluV1BatchHTTPTransport {
    func send(_ request: EluV1BatchHTTPRequest) async throws -> EluV1BatchHTTPResponse {
        throw EluNativeReplayAuthorityError.unavailable
    }
}
private actor NativeAuthorityOpenGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
