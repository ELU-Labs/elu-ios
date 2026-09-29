import Foundation
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import EluAnalytics

final class EluNativeReplayLifecycleTests: XCTestCase {
    func testWithdrawalListenerRunsOutsideLifecycleLockAndCanReenter() {
        let lifecycle = EluNativeReplayLifecycle(), calls = NativeLifecycleCalls()
        lifecycle.observeWithdrawal {
            calls.increment()
            lifecycle.observeWithdrawal(nil)
            lifecycle.withdraw()
        }
        lifecycle.attached(UUID())
        XCTAssertEqual(calls.count, 1)
    }

    func testOldAttachmentSignalsCannotAffectReplacementAndActivationDoesNotAuthorize() {
        let lifecycle = EluNativeReplayLifecycle(), calls = NativeLifecycleCalls()
        lifecycle.observeWithdrawal { calls.increment() }
        let old = UUID(), current = UUID()
        lifecycle.attached(old); lifecycle.attached(current)
        let initial = calls.count
        lifecycle.detached(old)
        lifecycle.receive(.applicationWillResign, attachment: old)
        lifecycle.receive(.didActivate, attachment: current)
        XCTAssertEqual(calls.count, initial)
        lifecycle.receive(.applicationWillResign, attachment: current)
        XCTAssertEqual(calls.count, initial + 1)
        lifecycle.close()
        let closed = calls.count
        lifecycle.attached(UUID()); lifecycle.receive(.didActivate, attachment: current)
        XCTAssertEqual(calls.count, closed)
    }

