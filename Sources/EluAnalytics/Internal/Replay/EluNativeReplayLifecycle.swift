import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum EluNativeReplayLifecycleSignal: Sendable {
    case applicationWillResign
    case sceneWillDeactivate(EluSceneIdentity)
    case didActivate
    case sceneDidBackground
    case timeZoneChanged
    case rootChanged
}

fileprivate final class EluNativeReplayWeakSelection: @unchecked Sendable {
    weak var root: AnyObject?
    weak var window: AnyObject?
    weak var scene: AnyObject?
    let hadScene: Bool
    init(root: AnyObject, window: AnyObject, scene: AnyObject?) {
        self.root = root; self.window = window; self.scene = scene; hadScene = scene != nil
    }
}

/// Only the main-actor UIKit selection method can create this witness. It never
/// owns the selected UIKit objects and does not grant source/privacy permission.
struct EluNativeReplaySelection: Sendable {
    fileprivate let owner: EluNativeReplayLifecycle
    fileprivate let token: UUID
    fileprivate let weakSelection: EluNativeReplayWeakSelection
    fileprivate var requiresDiscovery = false
    func isCurrent() -> Bool {
        owner.isCurrent(token) && weakSelection.root != nil && weakSelection.window != nil
            && (!weakSelection.hadScene || weakSelection.scene != nil)
    }
    #if canImport(UIKit)
    /// Borrows the original weak selection for one synchronous main-actor use.
    /// It never discovers a replacement root, window or scene.
    @MainActor func consumeRoot<Value>(_ operation: (UIView) throws -> Value) throws -> Value {
        guard validateCurrent(), let root = weakSelection.root as? UIView,
              let window = weakSelection.window as? UIWindow else {
            throw EluNativeReplayAuthorityError.stale
        }
        let value = try operation(root)
        guard weakSelection.root === root, weakSelection.window === window,
              validateCurrent() else { throw EluNativeReplayAuthorityError.stale }
        return value
    }
    #endif
    @MainActor func validateCurrent() -> Bool {
        #if canImport(UIKit)
        guard isCurrent(), let root = weakSelection.root as? UIView,
              let window = weakSelection.window as? UIWindow,
              root.window === window, !root.isHidden, root.alpha == 1,
              !window.isHidden, window.alpha == 1 else { return false }
        if requiresDiscovery {
            guard let current = owner.discoveredRoot(), current.0 === root, current.1 === window else { return false }
        }
        if weakSelection.hadScene {
            guard let scene = weakSelection.scene as? UIWindowScene,
                  window.windowScene === scene, scene.activationState == .foregroundActive else { return false }
        } else {
            guard window.windowScene == nil, UIApplication.shared.applicationState == .active else { return false }
        }
        return isCurrent()
        #else
        return false
        #endif
    }
}

/// Native-only lifecycle fence. It does not synthesize event foreground/background
/// activity, select an arbitrary active scene, or construct a collector.
final class EluNativeReplayLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var attachment: UUID?
    private var generation = UUID()
    private var selectedScene: EluSceneIdentity?
    private var closed = false
    private var listener: (@Sendable () -> Void)?
    private var reevaluate: (@Sendable () -> Void)?
    private var privacyChanged: (@Sendable () -> Void)?

    func observePrivacyChange(_ listener: (@Sendable () -> Void)?) {
        lock.lock(); privacyChanged = listener; lock.unlock()
    }
    func observeReevaluation(_ listener: (@Sendable () -> Void)?) {
        lock.lock(); reevaluate = listener; lock.unlock()
    }
    func observeWithdrawal(_ listener: (@Sendable () -> Void)?) {
        lock.lock(); self.listener = listener; lock.unlock()
    }
    func attached(_ token: UUID) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        attachment = token; selectedScene = nil; generation = UUID()
        let notify = listener; lock.unlock(); notify?()
    }
    func detached(_ token: UUID) {
        lock.lock()
        guard attachment == token else { lock.unlock(); return }
        attachment = nil; selectedScene = nil; generation = UUID()
        let notify = listener; lock.unlock(); notify?()
    }
    func receive(_ signal: EluNativeReplayLifecycleSignal, attachment token: UUID) {
        lock.lock()
        guard !closed, attachment == token else { lock.unlock(); return }
        switch signal {
        case .timeZoneChanged:
            let notify = privacyChanged; lock.unlock(); notify?(); return
        case .didActivate, .sceneDidBackground:
            let wake = reevaluate; lock.unlock(); wake?(); return // activation is never permission
        case .applicationWillResign, .rootChanged: break
        case let .sceneWillDeactivate(identity):
            guard selectedScene == identity else { lock.unlock(); return }
        }
        selectedScene = nil; generation = UUID()
        let notify = listener, wake = reevaluate; lock.unlock(); notify?(); wake?()
    }
    func withdraw() {
        lock.lock(); selectedScene = nil; generation = UUID()
        let notify = listener; lock.unlock(); notify?()
    }
    func close() {
        lock.lock(); closed = true; attachment = nil; selectedScene = nil; generation = UUID()
        let notify = listener; listener = nil; reevaluate = nil; privacyChanged = nil; lock.unlock(); notify?()
    }
    fileprivate func isCurrent(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && attachment != nil && selectedScene != nil && generation == token
    }
    #if canImport(UIKit)
    /// Main-only discovery never loads a view or chooses the first ambiguous window.
    @MainActor fileprivate func discoveredRoot() -> (UIView, UIWindow)? {
        let application = UIApplication.shared
        let scenes = application.connectedScenes.filter { $0.activationState == .foregroundActive }
        let windows: [UIWindow]
        if scenes.count == 1, let scene = scenes.first as? UIWindowScene { windows = scene.windows }
        else if scenes.isEmpty, application.connectedScenes.isEmpty, application.applicationState == .active {
            windows = application.windows
        } else { return nil }
        let eligible = windows.filter { $0.isKeyWindow && !$0.isHidden && $0.alpha == 1 && $0.windowLevel == .normal }
        guard eligible.count == 1, let window = eligible.first,
              let controller = window.rootViewController, controller.presentedViewController == nil,
              let root = controller.viewIfLoaded, root.window === window else { return nil }
        return (root, window)
    }
    @MainActor func selectCurrentRoot(reusing original: EluNativeReplaySelection?) -> EluNativeReplaySelection? {
        guard let (root, window) = discoveredRoot() else { return nil }
        if let original, original.requiresDiscovery, original.owner === self,
           original.weakSelection.root === root, original.weakSelection.window === window,
           original.validateCurrent() { return original }
        guard var selected = select(root: root, window: window) else { return nil }
        selected.requiresDiscovery = true
        return selected.validateCurrent() ? selected : nil
    }
    @MainActor func select(root: UIView, window: UIWindow) -> EluNativeReplaySelection? {
        guard root.window === window, !root.isHidden, root.alpha == 1,
              !window.isHidden, window.alpha == 1 else { return nil }
        let scene = window.windowScene
        if let scene { guard scene.activationState == .foregroundActive else { return nil } }
        else { guard UIApplication.shared.applicationState == .active else { return nil } }
        let objects = EluNativeReplayWeakSelection(root: root, window: window, scene: scene)
        lock.lock()
        guard !closed, attachment != nil else { lock.unlock(); return nil }
        generation = UUID(); selectedScene = EluSceneIdentity(scene)
        let token = generation, notify = listener
        lock.unlock(); notify?()
        let selection = EluNativeReplaySelection(owner: self, token: token, weakSelection: objects)
        return selection.validateCurrent() ? selection : nil
    }
    #endif
}
