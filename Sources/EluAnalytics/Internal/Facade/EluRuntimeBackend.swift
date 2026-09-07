import Foundation

/// Which analytics runtime the facade drives for a run. The selection is fixed
/// at `setup` and never changes for the lifetime of the process.
///
/// `.provider` is the shipped behavior: the embedded provider owns identity,
/// events, delivery, flags, and replay. `.standalone` drives the ELU-owned
/// runtime and the ELU-owned flag client instead, and never calls the
/// provider.
///
/// The two selections do NOT share stored identity. Selecting `.standalone`
/// starts a fresh ELU identity on the device; it does not read, import, or
/// convert anything the provider stored. Identity continuity across the
/// change is a separate, separately reviewed reader and must not be inferred
/// from this selection.
enum EluRuntimeSelection: Equatable, Sendable {
    case provider
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

    /// Performs one facade operation. Operations reach the runtime in the
    /// order they are handed over, including operations replayed from the
    /// pre-config buffer.
    func execute(_ op: EluBufferedOp)

    /// Called once the pre-config buffer has been replayed. The buffered
    /// calls carry the identity, groups, and flag context the first flag
    /// evaluation must use, so the initial load runs after the last of them.
    func activate()

    func distinctId() -> String?
    func featureFlag(_ key: String) -> Any?
    func featureFlagPayload(_ key: String) -> Any?
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
    let config: EluRemoteConfig
    /// The exact configuration response bytes, as served. The ELU-owned
    /// runtime validates the document itself and derives its own capture
    /// authority from it; `config` carries the decoded values the lifecycle
    /// state machine acts on.
    let configDocument: Data?
    let isNewUser: Bool
    /// Invoked on every flag load so the facade can run its registered
    /// callbacks. Called from the backend's own execution context.
    let flagsDidLoad: () -> Void
}

/// Builds the backend a selection names. Held as a value so tests can observe
/// exactly which runtime each selection reaches.
struct EluRuntimeBackendFactory {
    let make: (EluRuntimeSelection, EluRuntimeBackendContext) -> (any EluRuntimeBackend)?
}
