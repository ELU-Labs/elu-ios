import Foundation

/// Options for `Elu.setup(siteKey:options:)`. Dev/staging only — production
/// apps use the plain `Elu.setup(siteKey:)`.
public struct EluSetupOptions {
    /// ELU config endpoint origin. Default: `https://elu.dev`.
    public var configHost: URL

    public init(configHost: URL = URL(string: "https://elu.dev")!) {
        self.configHost = configHost
    }
}

/// The ELU Analytics facade — the mobile analog of the web `window.elu`.
///
/// Every method is safe in every lifecycle state: before config arrives,
/// capture-class calls buffer in memory; when analytics is disabled (kill
/// switch, EU block) they are silent no-ops; while running they delegate to
/// the embedded provider. Nothing here throws or blocks the caller on
/// network. Customer code never touches the underlying provider directly.
public enum Elu {
    // MARK: - Setup

    /// Initialize ELU Analytics with your site key. Call once, as early as
    /// possible (e.g. `application(_:didFinishLaunchingWithOptions:)`).
    /// A second call is ignored.
    public static func setup(siteKey: String) {
        setup(siteKey: siteKey, options: EluSetupOptions())
    }

    /// Initialize with explicit options (dev/staging config host only).
    public static func setup(siteKey: String, options: EluSetupOptions) {
        EluCore.shared.setup(siteKey: siteKey, options: options)
    }

    // MARK: - Identity

    /// Link this device's activity to your user id. ELU never auto-identifies:
    /// call this after your own login/session restore, with your stable id.
    public static func identify(_ distinctId: String, userProperties: [String: Any]? = nil) {
        EluCore.shared.dispatch(.identify(distinctId: distinctId, userProperties: userProperties))
    }

    /// Clear identity and stored ids (call on logout).
    public static func reset() {
        EluCore.shared.reset()
    }

    public static func alias(_ alias: String) {
        EluCore.shared.dispatch(.alias(alias))
    }

    /// The current distinct id, or `nil` before initialization / when disabled.
    public static func distinctId() -> String? {
        EluCore.shared.distinctId()
    }

    public static func setPersonProperties(_ properties: [String: Any]) {
        EluCore.shared.dispatch(.setPersonProperties(properties))
    }

    // MARK: - Events

    public static func capture(_ event: String, properties: [String: Any]? = nil) {
        EluCore.shared.dispatch(.capture(event: event, properties: properties))
    }

    /// Record a screen view (`$screen`). UIKit view controllers are captured
    /// automatically; SwiftUI navigation needs manual calls — see README.
    public static func screen(_ name: String, properties: [String: Any]? = nil) {
        EluCore.shared.dispatch(.screen(name: name, properties: properties))
    }

    public static func captureException(_ error: Error, properties: [String: Any]? = nil) {
        EluCore.shared.dispatch(.captureException(error, properties: properties))
    }

    // MARK: - Super properties

    /// Attach properties to every subsequent event (persisted until
    /// `unregister` or `reset`).
    public static func register(_ properties: [String: Any]) {
        EluCore.shared.dispatch(.register(properties))
    }

    public static func unregister(_ key: String) {
        EluCore.shared.dispatch(.unregister(key))
    }

    // MARK: - Groups

    public static func group(_ type: String, key: String, properties: [String: Any]? = nil) {
        EluCore.shared.dispatch(.group(type: type, key: key, properties: properties))
    }

    // MARK: - Feature flags

    public static func getFeatureFlag(_ key: String) -> Any? {
        EluCore.shared.getFeatureFlag(key)
    }

    public static func getFeatureFlagPayload(_ key: String) -> Any? {
        EluCore.shared.getFeatureFlagPayload(key)
    }

    public static func isFeatureEnabled(_ key: String) -> Bool {
        EluCore.shared.isFeatureEnabled(key)
    }

    public static func reloadFeatureFlags(_ completion: (() -> Void)? = nil) {
        EluCore.shared.reloadFeatureFlags(completion)
    }

    /// Invoked (on the main queue) every time feature flags finish loading.
    public static func onFeatureFlagsLoaded(_ callback: @escaping () -> Void) {
        EluCore.shared.onFeatureFlagsLoaded(callback)
    }

    public static func setPersonPropertiesForFlags(_ properties: [String: Any]) {
        EluCore.shared.dispatch(.setPersonPropertiesForFlags(properties))
    }

    public static func setGroupPropertiesForFlags(_ type: String, properties: [String: Any]) {
        EluCore.shared.dispatch(.setGroupPropertiesForFlags(type: type, properties: properties))
    }

    // MARK: - Delivery

    /// Force-send queued events now (e.g. right before expected termination).
    public static func flush() {
        EluCore.shared.flush()
    }
}
