import Foundation
import PostHog
#if canImport(UIKit)
    import UIKit
#endif

/// The internal engine behind the `Elu` facade: owns the lifecycle state
/// machine, the embedded PostHog instance, the pre-config buffer, config
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
    private var posthog: PostHogSDK?
    private var buffer = EluEventBuffer()
    private var configClient: EluConfigClient?
    private var deviceInEu = false
    private var isNewUser = false

    /// Privacy actually applied to the live PostHog instance. Fresh configs
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
                initializePostHog(with: cached)
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
                initializePostHog(with: cfg)
                for op in buffer.drain() {
                    execute(op)
                }
            }
        case .disabled:
            // Only `enabled:false → true` re-initializes mid-run, and only if
            // PostHog was never live. euBlocked/killSwitch loosens next launch.
            if EluLifecyclePolicy.shouldReactivate(
                disabledReason: disabledReason,
                runtimeWasInitialized: posthog != nil,
                config: cfg,
                deviceInEu: deviceInEu
            ) {
                initializePostHog(with: cfg)
                state = .running
                disabledReason = nil
            }
        case .running:
            applyWhileRunning(cfg)
        }
    }

    /// Mid-session rules: tightening acts immediately, loosening waits.
    private func applyWhileRunning(_ cfg: EluRemoteConfig) {
        guard let ph = posthog, var applied = appliedPrivacy else { return }

        if !cfg.enabled {
            ph.optOut()
            stopReplayPermanently(ph)
            state = .disabled
            disabledReason = .killSwitch
            return
        }

        if deviceInEu, cfg.privacy.blockEu, !applied.blockEu {
            ph.optOut()
            stopReplayPermanently(ph)
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
            stopReplayPermanently(ph)
            applied.maskTextInputs = applied.maskTextInputs || cfg.privacy.maskTextInputs
            applied.maskAllText = applied.maskAllText || cfg.privacy.maskAllText
            applied.maskImages = applied.maskImages || cfg.privacy.maskImages
        }

        if cfg.privacy.replayNewUsersOnly, !applied.replayNewUsersOnly, !isNewUser {
            stopReplayPermanently(ph)
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

    // MARK: - PostHog init

    private func initializePostHog(with cfg: EluRemoteConfig) {
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
            // posthog-ios has one text-masking knob covering labels AND inputs
            // (see CONTRACT.md) — either ELU control turns it on.
            config.sessionReplayConfig.maskAllTextInputs =
                cfg.privacy.maskTextInputs || cfg.privacy.maskAllText
            config.sessionReplayConfig.maskAllImages = cfg.privacy.maskImages
        #endif

        let ph = PostHogSDK.with(config)
        // A prior mid-session kill switch called optOut(), which posthog-ios
        // PERSISTS and restores on every setup — without clearing it here a
        // re-enabled org stays silently dark until app reinstall. This is the
        // ELU kill-switch path, the one sanctioned caller of optIn/optOut.
        if ph.isOptOut() { ph.optIn() }
        registerEluSuperProperties(ph)

        posthog = ph
        appliedPrivacy = cfg.privacy
        replayKilled = false
        budgetStoppedSessionId = nil
        startBudgetTimerIfNeeded()
    }

    /// PostHog `reset()` clears super properties along with identity, so both
    /// init and every reset path must (re-)register these — the backend
    /// depends on `elu_facade_version` for the fleet version histogram.
    private func registerEluSuperProperties(_ ph: PostHogSDK) {
        ph.register([
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
                  !replayKilled, posthog != nil
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
            guard let ph = posthog, let applied = appliedPrivacy,
                  applied.replayMaxMinutes > 0, !replayKilled, state == .running
            else { return }
            guard let sessionId = ph.getSessionId(), !sessionId.isEmpty else { return }

            if ph.isSessionReplayActive() {
                let startMs = EluDeviceMarkers.budgetStamp(sessionId: sessionId)
                let elapsedMs = Date().timeIntervalSince1970 * 1000 - startMs
                if elapsedMs >= Double(applied.replayMaxMinutes) * 60_000 {
                    ph.stopSessionRecording()
                    budgetStoppedSessionId = sessionId
                }
            } else if let stopped = budgetStoppedSessionId, stopped != sessionId {
                // PostHog rotated to a new session: fresh per-session budget.
                budgetStoppedSessionId = nil
                ph.startSessionRecording()
            }
        #endif
    }

    private func stopReplayPermanently(_ ph: PostHogSDK) {
        #if os(iOS)
            ph.stopSessionRecording()
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
        guard let ph = posthog else { return }
        switch op {
        case let .capture(event, properties):
            ph.capture(event, properties: properties)
        case let .identify(distinctId, userProperties):
            ph.identify(distinctId, userProperties: userProperties)
        case let .screen(name, properties):
            ph.screen(name, properties: properties)
        case let .alias(alias):
            ph.alias(alias)
        case let .register(properties):
            ph.register(properties)
        case let .unregister(key):
            ph.unregister(key)
        case let .group(type, key, properties):
            ph.group(type: type, key: key, groupProperties: properties)
        case let .setPersonProperties(properties):
            ph.setPersonProperties(userPropertiesToSet: properties)
        case let .setPersonPropertiesForFlags(properties):
            ph.setPersonPropertiesForFlags(properties)
        case let .setGroupPropertiesForFlags(type, properties):
            ph.setGroupPropertiesForFlags(type, properties: properties)
        case let .captureException(error, properties):
            ph.captureException(error, properties: properties)
        case .reset:
            performReset(ph)
        }
    }

    // MARK: - Non-buffered facade paths

    func reset() {
        queue.async { [self] in
            switch state {
            case .running:
                if let ph = posthog { performReset(ph) }
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

    private func performReset(_ ph: PostHogSDK) {
        ph.reset()
        registerEluSuperProperties(ph)
    }

    func flush() {
        queue.async { [self] in
            if state == .running { posthog?.flush() }
        }
    }

    func distinctId() -> String? {
        queue.sync {
            guard state == .running, let ph = posthog else { return nil }
            let id = ph.getDistinctId()
            return id.isEmpty ? nil : id
        }
    }

    func getFeatureFlag(_ key: String) -> Any? {
        queue.sync {
            guard state == .running else { return nil }
            return posthog?.getFeatureFlag(key)
        }
    }

    func getFeatureFlagPayload(_ key: String) -> Any? {
        queue.sync {
            guard state == .running else { return nil }
            // Web parity: payload reads do not emit $feature_flag_called.
            return posthog?.getFeatureFlagResult(key, sendFeatureFlagEvent: false)?.payload
        }
    }

    func isFeatureEnabled(_ key: String) -> Bool {
        queue.sync {
            guard state == .running else { return false }
            return posthog?.isFeatureEnabled(key) ?? false
        }
    }

    func reloadFeatureFlags(_ completion: (() -> Void)?) {
        queue.async { [self] in
            guard state == .running, let ph = posthog else {
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            if let completion {
                ph.reloadFeatureFlags { DispatchQueue.main.async(execute: completion) }
            } else {
                ph.reloadFeatureFlags()
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
