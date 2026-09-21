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
}
#endif
