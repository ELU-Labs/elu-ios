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

    @MainActor private func activeWindow() throws -> UIWindow {
        try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap { $0.windows }.first { !$0.isHidden })
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
private final class NativeLifecycleSink: EluRuntimeLifecycleSink, @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var backgrounds: Int { lock.lock(); defer { lock.unlock() }; return count }
    func applicationForegrounded(at: Date, fromBackground: Bool) {}
    func applicationBackgrounded(at: Date) { lock.lock(); count += 1; lock.unlock() }
    func screenViewed(_ name: String, at: Date) {}
}
#endif
