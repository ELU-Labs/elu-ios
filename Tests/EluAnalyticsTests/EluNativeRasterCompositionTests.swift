#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import UIKit
import XCTest
@testable import EluAnalytics

/// These tests drive the original mounted UIKit window and original SDK owners.
/// The controlled clock isolates admission/cadence; it does not qualify the
/// production renderer's 50ms budget or automatic discovery of SwiftUI inputs.
@MainActor
final class EluNativeRasterCompositionTests: XCTestCase {
    func testExplicitOriginalStackFetchesV3AndDeliversActualCandidateThroughBoundAck() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        do {
            let composition = try await h.install()
            try await h.wait { await h.transport.bodies.count == 1 }
            await composition.waitForCurrentDelivery()
            let requests = await h.config.urls
            XCTAssertEqual(requests.map(\.path), ["/sdk/v3/elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa/config"])
            let sent = await h.transport.bodies, endpoints = await h.transport.urls
            let request = try EluNativeRasterStoredRequest(restoring: XCTUnwrap(sent.first))
            XCTAssertEqual(request.sequence, 0)
            XCTAssertEqual(request.time.floorUnixMilliseconds, try EluNativeReplayCaptureClock.milliseconds(h.clock.wall()))
            XCTAssertEqual(endpoints.map(\.absoluteString), ["https://ingest.elu.dev/v3/replay"])
            let rows = try await h.queue.storedReplayRecords(); XCTAssertTrue(rows.isEmpty)
            let accounting = try await h.queue.nativeReplaySessionState()
            XCTAssertNotNil(accounting.session?.firstStartAt)
            await h.close()
        } catch { await h.close(); throw error }
    }

    func testLostAckReopensOriginalQueueAndRetriesExactBytesWithoutNewCapture() async throws {
        let h = try await Rig.make(lostAck: true); defer { h.remove() }
        let original: Data
        do {
            let composition = try await h.install()
            try await h.wait { await h.transport.bodies.count == 1 }
            h.runtime.setNativeReplayRecordingEnabled(false)
            await composition.reevaluate(); await composition.waitForCurrentDelivery()
            let rows = try await h.queue.storedReplayRecords()
            XCTAssertEqual(rows.count, 1); original = try XCTUnwrap(rows.first?.body)
            let sent = await h.transport.bodies; XCTAssertEqual(sent, [original])
            await h.close()
        } catch { await h.close(); throw error }
        let reopened = try await Rig.make(directory: h.directory)
        do {
            reopened.runtime.setNativeReplayRecordingEnabled(false)
            reopened.clock.advance(2)
            let composition = try await reopened.install()
            await composition.waitForCurrentDelivery()
            let beforeRetry = await reopened.transport.bodies
            XCTAssertTrue(beforeRetry.isEmpty, "Reopen must first retain the original retry delay")
            reopened.clock.advance(1)
            await composition.reevaluate()
            try await reopened.wait { await reopened.transport.bodies.count == 1 }
            await composition.waitForCurrentDelivery()
            let sent = await reopened.transport.bodies; XCTAssertEqual(sent, [original])
            let rows = try await reopened.queue.storedReplayRecords(); XCTAssertTrue(rows.isEmpty)
            XCTAssertFalse(reopened.runtime.nativeReplayIsRecording())
            await reopened.close()
        } catch { await reopened.close(); throw error }
    }

    func testDefaultStackKeepsOneV2FetchAndRejectsRasterFactoryDespiteInstalledScope() async throws {
        let h = try await Rig.make(format: .v2, supported: false); defer { h.remove() }
        do {
            let requests = await h.config.urls
            XCTAssertEqual(requests.map(\.path), ["/sdk/v2/elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa/config"])
            do { _ = try await h.runtime.prepareNativeRaster(sourceIdentity: h.registry.sourceIdentity()); XCTFail("default acquired raster") }
            catch { XCTAssertEqual(error as? EluNativeReplayAuthorityError, .unavailable) }
            let calls = await h.transport.bodies; XCTAssertTrue(calls.isEmpty)
            await h.close()
        } catch { await h.close(); throw error }
    }

    func testNativeV3FailureDoesNotFetchV2FallbackOrGrantRaster() async throws {
        let h = try await Rig.make(response: Data("{}".utf8), expectConfig: false); defer { h.remove() }
        do {
            let requests = await h.config.urls
            XCTAssertEqual(requests.map(\.path), ["/sdk/v3/elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa/config"])
            do { _ = try await h.runtime.prepareNativeRaster(sourceIdentity: h.registry.sourceIdentity()); XCTFail("invalid source admitted") }
            catch { XCTAssertEqual(error as? EluNativeReplayAuthorityError, .unavailable) }
            let calls = await h.transport.bodies; XCTAssertTrue(calls.isEmpty)
            let phase = await h.runtime.currentPhase; XCTAssertEqual(phase, .closed)
            await h.close()
        } catch { await h.close(); throw error }
    }

    func testMinimumPreservesOriginalFirstAndCurrentWithoutIntermediateSequence() async throws {
        let h = try await Rig.make(minimum: 2); defer { h.remove() }
        do {
            let owner = try await h.direct()
            try await h.wait { owner.collectedFrameCountForTesting() == 1 }
            let beginning = try EluNativeReplayCaptureClock.milliseconds(h.clock.wall())
            var rows = try await h.queue.storedReplayRecords(); XCTAssertTrue(rows.isEmpty)
            h.clock.advance(1)
            try await h.wait { owner.collectedFrameCountForTesting() == 2 }
            rows = try await h.queue.storedReplayRecords(); XCTAssertTrue(rows.isEmpty, "minimum not reached")
            h.clock.advance(1)
            try await h.wait { owner.collectedFrameCountForTesting() == 3 }
            _ = await owner.stop()
            rows = try await h.queue.storedReplayRecords()
            XCTAssertEqual(rows.map(\.sequence), [0, 1])
            XCTAssertEqual(rows.map { $0.startedAt.floorUnixMilliseconds }, [beginning, beginning + 2_000])
            XCTAssertEqual(Set(rows.map(\.replayId)).count, 1)
            await h.close()
        } catch { await h.close(); throw error }
    }

    func testRequiredMarkerRemovalBeforeMinimumRevokesPreparedAndDropsBothSamples() async throws {
        let h = try await Rig.make(minimum: 2); defer { h.remove() }
        do {
            let owner = try await h.direct()
            try await h.wait { owner.collectedFrameCountForTesting() == 1 }
            let original = try h.registry.sourceIdentity()
            h.privateMarker.removeFromSuperview()
            XCTAssertFalse(original.isCurrent())
            h.clock.advance(2)
            _ = await owner.finished()
            let rows = try await h.queue.storedReplayRecords(); XCTAssertTrue(rows.isEmpty)
            XCTAssertFalse(owner.isRecording())
            await h.close()
        } catch { await h.close(); throw error }
    }

    func testSourceWithdrawalBeforeMinimumDropsHeldPrefixAndReleasesPhysicalSlot() async throws {
        let h = try await Rig.make(minimum: 2); defer { h.remove() }
        do {
            let owner = try await h.direct()
            try await h.wait { owner.collectedFrameCountForTesting() == 1 }
            h.stack.setForeground(false); await h.stack.settled()
            h.clock.advance(2)
            _ = await owner.finished()
            let rows = try await h.queue.storedReplayRecords(); XCTAssertTrue(rows.isEmpty)
            // No original raw frame may occupy the registry after the owner joins.
            let frame = try h.registry.capture(deadline: 100.05, clock: { 100 }, draw: { _, _, _ in true })
            frame.close()
            let enrollment = try await h.queue.enrollNativeReplayCapture()
            XCTAssertNotNil(enrollment)
            enrollment?.cancelUnused()
            if let enrollment { _ = try await h.queue.finishNativeReplayCapture(enrollment) }
            await h.close()
        } catch { await h.close(); throw error }
    }

    func testMissingDuplicateAndReparentedBindingsAreUnavailableWithoutNewSourceIdentity() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        do {
            let selected = try XCTUnwrap(h.lifecycle.selectCurrentRoot(reusing: nil))
            guard case let .bound(bound) = EluSwiftUIReplayRegistry.discover(in: selected) else { await h.close(); return XCTFail("initial root") }
            let source = bound.sourceIdentity
            let duplicate = EluSwiftUIReplayMarkerView(region: "private", registry: h.registry)
            duplicate.frame = h.privateMarker.frame; h.root.addSubview(duplicate)
            XCTAssertFalse(source.isCurrent())
            guard case .unavailable = EluSwiftUIReplayRegistry.discover(in: selected) else { await h.close(); return XCTFail("duplicate passed") }
            duplicate.removeFromSuperview()
            guard case let .bound(rebound) = EluSwiftUIReplayRegistry.discover(in: selected) else { await h.close(); return XCTFail("new binding") }
            XCTAssertFalse(rebound.sourceIdentity === source)
            let container = UIView(frame: h.root.bounds); h.root.addSubview(container)
            container.addSubview(h.privateMarker)
            XCTAssertFalse(rebound.isCurrent())
            h.privateMarker.removeFromSuperview()
            guard case .unavailable = EluSwiftUIReplayRegistry.discover(in: selected) else { await h.close(); return XCTFail("missing passed") }
            await h.close()
        } catch { await h.close(); throw error }
    }

    func testRemovedRootBeforeFirstCompositionStillRetainsRequiredScopeIntent() async throws {
        let h = try await Rig.make(wireframeV1: true); defer { h.remove() }
        do {
            h.marker.removeFromSuperview()
            let selected = try XCTUnwrap(h.lifecycle.selectCurrentRoot(reusing: nil))
            guard case .unavailable = EluSwiftUIReplayRegistry.discover(in: selected) else {
                await h.close(); return XCTFail("removed root was treated as undeclared")
            }
            let composition = try await h.install(); await composition.reevaluate()
            XCTAssertFalse(h.runtime.nativeReplayIsRecording())
            let rows = try await h.queue.storedReplayRecords(); XCTAssertTrue(rows.isEmpty)
            await h.close()
        } catch { await h.close(); throw error }
    }

    func testReleasedScopeRetainsWeakHostIntentBeforeFirstCompositionObservation() async throws {
        let h = try await Rig.make(wireframeV1: true); defer { h.remove() }
        do {
            var transient: EluSwiftUIReplayRegistry? = EluSwiftUIReplayRegistry(requiredRegions: [])
            weak var original = transient
            let marker = EluSwiftUIReplayMarkerView(region: nil, registry: try XCTUnwrap(transient))
            marker.frame = h.marker.frame; h.root.addSubview(marker)
            marker.removeFromSuperview(); transient = nil
            XCTAssertNil(original, "intent must not retain the registry")
            let selected = try XCTUnwrap(h.lifecycle.selectCurrentRoot(reusing: nil))
            guard case .unavailable = EluSwiftUIReplayRegistry.discover(in: selected) else {
                await h.close(); return XCTFail("released declaration disappeared from its live host")
            }
            let composition = try await h.install(); await composition.reevaluate()
            XCTAssertFalse(h.runtime.nativeReplayIsRecording())
            let rows = try await h.queue.storedReplayRecords(); XCTAssertTrue(rows.isEmpty)
            await h.close()
        } catch { await h.close(); throw error }
    }

    func testCompositionRetainsDeclaredIntentAfterRootMarkerRemovalAndDoesNotFallback() async throws {
        let h = try await Rig.make(minimum: 30, wireframeV1: true); defer { h.remove() }
        do {
            let composition = try await h.install()
            try await h.wait { h.runtime.nativeReplayIsRecording() }
            h.marker.removeFromSuperview()
            await composition.reevaluate()
            XCTAssertFalse(h.runtime.nativeReplayIsRecording())
            let rows = try await h.queue.storedReplayRecords(); XCTAssertTrue(rows.isEmpty)
            let calls = await h.transport.bodies; XCTAssertTrue(calls.isEmpty)
            // Same UIKit root, now absent declared marker: no automatic collector.
            h.clock.advance(1); await composition.reevaluate()
            XCTAssertFalse(h.runtime.nativeReplayIsRecording())
            await h.close()
        } catch { await h.close(); throw error }
    }

    func testExactEpochRefusalStopsOriginalCaptureAndDoesNotLoopNewEpoch() async throws {
        let h = try await Rig.make(refusal: true); defer { h.remove() }
        do {
            let composition = try await h.install()
            try await h.wait { await h.transport.bodies.count == 1 }
            await composition.waitForCurrentDelivery()
            h.clock.advance(1)
            try await h.wait { !(h.runtime.nativeReplayIsRecording()) }
            await composition.reevaluate()
            let rows = try await h.queue.storedReplayRecords()
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.sequence, 0)
            let first = try XCTUnwrap(rows.first?.replayId)
            for _ in 0..<3 { await composition.reevaluate() }
            let finalRows = try await h.queue.storedReplayRecords()
            XCTAssertEqual(finalRows.map(\.replayId), [first])
            let sends = await h.transport.bodies.count; XCTAssertEqual(sends, 1)
            XCTAssertFalse(h.runtime.nativeReplayIsRecording())
            await h.close()
        } catch { await h.close(); throw error }
    }

    func testViewportChangeRevokesOriginalIdentityButOrdinaryPrivateGeometryKeepsSource() async throws {
        let h = try await Rig.make(); defer { h.remove() }
        do {
            let selected = try XCTUnwrap(h.lifecycle.selectCurrentRoot(reusing: nil))
            guard case let .bound(original) = EluSwiftUIReplayRegistry.discover(in: selected) else { await h.close(); return XCTFail("root") }
            h.privateMarker.frame.origin.y += 1
            XCTAssertTrue(original.isCurrent(), "ordinary motion retains source, each frame is revalidated")
            try original.validate()
            h.marker.bounds.size.width -= 1
            XCTAssertFalse(original.isCurrent())
            guard case let .bound(next) = EluSwiftUIReplayRegistry.discover(in: selected) else { await h.close(); return XCTFail("new viewport") }
            XCTAssertFalse(next.sourceIdentity === original.sourceIdentity)
            await h.close()
        } catch { await h.close(); throw error }
    }

    @MainActor private final class Rig {
        let directory: URL
        let stack: EluStandaloneStack
        var runtime: EluStandaloneRuntime { stack.runtime }
        let queue: EluSQLiteRuntimeQueue
        let config: ConfigTransport
        let transport: RasterTransport
        let clock: Clock
        let window: UIWindow, previous: UIViewController?, root: UIView
        let registry = EluSwiftUIReplayRegistry(requiredRegions: ["private"])
        let marker: EluSwiftUIReplayMarkerView, privateMarker: EluSwiftUIReplayMarkerView
        let lifecycle: EluNativeReplayLifecycle
        private var directOwner: EluNativeReplayCaptureOwner?

        private init(directory: URL, stack: EluStandaloneStack, queue: EluSQLiteRuntimeQueue,
                     config: ConfigTransport, transport: RasterTransport, clock: Clock) throws {
            self.directory = directory; self.stack = stack; self.queue = queue
            self.config = config; self.transport = transport
            self.clock = clock
            window = try EluUIKitTestHost.window(); previous = window.rootViewController
            let controller = UIViewController(); controller.view = UIView(frame: window.bounds)
            root = controller.view; root.backgroundColor = .green; window.rootViewController = controller
            marker = EluSwiftUIReplayMarkerView(region: nil, registry: registry)
            privateMarker = EluSwiftUIReplayMarkerView(region: "private", registry: registry)
            marker.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            privateMarker.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
            root.addSubview(marker); root.addSubview(privateMarker)
            window.makeKeyAndVisible(); window.layoutIfNeeded(); CATransaction.flush()
            lifecycle = EluNativeReplayLifecycle(windowInventoryForTesting: EluUIKitTestHost.inventory(for: window))
            lifecycle.attached(UUID()); runtime.bindNativeLifecycle(lifecycle)
        }

        static func make(minimum: Int = 0, format: EluV2ConfigRequest.Format = .nativeV3,
                         supported: Bool = true, response: Data? = nil, expectConfig: Bool = true,
                         refusal: Bool = false, lostAck: Bool = false, wireframeV1: Bool = false,
                         directory originalDirectory: URL? = nil) async throws -> Rig {
            let directory = originalDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("elu-raster-composition-" + UUID().uuidString)
            let clock = Clock(), sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            var base = try JSONSerialization.jsonObject(with: Data(contentsOf: sourceRoot.appendingPathComponent("Conformance/V2/fixtures/config-enabled.json"))) as! [String: Any]
            var privacy = base["privacy"] as! [String: Any], replay = privacy["replay"] as! [String: Any]
            replay["sampleRate"] = 1; replay["minimumDurationSeconds"] = minimum
            privacy["replay"] = replay; base["privacy"] = privacy
            var wrapper = try nativeV3SourceRasterFixture(base: JSONSerialization.data(withJSONObject: base))
            if wireframeV1 {
                // Only the base tuple changes; the effective privacy material
                // remains exact. An accidental v1 fallback can really record a
                // plain UIWindow, so the no-fallback negative is discriminating.
                wrapper = Data(String(decoding: wrapper, as: UTF8.self)
                    .replacingOccurrences(of: "elu-native-wireframe-v2", with: "elu-native-wireframe-v1")
                    .replacingOccurrences(of: "protocol-generation-v2", with: "protocol-generation-v1").utf8)
            }
            let embedded = try EluNativeV3ConfigParser.parse(wrapper).configV2Data
            let config = ConfigTransport(response ?? (format == .v2 ? embedded : wrapper)), transport = RasterTransport(refusal: refusal, lostAck: lostAck)
            let stack = try await EluStandaloneStack.make(rootDirectoryURL: directory,
                siteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", configHost: URL(string: "https://elu.dev")!,
                configTransport: config, configurationFormat: format, declaredRegionReplaySupported: supported,
                eventTransport: Events(), flagTransport: Flags(), clock: clock.source, scheduler: Scheduler(),
                timeZoneIdentifier: { "America/Los_Angeles" })
            let h: Rig
            do {
                let queue = try XCTUnwrap(Mirror(reflecting: stack.runtime).children.first { $0.label == "queue" }?.value as? EluSQLiteRuntimeQueue)
                h = try Rig(directory: directory, stack: stack, queue: queue, config: config, transport: transport, clock: clock)
            } catch {
                stack.close(); await stack.settled()
                if originalDirectory == nil { try? FileManager.default.removeItem(at: directory) }
                throw error
            }
            do {
                stack.start(); stack.setForeground(true)
                try await h.wait { await config.urls.count == 1 }
                if expectConfig {
                    try await h.wait { await stack.runtime.currentPhase == .capturing }
                    await stack.settled()
                    guard case .accepted = await stack.runtime.capture("raster-session-start") else {
                        throw EluRuntimeQueueError.invalidState
                    }
                } else {
                    stack.close(); await stack.settled()
                }
                return h
            } catch {
                await h.close()
                if originalDirectory == nil { h.remove() }
                throw error
            }
        }

        func direct() async throws -> EluNativeReplayCaptureOwner {
            let selection = try XCTUnwrap(lifecycle.selectCurrentRoot(reusing: nil))
            guard case let .bound(binding) = EluSwiftUIReplayRegistry.discover(in: selection) else { throw EluRuntimeQueueError.invalidState }
            let prepared = try await runtime.prepareNativeRaster(sourceIdentity: binding.sourceIdentity)
            let value = await runtime.makeNativeRasterCapture(prepared: prepared, selection: selection, binding: binding, onCommitted: {})
            let owner = try XCTUnwrap(value); directOwner = owner
            return owner
        }
        func install() async throws -> EluNativeReplayComposition {
            let value = await runtime.installNativeReplayComposition(lifecycle: lifecycle,
                capabilities: EluStandaloneRuntime.readbackProvenReplayCapabilities, deferredUntilActivation: true, transport: transport)
            let composition = try XCTUnwrap(value)
            await runtime.activateNativeReplayComposition()
            return composition
        }
        func wait(_ predicate: () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if try await predicate() { return }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            throw WaitFailure.expired
        }
        func close() async {
            _ = await directOwner?.stop(); directOwner = nil
            lifecycle.close(); stack.close(); await stack.settled()
            marker.unbind(); privateMarker.unbind(); window.rootViewController = previous
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private enum WaitFailure: Error { case expired }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var elapsed: UInt64 = 0
        func wall() -> Date {
            lock.lock(); defer { lock.unlock() }
            return Date(timeIntervalSince1970: 1_785_888_090 + Double(elapsed) / 1_000_000_000)
        }
        func ticks() -> UInt64 {
            lock.lock(); defer { lock.unlock() }; return 1_000_000_000 + elapsed
        }
        func advance(_ seconds: UInt64) {
            lock.lock(); elapsed += seconds * 1_000_000_000; lock.unlock()
        }
        var source: EluV2ConfigClock {
            .init(wallNow: { self.wall() }, continuousNow: { self.ticks() }, floorTicks: { $0 }, floorNanoseconds: { $0 })
        }
    }
    private actor ConfigTransport: EluV2ConfigTransport {
        let data: Data
        private(set) var urls: [URL] = []
        init(_ data: Data) { self.data = data }
        func fetch(_ request: EluV2ConfigRequest) async throws -> Data { urls.append(request.url); return data }
    }
    private struct Scheduler: EluV2ConfigLifecycleScheduler {
        func schedule(afterNanoseconds: UInt64, action: @escaping @Sendable () async -> Void) -> any EluV2ConfigScheduledTask { Timer() }
    }
    private struct Timer: EluV2ConfigScheduledTask { func cancel() {} }
    private struct Events: EluV1AuthorizedBatchTransport {
        func send(_ request: EluV1BatchHTTPRequest) async throws -> EluV1BatchHTTPResponse { throw CancellationError() }
        func send(_ request: EluV1BatchHTTPRequest, authority: EluV1TransportAuthority) async throws -> EluV1BatchHTTPResponse { throw CancellationError() }
    }
    private struct Flags: EluV1AuthorizedFlagTransport {
        func send(endpoint: URL, requestBody: Data) async throws -> Data { throw CancellationError() }
        func send(endpoint: URL, requestBody: Data, authority: EluV1TransportAuthority) async throws -> Data { throw CancellationError() }
    }
    private actor RasterTransport: EluV2ReplayHTTPTransport {
        let refusal: Bool, lostAck: Bool
        private(set) var bodies: [Data] = [], urls: [URL] = []
        init(refusal: Bool, lostAck: Bool) { self.refusal = refusal; self.lostAck = lostAck }
        func send(_ dispatch: EluV2ReplayDispatch) async throws -> EluV1BatchHTTPResponse {
            guard let use = dispatch.takePhysicalUse() else { throw EluV1BoundTransportError.occupied }
            defer { use.settle() }
            guard await use.revalidate(), use.beginOnce() else { throw EluV1BoundTransportError.staleAuthority }
            let request = try EluNativeRasterStoredRequest(restoring: use.request.body)
            bodies.append(use.request.body); urls.append(use.request.url)
            // A missing network response uses retry/backoff. Cancellation only
            // releases a claim and permits a later lawful trigger immediately.
            if lostAck { throw URLError(.networkConnectionLost) }
            if refusal {
                return .init(status: 413, headers: [:], body: try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 1, "requestId": request.requestId, "status": 413,
                    "code": "payload-too-large", "disposition": "retry-after-reduction", "message": "fixture"]))
            }
            let body = try JSONSerialization.data(withJSONObject: ["schemaVersion": 3, "requestId": request.requestId,
                "replayId": request.replayId, "chunkId": request.chunkId, "result": "accepted", "sequence": request.sequence])
            return .init(status: 200, headers: [:], body: body)
        }
    }
}
#endif
