import Foundation

/// The internal engine behind the facade. It hands ordered operations to the
/// owned runtime and retains the initial buffer until its original current
/// source signals readiness. Mutations use one serial queue; getters sync-hop.
final class EluCore {
    static let shared = EluCore()

    static let sdkVersion = "0.2.0"
    static let facadeVersion = 1

    /// Constructs the owned runtime once for this core's original setup.
    static let defaultBackendFactory = EluRuntimeBackendFactory { _, context in
        EluStandaloneFacadeRuntime.make(context: context)
    }

    // .userInitiated so facade getters that sync-hop from the main thread get
    // priority donation instead of waiting behind utility-class work.
    private let queue = DispatchQueue(label: "dev.elu.analytics", qos: .userInitiated)

    private var state: EluLifecycleState = .idle
    private var disabledReason: EluDisabledReason?
    private var backend: (any EluRuntimeBackend)?
    private let backendIntentLock = NSLock()
    private weak var intentBackend: (any EluRuntimeBackend)?
    private var acceptedConsent: EluConsentOperation? // guarded by backendIntentLock
    private var performance = EluPerformanceOptions()
    private var configHost = URL(string: "https://elu.dev")!
    private var buffer = EluEventBuffer()
    private var pendingConsent: EluConsentOperation?
    private var deliveredConsentId: UUID?
    private var isNewUser = false
    private var siteKey = ""
    private var selection: EluRuntimeSelection = .standalone
    private let backendFactory: EluRuntimeBackendFactory

    private var flagCallbacks = EluCallbackRegistry()

    init(backendFactory: EluRuntimeBackendFactory = EluCore.defaultBackendFactory) {
        self.backendFactory = backendFactory
    }

    // MARK: - Setup

    func setup(siteKey: String, options: EluSetupOptions) {
        queue.async { [self] in
            guard state == .idle else {
                warn("setup() called more than once — ignored")
                return
            }
            guard !siteKey.isEmpty else {
                warn("setup() called with an empty siteKey — ignored")
                return
            }

            // Marker FIRST: absent-at-setup is the replayNewUsersOnly probe.
            isNewUser = EluDeviceMarkers.recordFirstLaunchIfNeeded()
            self.siteKey = siteKey
            selection = options.runtimeSelection
            configHost = options.configHost
            performance = options.performance

            // The owned source, including independent flags/privacy, decides
            // readiness. No legacy cache or v1 request participates.
            state = .pending
            // Construction starts asynchronous work. Transfer the latest accepted
            // choice before that work exists, and publish the backend under the
            // same lock so no consent call can fall between those two steps.
            backendIntentLock.lock()
            let initialConsent = acceptedConsent
            let context = backendContext(config: nil, document: nil, initialConsent: initialConsent)
            guard let selected = backendFactory.make(.standalone, context) else {
                backendIntentLock.unlock()
                state = .disabled
                disabledReason = .runtimeUnavailable
                return
            }
            backend = selected
            intentBackend = selected
            pendingConsent = initialConsent
            backendIntentLock.unlock()
            if let initialConsent {
                deliveredConsentId = initialConsent.id
                selected.execute(.consent(initialConsent))
            }
        }
    }

    private func backendContext(config: EluRemoteConfig?, document: Data?, initialConsent: EluConsentOperation?) -> EluRuntimeBackendContext {
        EluRuntimeBackendContext(siteKey: siteKey, config: config, configDocument: document,
            isNewUser: isNewUser, flagsDidLoad: { [weak self] in
                self?.dispatchFlagNotification(ifCurrent: { true })
            }, configHost: configHost, performance: performance, initialConsent: initialConsent, guardedFlagsDidLoad: { [weak self] predicate in
                self?.dispatchFlagNotification(ifCurrent: predicate)
            }, initialConfigurationReady: { [weak self] predicate in
                guard let self else { return }
                self.queue.async {
                    guard self.selection == .standalone, self.state == .pending,
                          let backend = self.backend, predicate() else { return }
                    self.state = .running
                    self.disabledReason = nil
                    for op in self.buffer.drain() { backend.execute(op) }
                    backend.activate()
                }
            })
    }

    private func dispatchFlagNotification(ifCurrent: @escaping @Sendable () -> Bool) {
        queue.async { [weak self] in
            guard let self, ifCurrent() else { return }
            self.flagCallbacks.dispatch(on: .main, ifCurrent: ifCurrent)
        }
    }

