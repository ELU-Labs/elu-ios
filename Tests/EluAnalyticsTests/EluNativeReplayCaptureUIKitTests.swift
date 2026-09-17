import Foundation
import XCTest
#if canImport(UIKit)
import UIKit
@testable import EluAnalytics

@MainActor private final class CaptureRoot: UIView {
    var onBounds: (() -> Void)?
    private(set) var boundsReads = 0
    override var bounds: CGRect {
        get {
            boundsReads += 1
            let action = onBounds; onBounds = nil; action?()
            return super.bounds
        }
        set { super.bounds = newValue }
    }
}

final class EluNativeReplayCaptureUIKitTests: XCTestCase {
    @MainActor func testUIKitPairOnlyOrWrongGenerationCannotStartPhysicalCapture() async throws {
        for generations: Set<String> in [[], ["unproved-other-generation"]] {
            let h = try await make(), setup = try await selected(h, generations: generations)
            defer { setup.root.removeFromSuperview(); h.base.remove() }
            let owner = try start(h, setup)
            guard case .settled = await owner.finished() else { return XCTFail("unproved generation did not settle") }
            let state = try await h.queue.nativeReplaySessionState()
            XCTAssertNil(state.session?.firstStartAt); XCTAssertNil(state.session?.activeEpoch)
            let rows = try await h.queue.storedReplayChunks(); XCTAssertTrue(rows.isEmpty)
            await h.queue.close(); try await h.reopen(); await h.queue.close()
        }
    }

    @MainActor func testUIKitPreparedClockRollbackBeforeRunPersistsDenialBeforeRelease() async throws {
        let h = try await make(), setup = try await selected(h)
        defer { setup.root.removeFromSuperview(); h.base.remove() }
        let original = h.base.now
        h.base.testClock.set(original.addingTimeInterval(-0.1))
        let owner = try start(h, setup)
        guard case .settled = await owner.finished() else { return XCTFail("prepared denial did not settle") }
        let state = try await h.queue.nativeReplaySessionState()
        XCTAssertEqual(state.session?.clockDenied, true)
        XCTAssertNil(state.session?.firstStartAt); XCTAssertNil(state.session?.activeEpoch)
        await h.queue.close(); h.base.testClock.set(original.addingTimeInterval(0.1)); try await h.reopen()
        let reopened = try await h.queue.nativeReplaySessionState()
        XCTAssertEqual(reopened.session?.clockDenied, true)
        await h.queue.close()
    }

    @MainActor func testUIKitExpiredPreparedBeforeRunDoesNotStartOrStrandPhysicalUse() async throws {
        let h = try await make(), setup = try await selected(h)
        defer { setup.root.removeFromSuperview(); h.base.remove() }
        h.base.testClock.advance(601)
        let owner = try start(h, setup)
        guard case .settled = await owner.finished() else { return XCTFail("expired prepared work did not settle") }
        let state = try await h.queue.nativeReplaySessionState()
        XCTAssertNil(state.session?.firstStartAt); XCTAssertNil(state.session?.activeEpoch)
        let rows = try await h.queue.storedReplayChunks(); XCTAssertTrue(rows.isEmpty)
        await h.queue.close(); try await h.reopen(); await h.queue.close()
    }

    @MainActor func testUIKitActualCollectorSealerSQLiteSuffixAndReopen() async throws {
        let h = try await make(), setup = try await selected(h)
        defer { setup.root.removeFromSuperview(); h.base.remove() }
        let label = UILabel(frame: CGRect(x: 4, y: 8, width: 80, height: 20))
        label.text = "PRIVATE_CAPTURE_CONTENT"; setup.root.addSubview(label)
        let owner = try start(h, setup)
        try await wait { try await h.queue.storedReplayChunks().count == 1 }
        let first = try await h.queue.storedReplayChunks()
        label.frame.origin.x = 24; h.base.testClock.advance(10)
        try await wait { try await h.queue.storedReplayChunks().count == 2 }
        let outcome = await owner.stop()
        guard case .settled = outcome else { return XCTFail("capture did not settle") }
        let rows = try await h.queue.storedReplayChunks()
        XCTAssertEqual(rows[0], first[0]); XCTAssertEqual(rows.map(\.prepared.sequence), [0, 1])
        XCTAssertEqual(rows[0].prepared.replayId, rows[1].prepared.replayId)
        XCTAssertTrue(rows.allSatisfy { $0.maskingProfile == EluNativeMaskingProfile.blanketMask().canonicalBytes })
        try export(rows, name: "capture-suffix")
        await h.queue.close(); try await h.reopen()
        let reopened = try await h.queue.storedReplayChunks(); XCTAssertEqual(reopened, rows)
        await h.queue.close()
    }

