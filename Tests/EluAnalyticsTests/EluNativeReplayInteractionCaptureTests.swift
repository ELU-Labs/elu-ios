#if canImport(UIKit)
import UIKit
import XCTest
import zlib
@testable import EluAnalytics

/// The actual original queue/capture run arms the real window component here.
/// Detached facts exercise its callback decisions; no synthesized UITouch or
/// claim about genuine drag recognition/dispatch is made by these tests.
@MainActor
final class EluNativeReplayInteractionCaptureTests: XCTestCase {
    func testKnownInitialMinimumCommitArmsOnceAndLawfulScrollSurvivesGracefulSealAndReopen() async throws {
        let fixture = try await make(minimum: 3)
        let h = fixture.h
        let scroll = UIScrollView(frame: fixture.root.bounds)
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        scroll.contentSize = CGSize(width: scroll.bounds.width, height: 900)
        let safe = UIView(frame: CGRect(x: 10, y: 0, width: 100, height: 300))
        scroll.addSubview(safe); fixture.root.addSubview(scroll)
        fixture.root.layoutIfNeeded(); CATransaction.flush()
        let originalChildren = scroll.subviews.prefix(17).map(ObjectIdentifier.init)
        let owner = try start(fixture)
        let diagnostics = {
            ReplayScrollFixtureDiagnostics.describe(root: fixture.root, scroll: scroll, target: safe,
                originalChildren: originalChildren) +
                ";collectedFrames=\(owner.collectedFrameCountForTesting());recording=\(owner.isRecording())" +
                ";observerPresent=\(self.observer(fixture.window) != nil)" +
                ";observerOrdinal=\(self.observer(fixture.window)?.originalProjectionOrdinal ?? -1)" +
                ";contactActive=\(self.observer(fixture.window)?.contactIsActive == true)"
        }
        var settled = false
        defer { fixture.removeWindow(); if settled { h.base.remove() } }
        do {
            try await wait("initial original geometry", diagnostics: diagnostics) { owner.collectedFrameCountForTesting() == 1 }
            XCTAssertNil(observer(fixture.window))
            let early = try await h.queue.storedReplayChunks(); XCTAssertTrue(early.isEmpty)
            h.base.testClock.advance(3)
            try await wait("known minimum-qualified commit installs observer", diagnostics: diagnostics) { self.observer(fixture.window) != nil }
            let first = try await h.queue.storedReplayChunks()
            XCTAssertEqual(first.count, 1)
            let original = try XCTUnwrap(observer(fixture.window)), finger = NSObject()
            h.base.testClock.advance(0.25)
            original.observeForTesting(fact(.began, finger), originalView: safe) {}
            h.base.testClock.advance(0.25)
            original.observeForTesting(fact(.moved, finger), originalView: safe) { scroll.contentOffset.y = 20 }
            try await wait("first geometry after original scroll delivery", diagnostics: diagnostics) { owner.collectedFrameCountForTesting() >= 3 }
            XCTAssertTrue(observer(fixture.window) === original)
            h.base.testClock.advance(0.25)
            original.observeForTesting(fact(.moved, finger, y: 60), originalView: safe) {}
            h.base.testClock.advance(0.25)
            original.observeForTesting(fact(.ended, finger, y: 60), originalView: safe) {}
            guard case .settled = await owner.finishGracefully() else { return XCTFail("Original physical/accounting settlement required") }
            XCTAssertNil(observer(fixture.window))
            let rows = try await h.queue.storedReplayChunks()
            XCTAssertGreaterThanOrEqual(rows.count, 2)
            XCTAssertEqual(rows.first, first.first)
            let events = try rows.flatMap { try decoded($0.prepared) }
            let interaction = events.compactMap { $0["data"] as? [String: Any] }
            XCTAssertTrue(interaction.contains { ($0["source"] as? Int) == 2 && ($0["type"] as? Int) == 7 })
            XCTAssertTrue(interaction.contains { ($0["source"] as? Int) == 6 })
            XCTAssertTrue(interaction.contains { ($0["source"] as? Int) == 2 && ($0["type"] as? Int) == 9 })
            XCTAssertFalse(interaction.contains { ($0["source"] as? Int) == 2 && ($0["type"] as? Int) == 10 }, "Lawful scroll must not reduce to canceled contact")
            let state = try await h.queue.nativeReplaySessionState(); XCTAssertNil(state.session?.activeEpoch)
            await fixture.authority.close(); await h.queue.close(); try await h.reopen()
            let reopened = try await h.queue.storedReplayChunks(); XCTAssertEqual(reopened, rows)
            await h.queue.close(); settled = true
        } catch {
            let result = await owner.stop(); await fixture.authority.close(); await h.queue.close()
            if case .settled = result { settled = true }
            throw error
        }
    }