    private func beginPendingOperation(_ op: EluBufferedOp) -> (finish: (() -> Void)?, deniedAtCall: Bool) {
        backendIntentLock.lock()
        defer { backendIntentLock.unlock() }
        let current = intentBackend
        let denied = acceptedConsent?.optedOut == true || current?.isOptedOut() == true
        return (current?.beginPendingOperation(op), denied)
    }

    // MARK: - Facade dispatch

    /// Buffer-class ops: async, never blocks, safe in every state.
    func dispatch(_ op: EluBufferedOp) {
        let intent = beginPendingOperation(op)
        queue.async { [self] in
            defer { intent.finish?() }
            if intent.deniedAtCall || pendingConsent?.optedOut == true {
                switch op {
                case .capture, .screen, .captureException: return
                default: break
                }
            }
            switch state {
            case .running:
                execute(op)
            case .pending:
                buffer.push(op)
            case .idle, .disabled:
                break
            }
        }
    }

    private func execute(_ op: EluBufferedOp) {
        backend?.execute(op)
    }

    // MARK: - Non-buffered facade paths

    func setConsent(optedOut: Bool, event: String? = nil, properties: [String: Any]? = nil) {
        if let event, EluFacadeJSON.identifier(event, maximumLength: 512) == nil { return }
        let operation = EluConsentOperation(optedOut: optedOut, event: event, properties: properties)
        // Acceptance and enqueueing share one linearization point. Concurrent
        // callers cannot enqueue an older grant after a newer denial.
        backendIntentLock.lock()
        acceptedConsent = operation
        let finishIntent = intentBackend?.beginPendingOperation(.consent(operation))
        queue.async { [self] in
            defer { finishIntent?() }
            // Preserve the ordered privacy window even when a later consent
            // choice already superseded this operation's durable write.
            pendingConsent = operation
            if optedOut { buffer.dropAll() }
            backendIntentLock.lock()
            let isLatest = acceptedConsent?.id == operation.id
            backendIntentLock.unlock()
            guard isLatest, deliveredConsentId != operation.id else { return }
            // Consent is not a bounded event-buffer entry: persist it even
            // before configuration arrives, and never drop it on overflow.
            if let backend {
                deliveredConsentId = operation.id
                backend.execute(.consent(operation))
            }
        }
        backendIntentLock.unlock()
    }

    func isOptedOut() -> Bool {
        queue.sync { pendingConsent?.optedOut ?? backend?.isOptedOut() ?? false }
    }

    func reset() {
        dispatch(.reset)
    }

    func flush() {
        queue.async { [self] in
            if state == .running { backend?.flush() }
        }
    }

    func distinctId() -> String? {
        queue.sync {
            guard state == .running else { return nil }
            return backend?.distinctId()
        }
    }

    func getGroups() -> [String: String] {
        queue.sync { state == .running ? (backend?.groups() ?? [:]) : [:] }
    }

    func getFeatureFlag(_ key: String) -> Any? {
        queue.sync {
            guard state == .running else { return nil }
            return backend?.featureFlag(key)
        }
    }

    func getFeatureFlagPayload(_ key: String) -> Any? {
        queue.sync {
            guard state == .running else { return nil }
            return backend?.featureFlagPayload(key)
        }
    }

    func getFeatureFlagResult(_ key: String) -> EluFeatureFlagResult? {
        queue.sync {
            guard state == .running else { return nil }
            return backend?.featureFlagResult(key)
        }
    }

    func isFeatureEnabled(_ key: String) -> Bool {
        queue.sync {
            guard state == .running else { return false }
            return backend?.isFeatureEnabled(key) ?? false
        }
    }

    func reloadFeatureFlags(_ completion: (() -> Void)?) {
        queue.async { [self] in
            guard state == .running, let backend else {
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            backend.reloadFeatureFlags(completion)
        }
    }

    /// Test seam: the runtime this run selected, once one has been built.
    func backendForTesting() -> (any EluRuntimeBackend)? {
        queue.sync { backend }
    }

    /// Test seam: pre-config calls the buffer cap discarded.
    func bufferDropCountForTesting() -> Int {
        queue.sync { buffer.droppedCount }
    }

    func onFeatureFlagsLoaded(_ callback: @escaping () -> Void) {
        queue.async { [self] in
            flagCallbacks.append(callback)
            // A listener registered after flags have already loaded fires once
            // immediately with the loaded snapshot, then again on every later
            // load, in registration order.
            if state == .running, let predicate = backend?.flagNotificationPredicate() {
                DispatchQueue.main.async {
                    guard predicate() else { return }
                    callback()
                }
            }
        }
    }

    // MARK: -

    private func warn(_ message: String) {
        #if DEBUG
            print("[EluAnalytics] \(message)")
        #endif
    }
}
