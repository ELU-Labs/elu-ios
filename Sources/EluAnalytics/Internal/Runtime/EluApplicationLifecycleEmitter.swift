import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Turns application and scene activation into foreground, background, and
/// screen signals. Every entry point is serialized under one lock, so it may
/// be driven from notification handlers on any queue or from a test.
///
/// A foreground stretch is reported once. The system posts an activation
/// again after a dismissed alert or control center, which is not a new
/// foreground, and a multi-window app activates one scene at a time; both are
/// folded into the single transition that actually crossed the boundary.
///
/// The first scene signal marks the process as scene-driven. Scene counting
/// then owns the transitions and the application-wide notifications are
/// ignored, because they describe the same boundary a second time.
final class EluApplicationLifecycleTracker: @unchecked Sendable {
    private let sink: any EluRuntimeLifecycleSink
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var isForeground = false
    private var everForegrounded = false
    private var activeSceneCount = 0
    private var sceneDriven = false

    init(
        sink: any EluRuntimeLifecycleSink,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sink = sink
        self.clock = clock
    }

    func applicationActivated() {
        lock.lock()
        defer { lock.unlock() }
        guard !sceneDriven else { return }
        enterForeground()
    }

    func applicationBackgrounded() {
        lock.lock()
        defer { lock.unlock() }
        guard !sceneDriven else { return }
        enterBackground()
    }

    func sceneActivated() {
        lock.lock()
        defer { lock.unlock() }
        sceneDriven = true
        activeSceneCount += 1
        guard activeSceneCount == 1 else { return }
        enterForeground()
    }

    func sceneBackgrounded() {
        lock.lock()
        defer { lock.unlock() }
        sceneDriven = true
        if activeSceneCount > 0 {
            activeSceneCount -= 1
        }
        guard activeSceneCount == 0 else { return }
        enterBackground()
    }

    func screenAppeared(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        sink.screenViewed(name, at: clock())
    }

    var isInForeground: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isForeground
    }

    var activeScenes: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeSceneCount
    }

    private func enterForeground() {
        guard !isForeground else { return }
        isForeground = true
        sink.applicationForegrounded(at: clock(), fromBackground: everForegrounded)
        everForegrounded = true
    }

    private func enterBackground() {
        guard isForeground else { return }
        isForeground = false
        sink.applicationBackgrounded(at: clock())
    }
}

#if canImport(UIKit)
/// Maps application and scene notifications onto an
/// `EluApplicationLifecycleTracker`. A scene-based app posts both families for
/// the same boundary, so the tracker decides which one counts. The screen name
/// is the view controller's class name, which needs no lookup and is stable
/// across launches. Nothing registers this emitter yet.
final class EluApplicationLifecycleEmitter: @unchecked Sendable {
    private let tracker: EluApplicationLifecycleTracker
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    init(
        tracker: EluApplicationLifecycleTracker,
        notificationCenter: NotificationCenter = .default
    ) {
        self.tracker = tracker
        self.notificationCenter = notificationCenter
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }

    func attach() {
        lock.lock()
        defer { lock.unlock() }
        guard observers.isEmpty else { return }
        let tracker = self.tracker
        observers = [
            observe(UIApplication.didBecomeActiveNotification) {
                tracker.applicationActivated()
            },
            observe(UIApplication.didEnterBackgroundNotification) {
                tracker.applicationBackgrounded()
            },
            observe(UIScene.didActivateNotification) {
                tracker.sceneActivated()
            },
            observe(UIScene.didEnterBackgroundNotification) {
                tracker.sceneBackgrounded()
            },
        ]
    }

    func detach() {
        lock.lock()
        defer { lock.unlock() }
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers = []
    }

    func viewControllerAppeared(_ viewController: UIViewController) {
        tracker.screenAppeared(Self.screenName(for: viewController))
    }

    static func screenName(for viewController: UIViewController) -> String {
        String(describing: type(of: viewController))
    }

    private func observe(
        _ name: Notification.Name,
        _ handler: @escaping @Sendable () -> Void
    ) -> NSObjectProtocol {
        notificationCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
            handler()
        }
    }
}
#endif
