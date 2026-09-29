#if canImport(UIKit)
import UIKit
import XCTest

/// Own a visible test window when the local Swift package runner has no scenes.
/// This uses the same legacy application-window path supported by the SDK.
@MainActor
enum EluUIKitTestHost {
    private static var retainedWindow: UIWindow?
    static func window() throws -> UIWindow {
        if let window = retainedWindow { return window }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        XCTAssertEqual(UIApplication.shared.applicationState, .active)
        retainedWindow = window
        return window
    }

    /// Failure-only public fixture facts. No view text, object descriptions,
    /// scene/session identifiers or application identifiers are included.
    static func readinessDiagnostics(window: UIWindow, controller: UIViewController) -> String {
        let application = UIApplication.shared
        let scenes = application.connectedScenes
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let windows: [UIWindow]
        let inventory: Int
        if active.count == 1, let scene = active.first as? UIWindowScene {
            windows = scene.windows; inventory = 1
        } else if active.isEmpty, scenes.isEmpty, application.applicationState == .active {
            windows = application.windows; inventory = 2
        } else { windows = []; inventory = 0 }
        let eligible = windows.filter { $0.isKeyWindow && !$0.isHidden && $0.alpha == 1 && $0.windowLevel == .normal }
        let root = controller.viewIfLoaded
        let bounds = root?.bounds ?? .zero
        let validViewport = bounds.width.isFinite && bounds.height.isFinite &&
            (1 ... 16_384).contains(bounds.width) && (1 ... 16_384).contains(bounds.height) &&
            bounds.width.rounded(.towardZero) == bounds.width && bounds.height.rounded(.towardZero) == bounds.height
        // Fixed field count and capped aggregate counts; inventories are not printed.
        let fields = [
            "applicationState=\(application.applicationState.rawValue)",
            "sceneCount=\(min(scenes.count, 256))", "activeSceneCount=\(min(active.count, 256))",
            "inventoryKind=\(inventory)", "windowCount=\(min(windows.count, 256))",
            "eligibleCount=\(min(eligible.count, 256))",
            "originalInInventory=\(windows.contains { $0 === window })",
            "originalEligible=\(eligible.contains { $0 === window })",
            "originalHasScene=\(window.windowScene != nil)",
            "originalSceneState=\(window.windowScene?.activationState.rawValue ?? -99)",
            "originalKey=\(window.isKeyWindow)", "originalHidden=\(window.isHidden)",
            "originalOpaque=\(window.alpha == 1)", "originalNormalLevel=\(window.windowLevel == .normal)",
            "controllerIsOriginal=\(window.rootViewController === controller)",
            "controllerPresented=\(controller.presentedViewController != nil)",
            "rootLoaded=\(root != nil)", "rootAttached=\(root?.window === window)",
            "rootHidden=\(root?.isHidden ?? true)", "rootOpaque=\(root?.alpha == 1)",
            "rootWidth=\(bounds.width)", "rootHeight=\(bounds.height)", "validViewport=\(validViewport)"
        ]
        return fields.joined(separator: ";")
    }

}
#endif
