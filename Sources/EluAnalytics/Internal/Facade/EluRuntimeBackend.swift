import Foundation

/// The single runtime construction path behind the facade. Kept internal so
/// test fixtures can observe ordered initialization.
enum EluRuntimeSelection: Equatable, Sendable {
    case standalone
}

/// Why a facade call the selected runtime received was discarded. Counted
/// rather than surfaced: the facade never throws and never reports failure to
/// the caller. Calls the pre-config buffer discarded at its cap are counted by
/// the buffer itself, before any runtime sees them.
enum EluFacadeDropReason: String, Equatable, Sendable {
    /// The call could not be projected onto the runtime's value domain.
    case invalidInput
    /// A property name the runtime derives was removed from a call.
    case reservedProperty
    /// The runtime declined the call: no authority, opted out, or blocked.
    case unauthorized
    /// The runtime accepted no record because its store could not take one.
    case storage
    /// The site-scoped capture bucket declined this attempt.
    case rateLimited
    /// Customer filtering dropped or refused this event. No payload is logged.
    case filtered
    /// The oldest call held for a foreground configuration re-fetch, at its cap.
    case bufferFull
}

/// Controls the original native collector. Local preference never supplies
/// replay authority, and status reports physical collection, not desired state.
protocol EluReplayControl: AnyObject {
    func currentSessionId() -> String?
    func replayIsActive() -> Bool
    func startReplay()
    func stopReplay()
}

/// The live analytics runtime behind the `Elu` facade.
///
/// `EluCore` owns the lifecycle state machine and drives exactly one backend.
/// Every method here is called on `EluCore`'s serial queue and must not block
/// it: ordered work is handed to the backend and performed in call order, and
/// the getters answer from state the backend keeps in memory.
protocol EluRuntimeBackend: AnyObject {
    var selection: EluRuntimeSelection { get }
    var replayControl: (any EluReplayControl)? { get }
    /// True once a flag snapshot has been published for the running identity.
    var flagsAreLoaded: Bool { get }
    /// Captures the original projection for a callback that may run later.
    func flagNotificationPredicate() -> (@Sendable () -> Bool)?
    func featureFlagPublication() -> EluFeatureFlagPublication?
    /// Synchronous intent before the core queue hop. Completion transfers
    /// protection to execute's own ordered work, or releases a discarded call.
    func beginPendingOperation(_ op: EluBufferedOp) -> (() -> Void)?
    func beginNetworkObservation(_ request: URLRequest) -> EluNetworkObservation?

    /// Performs one facade operation. Operations reach the runtime in the
    /// order they are handed over, including operations replayed from the
    /// pre-config buffer.
    func execute(_ op: EluBufferedOp)

    /// Performs one facade operation with what the facade knew when the app
    /// made the call.
    func execute(_ op: EluBufferedOp, origin: EluCallOrigin)

    /// The time of a call the app makes now, on the runtime's wall clock.
    func callTime() -> Date

    /// Called once the pre-config buffer has been replayed. The buffered
    /// calls carry the identity, groups, and flag context the first flag
    /// evaluation must use, so the initial load runs after the last of them.
    func activate()

    /// An opt-out was accepted, in facade call order. Calls the backend still
    /// holds for configuration are discarded, except resets, exactly as the
    /// pre-config buffer is.
    func withdrawHeldCalls()

    func distinctId() -> String?
    func groups() -> [String: String]
    func isOptedOut() -> Bool
    func featureFlag(_ key: String) -> Any?
    func featureFlagPayload(_ key: String) -> Any?
    func featureFlagResult(_ key: String) -> EluFeatureFlagResult?
    func isFeatureEnabled(_ key: String) -> Bool
    func featureFlag(_ key: String, options: EluFeatureFlagOptions) -> Any?
    func featureFlagResult(_ key: String, options: EluFeatureFlagOptions) -> EluFeatureFlagResult?
    func isFeatureEnabled(_ key: String, options: EluFeatureFlagOptions) -> Bool?
    func reloadFeatureFlags(_ completion: (() -> Void)?)
    func flush()

    /// The ELU kill switch: stop capture and delivery for the rest of the run.
    func shutDown()
}

/// What the facade knew when the app made a call.
struct EluCallOrigin: Sendable {
    /// When the app made the call. A call held for configuration keeps this
    /// time instead of the time it is released.
    let calledAt: Date
    /// The visitor was opted out. Such a call never waits for configuration:
    /// only a reset is held, so a later opt-in cannot release the others.
    let optedOut: Bool
}

