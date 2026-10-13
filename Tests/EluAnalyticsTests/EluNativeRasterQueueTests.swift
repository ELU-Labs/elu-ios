#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SQLite3
import UIKit
import XCTest
@testable import EluAnalytics

@MainActor
final class EluNativeRasterQueueTests: XCTestCase {
    func testActualPreparedRequestRestoresExactBytesAndRejectsChangedEnvelope() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        let request = try h.request()
        let restored = try EluNativeRasterStoredRequest(restoring: request.body)
        XCTAssertEqual(restored.body, request.body); XCTAssertEqual(restored.digest, request.digest)
        XCTAssertEqual(restored.requestId, request.requestId); XCTAssertEqual(restored.sequence, 0)
        XCTAssertEqual(restored.effectivePolicyHash, h.permit.policy.effectivePolicyHash)
        XCTAssertEqual(EluNativeRasterStoredRequest.profileHash, EluNativeRasterSealer.profileHash)
        for invalid in [Data(" ".utf8) + request.body, request.body + Data("x".utf8),
                        Data(String(decoding: request.body, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":2").utf8),
                        Data(String(decoding: request.body, as: UTF8.self).replacingOccurrences(of: "\"requiredRegionsRedacted\":true", with: "\"requiredRegionsRedacted\":false").utf8)] {
            XCTAssertThrowsError(try EluNativeRasterStoredRequest(restoring: invalid))
        }
        XCTAssertThrowsError(try EluV2ReplayPreparedRequest(request.body, captureProtocolGeneration: EluNativeRasterSealer.protocolGeneration))
        await h.close()
    }

    func testOriginalAppendDuplicateAndReopenRetainExactBodyAndOrdinal() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        let request = try h.request()
        guard case let .committed(.inserted(row)) = try await h.append(request) else { return XCTFail("original append") }
        guard case let .committed(.duplicate(same)) = try await h.append(request) else { return XCTFail("original duplicate") }
        XCTAssertEqual(row, same); XCTAssertEqual(row.prepared.body, request.body)
        let before = try await h.queue.storedReplayRecords()
        XCTAssertEqual(before, [.raster(row)])
        let oldDeliveryRows = try await h.queue.storedReplayChunks(); XCTAssertTrue(oldDeliveryRows.isEmpty)
        let metadata = try await h.queue.nativeReplaySessionState(); XCTAssertEqual(metadata.nextReplayOrdinal, 1)
        await h.close(); try await h.native.reopen()
        let after = try await h.queue.storedReplayRecords(); XCTAssertEqual(after, before)
        XCTAssertEqual(try h.native.integer("SELECT count(*) FROM replay_delivery WHERE ordinal >= 0"), 1)
        await h.queue.close()
    }

    func testMigrationPreservesOriginalWireframeAndMixedRowsAcrossFlagUpgrade() async throws {
        let h = try await Rig.make(seedReplay: true); defer { h.remove() }
        let original = try XCTUnwrap(h.originalWireframe.first)
        let mixedBefore = try await h.queue.storedReplayRecords()
        XCTAssertEqual(mixedBefore, [.wireframe(original)])
        _ = try await h.append(h.request())
        try await h.queue.ensureFlagSchema()
        let mixed = try await h.queue.storedReplayRecords()
        XCTAssertEqual(mixed.count, 2); XCTAssertEqual(mixed.first?.body, original.prepared.body)
        let old = try await h.queue.storedReplayChunks(); XCTAssertEqual(old, [original])
        XCTAssertEqual(try h.native.integer("SELECT storage_schema FROM replay_chunks WHERE ordinal=0"), 1)
        XCTAssertEqual(try h.native.integer("SELECT storage_schema FROM replay_chunks WHERE ordinal=1"), 2)
        await h.close(); try await h.native.reopen()
        let reopened = try await h.queue.storedReplayRecords(); XCTAssertEqual(reopened, mixed)
        await h.queue.close()
    }

    func testMissingRasterBranchRetainsOriginalRowsButCannotPrepareCapture() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        _ = try await h.append(h.request())
        let original = try await h.queue.storedReplayRecords()
        await h.stop()
        try await h.publish(branch: false, advance: true)
        try await h.queue.reconcileNativeRasterSource(XCTUnwrap(h.native.base.witness))
        let retained = try await h.queue.storedReplayRecords(); XCTAssertEqual(retained, original)
        do {
            _ = try await h.owner.prepareRaster(source: XCTUnwrap(h.native.base.witness),
                sourceIdentity: h.registry.sourceIdentity(), timeZoneIdentifier: "America/Los_Angeles")
            XCTFail("absent branch authorized capture")
        } catch {}
        let oldDeliveryRows = try await h.queue.storedReplayChunks(); XCTAssertTrue(oldDeliveryRows.isEmpty)
        await h.close()
    }

    func testTemporarySourceWithdrawalNeverDeletesSealedBytesOrAuthorizesAppend() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        let request = try h.request(); _ = try await h.append(request)
        let original = try await h.queue.storedReplayRecords()
        h.native.base.gate.publish(token: EluV2ConfigLifecycleToken(), lease: nil)
        XCTAssertFalse(h.admission.isCurrent())
        do { _ = try await h.append(request); XCTFail("withdrawn append") } catch {}
        let retained = try await h.queue.storedReplayRecords(); XCTAssertEqual(retained, original)
        await h.close()
    }

    func testExplicitBaseDenialsAndLocalOptOutPurgeRasterAndWireframeRows() async throws {
        for denial in ["capture", "replay", "privacy", "masking", "optOut"] {
            let h = try await Rig.make(seedReplay: true); defer { h.remove() }
            _ = try await h.append(h.request()); await h.stop()
            if denial == "optOut" {
                let snapshot = try await h.queue.snapshot()
                _ = try await h.queue.setOptedOut(true, expectedGeneration: snapshot.generation)
            } else {
                var base = try JSONSerialization.jsonObject(with: h.native.base.config) as! [String: Any]
                if denial == "capture" || denial == "replay" {
                    var features = base["features"] as! [String: Any]; features[denial] = false; base["features"] = features
                } else {
                    var privacy = base["privacy"] as! [String: Any]
                    if denial == "privacy" { var replay = privacy["replay"] as! [String: Any]; replay["enabled"] = false; privacy["replay"] = replay }
                    else { var masking = privacy["masking"] as! [String: Any]; masking["text"] = "all"; privacy["masking"] = masking }
                    base["privacy"] = privacy
                }
                h.native.base.config = try JSONSerialization.data(withJSONObject: base)
                try await h.publish(branch: false, advance: true, installCapture: false)
                let parsed = try EluV1ConfigManager.prepareConfig(h.native.base.config, endpointPolicy: .cloud)
                _ = try await h.queue.reconcileReplayConfiguration(configData: h.native.base.config,
                    expectedConfigWitness: .init(issuedAt: parsed.document.issuedAt, semanticHash: parsed.semanticHash),
                    sourceWitness: h.native.base.witness, supportedProtocolGeneration: "protocol-generation-v2", mayRetainProfile: { _ in false })
            }
            let rows = try await h.queue.storedReplayRecords(); XCTAssertTrue(rows.isEmpty, denial)
            await h.close()
        }
    }

    func testWrapperConflictPersistsAcrossReopenAndCannotBeClearedByOriginalBody() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        _ = try await h.append(h.request()); let original = try await h.queue.storedReplayRecords()
        let bytes = try XCTUnwrap(h.native.base.witness?.nativeV3?.data)
        await h.close(); try await h.native.reopen()
        // Gate publication is a source seam, deliberately bypassing no SQL checks.
        // Same embedded base + absent branch changes only the full-wrapper witness.
        try await h.publish(branch: false, advance: false, installCapture: false)
        do { try await h.queue.reconcileNativeRasterSource(XCTUnwrap(h.native.base.witness)); XCTFail("same issuance conflict") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .generationMismatch) }
        let poison = try h.native.bytes("SELECT raster_source FROM replay_state")
        XCTAssertTrue(try EluNativeRasterSourceLedger(poison).conflicted)
        let current = try XCTUnwrap(h.native.base.witness)
        let denied = await h.queue.submitCaptureAuthority(configData: current.data,
            effectivePrivacyStateData: Data("{}".utf8), sourceWitness: current)
        guard case let .terminated(reason) = denied else { return XCTFail("whole wrapper conflict authorized base") }
        XCTAssertEqual(reason.reason, .conflict, "Ordering refuses before any new privacy projection")
        await h.queue.close(); try await h.native.reopen()
        try h.publishReceipt(EluNativeV3ConfigParser.parse(bytes))
        do { try await h.queue.reconcileNativeRasterSource(XCTUnwrap(h.native.base.witness)); XCTFail("conflict forgotten") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .generationMismatch) }
        XCTAssertEqual(try h.native.bytes("SELECT raster_source FROM replay_state"), poison)
        let retained = try await h.queue.storedReplayRecords(); XCTAssertEqual(retained, original)
        try await h.publish(branch: true, advance: true, installCapture: false)
        try await h.queue.reconcileNativeRasterSource(XCTUnwrap(h.native.base.witness))
        XCTAssertFalse(try EluNativeRasterSourceLedger(h.native.bytes("SELECT raster_source FROM replay_state")).conflicted)
        await h.queue.close()
    }

    func testPlainV2RestartCannotBypassPoisonAndNewerBaseDoesNotClearRasterWitness() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        _ = try await h.append(h.request())
        let original = try await h.queue.storedReplayRecords()
        let wrapper = try XCTUnwrap(h.native.base.witness?.nativeV3?.data)
        let issuedAt = h.native.base.now
        await h.close(); try await h.native.reopen()
        try await h.publish(branch: false, advance: false, installCapture: false)
        do { try await h.queue.reconcileNativeRasterSource(XCTUnwrap(h.native.base.witness)); XCTFail("conflict missing") } catch {}
        let poison = try h.native.bytes("SELECT raster_source FROM replay_state")
        XCTAssertTrue(try EluNativeRasterSourceLedger(poison).conflicted)
        let base = h.native.base.config
        for offset in [0.0, -0.001] {
            var document = try JSONSerialization.jsonObject(with: base) as! [String: Any]
            document["issuedAt"] = EluRFC3339.string(from: issuedAt.addingTimeInterval(offset))
            let result = try await h.publishPlainV2(JSONSerialization.data(withJSONObject: document))
            guard case let .terminated(terminal) = result else { return XCTFail("plain v2 bypassed poison") }
            XCTAssertEqual(terminal.reason, .conflict)
            let rows = try await h.queue.storedReplayRecords(); XCTAssertEqual(rows, original)
            XCTAssertEqual(try h.native.bytes("SELECT raster_source FROM replay_state"), poison)
        }
        h.native.base.testClock.advance(0.001)
        var newer = try JSONSerialization.jsonObject(with: base) as! [String: Any]
        newer["issuedAt"] = EluRFC3339.string(from: h.native.base.now)
        let result = try await h.publishPlainV2(JSONSerialization.data(withJSONObject: newer))
        guard case .activated = result else { return XCTFail("newer valid legacy source denied") }
        XCTAssertNil(h.native.base.witness?.nativeV3)
        XCTAssertEqual(try h.native.bytes("SELECT raster_source FROM replay_state"), poison)
        let retainedClock = h.native.base.testClock
        let reopenedOwner = EluNativeReplayAuthority(queue: h.queue, clock: { retainedClock.read() })
        do { _ = try await reopenedOwner.prepareRaster(source: XCTUnwrap(h.native.base.witness),
            sourceIdentity: h.registry.sourceIdentity(), timeZoneIdentifier: "America/Los_Angeles")
            XCTFail("plain v2 authorized raster") }
        catch { XCTAssertEqual(error as? EluNativeReplayAuthorityError, .unavailable) }
        await reopenedOwner.close()
        let retained = try await h.queue.storedReplayRecords(); XCTAssertEqual(retained, original)
        await h.queue.close(); try await h.native.reopen()
        try h.publishReceipt(EluNativeV3ConfigParser.parse(wrapper))
        do { try await h.queue.reconcileNativeRasterSource(XCTUnwrap(h.native.base.witness)); XCTFail("native poison cleared") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .generationMismatch) }
        XCTAssertEqual(try h.native.bytes("SELECT raster_source FROM replay_state"), poison)
        await h.queue.close()
    }

    func testEquivalentRawWrapperRepublishesSourceWithoutChangingOrderingWitness() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        let old = h.admission!
        let ledger = try h.native.bytes("SELECT raster_source FROM replay_state")
        let receipt = try XCTUnwrap(h.native.base.witness?.nativeV3)
        try h.publishReceipt(EluNativeV3ConfigParser.parse(Data(" \n".utf8) + receipt.data + Data("\n".utf8)))
        XCTAssertFalse(old.isCurrent())
        try await h.queue.reconcileNativeRasterSource(XCTUnwrap(h.native.base.witness))
        XCTAssertEqual(try h.native.bytes("SELECT raster_source FROM replay_state"), ledger)
        await h.close()
    }

    func testSourceWithdrawalAtFinalSQLCheckRollsBackOriginalCandidate() async throws {
        let fault = DeliveryFault(), h = try await Rig.make(fault: fault); defer { h.remove() }
        let request = try h.request()
        let gate = h.native.base.gate
        fault.action = { if $0 == .beforeCommit { gate.publish(token: EluV2ConfigLifecycleToken(), lease: nil) } }
        do { _ = try await h.append(request); XCTFail("withdrawn final write") } catch {}
        fault.action = nil
        let rows = try await h.queue.storedReplayRecords(); XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(try h.native.integer("SELECT next_ordinal FROM replay_state"), 0)
        await h.close()
    }

    func testKnownCommitWithdrawalRetainsExactImmutableCandidate() async throws {
        let fault = DeliveryFault(), h = try await Rig.make(fault: fault); defer { h.remove() }
        let request = try h.request()
        let gate = h.native.base.gate
        fault.action = { if $0 == .afterCommit { gate.publish(token: EluV2ConfigLifecycleToken(), lease: nil) } }
        guard case let .committedThenWithdrawn(.inserted(row)) = try await h.append(request) else { return XCTFail("known commit") }
        fault.action = nil
        XCTAssertEqual(row.prepared.body, request.body)
        let rows = try await h.queue.storedReplayRecords(); XCTAssertEqual(rows, [.raster(row)])
        await h.close()
    }

    func testContextAndIdentityResetRefuseOriginalAdmission() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        let request = try h.request(); _ = try await h.append(request)
        let original = try await h.queue.storedReplayRecords()
        _ = try await h.queue.registerStandaloneSuperProperties(["new": .bool(true)])
        XCTAssertFalse(h.admission.isCurrent())
        do { _ = try await h.append(request); XCTFail("old context") } catch {}
        let snapshot = try await h.queue.snapshot()
        _ = try await h.queue.reset(expectedGeneration: snapshot.generation)
        do { _ = try await h.append(request); XCTFail("old identity") } catch {}
        // Existing reset semantics retain lawful already sealed rows unchanged;
        // opt-out is the explicit purge barrier tested separately.
        let retained = try await h.queue.storedReplayRecords(); XCTAssertEqual(retained, original)
        await h.close()
    }

    func testOriginalCollectorIdentityCannotBeSubstitutedAtDurableAppend() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        let other = EluSwiftUIReplayRegistry(requiredRegions: [])
        let marker = EluSwiftUIReplayMarkerView(region: nil, registry: other)
        marker.frame = h.root.bounds; h.root.addSubview(marker)
        defer { marker.removeFromSuperview() }
        var foreign = try h.sealer(sourceIdentity: other.sourceIdentity())
        let frame = try other.capture(deadline: 1, clock: { 0 }, draw: { _, _, _ in true })
        let request = try foreign.seal(frame, timestamp: h.timestamp)
        do { _ = try await h.append(request); XCTFail("foreign collector") } catch {}
        let rows = try await h.queue.storedReplayRecords(); XCTAssertTrue(rows.isEmpty)
        await h.close()
    }

    func testMigrationRollbackPreservesExistingSchemaAndWireframeBytes() async throws {
        let fault = DeliveryFault()
        let h = try await Rig.make(fault: fault, start: false, seedReplay: true); defer { h.remove() }
        let before = try await h.queue.storedReplayRecords(), version = try h.native.base.schemaVersion()
        fault.action = { if $0 == .beforeCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { try await h.queue.ensureNativeRasterSchema(source: XCTUnwrap(h.native.base.witness)); XCTFail("migration committed") } catch {}
        fault.action = nil
        XCTAssertEqual(try h.native.base.schemaVersion(), version)
        let after = try await h.queue.storedReplayRecords(); XCTAssertEqual(after, before)
        try await h.queue.ensureNativeRasterSchema(source: XCTUnwrap(h.native.base.witness))
        XCTAssertEqual(try h.native.base.schemaVersion(), version + 128)
        await h.close(); try await h.native.reopen()
        let reopened = try await h.queue.storedReplayRecords(); XCTAssertEqual(reopened, before)
        await h.queue.close()
    }

    func testAmbiguousRasterCommitRetainsOriginalPhysicalOccupancy() async throws {
        let fault = DeliveryFault(), h = try await Rig.make(fault: fault); defer { h.remove() }
        let request = try h.request()
        fault.action = { if $0 == .afterCommit { throw EluRuntimeQueueError.faultInjected($0) } }
        do { _ = try await h.append(request); XCTFail("ambiguous commit") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ambiguousCommit) }
        fault.action = nil
        h.use.settle(); await h.queue.close()
        do { _ = try await h.queue.stopNativeReplayCaptureAccounting(h.use); XCTFail("unknown accounting released") } catch {}
        let result = try await h.queue.finishNativeReplayCapture(XCTUnwrap(h.enrollment))
        XCTAssertEqual(result, .accountingPending)
        do { try await h.native.reopen(); XCTFail("unknown original lease released") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict) }
        XCTAssertEqual(try h.native.bytes("SELECT body FROM replay_chunks"), request.body)
        await h.owner.close()
    }

    func testFlagSchemaBeforeAndAfterRasterKeepsOriginalFeatureCombination() async throws {
        for first in [true, false] {
            let h = try await Rig.make(start: false); defer { h.remove() }
            if first { try await h.queue.ensureFlagSchema() }
            let original = try h.native.base.schemaVersion()
            try await h.queue.ensureNativeRasterSchema(source: XCTUnwrap(h.native.base.witness))
            XCTAssertEqual(try h.native.base.schemaVersion(), original + 128)
            if !first { try await h.queue.ensureFlagSchema() }
            let final = try h.native.base.schemaVersion()
            XCTAssertEqual(final % 2, 0)
            await h.close(); try await h.native.reopen()
            XCTAssertEqual(try h.native.base.schemaVersion(), final)
            try await h.queue.ensureFlagSchema()
            XCTAssertEqual(try h.native.base.schemaVersion(), final)
            await h.queue.close()
        }
    }

    func testUnsupportedOuterSchemaRefusesWithoutChangingDatabaseSidecars() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        _ = try await h.append(h.request()); await h.close()
        try h.native.base.sql("PRAGMA user_version=193")
        let namespace = try EluV1SiteNamespace.directoryComponent(exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa")
        let directory = h.native.base.root.appendingPathComponent(namespace)
        func bytes() throws -> [String: Data] {
            var result: [String: Data] = [:]
            for name in ["runtime-state-v1.sqlite3", "runtime-state-v1.sqlite3-wal", "runtime-state-v1.sqlite3-shm"] {
                let path = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: path.path) { result[name] = try Data(contentsOf: path) }
            }
            return result
        }
        let before = try bytes()
        do { try await h.native.reopen(); XCTFail("unknown schema opened") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .unsupportedSchemaVersion(193)) }
        XCTAssertEqual(try bytes(), before)
        // This is actual current-opener refusal. Historical downgrade safety is
        // separately checked against retained predecessor source, not claimed here.
    }

    @MainActor private final class Rig {
        let native: NativeSessionHarness
        let window: UIWindow, previous: UIViewController?, root: UIView
        let registry = EluSwiftUIReplayRegistry(requiredRegions: [])
        let marker: EluSwiftUIReplayMarkerView
        let lifecycle = EluNativeReplayLifecycle()
        let owner: EluNativeReplayAuthority
        var enrollment: EluNativeReplayCaptureEnrollment?
        var use: EluNativeReplayCapturePhysicalUse!
        var permit: EluNativeRasterPermit!
        var admission: EluNativeRasterCaptureAdmission!
        var originalWireframe: [EluV2ReplayStoredChunk] = []
        var queue: EluSQLiteRuntimeQueue { native.queue }
        var timestamp: Int64 { get throws { try EluV1Timestamp.exactClock(native.base.now).floorUnixMilliseconds } }
        init(_ native: NativeSessionHarness) throws {
            self.native = native
            owner = EluNativeReplayAuthority(queue: native.queue, clock: { native.base.now })
            window = try EluUIKitTestHost.window(); previous = window.rootViewController
            let controller = UIViewController(); window.rootViewController = controller; controller.loadViewIfNeeded()
            root = controller.view; root.frame = window.bounds
            marker = EluSwiftUIReplayMarkerView(region: nil, registry: registry)
            marker.frame = CGRect(x: 0, y: 0, width: 32, height: 32); root.addSubview(marker)
            window.makeKeyAndVisible(); window.layoutIfNeeded(); CATransaction.flush()
            lifecycle.attached(UUID())
        }
        static func make(fault: DeliveryFault? = nil, start: Bool = true, seedReplay: Bool = false) async throws -> Rig {
            let native = try await NativeSessionHarness.make(seedReplay: seedReplay, fault: fault)
            let h = try Rig(native)
            h.originalWireframe = try await h.queue.storedReplayChunks()
            try await h.publish(branch: true, advance: true)
            if start {
                let selection = try XCTUnwrap(h.lifecycle.select(root: h.root, window: h.window))
                let prepared = try await h.owner.prepareRaster(source: XCTUnwrap(h.native.base.witness),
                    sourceIdentity: h.registry.sourceIdentity(), timeZoneIdentifier: "America/Los_Angeles")
                h.enrollment = try await h.queue.enrollNativeReplayCapture()
                h.use = try XCTUnwrap(h.enrollment?.takePhysicalUse())
                let permit = try await h.owner.startRaster(prepared, selection: selection, physicalUse: h.use)
                h.permit = try XCTUnwrap(permit)
                h.admission = try await h.owner.captureAdmission(for: h.permit, physicalUse: h.use)
            }
            return h
        }
        func publish(branch: Bool, advance: Bool, installCapture: Bool = true) async throws {
            var base = try JSONSerialization.jsonObject(with: native.base.config) as! [String: Any]
            if advance { native.base.testClock.advance(0.001); base["issuedAt"] = EluRFC3339.string(from: native.base.now) }
            let bytes = try JSONSerialization.data(withJSONObject: base)
            let parsed = try EluNativeV3ConfigParser.parse(branch ? nativeV3SourceRasterFixture(base: bytes) : nativeV3SourceEnvelope(bytes))
            try publishReceipt(parsed)
            guard installCapture else { return }
            guard case .activated = try await applyCapture(parsed.configV2Data) else { throw EluRuntimeQueueError.invalidState }
        }
        func publishPlainV2(_ data: Data) async throws -> EluV1CaptureAuthorityUpdateResult {
            let document = try EluV1ConfigManager.prepareConfig(data, endpointPolicy: .cloud).document
            let token = EluV2ConfigLifecycleToken()
            native.base.gate.publish(token: token, lease: EluV2ConfigLease(data: data,
                expiresAt: document.expiresAt, continuousDeadline: native.base.testClock.ticks() + 600_000_000_000))
            native.base.witness = try XCTUnwrap(native.base.gate.witness(for: token)); native.base.config = data
            return try await applyCapture(data)
        }
        func applyCapture(_ data: Data) async throws -> EluV1CaptureAuthorityUpdateResult {
            let manager = EluV1ConfigManager(); _ = try manager.update(configData: data, now: native.base.now)
            let snapshot = try await queue.snapshot()
            let input = EluPrivacyProjectionInput(contextRevision: snapshot.identity.contextRevision, identityOptedOut: snapshot.identity.optedOut,
                timeZoneIdentifier: "America/Los_Angeles", evaluatedAt: native.base.now,
                appliedMasking: EluPrivacyMaskingCapability(text: .all, inputs: .all, images: .block),
                replaySampleDraw: 0, replaySessionEligible: false, replayBudgetRemainingSeconds: 0, localReplayTransports: [])
            let projection = try EluPrivacyStateProjector.project(context: manager.activePrivacyProjectionContext(now: native.base.now), input: input)
            return await queue.submitCaptureAuthority(configData: data,
                effectivePrivacyStateData: projection.stateData, sourceWitness: native.base.witness)
        }
        func publishReceipt(_ parsed: EluNativeV3ConfigParser.Parsed) throws {
            let token = EluV2ConfigLifecycleToken()
            native.base.gate.publish(token: token, lease: EluV2ConfigLease(data: parsed.configV2Data,
                expiresAt: parsed.base.expiresAt, continuousDeadline: native.base.testClock.ticks() + 600_000_000_000, nativeV3: parsed))
            native.base.witness = try XCTUnwrap(native.base.gate.witness(for: token)); native.base.config = parsed.configV2Data
        }
        func sealer(sourceIdentity: EluSwiftUIReplaySourceIdentity? = nil) throws -> EluNativeRasterSealer {
            let original = admission!
            return try EluNativeRasterSealer(replayId: permit.replayId, identity: permit.identity, policy: permit.sealingPolicy(),
                versions: .init(runtime: .init(name: "elu-ios", version: "1.0.0"), facade: .init(name: "EluAnalytics", version: "1.0.0")),
                sourceIdentity: sourceIdentity ?? registry.sourceIdentity(), sourceIsCurrent: { original.isCurrent() })
        }
        func request() throws -> EluNativeRasterPreparedRequest {
            var value = try sealer()
            return try value.seal(registry.capture(deadline: 1, clock: { 0 }, draw: { _, _, context in
                context.setFillColor(UIColor.green.cgColor); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32)); return true
            }), timestamp: timestamp)
        }
        func append(_ request: EluNativeRasterPreparedRequest) async throws -> EluNativeRasterCaptureAppendResult {
            try await queue.appendNativeRaster(request, admission: admission, physicalUse: use)
        }
        func stop() async {
            use?.settle(); try? await owner.stop()
            if let enrollment { _ = try? await queue.finishNativeReplayCapture(enrollment) }
            enrollment = nil
        }
        func close() async { await stop(); await owner.close(); await queue.close() }
        func remove() { window.rootViewController = previous; native.base.remove() }
    }
}
#endif
