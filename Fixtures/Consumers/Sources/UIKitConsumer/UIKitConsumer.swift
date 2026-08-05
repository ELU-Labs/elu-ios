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
        return true
    }

    public func applicationDidEnterBackground(_ application: UIApplication) {
        Elu.flush()
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
