#if canImport(SwiftUI)
import EluAnalytics
import SwiftUI

public struct FixtureRootView: View {
    public init() {}

    public var body: some View {
        Text("Fixture")
            .onAppear {
                Elu.screen("Fixture Home", properties: ["source": "swiftui"])
            }
    }
}

public enum FixtureSwiftUIBootstrap {
    public static func configure() {
        Elu.setup(siteKey: "fixture-site-key")
        Elu.onFeatureFlagsLoaded {
            _ = Elu.isFeatureEnabled("fixture-flag")
        }
    }
}
#endif
