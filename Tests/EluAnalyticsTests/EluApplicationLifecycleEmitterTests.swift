import Foundation
import XCTest
@testable import EluAnalytics
#if canImport(UIKit)
import UIKit
#endif

final class EluApplicationLifecycleEmitterTests: XCTestCase {
    func testFirstActivationForegroundsAndTheNextBackgroundRoundTripIsReported() {
        let sink = RecordingLifecycleSink()
        let clock = SteppingClock()
        let tracker = EluApplicationLifecycleTracker(sink: sink, clock: { clock.next() })

        tracker.applicationActivated()
        tracker.screenAppeared("HomeViewController")
        tracker.applicationBackgrounded()
        tracker.applicationActivated()
        tracker.screenAppeared("HomeViewController")

        XCTAssertEqual(
            sink.events,
            [
                "foreground:false@2026-08-04T00:00:00.000Z",
                "screen:HomeViewController@2026-08-04T00:00:01.000Z",
                "background@2026-08-04T00:00:02.000Z",
                "foreground:true@2026-08-04T00:00:03.000Z",
                "screen:HomeViewController@2026-08-04T00:00:04.000Z",
            ]
        )
        XCTAssertTrue(tracker.isInForeground)
    }

    func testRepeatedActivationsAndUnbalancedBackgroundsAreFolded() {
        let sink = RecordingLifecycleSink()
        let tracker = EluApplicationLifecycleTracker(sink: sink, clock: { SteppingClock().next() })

        tracker.applicationBackgrounded()
        tracker.applicationActivated()
        tracker.applicationActivated()
        tracker.applicationBackgrounded()
        tracker.applicationBackgrounded()

        XCTAssertEqual(
            sink.events,
            [
                "foreground:false@2026-08-04T00:00:00.000Z",
                "background@2026-08-04T00:00:00.000Z",
            ]
        )
        XCTAssertFalse(tracker.isInForeground)
    }

    func testSceneActivationsFoldIntoOneForegroundAndBackgroundPair() {
        let sink = RecordingLifecycleSink()
        let clock = SteppingClock()
        let tracker = EluApplicationLifecycleTracker(sink: sink, clock: { clock.next() })

        tracker.sceneActivated()
        tracker.sceneActivated()
        tracker.screenAppeared("CartViewController")
        tracker.sceneBackgrounded()
        tracker.sceneBackgrounded()
        tracker.sceneActivated()

        XCTAssertEqual(
            sink.events,
            [
                "foreground:false@2026-08-04T00:00:00.000Z",
                "screen:CartViewController@2026-08-04T00:00:01.000Z",
                "background@2026-08-04T00:00:02.000Z",
                "foreground:true@2026-08-04T00:00:03.000Z",
            ]
        )
        XCTAssertEqual(tracker.activeScenes, 1)
        XCTAssertTrue(tracker.isInForeground)
    }

    func testTheFirstSceneSignalRetiresTheApplicationWideSignals() {
        let sink = RecordingLifecycleSink()
        let clock = SteppingClock()
        let tracker = EluApplicationLifecycleTracker(sink: sink, clock: { clock.next() })

        tracker.applicationActivated()
        tracker.sceneActivated()
        tracker.applicationBackgrounded()
        tracker.applicationActivated()
        tracker.sceneBackgrounded()

        XCTAssertEqual(
            sink.events,
            [
                "foreground:false@2026-08-04T00:00:00.000Z",
                "background@2026-08-04T00:00:01.000Z",
            ]
        )
        XCTAssertEqual(tracker.activeScenes, 0)
        XCTAssertFalse(tracker.isInForeground)
    }

    #if canImport(UIKit)
    @MainActor
    func testApplicationNotificationsDriveTheTrackerUntilDetached() {
        let sink = RecordingLifecycleSink()
        let clock = SteppingClock()
        let center = NotificationCenter()
        let emitter = EluApplicationLifecycleEmitter(
            tracker: EluApplicationLifecycleTracker(sink: sink, clock: { clock.next() }),
            notificationCenter: center
        )

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(sink.events.isEmpty)

        emitter.attach()
        emitter.attach()
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        emitter.viewControllerAppeared(CheckoutViewController())
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(
            sink.events,
            [
                "foreground:false@2026-08-04T00:00:00.000Z",
                "screen:CheckoutViewController@2026-08-04T00:00:01.000Z",
                "background@2026-08-04T00:00:02.000Z",
            ]
        )

        emitter.detach()
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(sink.events.count, 3)
        XCTAssertEqual(
            EluApplicationLifecycleEmitter.screenName(for: UIViewController()),
            "UIViewController"
        )
    }

    @MainActor
    func testSceneNotificationsOutrankApplicationNotifications() {
        let sink = RecordingLifecycleSink()
        let clock = SteppingClock()
        let center = NotificationCenter()
        let emitter = EluApplicationLifecycleEmitter(
            tracker: EluApplicationLifecycleTracker(sink: sink, clock: { clock.next() }),
            notificationCenter: center
        )
        emitter.attach()

        center.post(name: UIScene.didActivateNotification, object: nil)
        center.post(name: UIScene.didActivateNotification, object: nil)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.post(name: UIScene.didEnterBackgroundNotification, object: nil)
        center.post(name: UIScene.didEnterBackgroundNotification, object: nil)

        XCTAssertEqual(
            sink.events,
            [
                "foreground:false@2026-08-04T00:00:00.000Z",
                "background@2026-08-04T00:00:01.000Z",
            ]
        )
        emitter.detach()
    }
    #endif
}

#if canImport(UIKit)
private final class CheckoutViewController: UIViewController {}
#endif

private final class RecordingLifecycleSink: EluRuntimeLifecycleSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func applicationForegrounded(at occurredAt: Date, fromBackground: Bool) {
        append("foreground:\(fromBackground)@\(EluRFC3339.string(from: occurredAt))")
    }

    func applicationBackgrounded(at occurredAt: Date) {
        append("background@\(EluRFC3339.string(from: occurredAt))")
    }

    func screenViewed(_ name: String, at occurredAt: Date) {
        append("screen:\(name)@\(EluRFC3339.string(from: occurredAt))")
    }

    private func append(_ event: String) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }
}

private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_785_801_600)

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let value = current
        current = current.addingTimeInterval(1)
        return value
    }
}
