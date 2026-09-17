import Foundation
import SQLite3
import XCTest
@testable import EluAnalytics

final class EluSealedReplayPolicyQueueTests: XCTestCase {
    func testColdNoSessionOrLedgerSendsOriginalNativeBytesThroughExistingClaim() async throws {
        let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
        let noSession = try await h.identity(); XCTAssertNil(noSession.identity.session)
        XCTAssertEqual(try h.base.schemaVersion(), 5)
        let rows = try await h.base.queue.storedReplayChunks(), authority = try await h.authority()
        let permission = try XCTUnwrap(authority)
        guard case let .claimed(claim) = try await h.base.queue.claimNextReplay(permission) else { return XCTFail("original native row") }
        let enrolled = try await h.base.queue.enrollReplayDispatch(claim, dispatchAllowed: { true })
        let dispatch = try XCTUnwrap(enrolled), use = try XCTUnwrap(dispatch.takePhysicalUse())
        let valid = await use.revalidate(); XCTAssertTrue(valid); XCTAssertTrue(use.beginOnce())
        XCTAssertEqual(use.request.body, rows[0].prepared.body)
        XCTAssertEqual(rows[0].prepared.codec, "elu-native-wireframe-v1")
        use.settle(); _ = try await h.base.queue.finishReplayClaim(claim, completion: .response(.accepted))
        let count = try await h.base.count(); XCTAssertEqual(count, 0)
        XCTAssertEqual(try h.base.schemaVersion(), 5)
        await h.base.queue.close()
    }

    func testOriginalIdentityIsNotReboundAndPendingIntentRevokesCurrentPermission() async throws {
        let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
        let rows = try await h.base.queue.storedReplayChunks(), first = try await h.authority()
        let original = try XCTUnwrap(first)
        let intent = h.base.queue.beginFlagProjectionIntent()
        XCTAssertFalse(original.isCurrent()); let pending = try await h.authority(); XCTAssertNil(pending)
        h.base.queue.finishFlagProjectionIntent(intent)
        _ = try await h.base.queue.registerStandaloneSuperProperties(["plan": .string("later")])
        XCTAssertFalse(original.isCurrent())
        let next = try await h.authority(), current = try XCTUnwrap(next)
        guard case let .claimed(claim) = try await h.base.queue.claimNextReplay(current) else { return XCTFail("sealed original") }
        XCTAssertEqual(claim.row, rows[0]); _ = try await h.base.queue.finishReplayClaim(claim, completion: .released)
        await h.base.queue.close()
    }

    func testActualEventAckDoesNotRevokeCurrentPolicy() async throws {
        let base = try await DeliveryHarness.make(); defer { base.remove() }
        try await base.install(); try await base.queue.ensureReplayDeliverySchema()
        guard case let .accepted(record, snapshot) = await base.capture() else { return XCTFail("ordinary queued event") }
        let h = SealedPolicyTestHarness(base)
        try h.useNativeConfig(); try h.publish()
        let first = try await h.authority(), original = try XCTUnwrap(first)
        _ = try await base.queue.acknowledge([EluQueueAcknowledgementReference(streamId: snapshot.streamId,
            sequence: record.sequence, kind: record.kind, recordId: record.recordId)])
        XCTAssertTrue(original.isCurrent()); await base.queue.close()
    }

    func testFalseZeroAndInterruptedLedgerRemainExactWhileSealedPolicyIsAvailable() async throws {
        for mode in ["false", "zero", "interrupted"] {
            let h = try await SealedPolicyTestHarness.make(clearSession: false), n = NativeSessionHarness(h.base)
            defer { n.base.remove() }
            try await n.queue.ensureNativeReplayAuthoritySchema()
            try await n.update(rate: mode == "false" ? 0 : 1, cap: mode == "zero" ? 0 : 60)
            _ = try await n.observe()
            if mode == "interrupted" {
                let receipt = try await n.start(); _ = try await n.stop(receipt)
                await n.queue.close(); try await n.reopen(); try await n.publish()
                _ = try await n.observe()
            }
            let ledger = try await n.queue.nativeReplaySessionState()
            if mode == "false" { XCTAssertFalse(try XCTUnwrap(ledger.session).originalSelected) }
            if mode == "zero" { XCTAssertEqual(ledger.session?.maximumDurationSeconds, 0) }
            if mode == "interrupted" { XCTAssertEqual(ledger.session?.interrupted, true) }
            let bytes = try n.bytes("SELECT metadata FROM native_replay_authority")
            let rows = try await n.queue.storedReplayChunks(); XCTAssertEqual(rows.count, 1)
            let value = try await h.authority(), current = try XCTUnwrap(value)
            XCTAssertEqual(try n.bytes("SELECT metadata FROM native_replay_authority"), bytes)
            guard case let .claimed(claim) = try await n.queue.claimNextReplay(current) else { return XCTFail("original sealed row despite capture-only restriction") }
            XCTAssertEqual(claim.row, rows[0])
            _ = try await n.queue.finishReplayClaim(claim, completion: .released)
            XCTAssertEqual(try n.bytes("SELECT metadata FROM native_replay_authority"), bytes)
            await n.queue.close()
        }
    }