    func testOriginalRunEarlySealsBeforePeriodicFlushWithoutDroppingOrderedMoves() async throws {
        let fixture = try await make(), safe = UIView(frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        fixture.root.addSubview(safe); fixture.root.layoutIfNeeded(); CATransaction.flush()
        let h = fixture.h, owner = try start(fixture)
        var settled = false
        defer { fixture.removeWindow(); if settled { h.base.remove() } }
        do {
            try await wait { self.observer(fixture.window) != nil }
            let original = try XCTUnwrap(observer(fixture.window)), finger = NSObject(), began = h.base.now
            h.base.testClock.advance(0.125)
            original.observeForTesting(fact(.began, finger), originalView: safe) {}
            for index in 0 ..< 70 {
                h.base.testClock.advance(0.125)
                original.observeForTesting(fact(.moved, finger, y: CGFloat(30 + index % 20)), originalView: safe) {}
                // Let the one original serial consumer drain; no per-input task
                // or synthetic UIKit touch is installed by this fixture.
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertLessThan(h.base.now.timeIntervalSince(began), 10)
            try await wait { try await h.queue.storedReplayChunks().count >= 2 }
            h.base.testClock.advance(0.125)
            original.observeForTesting(fact(.ended, finger), originalView: safe) {}
            guard case .settled = await owner.finishGracefully() else { return XCTFail("early-seal run did not settle") }
            let rows = try await h.queue.storedReplayChunks(), events = try rows.flatMap { try decoded($0.prepared) }
            let records = events.compactMap { $0["data"] as? [String: Any] }
            let positions = records.filter { ($0["source"] as? Int) == 6 }.flatMap { $0["positions"] as? [[String: Any]] ?? [] }
            XCTAssertEqual(positions.count, 70, "Early sealing must retry the exact rejected unit rather than drop it")
            XCTAssertFalse(records.contains { ($0["source"] as? Int) == 2 && ($0["type"] as? Int) == 10 })
            XCTAssertNil(observer(fixture.window))
            await fixture.authority.close(); await h.queue.close(); settled = true
        } catch {
            let result = await owner.stop(); await fixture.authority.close(); await h.queue.close()
            if case .settled = result { settled = true }; throw error
        }
    }

    func testShortMinimumAndWithdrawalCannotInstallWindowObserver() async throws {
        for withdraw in [false, true] {
            let fixture = try await make(minimum: 30), owner = try start(fixture)
            var settled = false
            defer { fixture.removeWindow(); if settled { fixture.h.base.remove() } }
            do {
                try await wait { owner.collectedFrameCountForTesting() == 1 }
                XCTAssertNil(observer(fixture.window))
                if withdraw { fixture.h.base.gate.close() }
                let result: EluNativeReplayCaptureOutcome
                if withdraw { result = await owner.stop() } else { result = await owner.finishGracefully() }
                guard case .settled = result else { return XCTFail("short original capture did not settle") }
                XCTAssertNil(observer(fixture.window))
                let rows = try await fixture.h.queue.storedReplayChunks(); XCTAssertTrue(rows.isEmpty)
                let state = try await fixture.h.queue.nativeReplaySessionState(); XCTAssertNil(state.session?.activeEpoch)
                await fixture.authority.close(); await fixture.h.queue.close(); settled = true
            } catch {
                let result = await owner.stop(); await fixture.authority.close(); await fixture.h.queue.close()
                if case .settled = result { settled = true }; throw error
            }
        }
    }

    func testSourceWithdrawalDiscardsPendingCoordinatesAndDetachesOriginalBeforeLeaseRelease() async throws {
        let fixture = try await make(), safe = UIView(frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        fixture.root.addSubview(safe); fixture.root.layoutIfNeeded(); CATransaction.flush()
        let owner = try start(fixture)
        var settled = false
        defer { fixture.removeWindow(); if settled { fixture.h.base.remove() } }
        do {
            try await wait { self.observer(fixture.window) != nil }
            let first = try await fixture.h.queue.storedReplayChunks()
            let original = try XCTUnwrap(observer(fixture.window)), finger = NSObject()
            fixture.h.base.testClock.advance(0.25)
            original.observeForTesting(fact(.began, finger), originalView: safe) { fixture.h.base.gate.close() }
            guard case .settled = await owner.stop() else { return XCTFail("withdrawal did not settle") }
            XCTAssertNil(observer(fixture.window))
            let rows = try await fixture.h.queue.storedReplayChunks(); XCTAssertEqual(rows, first)
            XCTAssertFalse(fixture.window.installReplayObserver(original))
            await fixture.authority.close(); await fixture.h.queue.close(); try await fixture.h.reopen()
            await fixture.h.queue.close(); settled = true
        } catch {
            let result = await owner.stop(); await fixture.authority.close(); await fixture.h.queue.close()
            if case .settled = result { settled = true }; throw error
        }
    }

    func testRootReplacementDetachesOriginalBeforeRequestingFreshEpoch() async throws {
        let fixture = try await make(), owner = try start(fixture)
        var settled = false
        defer { fixture.removeWindow(); if settled { fixture.h.base.remove() } }
        do {
            try await wait { self.observer(fixture.window) != nil }
            let first = try await fixture.h.queue.storedReplayChunks()
            let controller = UIViewController()
            controller.view = UIView(frame: fixture.window.bounds)
            fixture.window.rootViewController = controller
            fixture.window.layoutIfNeeded(); CATransaction.flush()
            fixture.h.base.testClock.advance(1)
            guard case .settled = await owner.finished() else { return XCTFail("Original root boundary did not settle") }
            XCTAssertTrue(owner.needsRootRecovery())
            XCTAssertNil(observer(fixture.window))
            let rows = try await fixture.h.queue.storedReplayChunks()
            XCTAssertEqual(rows, first, "A replacement root cannot inherit the old observer or stream")
            let state = try await fixture.h.queue.nativeReplaySessionState()
            XCTAssertNil(state.session?.activeEpoch)
            await fixture.authority.close(); await fixture.h.queue.close(); settled = true
        } catch {
            let result = await owner.stop(); await fixture.authority.close(); await fixture.h.queue.close()
            if case .settled = result { settled = true }; throw error
        }
    }

    func testOrdinaryWindowCannotSpendV2FirstStartOrInstallObservation() async throws {
        let fixture = try await make(), h = fixture.h
        let ordinary = fixture.host.windowScene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: fixture.host.bounds)
        ordinary.frame = fixture.host.frame
        let controller = UIViewController(), root = UIView(frame: ordinary.bounds)
        controller.view = root; ordinary.rootViewController = controller; ordinary.makeKeyAndVisible()
        ordinary.layoutIfNeeded(); root.layoutIfNeeded(); CATransaction.flush()
        var settled = false
        defer {
            ordinary.isHidden = true; ordinary.rootViewController = nil
            fixture.removeWindow(); if settled { h.base.remove() }
        }
        let lifecycle = EluNativeReplayLifecycle(); lifecycle.attached(UUID())
        let selection = try XCTUnwrap(lifecycle.select(root: root, window: ordinary))
        let versions = try EluVersionContext(runtime: .init(name: "elu-ios", version: "0.1.0"), facade: .init(name: "elu-ios", version: "0.1.0"))
        let owner = EluNativeReplayCaptureOwner(queue: h.queue, authority: fixture.authority, prepared: fixture.prepared,
            selection: selection, versions: versions, wallClock: { h.base.now }, continuousNanoseconds: { h.base.testClock.ticks() })
        guard case .settled = await owner.finished() else { return XCTFail("Unsupported original host did not settle") }
        let state = try await h.queue.nativeReplaySessionState(), rows = try await h.queue.storedReplayChunks()
        XCTAssertNil(state.session?.firstStartAt); XCTAssertNil(state.session?.activeEpoch); XCTAssertTrue(rows.isEmpty)
        await fixture.authority.close(); await h.queue.close(); settled = true
    }

    func testUnknownInitialCommitNeverArmsAndRetainsOriginalQueueLease() async throws {
        let fault = DeliveryFault(), fixture = try await make(fault: fault)
        defer { fixture.removeWindow() } // Preserve the poisoned original directory/lease.
        var inserted = false
        fault.action = { point in
            if point == .afterRecordInsert(0) { inserted = true }
            if inserted && point == .afterCommit { throw EluRuntimeQueueError.faultInjected(point) }
        }
        let owner = try start(fixture)
        guard case .quarantined = await owner.finished() else { return XCTFail("Unknown append released the original lease") }
        fault.action = nil
        XCTAssertTrue(inserted)
        XCTAssertNil(observer(fixture.window), "An ambiguous initial result grants no observer installation")
        XCTAssertFalse(owner.isRecording())
        await fixture.h.queue.close()
        do { try await fixture.h.reopen(); XCTFail("Quarantined original queue was replaced") }
        catch { XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict) }
    }

    private struct Fixture {
        let h: NativeSessionHarness
        let host: UIWindow
        let window: EluReplayWindow
        let root: UIView
        let lifecycle: EluNativeReplayLifecycle
        let authority: EluNativeReplayAuthority
        let prepared: EluNativeReplayPreparedAuthority
        let selection: EluNativeReplaySelection
        @MainActor func removeWindow() { window.isHidden = true; window.rootViewController = nil; host.makeKeyAndVisible() }
    }
    private func make(minimum: Int = 0, fault: DeliveryFault? = nil) async throws -> Fixture {
        let h = try await NativeSessionHarness.make(fault: fault)
        h.base.testClock.advance(0.001)
        var body = try JSONSerialization.jsonObject(with: h.base.config) as! [String: Any]
        var capabilities = body["capabilities"] as! [String: Any], replay = capabilities["replay"] as! [String: Any]
        replay["transports"] = [["codec": EluNativeReplayProtocol.v2.codec, "compression": "gzip"]]
        replay["replayProtocolGeneration"] = EluNativeReplayProtocol.v2.generation
        h.base.generation = EluNativeReplayProtocol.v2.generation
        capabilities["replay"] = replay; body["capabilities"] = capabilities
        var privacy = body["privacy"] as! [String: Any], policy = privacy["replay"] as! [String: Any]
        var masking = privacy["masking"] as! [String: Any]
        masking["text"] = "sensitive"; privacy["masking"] = masking
        policy["minimumDurationSeconds"] = minimum; privacy["replay"] = policy; body["privacy"] = privacy
        body["issuedAt"] = EluRFC3339.string(from: h.base.now)
        h.base.config = try JSONSerialization.data(withJSONObject: body); try await h.publish()
        let host = try EluUIKitTestHost.window()
        let window = host.windowScene.map { EluReplayWindow(windowScene: $0) } ?? EluReplayWindow(frame: host.bounds)
        window.frame = host.frame
        let controller = UIViewController(), root = UIView(frame: window.bounds)
        controller.view = root; window.rootViewController = controller; window.makeKeyAndVisible()
        window.layoutIfNeeded(); root.layoutIfNeeded(); CATransaction.flush()
        let authority = EluNativeReplayAuthority(queue: h.queue, clock: { h.base.now })
        let lifecycle = EluNativeReplayLifecycle(windowInventoryForTesting: EluUIKitTestHost.inventory(for: window))
        lifecycle.observeWithdrawal { authority.withdraw() }; lifecycle.attached(UUID())
        let selection = try XCTUnwrap(lifecycle.select(root: root, window: window))
        let prepared = try await authority.prepare(source: XCTUnwrap(h.base.witness), capabilities: .init(
            readbackProvenTransports: [EluNativeReplayProtocol.v2.transport],
            readbackProvenProtocolGenerations: [EluNativeReplayProtocol.v2.generation]), timeZoneIdentifier: "America/Los_Angeles")
        XCTAssertTrue(prepared.profile.allowsOrdinaryText)
        return Fixture(h: h, host: host, window: window, root: root, lifecycle: lifecycle,
            authority: authority, prepared: prepared, selection: selection)
    }
    private func start(_ f: Fixture) throws -> EluNativeReplayCaptureOwner {
        let base = f.h.base
        return EluNativeReplayCaptureOwner(queue: f.h.queue, authority: f.authority, prepared: f.prepared,
            selection: f.selection, versions: try .init(runtime: .init(name: "elu-ios", version: "0.1.0"),
                facade: .init(name: "elu-ios", version: "0.1.0")),
            wallClock: { base.now }, continuousNanoseconds: { base.testClock.ticks() })
    }
    private func observer(_ window: EluReplayWindow) -> EluUIKitReplayTouchObserver? {
        guard let value = Mirror(reflecting: window).children.first(where: { $0.label == "replayObserver" })?.value else { return nil }
        return Mirror(reflecting: value).children.first?.value as? EluUIKitReplayTouchObserver
    }
    private func fact(_ phase: EluUIKitReplayTouchFact.Phase, _ finger: NSObject, y: CGFloat = 50) -> EluUIKitReplayTouchFact {
        .init(phase: phase, identity: ObjectIdentifier(finger), location: CGPoint(x: 50, y: y),
            liveDirectTouches: phase == .ended ? 0 : 1, allTouchesLifted: phase == .ended)
    }
    private func wait(_ phase: String = "original capture condition", diagnostics: (() -> String)? = nil,
                      _ predicate: () async throws -> Bool) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < 6_000_000_000 {
            if try await predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000)
        }
        if let diagnostics { throw InteractionCaptureWaitFailure(phase: phase, diagnostics: diagnostics()) }
        throw EluNativeReplayCaptureError.settlementPending
    }
    private func decoded(_ request: EluV2ReplayPreparedRequest) throws -> [[String: Any]] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let chunk = try XCTUnwrap(object["chunk"] as? [String: Any])
        let data = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(chunk["payload"] as? String)))
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw EluNativeReplaySealingError.compression }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 65_536)
        let result = data.withUnsafeBytes { source in output.withUnsafeMutableBytes { destination in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress); stream.avail_in = uInt(source.count)
            stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = uInt(destination.count)
            return inflate(&stream, Z_FINISH)
        } }
        guard result == Z_STREAM_END else { throw EluNativeReplaySealingError.compression }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.prefix(Int(stream.total_out)))) as? [[String: Any]])
    }
}

private struct InteractionCaptureWaitFailure: Error, CustomStringConvertible {
    let phase: String
    let diagnostics: String?
    var description: String {
        "Timed out waiting for interaction fixture phase: \(phase)" + (diagnostics.map { ";" + $0 } ?? "")
    }
}
#endif