    @MainActor func testUIKitMinimumRetainsMaskedInitialUntilOriginalContinuousThreshold() async throws {
        let h = try await make(minimum: 3), setup = try await selected(h)
        defer { setup.root.removeFromSuperview(); h.base.remove() }
        let owner = try start(h, setup)
        try await wait { try await h.queue.nativeReplaySessionState().session?.activeEpoch != nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        let reads = setup.probe.boundsReads
        h.base.testClock.advance(2.999)
        try await wait { setup.probe.boundsReads > reads }
        let early = try await h.queue.storedReplayChunks(); XCTAssertTrue(early.isEmpty)
        h.base.testClock.advance(0.001)
        try await wait { try await h.queue.storedReplayChunks().count == 1 }
        guard case .settled = await owner.stop() else { return XCTFail("minimum capture did not settle") }
        let rows = try await h.queue.storedReplayChunks(); try export(rows, name: "capture-minimum")
        await h.queue.close()
    }

    @MainActor func testUIKitShortWithdrawalDiscardsUnsealedInitial() async throws {
        let h = try await make(minimum: 30), setup = try await selected(h)
        defer { setup.root.removeFromSuperview(); h.base.remove() }
        let owner = try start(h, setup)
        try await wait { try await h.queue.nativeReplaySessionState().session?.activeEpoch != nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        guard case .settled = await owner.stop() else { return XCTFail("short capture did not settle") }
        let rows = try await h.queue.storedReplayChunks(); XCTAssertTrue(rows.isEmpty)
        let state = try await h.queue.nativeReplaySessionState(); XCTAssertNil(state.session?.activeEpoch)
        await h.queue.close()
    }

    @MainActor func testUIKitWithdrawalInsideGetterCannotAppendCollectedFrame() async throws {
        let h = try await make(), setup = try await selected(h)
        defer { setup.root.removeFromSuperview(); h.base.remove() }
        var owner: EluNativeReplayCaptureOwner?
        setup.probe.onBounds = { owner?.withdraw() }
        owner = try start(h, setup)
        guard case .settled = await owner!.finished() else { return XCTFail("getter withdrawal did not settle") }
        let rows = try await h.queue.storedReplayChunks(); XCTAssertTrue(rows.isEmpty)
        let state = try await h.queue.nativeReplaySessionState(); XCTAssertNil(state.session?.activeEpoch)
        owner = nil; await h.queue.close()
    }

    @MainActor func testUIKitWeakHandleDeinitSettlesExistingRunWithoutRetainingOwner() async throws {
        let h = try await make(minimum: 30), setup = try await selected(h)
        defer { setup.root.removeFromSuperview(); h.base.remove() }
        var owner: EluNativeReplayCaptureOwner? = try start(h, setup)
        weak var weakOwner = owner
        try await wait { try await h.queue.nativeReplaySessionState().session?.activeEpoch != nil }
        owner = nil; XCTAssertNil(weakOwner)
        try await wait { try await h.queue.nativeReplaySessionState().session?.activeEpoch == nil }
        let rows = try await h.queue.storedReplayChunks(); XCTAssertTrue(rows.isEmpty)
        let enrolled = try await h.queue.enrollNativeReplayCapture()
        let replacement = try XCTUnwrap(enrolled); replacement.cancelUnused()
        let finished = try await h.queue.finishNativeReplayCapture(replacement); XCTAssertEqual(finished, .settled)
        await h.queue.close(); try await h.reopen(); await h.queue.close()
    }

    @MainActor func testUIKitKnownCommitThenWithdrawalPreservesExactFirstChunk() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault), setup = try await selected(h)
        defer { setup.root.removeFromSuperview(); h.base.remove() }
        var inserted = false, fired = false
        fault.action = { point in
            if point == .afterRecordInsert(0) { inserted = true }
            if point == .afterCommit, inserted, !fired { fired = true; setup.authority.withdraw() }
        }
        let owner = try start(h, setup)
        guard case .settled = await owner.finished() else { return XCTFail("known append withdrawal did not settle") }
        fault.action = nil; XCTAssertTrue(fired)
        let rows = try await h.queue.storedReplayChunks(); XCTAssertEqual(rows.count, 1)
        try export(rows, name: "capture-commit-withdrawal")
        let state = try await h.queue.nativeReplaySessionState(); XCTAssertNil(state.session?.activeEpoch)
        await h.queue.close()
    }

