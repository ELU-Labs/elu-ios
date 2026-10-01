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

    /// Alternative to configure(), selected before the first setup call.
    /// This local option still requires the original server's declared-region grant.
    public static func configureDeclaredRegions() {
        var options = EluSetupOptions()
        options.declaredRegionReplayEnabled = true
        Elu.setup(siteKey: "fixture-site-key", options: options)
    }
}

/// iOS 14+ is required by StateObject and TextEditor, not by the SDK's base API.
@available(iOS 14.0, *)
@MainActor
public struct FixtureDeclaredRootView: View {
    @StateObject private var replay = EluSwiftUIReplayScope(requiredRegions: ["inputs", "private-card"])
    @State private var name = ""
    @State private var password = ""
    @State private var notes = ""

    public init() {}

    public var body: some View {
        VStack {
            Text("Public fixture content")
            VStack {
                TextField("Name", text: $name)
                SecureField("Password", text: $password)
                TextEditor(text: $notes).frame(height: 80)
            }
            .eluMask(replay, region: "inputs")
            Text("Private fixture card")
                .eluBlock(replay, region: "private-card")
        }
        .eluReplayRoot(replay)
        .onAppear { Elu.screen("Declared Fixture") }
    }
}
#endif
