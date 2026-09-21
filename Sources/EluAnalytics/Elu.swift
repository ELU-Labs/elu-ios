import Foundation

/// Options for `Elu.setup(siteKey:options:)`. Production uses the default host.
public struct EluSetupOptions {
    /// ELU config endpoint origin. Default: `https://elu.dev`.
    public var configHost: URL
    /// Native performance collection is disabled unless explicitly enabled.
    public var performance = EluPerformanceOptions()

    /// Internal construction marker for the owned runtime. Customer code
    /// cannot select or construct another backend.
    var runtimeSelection: EluRuntimeSelection = .standalone

    public init(configHost: URL = URL(string: "https://elu.dev")!) {
        self.configHost = configHost
    }

    public init(configHost: URL = URL(string: "https://elu.dev")!, performance: EluPerformanceOptions) {
        self.configHost = configHost; self.performance = performance
    }
}

/// The ELU Analytics facade — the mobile analog of the web `window.elu`.
///
/// Every method is safe in every lifecycle state: before config arrives,
/// capture-class calls buffer in memory; when analytics is disabled (kill
/// switch, EU block) they are silent no-ops; while running they delegate to
/// the ELU-owned runtime. Nothing here throws or blocks the caller on
/// network. Customer code never touches the underlying provider directly.
public enum Elu {
    // MARK: - Setup

    /// Initialize ELU Analytics with your site key. Call once, as early as
    /// possible (e.g. `application(_:didFinishLaunchingWithOptions:)`).
    /// A second call is ignored.
    public static func setup(siteKey: String) {
        setup(siteKey: siteKey, options: EluSetupOptions())
    }

    /// Initialize with explicit options. Alternate config hosts are for development only.
    public static func setup(siteKey: String, options: EluSetupOptions) {
        EluCore.shared.setup(siteKey: siteKey, options: options)
    }

    // MARK: - Identity

    /// Link this device's activity to your user id. ELU never auto-identifies:
    /// call this after your own login/session restore, with your stable id.
    public static func identify(_ distinctId: String, userProperties: [String: Any]? = nil) {
        EluCore.shared.dispatch(.identify(distinctId: distinctId, userProperties: userProperties))
    }

    public static func identify(_ distinctId: String, userProperties: [String: Any]?, userPropertiesOnce: [String: Any]) {
        EluCore.shared.dispatch(.identify(distinctId: distinctId, userProperties: userProperties, userPropertiesOnce: userPropertiesOnce))
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

    public static func setPersonProperties(_ properties: [String: Any], propertiesOnce: [String: Any]) {
        EluCore.shared.dispatch(.setPersonProperties(properties, propertiesOnce: propertiesOnce))
    }

    public static func getGroups() -> [String: String] { EluCore.shared.getGroups() }
    public static func resetGroups() { EluCore.shared.dispatch(.resetGroups) }
    public static func resetPersonPropertiesForFlags() { EluCore.shared.dispatch(.resetPersonPropertiesForFlags) }
    public static func resetGroupPropertiesForFlags(_ type: String? = nil) {
        EluCore.shared.dispatch(.resetGroupPropertiesForFlags(type))
    }

    // MARK: - Events

    public static func capture(_ event: String, properties: [String: Any]? = nil) {
        EluCore.shared.dispatch(.capture(event: event, properties: properties))
    }

    /// Record a logical screen view. Call explicitly from UIKit and SwiftUI
    /// when the application presents a screen — see README.
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

    /// Set each super property only when absent, or equal to `defaultValue`.
    /// Explicit null values count as present unless `defaultValue` is `NSNull()`.
    public static func registerOnce(_ properties: [String: Any], defaultValue: Any? = "None") {
        EluCore.shared.dispatch(.registerOnce(properties, defaultValue: defaultValue))
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

    /// Read one identity-bound flag snapshot, including its variant and payload.
    /// Returns nil while unavailable or when the key is absent.
    public static func getFeatureFlagResult(_ key: String) -> EluFeatureFlagResult? {
        EluCore.shared.getFeatureFlagResult(key)
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

    // MARK: - Consent

    /// Persistently stop capture, replay, and delivery for this installation.
    /// Calls made while opted out are not backfilled when consent is restored.
    public static func optOut() { EluCore.shared.setConsent(optedOut: true) }

    /// Restore capture when current remote privacy policy also permits it.
    /// Pass nil to suppress the optional opt-in event.
    public static func optIn(captureEventName: String? = "$opt_in", properties: [String: Any]? = nil) {
        EluCore.shared.setConsent(optedOut: false, event: captureEventName, properties: properties)
    }

    public static func isOptedOut() -> Bool { EluCore.shared.isOptedOut() }

    // MARK: - Delivery

    /// Request a delivery attempt for queued events. This does not wait for a
    /// server acknowledgment or guarantee delivery before process termination.
    /// Unacknowledged durable events are retried on a later eligible launch.
    public static func flush() {
        EluCore.shared.flush()
    }
}
