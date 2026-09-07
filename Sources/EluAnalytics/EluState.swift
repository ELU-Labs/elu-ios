import Foundation
import PostHog
#if canImport(UIKit)
    import UIKit
#endif

/// The provider-backed runtime: the behavior `0.1.0` shipped, unchanged. This
/// is the only place in the package that reaches the embedded provider, so
/// selecting the ELU-owned runtime leaves every provider call unreachable.
final class EluProviderRuntime: EluRuntimeBackend, EluReplayControl {
    let selection: EluRuntimeSelection = .provider
    var replayControl: (any EluReplayControl)? { self }
    /// The provider owns flag loading and announces it by notification, so the
    /// facade tracks no loaded state for it: a callback registered after a
    /// load waits for the next one, exactly as it does today.
    let flagsAreLoaded = false

    private let runtime: PostHogSDK
    private var flagObserver: NSObjectProtocol?

    init(context: EluRuntimeBackendContext) {
        let cfg = context.config
        let config = PostHogConfig(projectToken: cfg.publicToken, host: cfg.host)
        config.captureScreenViews = true
        config.captureApplicationLifecycleEvents = true
        #if os(iOS)
            if #available(iOS 15.0, *) {
                config.surveys = false
            }
            config.captureElementInteractions = false
            config.capturePushNotificationSubscriptions = false
            config.capturePushNotificationOpened = false

            let replayAllowed = !(cfg.privacy.replayNewUsersOnly && !context.isNewUser)
            config.sessionReplay = replayAllowed
            // Screenshot mode is LOAD-BEARING: ELU's render/analysis pipeline
            // consumes the screenshot wireframe format only.
            config.sessionReplayConfig.screenshotMode = true
            // The runtime has one text-masking knob covering labels AND inputs
            // (see CONTRACT.md) — either ELU control turns it on.
            config.sessionReplayConfig.maskAllTextInputs =
                cfg.privacy.maskTextInputs || cfg.privacy.maskAllText
            config.sessionReplayConfig.maskAllImages = cfg.privacy.maskImages
        #endif

        runtime = PostHogSDK.with(config)
        // A prior mid-session kill switch called optOut(), which the runtime
        // persists and restores on every setup — without clearing it here a
        // re-enabled org stays silently dark until app reinstall. This is the
        // ELU kill-switch path, the one sanctioned caller of optIn/optOut.
        if runtime.isOptOut() { runtime.optIn() }
        registerEluSuperProperties()

