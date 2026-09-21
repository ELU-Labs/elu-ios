import Foundation

/// The single runtime construction path behind the facade. Kept internal so
/// existing owned fixture factories can observe ordered initialization without
/// exposing a customer runtime selector. This does not import legacy identity.
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
}

/// Visual-replay controls. Only a runtime that renders replay frames offers
/// them; the ELU-owned runtime records none, so it has none.
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
    /// Synchronous intent before the core queue hop. Completion transfers
    /// protection to execute's own ordered work, or releases a discarded call.
    func beginPendingOperation(_ op: EluBufferedOp) -> (() -> Void)?

    /// Performs one facade operation. Operations reach the runtime in the
    /// order they are handed over, including operations replayed from the
    /// pre-config buffer.
    func execute(_ op: EluBufferedOp)

    /// Called once the pre-config buffer has been replayed. The buffered
    /// calls carry the identity, groups, and flag context the first flag
    /// evaluation must use, so the initial load runs after the last of them.
    func activate()

    func distinctId() -> String?
    func isOptedOut() -> Bool
    func featureFlag(_ key: String) -> Any?
    func featureFlagPayload(_ key: String) -> Any?
    func featureFlagResult(_ key: String) -> EluFeatureFlagResult?
    func isFeatureEnabled(_ key: String) -> Bool
    func reloadFeatureFlags(_ completion: (() -> Void)?)
    func flush()

    /// The ELU kill switch: stop capture and delivery for the rest of the run.
    func shutDown()
}

/// Everything a backend needs to start. Assembled by `EluCore` at the moment
/// the lifecycle state machine decides to run.
struct EluRuntimeBackendContext {
    let siteKey: String
    let config: EluRemoteConfig?
    /// The exact configuration response bytes, as served. The ELU-owned
    /// runtime validates the document itself and derives its own capture
    /// authority from it; `config` carries the decoded values the lifecycle
    /// state machine acts on.
    let configDocument: Data?
    let isNewUser: Bool
    /// Invoked on every flag load so the facade can run its registered
    /// callbacks. Called from the backend's own execution context.
    let flagsDidLoad: () -> Void
    let configHost: URL
    let performance: EluPerformanceOptions
    let guardedFlagsDidLoad: @Sendable (@escaping @Sendable () -> Bool) -> Void
    let initialConfigurationReady: @Sendable (@escaping @Sendable () -> Bool) -> Void

    init(siteKey: String, config: EluRemoteConfig? = nil, configDocument: Data? = nil,
         isNewUser: Bool, flagsDidLoad: @escaping () -> Void,
         configHost: URL = URL(string: "https://elu.dev")!,
         performance: EluPerformanceOptions = .init(),
         guardedFlagsDidLoad: (@Sendable (@escaping @Sendable () -> Bool) -> Void)? = nil,
         initialConfigurationReady: @escaping @Sendable (@escaping @Sendable () -> Bool) -> Void = { _ in }) {
        self.siteKey = siteKey
        self.config = config
        self.configDocument = configDocument
        self.isNewUser = isNewUser
        self.flagsDidLoad = flagsDidLoad
        self.configHost = configHost
        self.performance = performance
        self.guardedFlagsDidLoad = guardedFlagsDidLoad ?? { predicate in
            if predicate() { flagsDidLoad() }
        }
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
    func isOptedOut() -> Bool { false }
    func featureFlagResult(_ key: String) -> EluFeatureFlagResult? { nil }
    func flagNotificationPredicate() -> (@Sendable () -> Bool)? {
        guard flagsAreLoaded else { return nil }
        return { [weak self] in self?.flagsAreLoaded == true }
    }
    func beginPendingOperation(_ op: EluBufferedOp) -> (() -> Void)? { nil }
}

extension EluBufferedOp {
    var changesFlagContext: Bool {
        switch self {
        case .capture, .screen, .captureException: return false
        default: return true
        }
    }
}
