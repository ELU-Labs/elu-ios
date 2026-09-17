import Foundation
import XCTest
#if canImport(UIKit)
import UIKit
@testable import EluAnalytics

/// Private simulator fixture. Its gates use existing queue clock/fault inputs;
/// no synchronization hook is added to shipping authority or selection code.
final class EluNativeReplayMixedStartUIKitTests: XCTestCase {
    @MainActor func testUIKitMixedPhysicalAndLegacyStartKeepsOriginalPhysicalUse() async throws {
        let fault = DeliveryFault()
        let h = try await NativeSessionHarness.make(fault: fault)
        defer { h.base.remove() }
        let gate = NativeMixedStartGate()
        await h.queue.close()
        let clock = h.base.testClock
        h.base.queue = try await EluSQLiteRuntimeQueue.openCaptureRuntime(rootDirectoryURL: h.base.root,
            exactConstructorSiteKey: "elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa", limits: h.base.limits,
            clock: { gate.clockRead(); return clock.read() }, continuousClock: { clock.ticks() },
            continuousBudgetConverter: { $0 }, nativeContinuousNanoseconds: { $0 },
            configurationGate: h.base.gate, faultInjector: fault)
        h.base.testClock.advance(0.001)
        var config = try XCTUnwrap(JSONSerialization.jsonObject(with: h.base.config) as? [String: Any])
        var capabilities = config["capabilities"] as! [String: Any], replay = capabilities["replay"] as! [String: Any]
        replay["transports"] = [["codec": "elu-native-wireframe-v1", "compression": "gzip"]]
        capabilities["replay"] = replay; config["capabilities"] = capabilities
        config["issuedAt"] = EluRFC3339.string(from: h.base.now)
        h.base.config = try JSONSerialization.data(withJSONObject: config)
        try await h.publish()
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap { $0.windows }.first { !$0.isHidden })
        let root = NativeMixedStartRoot(frame: window.bounds)
        window.addSubview(root); root.layoutIfNeeded(); window.layoutIfNeeded()
        defer { gate.releaseAll(); root.removeFromSuperview() }
        let lifecycle = EluNativeReplayLifecycle(); lifecycle.attached(UUID())
        let selection = try XCTUnwrap(lifecycle.select(root: root, window: window))
        let authority = EluNativeReplayAuthority(queue: h.queue, clock: { clock.read() })
        let pair = try XCTUnwrap(EluV1ReplayTransportSelection(codec: "elu-native-wireframe-v1", compression: .gzip))
        let prepared = try await authority.prepare(source: XCTUnwrap(h.base.witness),
            capabilities: .init(readbackProvenTransports: [pair], readbackProvenProtocolGenerations: [h.base.generation]),
            timeZoneIdentifier: "America/Los_Angeles")
        let pending = try await h.queue.enrollNativeReplayCapture(), enrollment = try XCTUnwrap(pending)
        let use = try XCTUnwrap(enrollment.takePhysicalUse())
        fault.action = { if $0 == .afterBegin { gate.beginObserved() } }
        root.gate = gate
        gate.arm()
        let physical = Task.detached { try await authority.start(prepared, selection: selection, physicalUse: use) }
        let legacy = Task.detached { () async throws -> EluNativeReplayPermit? in
            guard gate.waitForFirstGetter() else { throw NativeMixedStartFailure.timeout }
            return try await authority.start(prepared, selection: selection)
        }
        do {
            let result = try await physical.value
            let other = try await legacy.value
            gate.releaseAll(); fault.action = nil
            // These prove the overlap actually happened. A skipped phase or
            // expired semaphore is a fixture failure, never a passing race test.
            XCTAssertTrue(gate.observedExactOverlap)
            let permit = try XCTUnwrap(result)
            XCTAssertNil(other)
            let admission = try await authority.captureAdmission(for: permit, physicalUse: use)
            XCTAssertTrue(admission.isCurrent())
            use.settle()
            let stopped = try await authority.stop(); XCTAssertEqual(stopped, .settled)
            let finished = try await h.queue.finishNativeReplayCapture(enrollment); XCTAssertEqual(finished, .settled)
            await authority.close(); await h.queue.close()
        } catch {
            gate.releaseAll(); fault.action = nil
            _ = try? await physical.value; _ = try? await legacy.value
            use.settle()
            _ = try? await authority.stop()
            let finished = try? await h.queue.finishNativeReplayCapture(enrollment)
            if finished != .settled { enrollment.quarantine() }
            await authority.close(); await h.queue.close()
            throw error
        }
    }
}

private enum NativeMixedStartFailure: Error { case timeout }
private final class NativeMixedStartRoot: UIView {
    var gate: NativeMixedStartGate?
    override var isHidden: Bool {
        get { gate?.hiddenRead(); return super.isHidden }
        set { super.isHidden = newValue }
    }
}

private final class NativeMixedStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private let firstEntered = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let releaseSecond = DispatchSemaphore(value: 0)
    private var armed = false
    private var sawInitialClock = false
    private var getterCount = 0
    private var sawLegacyClock = false
    private var sawBegin = false
    private var timedOut = false
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func clockRead() {
        lock.lock()
        guard armed else { lock.unlock(); return }
        if !sawInitialClock { sawInitialClock = true; lock.unlock(); return }
        let release = getterCount == 1 && !sawLegacyClock
        if release { sawLegacyClock = true }
        lock.unlock()
        if release { releaseFirst.signal() }
    }
    func hiddenRead() {
        lock.lock()
        guard armed, sawInitialClock, getterCount < 2 else { lock.unlock(); return }
        getterCount += 1; let index = getterCount
        lock.unlock()
        if index == 1 { firstEntered.signal() }
        let semaphore = index == 1 ? releaseFirst : releaseSecond
        if semaphore.wait(timeout: .now() + 5) != .success {
            lock.lock(); timedOut = true; lock.unlock()
        }
    }
    func waitForFirstGetter() -> Bool {
        let success = firstEntered.wait(timeout: .now() + 5) == .success
        if !success { lock.lock(); timedOut = true; lock.unlock(); releaseAll() }
        return success
    }
    func beginObserved() {
        lock.lock()
        let release = armed && getterCount >= 1 && sawLegacyClock && !sawBegin
        if release { sawBegin = true }
        lock.unlock()
        if release { releaseSecond.signal() }
    }
    var observedExactOverlap: Bool {
        lock.lock(); defer { lock.unlock() }
        return armed && sawInitialClock && getterCount == 2 && sawLegacyClock && sawBegin && !timedOut
    }
    func releaseAll() { releaseFirst.signal(); releaseSecond.signal(); firstEntered.signal() }
}
#endif