        let flagsDidLoad = context.flagsDidLoad
        flagObserver = NotificationCenter.default.addObserver(
            forName: PostHogSDK.didReceiveFeatureFlags,
            object: nil,
            queue: nil
        ) { _ in flagsDidLoad() }
    }

    deinit {
        if let flagObserver {
            NotificationCenter.default.removeObserver(flagObserver)
        }
    }

    func execute(_ op: EluBufferedOp) {
        switch op {
        case let .capture(event, properties):
            runtime.capture(event, properties: properties)
        case let .identify(distinctId, userProperties):
            runtime.identify(distinctId, userProperties: userProperties)
        case let .screen(name, properties):
            runtime.screen(name, properties: properties)
        case let .alias(alias):
            runtime.alias(alias)
        case let .register(properties):
            runtime.register(properties)
        case let .unregister(key):
            runtime.unregister(key)
        case let .group(type, key, properties):
            runtime.group(type: type, key: key, groupProperties: properties)
        case let .setPersonProperties(properties):
            runtime.setPersonProperties(userPropertiesToSet: properties)
        case let .setPersonPropertiesForFlags(properties):
            runtime.setPersonPropertiesForFlags(properties)
        case let .setGroupPropertiesForFlags(type, properties):
            runtime.setGroupPropertiesForFlags(type, properties: properties)
        case let .captureException(error, properties):
            runtime.captureException(error, properties: properties)
        case .reset:
            runtime.reset()
            registerEluSuperProperties()
        }
    }

    func activate() {}

    func distinctId() -> String? {
        let id = runtime.getDistinctId()
        return id.isEmpty ? nil : id
    }

    func featureFlag(_ key: String) -> Any? {
        runtime.getFeatureFlag(key)
    }

    func featureFlagPayload(_ key: String) -> Any? {
        // Web parity: payload reads do not emit $feature_flag_called.
        runtime.getFeatureFlagResult(key, sendFeatureFlagEvent: false)?.payload
    }

    func isFeatureEnabled(_ key: String) -> Bool {
        runtime.isFeatureEnabled(key)
    }

    func reloadFeatureFlags(_ completion: (() -> Void)?) {
        if let completion {
            runtime.reloadFeatureFlags { DispatchQueue.main.async(execute: completion) }
        } else {
            runtime.reloadFeatureFlags()
        }
    }

    func flush() {
        runtime.flush()
    }

    func shutDown() {
        runtime.optOut()
        stopReplay()
    }

    // MARK: - Replay control

    func currentSessionId() -> String? {
        #if os(iOS)
            guard let id = runtime.getSessionId(), !id.isEmpty else { return nil }
            return id
        #else
            return nil
        #endif
    }

    func replayIsActive() -> Bool {
        #if os(iOS)
            return runtime.isSessionReplayActive()
        #else
            return false
        #endif
    }

    func startReplay() {
        #if os(iOS)
            runtime.startSessionRecording()
        #endif
    }

    func stopReplay() {
        #if os(iOS)
            runtime.stopSessionRecording()
        #endif
    }

    /// The runtime's `reset()` clears super properties along with identity, so
    /// both init and every reset path must (re-)register these — the backend
    /// depends on `elu_facade_version` for the fleet version histogram.
    private func registerEluSuperProperties() {
        runtime.register([
            "elu_sdk": "ios",
            "elu_sdk_version": EluCore.sdkVersion,
            "elu_facade_version": EluCore.facadeVersion,
        ])
    }
}

/// The internal engine behind the `Elu` facade: owns the lifecycle state
/// machine, the analytics runtime, the pre-config buffer, config
/// refresh, and the replay budget. Every mutation runs on one serial queue;
/// facade ops dispatch async (never block the caller), getters sync-hop.
final class EluCore {
    static let shared = EluCore()

    static let sdkVersion = "0.1.0"
    static let facadeVersion = 1

    /// Builds the runtime the setup options select. The ELU-owned runtime and
    /// the provider are mutually exclusive for a run: whichever one a run
    /// selects, the other is never constructed and never called.
    static let defaultBackendFactory = EluRuntimeBackendFactory { selection, context in
        switch selection {
        case .provider:
            return EluProviderRuntime(context: context)
        case .standalone:
            return EluStandaloneFacadeRuntime.make(context: context)
        }
    }

    // .userInitiated so facade getters that sync-hop from the main thread get
    // priority donation instead of waiting behind utility-class work.
    private let queue = DispatchQueue(label: "dev.elu.analytics", qos: .userInitiated)

    private var state: EluLifecycleState = .idle
    private var disabledReason: EluDisabledReason?
    private var backend: (any EluRuntimeBackend)?
    private var buffer = EluEventBuffer()
    private var configClient: EluConfigClient?
    private var deviceInEu = false
    private var isNewUser = false
    private var siteKey = ""
    private var selection: EluRuntimeSelection = .provider
    private let backendFactory: EluRuntimeBackendFactory

    /// Privacy actually applied to the live analytics runtime. Fresh configs
    /// diff against this: tightening acts now, loosening waits for relaunch.
    private var appliedPrivacy: EluPrivacyConfig?
    /// Replay permanently stopped for this run (masking tightened, kill, or
    /// newUsersOnly turned on) — the budget loop must not restart it.
    private var replayKilled = false
    /// Session id whose replay we stopped for budget exhaustion; a NEW session
    /// gets a fresh budget and a restart.
    private var budgetStoppedSessionId: String?
    private var budgetTimer: DispatchSourceTimer?
    private var flagCallbacks = EluCallbackRegistry()
    private var observersInstalled = false

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
            deviceInEu = EluEuGuard.deviceIsInEu()
            self.siteKey = siteKey
            selection = options.runtimeSelection