    func testClockSamplingAndFloorUpdateHaveOneOrder() async throws {
        let scope = EluNativeReplayScope(), now = Date(timeIntervalSince1970: 1_785_888_090)
        scope.publishSession(try EluSessionState(id: "session", startedAt: now, lastActivityAt: now,
            timeoutSeconds: 1_800, maximumDurationSeconds: 86_400))
        let token = scope.token(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let secondRead = DispatchSemaphore(value: 0), finished = expectation(description: "both samples")
        finished.expectedFulfillmentCount = 2
        DispatchQueue.global().async {
            let value = scope.sample(token, wall: {
                entered.signal(); _ = release.wait(timeout: .now() + 2); return now
            }, continuous: { 1 })
            XCTAssertNotNil(value); finished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            let value = scope.sample(token, wall: {
                secondRead.signal(); return now.addingTimeInterval(0.1)
            }, continuous: { 2 })
            XCTAssertNotNil(value); finished.fulfill()
        }
        XCTAssertEqual(secondRead.wait(timeout: .now() + 0.02), .timedOut)
        release.signal()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertTrue(scope.current(token))
    }

    func testClockDenialAndPendingIntentsCannotLeakAcrossRealSessionReplacement() throws {
        let scope = EluNativeReplayScope(), now = Date(timeIntervalSince1970: 1_785_888_090)
        scope.publishSession(try EluSessionState(id: "a", startedAt: now, lastActivityAt: now,
            timeoutSeconds: 1_800, maximumDurationSeconds: 86_400))
        let old = scope.token()
        XCTAssertNotNil(scope.sample(old, wall: { now }, continuous: { 2 }))
        XCTAssertNil(scope.sample(old, wall: { now }, continuous: { 1 }))
        XCTAssertFalse(scope.current(old))
        scope.publishSession(try EluSessionState(id: "b", startedAt: now.addingTimeInterval(1), lastActivityAt: now.addingTimeInterval(1),
            timeoutSeconds: 1_800, maximumDurationSeconds: 86_400))
        let next = scope.token(); XCTAssertTrue(scope.current(next)); XCTAssertFalse(scope.current(old))
        let pending = scope.beginIntent(); XCTAssertFalse(scope.current(next))
        scope.finish(pending); XCTAssertFalse(scope.current(next)); XCTAssertTrue(scope.current(scope.token()))
    }
    #if canImport(UIKit)
    @MainActor func testUIKitSelectedSceneWillDeactivateRevokesBeforeBackground() async throws {
        let lifecycle = EluNativeReplayLifecycle(), center = NotificationCenter(), sink = NativeLifecycleSink()
        let tracker = EluApplicationLifecycleTracker(sink: sink)
        let emitter = EluApplicationLifecycleEmitter(tracker: tracker, nativeLifecycle: lifecycle,
            notificationCenter: center, seedCurrentState: false)
        emitter.attach(); defer { emitter.detach() }
        let window = try activeWindow(), root = UIView(frame: window.bounds)
        window.addSubview(root); defer { root.removeFromSuperview() }
        let selection = try XCTUnwrap(lifecycle.select(root: root, window: window))
        center.post(name: UIScene.didActivateNotification, object: window.windowScene)
        XCTAssertTrue(selection.validateCurrent()); XCTAssertEqual(sink.backgrounds, 0)
        center.post(name: UIScene.willDeactivateNotification, object: window.windowScene)
        XCTAssertFalse(selection.isCurrent()); XCTAssertEqual(sink.backgrounds, 0)
        center.post(name: UIScene.didActivateNotification, object: window.windowScene)
        XCTAssertFalse(selection.isCurrent())
    }

    @MainActor func testUIKitApplicationResignAndDetachCallbacksCanReenterEmitter() async throws {
        let lifecycle = EluNativeReplayLifecycle(), center = NotificationCenter(), sink = NativeLifecycleSink()
        let emitter = EluApplicationLifecycleEmitter(tracker: .init(sink: sink), nativeLifecycle: lifecycle,
            notificationCenter: center, seedCurrentState: false)
        emitter.attach()
        let window = try activeWindow(), root = UIView(frame: window.bounds)
        window.addSubview(root); defer { root.removeFromSuperview() }
        let selection = try XCTUnwrap(lifecycle.select(root: root, window: window))
        lifecycle.observeWithdrawal { lifecycle.observeWithdrawal(nil); emitter.detach() }
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertFalse(selection.isCurrent()); XCTAssertEqual(sink.backgrounds, 0)
        emitter.attach(); XCTAssertFalse(selection.isCurrent()); emitter.detach()
    }

    @MainActor func testUIKitWeakSelectionDoesNotRetainRootAndVisibilityNeverReopensOldToken() async throws {
        let lifecycle = EluNativeReplayLifecycle(); lifecycle.attached(UUID())
        let window = try activeWindow()
        weak var weakRoot: UIView?
        var retained: EluNativeReplaySelection?
        autoreleasepool {
            let root = UIView(frame: window.bounds); weakRoot = root; window.addSubview(root)
            retained = lifecycle.select(root: root, window: window)
            XCTAssertTrue(retained?.validateCurrent() == true)
            root.isHidden = true; XCTAssertFalse(retained?.validateCurrent() == true)
            root.isHidden = false; lifecycle.withdraw()
            XCTAssertFalse(retained?.validateCurrent() == true)
            root.removeFromSuperview()
        }
        XCTAssertNil(weakRoot); XCTAssertFalse(retained?.isCurrent() == true)
    }

    @MainActor func testRootReadinessIsReadOnlyAcrossReplacementHiddenAndPresentedRoots() async throws {
        let attachment = UUID(), calls = NativeLifecycleCalls()
        let window = try activeWindow(), previous = window.rootViewController, first = UIViewController()
        let lifecycle = EluNativeReplayLifecycle(windowInventoryForTesting: EluUIKitTestHost.inventory(for: window))
        lifecycle.attached(attachment); lifecycle.observeWithdrawal { calls.increment() }
        first.view = UIView(frame: window.bounds); window.rootViewController = first
        defer { lifecycle.close(); window.rootViewController = previous }
        // Unlike explicit-root fixtures, discovery requires the sole key window
        // and its controller's actual attached view, after public UIKit layout.
        window.windowLevel = .normal; window.alpha = 1; window.makeKeyAndVisible()
        try await settleDiscoveredRoot(first, in: window, lifecycle: lifecycle, stage: "initial controller")
        let original = try XCTUnwrap(lifecycle.selectCurrentRoot(reusing: nil)), count = calls.count
        XCTAssertEqual(lifecycle.observeRootReadiness(), .available)
        XCTAssertTrue(original.validateCurrent()); XCTAssertEqual(calls.count, count)
        let next = UIViewController(); next.view = UIView(frame: window.bounds); window.rootViewController = next
        try await settleDiscoveredRoot(next, in: window, lifecycle: lifecycle, stage: "replacement controller")
        XCTAssertFalse(original.validateCurrent())
        for _ in 0..<3 { XCTAssertEqual(lifecycle.observeRootReadiness(), .available) }
        XCTAssertEqual(calls.count, count, "Observation must not select or revoke an original generation")
        next.view.isHidden = true; XCTAssertEqual(lifecycle.observeRootReadiness(), .waiting)
        next.view.isHidden = false
        let modal = UIViewController(); modal.view = UIView(frame: window.bounds)
        await withCheckedContinuation { continuation in next.present(modal, animated: false) { continuation.resume() } }
        XCTAssertEqual(lifecycle.observeRootReadiness(), .waiting)
        await withCheckedContinuation { continuation in next.dismiss(animated: false) { continuation.resume() } }
        XCTAssertEqual(lifecycle.observeRootReadiness(), .available)
        window.rootViewController = nil; XCTAssertEqual(lifecycle.observeRootReadiness(), .waiting)
        lifecycle.detached(attachment); XCTAssertEqual(lifecycle.observeRootReadiness(), .inactive)
    }

    @MainActor func testInjectedInventoryRejectsAbsentAndDuplicateWindowCandidates() throws {
        let window = try activeWindow(), previous = window.rootViewController
        let controller = UIViewController(); controller.view = UIView(frame: window.bounds)
        window.rootViewController = controller; window.windowLevel = .normal; window.alpha = 1
        window.makeKeyAndVisible(); window.layoutIfNeeded(); controller.view.layoutIfNeeded(); CATransaction.flush()
        defer { window.rootViewController = previous }
        let unavailable = EluNativeReplayLifecycle(windowInventoryForTesting: { nil })
        let empty = EluNativeReplayLifecycle(windowInventoryForTesting: { [] })
        let duplicate = EluNativeReplayLifecycle(windowInventoryForTesting: { [window, window] })
        let original = EluNativeReplayLifecycle(windowInventoryForTesting: EluUIKitTestHost.inventory(for: window))
        defer { [unavailable, empty, duplicate, original].forEach { $0.close() } }
        for lifecycle in [unavailable, empty, duplicate, original] { lifecycle.attached(UUID()) }
        XCTAssertEqual(original.observeRootReadiness(), .available)
        XCTAssertNotNil(original.selectCurrentRoot(reusing: nil))
        for lifecycle in [unavailable, empty, duplicate] {
            XCTAssertEqual(lifecycle.observeRootReadiness(), .waiting)
            XCTAssertNil(lifecycle.selectCurrentRoot(reusing: nil))
        }
    }

    @MainActor private func settleDiscoveredRoot(_ controller: UIViewController, in window: UIWindow,
                                                lifecycle: EluNativeReplayLifecycle, stage: String) async throws {
        window.setNeedsLayout(); window.layoutIfNeeded(); controller.view.layoutIfNeeded()
        CATransaction.flush()
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < 6_000_000_000 {
            if UIApplication.shared.applicationState == .active && window.isKeyWindow && !window.isHidden &&
                window.alpha == 1 && window.windowLevel == .normal && window.rootViewController === controller &&
                controller.viewIfLoaded?.window === window && lifecycle.observeRootReadiness() == .available {
                XCTAssertTrue(window.isKeyWindow); XCTAssertTrue(controller.viewIfLoaded?.window === window)
                XCTAssertEqual(UIApplication.shared.applicationState, .active)
                XCTAssertEqual(lifecycle.observeRootReadiness(), .available)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NativeLifecycleFixtureFailure(stage: stage,
            diagnostics: EluUIKitTestHost.readinessDiagnostics(window: window, controller: controller) +
                ";lifecycleReadiness=\(lifecycle.observeRootReadiness())")
    }

    @MainActor private func activeWindow() throws -> UIWindow {
        try EluUIKitTestHost.window()
    }
    #endif

}

private final class NativeLifecycleCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

#if canImport(UIKit)
private struct NativeLifecycleFixtureFailure: Error, CustomStringConvertible {
    let stage: String
    let diagnostics: String
    var description: String { "UIKit fixture did not discover its key window and attached root: \(stage);\(diagnostics)" }
}
private final class NativeLifecycleSink: EluRuntimeLifecycleSink, @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var backgrounds: Int { lock.lock(); defer { lock.unlock() }; return count }
    func applicationForegrounded(at: Date, fromBackground: Bool) {}
    func applicationBackgrounded(at: Date) { lock.lock(); count += 1; lock.unlock() }
    func screenViewed(_ name: String, at: Date) {}
}
#endif
