import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Identifies the scene a lifecycle signal describes. Signals that carry no
/// scene share the unidentified case, so a single-scene driver that leaves the
/// scene out still describes one scene rather than a new one every time.
enum EluSceneIdentity: Hashable, Sendable {
    case unidentified
    case scene(ObjectIdentifier)

    init(_ scene: AnyObject?) {
        guard let scene else {
            self = .unidentified
            return
        }
        self = .scene(ObjectIdentifier(scene))
    }
}

/// Turns application and scene activation into foreground, background, and
/// screen signals. Every entry point is serialized under one lock, so it may
/// be driven from notification handlers on any queue or from a test.
///
/// A foreground stretch is reported once. The system posts an activation for a
/// scene that is already in the foreground whenever it returns to active from
/// control center, the app switcher, a system alert, or an authentication
/// prompt, and none of those is a new foreground. A multi-window app also
/// activates its scenes one at a time. Transitions therefore follow which
/// scenes are currently active rather than how many activations arrived:
/// foreground is reported when the first scene becomes active and background
/// when the last one leaves.
///
/// The first scene signal marks the process as scene-driven. The scene signals
/// then own the transitions and the application-wide notifications are
/// ignored, because they describe the same boundary a second time.
final class EluApplicationLifecycleTracker: @unchecked Sendable {
    private let sink: any EluRuntimeLifecycleSink
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var isForeground = false
    private var everForegrounded = false
    private var activeSceneIdentities: Set<EluSceneIdentity> = []
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

    func sceneActivated(_ identity: EluSceneIdentity) {
        lock.lock()
        defer { lock.unlock() }
        sceneDriven = true
        let wasIdle = activeSceneIdentities.isEmpty
        activeSceneIdentities.insert(identity)
        guard wasIdle else { return }
        enterForeground()
    }

    func sceneBackgrounded(_ identity: EluSceneIdentity) {
        lock.lock()
        defer { lock.unlock() }
        sceneDriven = true
        activeSceneIdentities.remove(identity)
        guard activeSceneIdentities.isEmpty else { return }
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
        return activeSceneIdentities.count
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
            observe(UIApplication.didBecomeActiveNotification) { _ in
                tracker.applicationActivated()
            },
            observe(UIApplication.didEnterBackgroundNotification) { _ in
                tracker.applicationBackgrounded()
            },
            observe(UIScene.didActivateNotification) { identity in
                tracker.sceneActivated(identity)
            },
            observe(UIScene.didEnterBackgroundNotification) { identity in
                tracker.sceneBackgrounded(identity)
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

    /// Observes `name` and hands the handler the scene the notification is
    /// about. Scene notifications carry their scene, which is what tells a
    /// repeated activation of a scene already in the foreground apart from a
    /// second scene becoming active; application notifications carry no scene.
    private func observe(
        _ name: Notification.Name,
        _ handler: @escaping @Sendable (EluSceneIdentity) -> Void
    ) -> NSObjectProtocol {
        notificationCenter.addObserver(forName: name, object: nil, queue: nil) { notification in
            handler(EluSceneIdentity(notification.object as? UIScene))
        }
    }
}
#endif