            let client = EluConfigClient(siteKey: siteKey, configHost: options.configHost, queue: queue)
            client.onConfig = { [weak self] cfg, document in
                self?.applyFetched(cfg, document: document)
            }
            configClient = client

            let cached = client.loadCached()
            let decision = EluLifecyclePolicy.initial(cached: cached?.config, deviceInEu: deviceInEu)
            state = decision.state
            disabledReason = decision.disabledReason
            if decision.state == .running, let cached {
                if initializeRuntime(with: cached.config, document: cached.document) {
                    // No buffered calls exist on this path, so the first flag
                    // evaluation may start immediately.
                    backend?.activate()
                } else {
                    state = .disabled
                    disabledReason = .runtimeUnavailable
                }
            }

            client.fetchNow()
            installObservers()
        }
    }

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        #if canImport(UIKit)
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.configClient?.handleForeground()
                    self.budgetTick()
                }
            }
        #endif
    }

    // MARK: - Config application

    private func applyFetched(_ cfg: EluRemoteConfig, document: Data) {
        switch state {
        case .idle:
            break
        case .pending:
            let decision = EluLifecyclePolicy.activation(for: cfg, deviceInEu: deviceInEu)
            state = decision.state
            disabledReason = decision.disabledReason
            if decision.state == .disabled {
                buffer.dropAll()
            } else if initializeRuntime(with: cfg, document: document) {
                for op in buffer.drain() {
                    execute(op)
                }
                // The replayed calls carry the identity, groups, and flag
                // context the first evaluation must use, so it runs after the
                // last of them.
                backend?.activate()
            } else {
                buffer.dropAll()
                state = .disabled
                disabledReason = .runtimeUnavailable
            }
        case .disabled:
            // Only `enabled:false → true` re-initializes mid-run, and only if
            // The runtime was never live. euBlocked/killSwitch loosens next launch.
            if EluLifecyclePolicy.shouldReactivate(
                disabledReason: disabledReason,
                runtimeWasInitialized: backend != nil,
                config: cfg,
                deviceInEu: deviceInEu
            ) {
                guard initializeRuntime(with: cfg, document: document) else {
                    disabledReason = .runtimeUnavailable
                    return
                }
                state = .running
                disabledReason = nil
                backend?.activate()
            }
        case .running:
            applyWhileRunning(cfg)
        }
    }

    /// Mid-session rules: tightening acts immediately, loosening waits.
    private func applyWhileRunning(_ cfg: EluRemoteConfig) {
        guard backend != nil, var applied = appliedPrivacy else { return }

        if !cfg.enabled {
            killCapture()
            state = .disabled
            disabledReason = .killSwitch
            return
        }

        if deviceInEu, cfg.privacy.blockEu, !applied.blockEu {
            killCapture()
            state = .disabled
            disabledReason = .killSwitch
            applied.blockEu = true
            appliedPrivacy = applied
            return
        }

        let maskingTightened =
            (cfg.privacy.maskTextInputs && !applied.maskTextInputs)
                || (cfg.privacy.maskAllText && !applied.maskAllText)
                || (cfg.privacy.maskImages && !applied.maskImages)
        if maskingTightened {
            // Cannot re-mask live frames; correct masking applies next launch.
            stopReplayPermanently()
            applied.maskTextInputs = applied.maskTextInputs || cfg.privacy.maskTextInputs
            applied.maskAllText = applied.maskAllText || cfg.privacy.maskAllText
            applied.maskImages = applied.maskImages || cfg.privacy.maskImages
        }

        if cfg.privacy.replayNewUsersOnly, !applied.replayNewUsersOnly, !isNewUser {
            stopReplayPermanently()
            applied.replayNewUsersOnly = true
        }

        let newBudget = cfg.privacy.replayMaxMinutes
        let oldBudget = applied.replayMaxMinutes
        let budgetReduced = newBudget != 0 && (oldBudget == 0 || newBudget < oldBudget)
        if budgetReduced {
            applied.replayMaxMinutes = newBudget
            appliedPrivacy = applied
            startBudgetTimerIfNeeded()
            budgetTick()
            return
        }

        appliedPrivacy = applied
    }

    // MARK: - Runtime initialization

    /// Returns false when the selected runtime could not be created, which
    /// the caller turns into a disabled run rather than a running state with
    /// nothing behind it.
    private func initializeRuntime(with cfg: EluRemoteConfig, document: Data?) -> Bool {
        let context = EluRuntimeBackendContext(
            siteKey: siteKey,
            config: cfg,
            configDocument: document,
            isNewUser: isNewUser,
            flagsDidLoad: { [weak self] in
                guard let self else { return }
                self.queue.async { self.flagCallbacks.dispatch(on: .main) }
            }
        )
        guard let backend = backendFactory.make(selection, context) else { return false }
        self.backend = backend
        appliedPrivacy = cfg.privacy
        replayKilled = false
        budgetStoppedSessionId = nil
        startBudgetTimerIfNeeded()
        return true
    }

    // MARK: - Replay budget (replayMaxMinutes)

    private func startBudgetTimerIfNeeded() {
        #if os(iOS)
            guard budgetTimer == nil,
                  let applied = appliedPrivacy, applied.replayMaxMinutes > 0,
                  !replayKilled, backend?.replayControl != nil
            else { return }
            // First tick immediately: a relaunch inside an exhausted-budget
            // session must stop replay before meaningful capture, and the
            // start stamp should land at replay start, not one poll later.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 5)
            timer.setEventHandler { [weak self] in self?.budgetTick() }
            timer.resume()
            budgetTimer = timer
        #endif
    }

    private func budgetTick() {
        #if os(iOS)
            guard let replay = backend?.replayControl, let applied = appliedPrivacy,
                  applied.replayMaxMinutes > 0, !replayKilled, state == .running
            else { return }
            guard let sessionId = replay.currentSessionId() else { return }

            if replay.replayIsActive() {
                let startMs = EluDeviceMarkers.budgetStamp(sessionId: sessionId)
                let elapsedMs = Date().timeIntervalSince1970 * 1000 - startMs
                if elapsedMs >= Double(applied.replayMaxMinutes) * 60_000 {
                    replay.stopReplay()
                    budgetStoppedSessionId = sessionId
                }
            } else if let stopped = budgetStoppedSessionId, stopped != sessionId {
                // A rotated session gets a fresh per-session budget.
                budgetStoppedSessionId = nil
                replay.startReplay()
            }
        #endif
    }

    private func stopReplayPermanently() {
        backend?.replayControl?.stopReplay()
        endReplay()
    }

    /// The ELU kill switch: capture and delivery stop for the rest of the run.
    private func killCapture() {
        backend?.shutDown()
        endReplay()
    }

    private func endReplay() {
        replayKilled = true
        budgetStoppedSessionId = nil
        budgetTimer?.cancel()
        budgetTimer = nil
    }

    // MARK: - Facade dispatch

    /// Buffer-class ops: async, never blocks, safe in every state.
    func dispatch(_ op: EluBufferedOp) {
        queue.async { [self] in
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

    func reset() {
        queue.async { [self] in
            switch state {
            case .running:
                execute(.reset)
            case .pending:
                // Buffered in order so the drain replays capture → reset →
                // capture exactly like web: pre-reset events deliver under the
                // pre-reset identity instead of being dropped.
                buffer.push(.reset)
            case .idle, .disabled:
                break
            }
        }
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

    /// Test seam: applies a configuration exactly as a successful fetch does,
    /// on the same serial queue, without a request.
    func deliverConfigForTesting(_ config: EluRemoteConfig, document: Data) {
        queue.async { [self] in applyFetched(config, document: document) }
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
            if state == .running, backend?.flagsAreLoaded == true {
                DispatchQueue.main.async(execute: callback)
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