    func testOriginalContinuousExpiryWhileWallStallsRevokesWithoutPurging() async throws {
        let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
        let rows = try await h.base.queue.storedReplayChunks(), first = try await h.authority(), original = try XCTUnwrap(first)
        let wall = h.base.now; h.base.testClock.advance(601); h.base.testClock.set(wall)
        XCTAssertFalse(original.isCurrent())
        let expired = try await h.authority(); XCTAssertNil(expired)
        let after = try await h.base.queue.storedReplayChunks(); XCTAssertEqual(after, rows)
        await h.base.queue.close()
    }

    func testRestrictiveProfileAndUnsupportedGenerationPurgeButMissingProofDoesNot() async throws {
        for reason in ["profile", "generation", "pair", "feature"] {
            let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
            if reason == "profile" { try h.addBlockRule(); try h.publish() }
            if reason == "feature" {
                try h.changeConfig { root in
                    var features = root["features"] as! [String: Any]; features["replay"] = false; root["features"] = features
                }; try h.publish()
            }
            let proof = EluNativeReplayCapabilities(readbackProvenTransports: reason == "pair" ? [] : [h.pair],
                readbackProvenProtocolGenerations: reason == "generation" ? ["unsupported"] : [h.base.generation])
            let result = try await h.authority(proof: proof); XCTAssertNil(result)
            let count = try await h.base.count(); XCTAssertEqual(count, reason == "pair" ? 1 : 0)
            await h.base.queue.close()
        }
    }

    func testExplicitDisabledAndRevokedConfigRetireRowsWithoutNeedingEnabledPrivacyFields() async throws {
        for status in ["disabled", "revoked"] {
            let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
            let before = try await h.base.count(); XCTAssertEqual(before, 1)
            try h.changeConfig { root in
                root = ["schemaVersion": 2, "revision": "sealed-stop", "status": status,
                    "issuedAt": root["issuedAt"]!, "expiresAt": root["expiresAt"]!, "reason": "fixture restriction"]
            }
            try h.publish()
            let value = try await h.authority(); XCTAssertNil(value)
            let count = try await h.base.count(); XCTAssertEqual(count, 0)
            await h.base.queue.close()
        }
    }

    func testUnavailableSourceAndMalformedPolicyPreserveSealedBytes() async throws {
        for malformed in [false, true] {
            let h = try await SealedPolicyTestHarness.make(); defer { h.base.remove() }
            let rows = try await h.base.queue.storedReplayChunks()
            if malformed {
                try h.changeConfig { $0.removeValue(forKey: "privacy") }; try h.publish(validate: false)
                do { _ = try await h.authority(); XCTFail("malformed enabled policy") } catch {}
            } else { h.base.gate.close(); let unavailable = try await h.authority(); XCTAssertNil(unavailable) }
            let after = try await h.base.queue.storedReplayChunks(); XCTAssertEqual(after, rows)
            await h.base.queue.close()
        }
    }

    func testWithdrawalAtReadCommitAndAfterKnownCommitNeverPublishes() async throws {
        for point: EluRuntimeQueueFaultPoint in [.afterStateRead, .beforeCommit, .afterCommit] {
            let fault = DeliveryFault(), h = try await SealedPolicyTestHarness.make(fault: fault); defer { h.base.remove() }
            let rows = try await h.base.queue.storedReplayChunks()
            fault.action = { if $0 == point { h.base.gate.close() } }
            do { let value = try await h.authority(); XCTAssertNil(value) } catch {}
            fault.action = nil
            let after = try await h.base.queue.storedReplayChunks(); XCTAssertEqual(after, rows)
            await h.base.queue.close()
        }
    }

