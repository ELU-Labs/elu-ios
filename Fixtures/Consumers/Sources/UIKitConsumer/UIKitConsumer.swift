#if canImport(UIKit)
import EluAnalytics
import UIKit

public final class FixtureAppDelegate: NSObject, UIApplicationDelegate {
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Elu.setup(siteKey: "fixture-site-key")
        Elu.register(["fixture": "uikit"])
        let flags = EluFeatureFlagOptions(sendEvent: false, fresh: true)
        _ = Elu.getFeatureFlag("checkout", options: flags)
        _ = Elu.getFeatureFlagResult("checkout", options: flags)
        let _: Bool? = Elu.isFeatureEnabled("checkout", options: flags, defaultValue: false)
        return true
    }

    public func applicationDidEnterBackground(_ application: UIApplication) {
        Elu.flush()
    }
}

/// Replace the application's existing window construction with this choice;
/// this compile fixture does not create an additional displayed window.
@MainActor
public final class FixtureSceneDelegate: NSObject, UIWindowSceneDelegate {
    public var window: UIWindow?

    public func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = EluReplayWindow(windowScene: windowScene)
        window.rootViewController = FixtureCheckoutViewController()
        self.window = window
        window.makeKeyAndVisible()
    }

    /// Alternative for an app that already creates its window without scenes.
    /// Returning an unshown window keeps this separate from the scene example.
    public static func makeLegacyWindow() -> UIWindow {
        let window = EluReplayWindow(frame: UIScreen.main.bounds)
        window.rootViewController = FixtureCheckoutViewController()
        return window
    }
}

public final class FixtureCheckoutViewController: UIViewController {
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Elu.screen("Checkout", properties: ["fixture": true])
    }

    public func completeCheckout(userID: String) {
        Elu.identify(userID, userProperties: ["plan": "pro"])
        Elu.group("company", key: "fixture-company", properties: ["tier": "test"])
        Elu.capture("checkout completed", properties: ["source": "uikit"])
    }
}
#endif