    @MainActor func testUIKitAppendRollbackStopsWithoutSuffixOrFalsePhysicalOccupancy() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault), setup = try await selected(h)
        defer { setup.root.removeFromSuperview(); h.base.remove() }
        var inserted = false, fired = false
        fault.action = { point in
            if point == .afterRecordInsert(0) { inserted = true }
            if point == .beforeCommit, inserted, !fired {
                fired = true; throw EluRuntimeQueueError.faultInjected(point)
            }
        }
        let owner = try start(h, setup)
        guard case .settled = await owner.finished() else { return XCTFail("proven append rollback quarantined") }
        fault.action = nil; XCTAssertTrue(fired)
        let rows = try await h.queue.storedReplayChunks(); XCTAssertTrue(rows.isEmpty)
        let state = try await h.queue.nativeReplaySessionState(); XCTAssertNil(state.session?.activeEpoch)
        let enrolled = try await h.queue.enrollNativeReplayCapture()
        let replacement = try XCTUnwrap(enrolled); replacement.cancelUnused()
        let finished = try await h.queue.finishNativeReplayCapture(replacement); XCTAssertEqual(finished, .settled)
        await h.queue.close()
    }

    @MainActor func testUIKitUnknownStopRetainsInstallationUntilProcessExit() async throws {
        let fault = DeliveryFault(), h = try await make(fault: fault), setup = try await selected(h)
        defer { setup.root.removeFromSuperview() }
        let owner = try start(h, setup)
        try await wait { try await h.queue.storedReplayChunks().count == 1 }
        var fired = false
        fault.action = { point in
            if point == .afterCommit, !fired { fired = true; throw EluRuntimeQueueError.faultInjected(point) }
        }
        guard case .quarantined = await owner.stop() else { return XCTFail("unknown stop released occupancy") }
        fault.action = nil; XCTAssertTrue(fired); await h.queue.close()
        do { try await h.reopen(); XCTFail("uncertain stop released flock") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict) }
        // Keep this private fixture directory with its quarantined process lease.
    }

    @MainActor func testUIKitExplicitCollectorSealerAndNativeAdmission() async throws {
        let h = try await make(), setup = try await selected(h)
        defer { setup.root.removeFromSuperview(); h.base.remove() }
        let pending = try await h.queue.enrollNativeReplayCapture()
        let enrollment = try XCTUnwrap(pending), use = try XCTUnwrap(enrollment.takePhysicalUse())
        do {
            let started = try await setup.authority.start(setup.prepared, selection: setup.selection, physicalUse: use)
            let permit = try XCTUnwrap(started)
            let admission = try await setup.authority.captureAdmission(for: permit, physicalUse: use)
            let collector = try EluUIKitReplayCollector()
            let frame = try setup.selection.consumeRoot { root in
                try collector.collect(root: root, ordinal: 0,
                    timestamp: EluNativeReplayCaptureClock.milliseconds(h.base.now),
                    hasUnresolvedConfiguredBlockRules: admission.hasUnresolvedBlockRules,
                    isCurrent: { permit.isCurrentForCollection() && admission.isCurrent() })
            }
            let versions = try EluVersionContext(runtime: .init(name: "elu-ios", version: "0.1.0"), facade: .init(name: "elu-ios", version: "0.1.0"))
            var sealer = try EluNativeReplaySealer(replayId: permit.replayId, identity: permit.identity,
                authorization: permit.resolution, privacy: permit.privacy, profile: permit.profile, versions: versions)
            let request = try sealer.seal([frame])
            let state = try await h.queue.nativeReplaySessionState()
            print("native-time-boundary", String(reflecting: request.startedAt), String(reflecting: state.session?.firstStartAt))
            _ = try await h.queue.appendNativeReplay(request, admission: admission, physicalUse: use)
            let rows = try await h.queue.storedReplayChunks(); XCTAssertEqual(rows.count, 1)
            collector.withdraw(); use.settle()
            let stopped = try await setup.authority.stop(); XCTAssertEqual(stopped, .settled)
            let finished = try await h.queue.finishNativeReplayCapture(enrollment); XCTAssertEqual(finished, .settled)
            await h.queue.close()
        } catch {
            use.settle(); _ = try? await setup.authority.stop()
            if (try? await h.queue.finishNativeReplayCapture(enrollment)) != .settled { enrollment.quarantine() }
            await h.queue.close(); throw error
        }
    }

    private struct Selection {
        let root: UIView
        let probe: CaptureRoot
        let authority: EluNativeReplayAuthority
        let prepared: EluNativeReplayPreparedAuthority
        let selection: EluNativeReplaySelection
    }
    @MainActor private func selected(_ h: NativeSessionHarness, generations: Set<String>? = nil) async throws -> Selection {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap { $0.windows }.filter { !$0.isHidden }
        let window = try XCTUnwrap(windows.first), root = UIView(frame: window.bounds)
        window.addSubview(root)
        let probe = CaptureRoot(frame: CGRect(x: 0, y: 0, width: 2, height: 2)); root.addSubview(probe)
        let authority = EluNativeReplayAuthority(queue: h.queue, clock: { h.base.now })
        let lifecycle = EluNativeReplayLifecycle(); lifecycle.observeWithdrawal { authority.withdraw() }
        lifecycle.attached(UUID())
        let selection = try XCTUnwrap(lifecycle.select(root: root, window: window))
        let capabilities = EluNativeReplayCapabilities(readbackProvenTransports: [
            EluV1ReplayTransportSelection(codec: "elu-native-wireframe-v1", compression: .gzip)!
        ], readbackProvenProtocolGenerations: generations ?? [h.base.generation])
        let prepared = try await authority.prepare(source: XCTUnwrap(h.base.witness),
            capabilities: capabilities, timeZoneIdentifier: "America/Los_Angeles")
        return Selection(root: root, probe: probe, authority: authority, prepared: prepared, selection: selection)
    }
    @MainActor private func start(_ h: NativeSessionHarness, _ setup: Selection) throws -> EluNativeReplayCaptureOwner {
        let versions = try EluVersionContext(runtime: .init(name: "elu-ios", version: "0.1.0"),
            facade: .init(name: "elu-ios", version: "0.1.0"))
        return EluNativeReplayCaptureOwner(queue: h.queue, authority: setup.authority,
            prepared: setup.prepared, selection: setup.selection, versions: versions,
            wallClock: { h.base.now }, continuousNanoseconds: { h.base.testClock.ticks() })
    }
    private func make(minimum: Int = 0, fault: DeliveryFault? = nil) async throws -> NativeSessionHarness {
        let h = try await NativeSessionHarness.make(fault: fault)
        h.base.testClock.advance(0.001)
        var body = try JSONSerialization.jsonObject(with: h.base.config) as! [String: Any]
        var capabilities = body["capabilities"] as! [String: Any], replay = capabilities["replay"] as! [String: Any]
        replay["transports"] = [["codec": "elu-native-wireframe-v1", "compression": "gzip"]]
        capabilities["replay"] = replay; body["capabilities"] = capabilities
        var privacy = body["privacy"] as! [String: Any], policy = privacy["replay"] as! [String: Any]
        policy["minimumDurationSeconds"] = minimum; privacy["replay"] = policy; body["privacy"] = privacy
        body["issuedAt"] = EluRFC3339.string(from: h.base.now)
        h.base.config = try JSONSerialization.data(withJSONObject: body); try await h.publish()
        return h
    }
    @MainActor private func wait(_ predicate: () async throws -> Bool) async throws {
        let began = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - began < 6_000_000_000 {
            if try await predicate() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw EluNativeReplayCaptureError.settlementPending
    }
    private func export(_ rows: [EluV2ReplayStoredChunk], name: String) throws {
        guard ProcessInfo.processInfo.environment["ELU_NATIVE_CAPTURE_EXPORTS"] == "1" else { return }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("native-capture-output", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, row) in rows.enumerated() {
            try row.prepared.body.write(to: directory.appendingPathComponent("\(name)-\(index).json"), options: .atomic)
        }
    }
}
#endif
