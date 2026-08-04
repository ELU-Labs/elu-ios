import Foundation
import PostHog
#if canImport(UIKit)
    import UIKit
#endif

/// The internal engine behind the `Elu` facade: owns the lifecycle state
/// machine, the analytics runtime, the pre-config buffer, config
/// refresh, and the replay budget. Every mutation runs on one serial queue;
/// facade ops dispatch async (never block the caller), getters sync-hop.
final class EluCore {
    static let shared = EluCore()

    static let sdkVersion = "0.1.0"
    static let facadeVersion = 1

    // .userInitiated so facade getters that sync-hop from the main thread get
    // priority donation instead of waiting behind utility-class work.
    private let queue = DispatchQueue(label: "dev.elu.analytics", qos: .userInitiated)

    private var state: EluLifecycleState = .idle
    private var disabledReason: EluDisabledReason?
    private var runtime: PostHogSDK?
    private var buffer = EluEventBuffer()
    private var configClient: EluConfigClient?
    private var deviceInEu = false
    private var isNewUser = false

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

    private init() {}

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

            let client = EluConfigClient(siteKey: siteKey, configHost: options.configHost, queue: queue)
            client.onConfig = { [weak self] cfg in self?.applyFetched(cfg) }
            configClient = client

            let cached = client.loadCached()
            let decision = EluLifecyclePolicy.initial(cached: cached, deviceInEu: deviceInEu)
            state = decision.state
            disabledReason = decision.disabledReason
            if decision.state == .running, let cached {
                initializeRuntime(with: cached)
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
        NotificationCenter.default.addObserver(
            forName: PostHogSDK.didReceiveFeatureFlags,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.flagCallbacks.dispatch(on: .main)
            }
        }
    }

    // MARK: - Config application

    private func applyFetched(_ cfg: EluRemoteConfig) {
        switch state {
        case .idle:
            break
        case .pending:
            let decision = EluLifecyclePolicy.activation(for: cfg, deviceInEu: deviceInEu)
            state = decision.state
            disabledReason = decision.disabledReason
            if decision.state == .disabled {
                buffer.dropAll()
            } else {
                initializeRuntime(with: cfg)
                for op in buffer.drain() {
                    execute(op)
                }
            }
        case .disabled:
            // Only `enabled:false → true` re-initializes mid-run, and only if
            // The runtime was never live. euBlocked/killSwitch loosens next launch.
            if EluLifecyclePolicy.shouldReactivate(
                disabledReason: disabledReason,
                runtimeWasInitialized: runtime != nil,
                config: cfg,
                deviceInEu: deviceInEu
            ) {
                initializeRuntime(with: cfg)
                state = .running
                disabledReason = nil
            }
        case .running:
            applyWhileRunning(cfg)
        }
    }

    /// Mid-session rules: tightening acts immediately, loosening waits.
    private func applyWhileRunning(_ cfg: EluRemoteConfig) {
        guard let runtime, var applied = appliedPrivacy else { return }

        if !cfg.enabled {
            runtime.optOut()
            stopReplayPermanently(runtime)
            state = .disabled
            disabledReason = .killSwitch
            return
        }

        if deviceInEu, cfg.privacy.blockEu, !applied.blockEu {
            runtime.optOut()
            stopReplayPermanently(runtime)
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
            stopReplayPermanently(runtime)
            applied.maskTextInputs = applied.maskTextInputs || cfg.privacy.maskTextInputs
            applied.maskAllText = applied.maskAllText || cfg.privacy.maskAllText
            applied.maskImages = applied.maskImages || cfg.privacy.maskImages
        }

        if cfg.privacy.replayNewUsersOnly, !applied.replayNewUsersOnly, !isNewUser {
            stopReplayPermanently(runtime)
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

    private func initializeRuntime(with cfg: EluRemoteConfig) {
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

            let replayAllowed = !(cfg.privacy.replayNewUsersOnly && !isNewUser)
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

        let runtime = PostHogSDK.with(config)
        // A prior mid-session kill switch called optOut(), which the runtime
        // persists and restores on every setup — without clearing it here a
        // re-enabled org stays silently dark until app reinstall. This is the
        // ELU kill-switch path, the one sanctioned caller of optIn/optOut.
        if runtime.isOptOut() { runtime.optIn() }
        registerEluSuperProperties(runtime)

        self.runtime = runtime
        appliedPrivacy = cfg.privacy
        replayKilled = false
        budgetStoppedSessionId = nil
        startBudgetTimerIfNeeded()
    }

    /// Runtime `reset()` clears super properties along with identity, so both
    /// init and every reset path must (re-)register these — the backend
    /// depends on `elu_facade_version` for the fleet version histogram.
    private func registerEluSuperProperties(_ runtime: PostHogSDK) {
        runtime.register([
            "elu_sdk": "ios",
            "elu_sdk_version": Self.sdkVersion,
            "elu_facade_version": Self.facadeVersion,
        ])
    }

    // MARK: - Replay budget (replayMaxMinutes)

    private func startBudgetTimerIfNeeded() {
        #if os(iOS)
            guard budgetTimer == nil,
                  let applied = appliedPrivacy, applied.replayMaxMinutes > 0,
                  !replayKilled, runtime != nil
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
            guard let runtime, let applied = appliedPrivacy,
                  applied.replayMaxMinutes > 0, !replayKilled, state == .running
            else { return }
            guard let sessionId = runtime.getSessionId(), !sessionId.isEmpty else { return }

            if runtime.isSessionReplayActive() {
                let startMs = EluDeviceMarkers.budgetStamp(sessionId: sessionId)
                let elapsedMs = Date().timeIntervalSince1970 * 1000 - startMs
                if elapsedMs >= Double(applied.replayMaxMinutes) * 60_000 {
                    runtime.stopSessionRecording()
                    budgetStoppedSessionId = sessionId
                }
            } else if let stopped = budgetStoppedSessionId, stopped != sessionId {
                // A rotated session gets a fresh per-session budget.
                budgetStoppedSessionId = nil
                runtime.startSessionRecording()
            }
        #endif
    }

    private func stopReplayPermanently(_ runtime: PostHogSDK) {
        #if os(iOS)
            runtime.stopSessionRecording()
        #endif
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
        guard let runtime else { return }
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
            performReset(runtime)
        }
    }

    // MARK: - Non-buffered facade paths

    func reset() {
        queue.async { [self] in
            switch state {
            case .running:
                if let runtime { performReset(runtime) }
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

    private func performReset(_ runtime: PostHogSDK) {
        runtime.reset()
        registerEluSuperProperties(runtime)
    }

    func flush() {
        queue.async { [self] in
            if state == .running { runtime?.flush() }
        }
    }

    func distinctId() -> String? {
        queue.sync {
            guard state == .running, let runtime else { return nil }
            let id = runtime.getDistinctId()
            return id.isEmpty ? nil : id
        }
    }

    func getFeatureFlag(_ key: String) -> Any? {
        queue.sync {
            guard state == .running else { return nil }
            return runtime?.getFeatureFlag(key)
        }
    }

    func getFeatureFlagPayload(_ key: String) -> Any? {
        queue.sync {
            guard state == .running else { return nil }
            // Web parity: payload reads do not emit $feature_flag_called.
            return runtime?.getFeatureFlagResult(key, sendFeatureFlagEvent: false)?.payload
        }
    }

    func isFeatureEnabled(_ key: String) -> Bool {
        queue.sync {
            guard state == .running else { return false }
            return runtime?.isFeatureEnabled(key) ?? false
        }
    }

    func reloadFeatureFlags(_ completion: (() -> Void)?) {
        queue.async { [self] in
            guard state == .running, let runtime else {
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            if let completion {
                runtime.reloadFeatureFlags { DispatchQueue.main.async(execute: completion) }
            } else {
                runtime.reloadFeatureFlags()
            }
        }
    }

    func onFeatureFlagsLoaded(_ callback: @escaping () -> Void) {
        queue.async { [self] in
            flagCallbacks.append(callback)
        }
    }

    // MARK: -

    private func warn(_ message: String) {
        #if DEBUG
            print("[EluAnalytics] \(message)")
        #endif
    }
}