    func testOriginalSourceIsNotRenewedDuringReconciliation() async throws {
        let fault = DeliveryFault(), h = try await SealedPolicyTestHarness.make(fault: fault); defer { h.base.remove() }
        let old = try XCTUnwrap(h.base.witness)
        fault.action = { if $0 == .beforeCommit { try h.publish() } }
        do { let value = try await h.authority(); XCTAssertNil(value) } catch {}
        fault.action = nil
        XCTAssertFalse(h.base.gate.isCurrent(old))
        let stale = try await h.base.queue.currentSealedReplayDelivery(source: old, capabilities: h.proof, timeZoneIdentifier: h.zone)
        XCTAssertNil(stale); let next = try await h.authority(); XCTAssertNotNil(next)
        await h.base.queue.close()
    }

    func testPendingIdentityIntentInsideTransactionCannotPublish() async throws {
        let fault = DeliveryFault(), h = try await SealedPolicyTestHarness.make(fault: fault); defer { h.base.remove() }
        var intent: EluV1FlagProjectionIntent?
        fault.action = { if $0 == .beforeCommit { intent = h.base.queue.beginFlagProjectionIntent() } }
        do { let value = try await h.authority(); XCTAssertNil(value) } catch {}
        fault.action = nil
        h.base.queue.finishFlagProjectionIntent(try XCTUnwrap(intent))
        let next = try await h.authority(); XCTAssertNotNil(next); await h.base.queue.close()
    }

    func testAmbiguousCommitAndPoisonNeverIssueSealedAuthority() async throws {
        let fault = DeliveryFault(), h = try await SealedPolicyTestHarness.make(fault: fault); defer { h.base.remove() }
        let first = try await h.authority(), original = try XCTUnwrap(first)
        fault.action = { if $0 == .afterCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { _ = try await h.authority(); XCTFail("ambiguous commit") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ambiguousCommit) }
        fault.action = nil; XCTAssertFalse(original.isCurrent())
        do { _ = try await h.authority(); XCTFail("poisoned owner") } catch {}
        await h.base.queue.close()
    }
}