/// Everything a backend needs to start. Assembled by `EluCore` at the moment
/// the lifecycle state machine decides to run.
struct EluRuntimeBackendContext {
    let siteKey: String
    /// Exact configuration bytes supplied by an injected fixture. The runtime
    /// validates the document itself and derives its own capture authority
    /// from it.
    let configDocument: Data?
    /// Invoked on every flag load so the facade can run its registered
    /// callbacks. Called from the backend's own execution context.
    let flagsDidLoad: () -> Void
    let configHost: URL
    let endpointPolicy: EluEndpointPolicy
    let performance: EluPerformanceOptions
    let diagnostics: EluDiagnosticsOptions
    /// Local implementation selection only; the original source still owns permission.
    let declaredRegionReplayEnabled: Bool
    let personProfiles: EluPersonProfilesMode
    let persistence: EluPersistenceMode
    let rateLimiting: EluRateLimitingOptions
    let eventFilter: EluEventFilter
    /// Installed synchronously by the constructor, then persisted before any
    /// configuration or lifecycle work can authorize collection.
    let initialConsent: EluConsentOperation?
    let guardedFlagsDidLoad: @Sendable (@escaping @Sendable () -> Bool) -> Void
    let flagSnapshotDidLoad: @Sendable (EluFeatureFlagPublication) -> Void
    let initialConfigurationReady: @Sendable (@escaping @Sendable () -> Bool) -> Void

    init(siteKey: String, configDocument: Data? = nil,
         flagsDidLoad: @escaping () -> Void,
         configHost: URL = URL(string: "https://elu.dev")!,
         endpointPolicy: EluEndpointPolicy = .cloud,
         performance: EluPerformanceOptions = .init(),
         diagnostics: EluDiagnosticsOptions = .init(),
         declaredRegionReplayEnabled: Bool = false,
         personProfiles: EluPersonProfilesMode = .identifiedOnly,
         persistence: EluPersistenceMode = .persistent,
         rateLimiting: EluRateLimitingOptions = .init(),
         eventFilter: EluEventFilter = .init(),
         initialConsent: EluConsentOperation? = nil,
         guardedFlagsDidLoad: (@Sendable (@escaping @Sendable () -> Bool) -> Void)? = nil,
         flagSnapshotDidLoad: @escaping @Sendable (EluFeatureFlagPublication) -> Void = { _ in },
         initialConfigurationReady: @escaping @Sendable (@escaping @Sendable () -> Bool) -> Void = { _ in }) {
        self.siteKey = siteKey
        self.configDocument = configDocument
        self.flagsDidLoad = flagsDidLoad
        self.configHost = configHost
        self.endpointPolicy = endpointPolicy
        self.performance = performance
        self.diagnostics = diagnostics
        self.declaredRegionReplayEnabled = declaredRegionReplayEnabled
        self.personProfiles = personProfiles
        self.persistence = persistence
        self.rateLimiting = rateLimiting.normalized
        self.eventFilter = eventFilter
        self.initialConsent = initialConsent
        self.guardedFlagsDidLoad = guardedFlagsDidLoad ?? { predicate in
            if predicate() { flagsDidLoad() }
        }
        self.flagSnapshotDidLoad = flagSnapshotDidLoad
        self.initialConfigurationReady = initialConfigurationReady
    }
}

/// Builds the backend a selection names. Held as a value so tests can observe
/// exactly which runtime each selection reaches.
struct EluRuntimeBackendFactory {
    let make: (EluRuntimeSelection, EluRuntimeBackendContext) -> (any EluRuntimeBackend)?
}

// Simple injected test backends have no retained projection. The owned
// backend overrides both methods with original guards.
extension EluRuntimeBackend {
    func featureFlagPublication() -> EluFeatureFlagPublication? { nil }
    func groups() -> [String: String] { [:] }
    func isOptedOut() -> Bool { false }
    func featureFlagResult(_ key: String) -> EluFeatureFlagResult? { nil }
    // Injected test backends without a projection cannot establish a fresh or
    // exposure-free read. The installed backend implements these requirements.
    func featureFlag(_ key: String, options: EluFeatureFlagOptions) -> Any? {
        guard options.sendEvent, !options.fresh else { return nil }
        return featureFlag(key)
    }
    func featureFlagResult(_ key: String, options: EluFeatureFlagOptions) -> EluFeatureFlagResult? {
        guard options.sendEvent, !options.fresh else { return nil }
        return featureFlagResult(key)
    }
    func isFeatureEnabled(_ key: String, options: EluFeatureFlagOptions) -> Bool? {
        guard let value = featureFlag(key, options: options) else { return nil }
        if let value = value as? Bool { return value }
        return (value as? String).map { !$0.isEmpty }
    }
    func flagNotificationPredicate() -> (@Sendable () -> Bool)? {
        guard flagsAreLoaded else { return nil }
        return { [weak self] in self?.flagsAreLoaded == true }
    }
    func beginPendingOperation(_ op: EluBufferedOp) -> (() -> Void)? { nil }
    func beginNetworkObservation(_ request: URLRequest) -> EluNetworkObservation? { nil }
    func withdrawHeldCalls() {}
    func execute(_ op: EluBufferedOp, origin: EluCallOrigin) { execute(op) }
    func callTime() -> Date { Date() }
}

extension EluBufferedOp {
    var changesFlagContext: Bool {
        switch self {
        case let .capture(_, _, _, set, setOnce): return set != nil || setOnce != nil
        case .screen, .captureException: return false
        default: return true
        }
    }
}
