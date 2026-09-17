import Foundation
import XCTest
@testable import EluAnalytics

final class EluNativeReplayCaptureQueueTests: XCTestCase {
    func testProtocolProofDefaultsClosedAndComparesExactBytes() throws {
        let pair = try XCTUnwrap(EluV1ReplayTransportSelection(codec: "elu-native-wireframe-v1", compression: .gzip))
        let pairOnly = EluNativeReplayCapabilities(readbackProvenTransports: [pair])
        XCTAssertNil(pairOnly.supportedProtocolGeneration("native-g1"))
        let proof = EluNativeReplayCapabilities(readbackProvenTransports: [pair],
            readbackProvenProtocolGenerations: ["native-g1", "g-\u{00e9}"])
        XCTAssertEqual(proof.supportedProtocolGeneration("native-g1"), "native-g1")
        XCTAssertNil(proof.supportedProtocolGeneration("native-g2"))
        XCTAssertNil(proof.supportedProtocolGeneration("g-e\u{0301}"))
        XCTAssertNil(proof.supportedProtocolGeneration(nil))
    }

    func testUnusedCancellationIsTerminalAndRequiresNoStartProofBeforeRelease() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let enrolled = try await h.queue.enrollNativeReplayCapture()
        let enrollment = try XCTUnwrap(enrolled)
        let duplicate = try await h.queue.enrollNativeReplayCapture(); XCTAssertNil(duplicate)
        enrollment.cancelUnused(); XCTAssertNil(enrollment.takePhysicalUse())
        await h.queue.close()
        await assertOccupied(h)
        let finished = try await h.queue.finishNativeReplayCapture(enrollment)
        XCTAssertEqual(finished, .settled)
        XCTAssertNil(enrollment.takePhysicalUse())
        try await h.reopen(); await h.queue.close()
    }

    func testTakenSlotRetainsCloseUntilPhysicalAndExactOriginalStop() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let input = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        let enrolled = try await h.queue.enrollNativeReplayCapture(), enrollment = try XCTUnwrap(enrolled)
        let use = try XCTUnwrap(enrollment.takePhysicalUse())
        XCTAssertNil(enrollment.takePhysicalUse())
        let began = try await h.queue.beginNativeReplayStartAccounting(input, physicalUse: use)
        let receipt = try XCTUnwrap(began)
        let first = try await h.queue.stopNativeReplayCaptureAccounting(use)
        XCTAssertEqual(first, .physicalWorkPending)
        do { _ = try await h.queue.stopNativeReplayAccounting(receipt); XCTFail("physical stop bypass") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .nativeCaptureWorkPending) }
        await h.queue.close(); enrollment.cancelUnused()
        let pending = try await h.queue.finishNativeReplayCapture(enrollment)
        XCTAssertEqual(pending, .physicalWorkPending); await assertOccupied(h)
        use.settle(); use.settle()
        let accounting = try await h.queue.finishNativeReplayCapture(enrollment)
        XCTAssertEqual(accounting, .accountingPending); await assertOccupied(h)
        let stopped = try await h.queue.stopNativeReplayCaptureAccounting(use)
        XCTAssertEqual(stopped, .settled)
        let result = try await h.queue.finishNativeReplayCapture(enrollment)
        XCTAssertEqual(result, .settled)
        try await h.reopen()
        let metadata = try await h.queue.nativeReplaySessionState()
        XCTAssertNil(metadata.session?.activeEpoch)
        XCTAssertEqual(metadata.session?.firstStartAt, receipt.firstStartAt)
        await h.queue.close()
    }

    func testLegacyStartCannotBypassReservedOrTakenEnrollment() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        let input = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        let observation = try await h.observe()
        let enrolled = try await h.queue.enrollNativeReplayCapture(), enrollment = try XCTUnwrap(enrolled)
        let old = try await h.queue.beginNativeReplayStartAccounting(observation)
        let opaque = try await h.queue.beginNativeReplayStartAccounting(input)
        XCTAssertNil(old); XCTAssertNil(opaque)
        let use = try XCTUnwrap(enrollment.takePhysicalUse())
        let taken = try await h.queue.beginNativeReplayStartAccounting(input); XCTAssertNil(taken)
        use.settle()
        let result = try await h.queue.finishNativeReplayCapture(enrollment)
        XCTAssertEqual(result, .settled); await h.queue.close()
    }

    func testForeignAndPreviousEnrollmentCannotReleaseAnotherPhysicalUse() async throws {
        let a = try await NativeSessionHarness.make(), b = try await NativeSessionHarness.make()
        defer { a.base.remove(); b.base.remove() }
        let first = try await a.queue.enrollNativeReplayCapture(), original = try XCTUnwrap(first)
        original.cancelUnused()
        let foreign = try await b.queue.finishNativeReplayCapture(original); XCTAssertEqual(foreign, .stale)
        let released = try await a.queue.finishNativeReplayCapture(original); XCTAssertEqual(released, .settled)
        let next = try await a.queue.enrollNativeReplayCapture(), current = try XCTUnwrap(next)
        let use = try XCTUnwrap(current.takePhysicalUse())
        let old = try await a.queue.finishNativeReplayCapture(original); XCTAssertEqual(old, .stale)
        original.quarantine() // A released token cannot quarantine its replacement.
        await a.queue.close(); await assertOccupied(a)
        use.settle()
        let done = try await a.queue.finishNativeReplayCapture(current); XCTAssertEqual(done, .settled)
        try await a.reopen(); await a.queue.close(); await b.queue.close()
    }

    func testProvenBeginRollbackCanFinishWithoutInventingReceipt() async throws {
        let fault = DeliveryFault(), h = try await NativeSessionHarness.make(fault: fault)
        defer { h.base.remove() }
        let input = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        let enrolled = try await h.queue.enrollNativeReplayCapture(), enrollment = try XCTUnwrap(enrolled)
        let use = try XCTUnwrap(enrollment.takePhysicalUse())
        fault.action = { if $0 == .beforeCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { _ = try await h.queue.beginNativeReplayStartAccounting(input, physicalUse: use); XCTFail("begin fault") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .provenNotCommitted) }
        fault.action = nil
        let metadata = try await h.queue.nativeReplaySessionState()
        XCTAssertNil(metadata.session?.firstStartAt); XCTAssertNil(metadata.session?.activeEpoch)
        XCTAssertEqual(metadata.nextReplayOrdinal, 0)
        use.settle()
        let stopped = try await h.queue.stopNativeReplayCaptureAccounting(use); XCTAssertEqual(stopped, .settled)
        let done = try await h.queue.finishNativeReplayCapture(enrollment); XCTAssertEqual(done, .settled)
        await h.queue.close(); try await h.reopen(); await h.queue.close()
    }

    func testCommittedStartWithdrawalStillRetainsOriginalReceiptForPhysicalFinalization() async throws {
        let fault = DeliveryFault(), h = try await NativeSessionHarness.make(fault: fault)
        defer { h.base.remove() }
        let input = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
        let enrolled = try await h.queue.enrollNativeReplayCapture(), enrollment = try XCTUnwrap(enrolled)
        let use = try XCTUnwrap(enrollment.takePhysicalUse())
        fault.action = { if $0 == .afterCommit { h.base.gate.close() } }
        do { _ = try await h.queue.beginNativeReplayStartAccounting(input, physicalUse: use); XCTFail("withdrawn begin") } catch {}
        fault.action = nil
        let metadata = try await h.queue.nativeReplaySessionState()
        XCTAssertNotNil(metadata.session?.activeEpoch); XCTAssertEqual(metadata.nextReplayOrdinal, 1)
        await h.queue.close(); await assertOccupied(h)
        use.settle()
        let stopped = try await h.queue.stopNativeReplayCaptureAccounting(use); XCTAssertEqual(stopped, .settled)
        let done = try await h.queue.finishNativeReplayCapture(enrollment); XCTAssertEqual(done, .settled)
        try await h.reopen()
        let final = try await h.queue.nativeReplaySessionState()
        XCTAssertNil(final.session?.activeEpoch); XCTAssertEqual(final.nextReplayOrdinal, 1)
        await h.queue.close()
    }

    func testUnknownBeginAndUnrelatedPoisonRetainOutstandingInstallation() async throws {
        for poisonBegin in [true, false] {
            let fault = DeliveryFault(), h = try await NativeSessionHarness.make(fault: fault)
            defer { h.base.remove() }
            var acknowledgement: EluQueueAcknowledgementReference?
            if !poisonBegin {
                guard case let .accepted(record, snapshot) = await h.base.capture() else { return XCTFail("ordinary event fixture") }
                acknowledgement = EluQueueAcknowledgementReference(streamId: snapshot.streamId,
                    sequence: record.sequence, kind: record.kind, recordId: record.recordId)
            }
            let input = try await h.queue.nativeReplayProjection(source: XCTUnwrap(h.base.witness))
            let enrolled = try await h.queue.enrollNativeReplayCapture(), enrollment = try XCTUnwrap(enrolled)
            let use = try XCTUnwrap(enrollment.takePhysicalUse())
            if !poisonBegin {
                let receipt = try await h.queue.beginNativeReplayStartAccounting(input, physicalUse: use)
                XCTAssertNotNil(receipt)
            }
            fault.action = { if $0 == .afterCommit { throw EluRuntimeQueueError.faultInjected($0) } }
            do {
                if poisonBegin { _ = try await h.queue.beginNativeReplayStartAccounting(input, physicalUse: use) }
                else { _ = try await h.queue.acknowledge([try XCTUnwrap(acknowledgement)]) }
                XCTFail("expected unknown commit")
            } catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ambiguousCommit) }
            fault.action = nil; use.settle(); await h.queue.close()
            do { _ = try await h.queue.stopNativeReplayCaptureAccounting(use); XCTFail("poisoned accounting write") } catch {}
            let done = try await h.queue.finishNativeReplayCapture(enrollment); XCTAssertEqual(done, .accountingPending)
            await assertOccupied(h)
        }
    }

    func testCaptureEnrollmentCoexistsWithOriginalSealedDeliverySlot() async throws {
        let h = try await NativeSessionHarness.make(seedReplay: true); defer { h.base.remove() }
        _ = try await h.queue.reconcileReplayConfiguration(configData: h.base.config,
            expectedConfigWitness: h.base.configWitness, sourceWitness: h.base.witness,
            supportedProtocolGeneration: h.base.generation, mayRetainProfile: { _ in true })
        let permission = try await h.base.deliveryAuthority()
        guard case let .claimed(claim) = try await h.queue.claimNextReplay(permission) else { return XCTFail("sealed claim") }
        let pending = try await h.queue.enrollReplayDispatch(claim, dispatchAllowed: { true })
        let dispatch = try XCTUnwrap(pending), send = try XCTUnwrap(dispatch.takePhysicalUse())
        let enrolled = try await h.queue.enrollNativeReplayCapture(), capture = try XCTUnwrap(enrolled)
        capture.cancelUnused(); await h.queue.close()
        let done = try await h.queue.finishNativeReplayCapture(capture); XCTAssertEqual(done, .settled)
        await assertOccupied(h)
        send.settle()
        _ = try await h.queue.finishReplayClaim(claim, completion: .released)
        try await h.reopen(); await h.queue.close()
    }

    func testExactNativeProfileRetainsBytesAcrossSQLiteReopen() async throws {
        let h = try await DeliveryHarness.make(); defer { h.remove() }
        try await h.install()
        let profile = EluNativeMaskingProfile.blanketMask().canonicalBytes
        let request = try h.request(maskingProfile: profile)
        // This storage fixture deliberately keeps the existing opaque browser
        // payload. UIKit/encoder native payload proof lives in the joined tests.
        let result = try await h.queue.appendReplay(request, maskingProfile: profile,
            authorization: h.authorization, sourceWitness: h.witness, isCurrentProfile: { $0 == profile })
        guard case let .inserted(row) = result else { return XCTFail("native metadata insertion") }
        XCTAssertEqual(row.maskingProfile, profile); XCTAssertEqual(row.prepared.body, request.body)
        await h.queue.close(); h.queue = try await h.reopen()
        let rows = try await h.queue.storedReplayChunks()
        XCTAssertEqual(rows, [row]); await h.queue.close()
    }

    func testActualNativeEnvelopeCannotUseGenericAppendWithoutPhysicalAdmission() async throws {
        let h = try await NativeSessionHarness.make(); defer { h.base.remove() }
        h.base.testClock.advance(0.001)
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: h.base.config) as? [String: Any])
        var capabilities = body["capabilities"] as! [String: Any], replay = capabilities["replay"] as! [String: Any]
        replay["transports"] = [["codec": "elu-native-wireframe-v1", "compression": "gzip"]]
        capabilities["replay"] = replay; body["capabilities"] = capabilities
        body["issuedAt"] = EluRFC3339.string(from: h.base.now)
        h.base.config = try JSONSerialization.data(withJSONObject: body); try await h.publish()
        let pair = try XCTUnwrap(EluV1ReplayTransportSelection(codec: "elu-native-wireframe-v1", compression: .gzip))
        let proof = EluNativeReplayCapabilities(readbackProvenTransports: [pair],
            readbackProvenProtocolGenerations: [h.base.generation])
        let authority = EluNativeReplayAuthority(queue: h.queue, clock: { h.base.now })
        let original = try await authority.prepare(source: XCTUnwrap(h.base.witness),
            capabilities: proof, timeZoneIdentifier: "America/Los_Angeles")
        let snapshot = try await h.queue.snapshot()
        let identity = EluIdentitySnapshot(identity: snapshot.identity, streamId: snapshot.streamId,
            nextSequence: snapshot.nextSequence, flagContext: snapshot.flagContext)
        let versions = try EluVersionContext(runtime: .init(name: "elu-ios", version: "0.1.0"),
            facade: .init(name: "elu-ios", version: "0.1.0"))
        var sealer = try EluNativeReplaySealer(replayId: "native-unenrolled-fixture", identity: identity,
            authorization: original.resolution, privacy: original.privacy, profile: original.profile, versions: versions)
        let frame = EluNativeMaskedSnapshot(ordinal: 0, timestamp: Int64(h.base.now.timeIntervalSince1970 * 1_000),
            viewport: try .init(width: 320, height: 640), nodes: [])
        let request = try sealer.seal([frame])
        XCTAssertEqual(request.codec, "elu-native-wireframe-v1")
        // Prove the exact source/profile/protocol storage requirements are current;
        // the only missing capability is the physical native admission.
        _ = try await h.queue.reconcileReplayConfiguration(configData: h.base.config,
            expectedConfigWitness: h.base.configWitness, sourceWitness: h.base.witness,
            supportedProtocolGeneration: h.base.generation,
            mayRetainProfile: { $0 == original.profile.canonicalBytes })
        XCTAssertTrue(original.isCurrent())
        do {
            _ = try await h.queue.appendReplay(request, maskingProfile: original.profile.canonicalBytes,
                authorization: original.resolution, sourceWitness: h.base.witness,
                isCurrentProfile: { $0 == original.profile.canonicalBytes })
            XCTFail("native envelope bypassed physical admission")
        } catch { XCTAssertEqual(error as? EluNativeReplayAuthorityError, .stale) }
        let rows = try await h.queue.storedReplayChunks(); XCTAssertTrue(rows.isEmpty)
        let metadata = try await h.queue.nativeReplaySessionState()
        XCTAssertNil(metadata.session?.activeEpoch); XCTAssertEqual(metadata.nextReplayOrdinal, 0)
        await authority.close(); await h.queue.close()
    }

    func testSelfHashedNativeProfileMutationAndExtraFieldStillReject() async throws {
        let h = try await DeliveryHarness.make(); defer { h.remove() }; try await h.install()
        let frozen = EluNativeMaskingProfile.blanketMask().canonicalBytes
        for field in ["maskToken", "extra"] {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: frozen) as? [String: Any])
            value[field] = "changed"
            let data = try EluV1StrictCanonicalJSON.parse(JSONSerialization.data(withJSONObject: value)).canonicalData
            let request = try h.request(maskingProfile: data)
            XCTAssertThrowsError(try EluV2ReplayStoredChunk(ordinal: 0, siteId: h.authorization.siteId,
                captureProtocolGeneration: h.generation, prepared: request, maskingProfile: data))
            do { _ = try await h.queue.appendReplay(request, maskingProfile: data,
                authorization: h.authorization, sourceWitness: h.witness, isCurrentProfile: { _ in true }); XCTFail("self-hashed profile widening") } catch {}
        }
        let count = try await h.count(); XCTAssertEqual(count, 0); await h.queue.close()
    }

    private func assertOccupied(_ h: NativeSessionHarness, file: StaticString = #filePath, line: UInt = #line) async {
        do { let next = try await h.base.reopen(); await next.close(); XCTFail("installation lease released", file: file, line: line) }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict, file: file, line: line) }
    }
}