/// A closed durable-read fixture, not native capture admission evidence. It uses
/// actual N1/sealer bytes and inserts them only while the queue owner is closed.
final class SealedPolicyTestHarness: @unchecked Sendable {
    let base: DeliveryHarness
    let zone = "America/Los_Angeles"
    let pair = EluV1ReplayTransportSelection(codec: "elu-native-wireframe-v1", compression: .gzip)!
    var proof: EluNativeReplayCapabilities { .init(readbackProvenTransports: [pair], readbackProvenProtocolGenerations: [base.generation]) }
    init(_ base: DeliveryHarness) { self.base = base }
    static func make(seed: Bool = true, clearSession: Bool = true, fault: DeliveryFault? = nil) async throws -> SealedPolicyTestHarness {
        let base = try await DeliveryHarness.make(fault: fault), h = SealedPolicyTestHarness(base)
        var phase = "install"
        do {
        if seed { try await base.install() }
        else { try await base.queue.ensureReplaySchema() }
        try await base.queue.ensureReplayDeliverySchema()
        try h.useNativeConfig()
        if seed {
            phase = "project binding"
            let identity = try await h.identity(), manager = EluV1ConfigManager(readbackProvenReplayTransports: [h.pair])
            _ = try manager.update(configData: base.config, now: base.now)
            let projected = try EluPrivacyStateProjector.project(context: manager.activePrivacyProjectionContext(now: base.now),
                input: .init(contextRevision: identity.identity.contextRevision, identityOptedOut: false, timeZoneIdentifier: h.zone,
                    evaluatedAt: base.now, appliedMasking: .init(text: .all, inputs: .all, images: .block),
                    replaySampleDraw: 0, replaySessionEligible: true, replayBudgetRemainingSeconds: 60, localReplayTransports: h.proof.pairs))
            let auth = try manager.authorize(effectivePrivacyStateData: projected.stateData, identity: identity, now: base.now)
            let versions = try EluVersionContext(runtime: .init(name: "elu-ios", version: "0.1.0"), facade: .init(name: "elu-ios", version: "0.1.0"))
            phase = "sealer init"
            var sealer = try EluNativeReplaySealer(replayId: "sealed-current-policy", identity: identity, authorization: auth,
                privacy: projected, profile: .blanketMask(), versions: versions)
            phase = "seal"
            let request = try sealer.seal([EluNativeMaskedSnapshot(ordinal: 0, timestamp: Int64(base.now.timeIntervalSince1970 * 1000),
                viewport: try .init(width: 320, height: 640), nodes: [])])
            let doc = try JSONDecoder().decode(EluV1ConfigDocument.self, from: base.config)
            phase = "stored row"
            let row = try EluV2ReplayStoredChunk(ordinal: 0, siteId: XCTUnwrap(doc.site?.id), captureProtocolGeneration: base.generation,
                prepared: request, maskingProfile: EluNativeMaskingProfile.blanketMask().canonicalBytes)
            phase = "identity encode"
            var noSession = identity.identity; if clearSession { noSession.session = nil }
            let identityData = try EluStateCoding.encoder().encode(noSession)
            await base.queue.close()
            phase = "closed SQLite fixture"
            func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
            func sqlText(_ value: String) -> String { "CAST(X'" + hex(Data(value.utf8)) + "' AS TEXT)" }
            try base.sql("INSERT INTO replay_chunks VALUES (0,1,\(sqlText(row.siteId)),\(sqlText(request.requestId)),\(sqlText(request.replayId)),\(sqlText(request.chunkId)),\(request.sequence),\(sqlText(base.generation)),X'\(hex(request.body))',X'\(hex(row.maskingProfile))')")
            try base.sql("INSERT INTO replay_delivery VALUES (0,X'\(hex(try EluV2ReplayDeliveryState.pending.encoded()))')")
            try base.sql("UPDATE replay_state SET next_ordinal=1")
            try base.sql("UPDATE runtime_state SET identity_json=X'\(hex(identityData))'")
            phase = "reopen"
            base.queue = try await base.reopen()
        }
        phase = "publish"
        try h.publish(); return h
        } catch { throw NSError(domain: "Sealed durable fixture: " + phase + ": " + String(describing: error), code: 1) }
    }
    func identity() async throws -> EluIdentitySnapshot {
        let state = try await base.queue.snapshot()
        return EluIdentitySnapshot(identity: state.identity, streamId: state.streamId, nextSequence: state.nextSequence, flagContext: state.flagContext)
    }
    func changeConfig(_ change: (inout [String: Any]) -> Void) throws {
        base.testClock.advance(0.001)
        var root = try JSONSerialization.jsonObject(with: base.config) as! [String: Any]
        change(&root); root["issuedAt"] = EluRFC3339.string(from: base.now)
        base.config = try JSONSerialization.data(withJSONObject: root)
    }
    func useNativeConfig() throws {
        try changeConfig { root in
            var caps = root["capabilities"] as! [String: Any], replay = caps["replay"] as! [String: Any]
            replay["transports"] = [["codec": "elu-native-wireframe-v1", "compression": "gzip"]]
            caps["replay"] = replay; root["capabilities"] = caps
        }
    }
    func addBlockRule() throws {
        try changeConfig { root in
            var privacy = root["privacy"] as! [String: Any], masking = privacy["masking"] as! [String: Any]
            masking["platformRules"] = [["platform": "ios", "targetDialect": "elu-unknown-native-v9", "target": "secret", "action": "block"]]
            privacy["masking"] = masking; root["privacy"] = privacy
        }
    }
    func publish(validate: Bool = true) throws {
        let expiry: EluV1Timestamp
        if validate { expiry = try JSONDecoder().decode(EluV1ConfigDocument.self, from: base.config).expiresAt }
        else { expiry = try EluV1Timestamp("2026-08-05T00:10:00.000Z") }
        let token = EluV2ConfigLifecycleToken()
        base.gate.publish(token: token, lease: EluV2ConfigLease(data: base.config, expiresAt: expiry,
            continuousDeadline: base.testClock.ticks() + 600_000_000_000))
        base.witness = try XCTUnwrap(base.gate.witness(for: token))
    }
    func observation(_ identity: EluIdentitySnapshot, zone: String? = "America/Los_Angeles") throws -> (EluV1ConfigManager, EluProjectedSealedReplayPolicy) {
        let manager = EluV1ConfigManager(readbackProvenReplayTransports: [pair])
        _ = try manager.update(configData: base.config, now: base.now)
        return (manager, try EluPrivacyStateProjector.projectSealedPolicy(context: manager.activePrivacyProjectionContext(now: base.now),
            configWitness: XCTUnwrap(manager.validatedCandidateIdentity()), identity: identity, timeZoneIdentifier: zone))
    }
    func authority(proof: EluNativeReplayCapabilities? = nil) async throws -> EluV2ReplayDeliveryAuthority? {
        try await base.queue.currentSealedReplayDelivery(source: XCTUnwrap(base.witness), capabilities: proof ?? self.proof, timeZoneIdentifier: zone)
    }
}
