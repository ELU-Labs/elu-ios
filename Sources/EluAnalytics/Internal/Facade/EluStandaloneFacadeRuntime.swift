import Foundation

/// Drives the ELU-owned runtime and the ELU-owned flag client from the `Elu`
/// facade. Nothing here calls the embedded provider.
///
/// Ordering: every state-changing call is chained onto one task tail in the
/// order the facade handed it over, so calls replayed from the pre-config
/// buffer and calls made afterwards reach the runtime in call order. The
/// facade getters never join that chain; they answer from the identity and
/// flag state this object mirrors, which is how a synchronous getter can be
/// safe on any thread without blocking on the runtime.
///
/// Identity: selecting this runtime starts a FRESH ELU identity. It never
/// reads, imports, or converts identity the embedded provider stored, so a
/// device that had been reporting under a provider-issued id begins reporting
/// under a new ELU anonymous id. Carrying an existing identity across is a
/// separate reader with its own review, and must not be inferred from this
/// selection.
final class EluStandaloneFacadeRuntime: EluRuntimeBackend, @unchecked Sendable {
    /// Attempts a superseded flag reload makes before giving up. A reload is
    /// superseded when the identity or configuration it was evaluated against
    /// changed while it was in flight.
    static let flagReloadAttempts = 3

    private struct Started {
        let runtime: EluStandaloneRuntime
        let flags: EluV1FlagClient?
    }

    let selection: EluRuntimeSelection = .standalone
    /// Public replay controls remain disabled. Internal composition starts
    /// capture only with separately qualified local proof and durable policy.
    let replayControl: (any EluReplayControl)? = nil

    private let flagsDidLoad: () -> Void
    private var guardedFlagsDidLoad: (@Sendable (@escaping @Sendable () -> Bool) -> Void)?
    private var stack: EluStandaloneStack?
    private let nativeLifecycle = EluNativeReplayLifecycle()
    private var foregroundIntent = false
    private var foregroundGeneration = UUID()
    private var flagGeneration = UUID()
    private var pendingFlagIntents: [UUID: EluStandaloneFacadePendingIntent] = [:]
    private let flagTransport: (any EluV1FlagTransport)?
    private let lock = NSLock()

    private var tail: Task<Void, Never>?
    private var tailVersion = UUID()
    private var started: Started?

    private var identity: EluIdentityState?
    private var projectedDistinctId: String?
    private var pendingIdentityOperations = 0
    private var consentProjection: (id: UUID, optedOut: Bool)?

    private var flagCache: EluV1FlagCacheProjection?
    private var flagsLoadedState = false
    private var flagLoadDeferred = true
    private var flagReloadScheduled = false

    private var exposures: Set<String> = []
    private var exposureIdentityRevision: Int64?

    private var dropped: [EluFacadeDropReason: Int] = [:]
    private var isShutDown = false

    #if canImport(UIKit)
        private var lifecycleEmitter: EluApplicationLifecycleEmitter?
    #endif

    init(
        context: EluRuntimeBackendContext,
        open: @escaping @Sendable () async throws -> EluStandaloneRuntime,
        flagTransport: (any EluV1FlagTransport)? = nil,
        observeApplicationLifecycle: Bool = false
    ) {
        flagsDidLoad = context.flagsDidLoad
        self.flagTransport = flagTransport
        let document = context.configDocument
        tail = Task { [weak self] in
            await self?.start(open: open, configDocument: document, observeApplicationLifecycle: observeApplicationLifecycle)
        }
    }

    /// Injected internal stack path. The later public bootstrap supplies a
    /// dispatcher that checks the supplied predicate on its final callback queue.
    init(
        context: EluRuntimeBackendContext,
        openStack: @escaping @Sendable () async throws -> EluStandaloneStack,
        guardedFlagsDidLoad: @escaping @Sendable (@escaping @Sendable () -> Bool) -> Void
    ) {
        flagsDidLoad = context.flagsDidLoad
        flagTransport = nil
        self.guardedFlagsDidLoad = guardedFlagsDidLoad
        tail = Task { [weak self] in
            guard let self, let stack = try? await openStack() else { return }
            let accepted = self.withLock { () -> Bool in
                guard !self.isShutDown else { return false }
                self.stack = stack
                self.started = Started(runtime: stack.runtime, flags: stack.flags)
                self.bindPendingIntents(to: stack.runtime)
                return true
            }
            guard accepted else { stack.close(); return }
            stack.observe(onIntent: { [weak self] in self?.configurationIntent() },
                onSettled: { [weak self] in self?.scheduleFlagReload() },
                onReady: context.initialConfigurationReady)
            await stack.runtime.installNativeReplayComposition(lifecycle: self.nativeLifecycle, capabilities: EluStandaloneRuntime.readbackProvenReplayCapabilities, deferredUntilActivation: true)
            self.syncIdentity(await stack.runtime.currentSnapshot.identity)
            stack.start()
            self.applyForegroundIntent()
        }
        attachOwnedLifecycle()
    }

    func setForeground(_ foreground: Bool) {
        withLock {
            guard !isShutDown else { return }
            foregroundIntent = foreground
            started?.runtime.performanceLifecycleIntent(foreground: foreground)
            foregroundGeneration = UUID()
        }
        applyForegroundIntent()
    }

    private func applyForegroundIntent() {
        let (current, foreground, generation) = withLock { (stack, foregroundIntent, foregroundGeneration) }
        current?.setForeground(foreground, ifCurrent: { [weak self] in
            self?.withLock { self?.isShutDown == false && self?.foregroundGeneration == generation } ?? false
        })
    }

    /// Opens the site-scoped runtime under the ELU support directory with the
    /// production transports.
    static func make(context: EluRuntimeBackendContext) -> EluStandaloneFacadeRuntime? {
        guard let rootDirectoryURL = runtimeDirectoryURL() else { return nil }
        let siteKey = context.siteKey
        return EluStandaloneFacadeRuntime(
            context: context,
            openStack: {
                try await EluStandaloneStack.make(
                    rootDirectoryURL: rootDirectoryURL,
                    siteKey: siteKey,
                    configHost: context.configHost,
                    performance: context.performance
                )
            },
            guardedFlagsDidLoad: context.guardedFlagsDidLoad
        )
    }

    static func runtimeDirectoryURL() -> URL? {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        else {
            return nil
        }
        let directory = base
            .appendingPathComponent("EluAnalytics", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    // MARK: - Startup

    private func start(
        open: @escaping @Sendable () async throws -> EluStandaloneRuntime,
        configDocument: Data?,
        observeApplicationLifecycle: Bool
    ) async {
        guard let runtime = try? await open() else { return }
        if let configDocument {
            _ = await runtime.applyConfiguration(configDocument)
        }
        var client: EluV1FlagClient?
        if let flagTransport {
            client = try? await runtime.flagClient(transport: flagTransport)
            if let client, let configDocument {
                _ = await client.applyConfig(configDocument)
            }
        }
        let snapshot = await runtime.currentSnapshot
        let accepted = withLock { () -> Bool in
            guard !isShutDown else { return false }
            started = Started(runtime: runtime, flags: client)
            bindPendingIntents(to: runtime)
            return true
        }
        guard accepted else { await client?.close(); await runtime.close(); return }
        await runtime.installNativeReplayComposition(lifecycle: nativeLifecycle, capabilities: EluStandaloneRuntime.readbackProvenReplayCapabilities, deferredUntilActivation: true)
        syncIdentity(snapshot.identity)
        if observeApplicationLifecycle { attachLifecycle(to: runtime) }
    }

    private func attachLifecycle(to runtime: EluStandaloneRuntime) {
        #if canImport(UIKit)
            // Application lifecycle events are on, per the facade contract.
            // Automatic screen views are not: this runtime installs no view
            // controller interception, so SwiftUI and UIKit screens are
            // reported through `Elu.screen`.
            let emitter = EluApplicationLifecycleEmitter(
                tracker: EluApplicationLifecycleTracker(sink: runtime.lifecycleSink()), nativeLifecycle: nativeLifecycle
            )
            lock.lock()
            let shuttingDown = isShutDown
            if !shuttingDown { lifecycleEmitter = emitter }
            lock.unlock()
            guard !shuttingDown else { return }
            emitter.attach()
        #endif
    }

    private func attachOwnedLifecycle() {
        #if canImport(UIKit)
            let emitter = EluApplicationLifecycleEmitter(
                tracker: EluApplicationLifecycleTracker(sink: EluStandaloneFacadeLifecycleSink(owner: self)), nativeLifecycle: nativeLifecycle)
            withLock { lifecycleEmitter = emitter }
            emitter.attach()
        #endif
    }

    fileprivate func applicationForegrounded(at occurredAt: Date, fromBackground: Bool) {
        setForeground(true)
        enqueue { runtime, _ in
            _ = await runtime.capture(EluStandaloneRuntime.applicationOpenedEvent,
                properties: [EluStandaloneRuntime.fromBackgroundProperty: .bool(fromBackground)],
                occurredAt: occurredAt)
            await runtime.markForegrounded()
        }
    }

    fileprivate func applicationBackgrounded(at occurredAt: Date) {
        setForeground(false)
        enqueue { runtime, _ in
            _ = await runtime.capture(EluStandaloneRuntime.applicationBackgroundedEvent, occurredAt: occurredAt)
            _ = await runtime.markBackgrounded(at: occurredAt)
        }
    }

    fileprivate func lifecycleScreen(_ name: String, at occurredAt: Date) {
        enqueue { runtime, _ in _ = await runtime.screen(name, occurredAt: occurredAt) }
    }

    func beginPendingOperation(_ op: EluBufferedOp) -> (() -> Void)? {
        if case let .consent(operation) = op { acceptConsent(operation) }
        guard op.changesFlagContext else { return nil }
        let pending = withLock { () -> EluStandaloneFacadePendingIntent? in
            guard !isShutDown else { return nil }
            flagGeneration = UUID()
            clearFlagsLocked()
            let pending = EluStandaloneFacadePendingIntent()
            if let runtime = started?.runtime { pending.bind(runtime) }
            pendingFlagIntents[pending.id] = pending
            return pending
        }
        guard let pending else { return nil }
        return { [weak self] in self?.finishPendingIntent(pending) }
    }

    func flagNotificationPredicate() -> (@Sendable () -> Bool)? {
        withLock {
            guard !isShutDown, pendingFlagIntents.isEmpty, flagsLoadedState else { return nil }
            let generation = flagGeneration
            let projection = flagCache
            return { [weak self] in
                self?.withLock {
                    guard let self, !self.isShutDown, self.pendingFlagIntents.isEmpty,
                          self.flagGeneration == generation, self.flagsLoadedState else { return false }
                    return projection?.authority.isCurrent() ?? true
                } ?? false
            }
        }
    }

    // MARK: - Facade operations

    func execute(_ op: EluBufferedOp) {
        switch op {
        case let .capture(event, properties):
            guard let name = EluFacadeJSON.identifier(event, maximumLength: 512) else {
                count(.invalidInput)
                return
            }
            let projected = project(properties)
            enqueue { runtime, owner in
                owner.record(await runtime.capture(name, properties: projected))
            }

        case let .screen(name, properties):
            guard let screen = EluFacadeJSON.identifier(name, maximumLength: 512) else {
                count(.invalidInput)
                return
            }
            let projected = project(properties)
            enqueue { runtime, owner in
                owner.record(await runtime.screen(screen, properties: projected))
            }

        case let .captureException(error, properties):
            // The error is serialized here, on the facade's own queue, so the
            // ordered chain carries only bounded JSON. Explicit properties win
            // over the derived ones.
            let exception = EluExceptionSerializer.properties(for: error)
                .merging(project(properties)) { _, explicit in explicit }
            enqueue { runtime, owner in
                owner.record(await runtime.captureException(properties: exception))
            }

        case let .identify(distinctId, userProperties, userPropertiesOnce):
            guard let userId = EluFacadeJSON.identifier(distinctId, maximumLength: 512) else {
                count(.invalidInput)
                return
            }
            let projected = project(userProperties), projectedOnce = project(userPropertiesOnce)
            // The synchronous getter follows call order: the new id is
            // reported from the moment `identify` is accepted, and the
            // projection is withdrawn once the call settles.
            projectIdentity { $0.projectedDistinctId = userId }
            enqueue(settlesProjection: true, affectsFlags: true) { runtime, owner in
                owner.apply(await runtime.identify(userId, properties: projected, propertiesOnce: projectedOnce))
                owner.scheduleFlagReload()
            }

        case let .alias(alias):
            guard let aliasId = EluFacadeJSON.identifier(alias, maximumLength: 512) else {
                count(.invalidInput)
                return
            }
            enqueue(affectsFlags: true) { runtime, owner in
                owner.apply(await runtime.alias(aliasId))
            }

        case let .register(properties):
            let projected = project(properties)
            guard !projected.isEmpty else { return }
            enqueue(affectsFlags: true) { runtime, owner in
                owner.apply(await runtime.registerSuperProperties(projected))
            }

        case let .registerOnce(properties, defaultValue):
            let projected = project(properties)
            guard !projected.isEmpty else { return }
            let projectedDefault = defaultValue.flatMap { EluFacadeJSON.value($0) }
            guard defaultValue == nil || projectedDefault != nil else {
                count(.invalidInput)
                return
            }
            enqueue(affectsFlags: true) { runtime, owner in
                owner.apply(await runtime.registerSuperProperties(projected,
                    onlyIfAbsent: true, defaultValue: projectedDefault))
            }

        case let .unregister(key):
            guard EluFacadeJSON.isStorableKey(key) else {
                count(.invalidInput)
                return
            }
            guard !EluFacadeJSON.isReservedKey(key) else { return }
            enqueue(affectsFlags: true) { runtime, owner in
                owner.apply(await runtime.unregisterSuperProperty(key))
            }

        case let .group(type, key, properties):
            guard let groupType = EluFacadeJSON.identifier(type, maximumLength: 256),
                  let groupKey = EluFacadeJSON.identifier(key, maximumLength: 512)
            else {
                count(.invalidInput)
                return
            }
            let projected = project(properties)
            enqueue(affectsFlags: true) { runtime, owner in
                owner.apply(
                    await runtime.group(type: groupType, key: groupKey, properties: projected)
                )
                // The association and its properties are part of the flag
                // evaluation context, so the next evaluation sees the group
                // the caller just described.
                owner.scheduleFlagReload()
            }

        case let .setPersonProperties(properties, propertiesOnce):
            let projected = project(properties), projectedOnce = project(propertiesOnce)
            guard !projected.isEmpty || !projectedOnce.isEmpty else { return }
            enqueue(affectsFlags: true) { runtime, owner in
                owner.apply(await runtime.setPersonProperties(projected, propertiesOnce: projectedOnce))
                owner.scheduleFlagReload()
            }

        case let .setPersonPropertiesForFlags(properties):
            let projected = project(properties)
            guard !projected.isEmpty else { return }
            enqueue(affectsFlags: true) { runtime, owner in
                owner.apply(await runtime.setFlagPersonProperties(projected))
                owner.scheduleFlagReload()
            }

        case let .setGroupPropertiesForFlags(type, properties):
            guard let groupType = EluFacadeJSON.identifier(type, maximumLength: 256) else {
                count(.invalidInput)
                return
            }
            let projected = project(properties)
            guard !projected.isEmpty else { return }
            enqueue(affectsFlags: true) { runtime, owner in
                owner.apply(
                    await runtime.setFlagGroupProperties(type: groupType, properties: projected)
                )
                owner.scheduleFlagReload()
            }

        case let .consent(operation):
            acceptConsent(operation)
            let properties = project(operation.properties)
            enqueue(affectsFlags: true) { runtime, owner in
                let snapshot = await runtime.setOptedOut(operation.optedOut, intent: operation.id)
                owner.apply(snapshot)
                guard snapshot != nil, !operation.optedOut else { return }
                owner.scheduleFlagReload()
                if let event = operation.event {
                    owner.record(await runtime.capture(event, properties: properties))
                }
            }

        case .resetGroups:
            enqueue(affectsFlags: true) { runtime, owner in
                owner.apply(await runtime.updateFlagContext(.resetGroups)); owner.scheduleFlagReload()
            }
        case .resetPersonPropertiesForFlags:
            enqueue(affectsFlags: true) { runtime, owner in
                owner.apply(await runtime.updateFlagContext(.resetPerson)); owner.scheduleFlagReload()
            }
        case let .resetGroupPropertiesForFlags(type):
            if let type, EluFacadeJSON.identifier(type, maximumLength: 256) == nil { count(.invalidInput); return }
            enqueue(affectsFlags: true) { runtime, owner in
                owner.apply(await runtime.updateFlagContext(.resetGroup(type))); owner.scheduleFlagReload()
            }
        case .reset:
            // The loaded flags belong to the identity that is ending, so a
            // read before the queued call runs must not report them or
            // attribute an exposure to the identity replacing it.
            projectIdentity { $0.clearFlagsLocked() }
            enqueue(settlesProjection: true, affectsFlags: true) { runtime, owner in
                owner.apply(await runtime.resetIdentity())
                owner.clearFlags()
                owner.scheduleFlagReload()
            }
        }
    }

    func activate() {
        lock.lock()
        let alreadyActive = !flagLoadDeferred || isShutDown
        flagLoadDeferred = false
        lock.unlock()
        guard !alreadyActive else { return }
        enqueue { runtime, owner in
            await runtime.activateNativeReplayComposition()
            await owner.loadFlags(runtime)
        }
    }

    func flush() {
        enqueue { runtime, _ in
            _ = await runtime.flush()
        }
    }

    func shutDown() {
        lock.lock()
        isShutDown = true
        flagGeneration = UUID()
        clearFlagsLocked()
        let currentStack = stack
        started?.runtime.invalidateAuthority()
        #if canImport(UIKit)
            let emitter = lifecycleEmitter
            lifecycleEmitter = nil
        #endif
        lock.unlock()
        currentStack?.close()
        #if canImport(UIKit)
            emitter?.detach()
        #endif
        enqueue(whileShutDown: true) { runtime, _ in
            await runtime.close()
        }
    }

    // MARK: - Getters

    private func acceptConsent(_ operation: EluConsentOperation) {
        guard operation.acceptOnce() else { return }
        withLock {
            consentProjection = (operation.id, operation.optedOut)
            started?.runtime.acceptConsentIntent(operation.id, optedOut: operation.optedOut)
        }
    }

    func isOptedOut() -> Bool {
        withLock { consentProjection?.optedOut ?? identity?.optedOut ?? false }
    }

    func distinctId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let projectedDistinctId { return projectedDistinctId }
        guard let identity else { return nil }
        return identity.userId ?? identity.anonymousId
    }

    func groups() -> [String: String] {
        withLock {
            guard !isShutDown, pendingFlagIntents.isEmpty, pendingIdentityOperations == 0,
                  !(consentProjection?.optedOut ?? identity?.optedOut ?? false) else { return [:] }
            return identity?.groups ?? [:]
        }
    }

    var flagsAreLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isShutDown && pendingFlagIntents.isEmpty && flagsLoadedState &&
            (flagCache?.authority.isCurrent() ?? true)
    }

    func featureFlag(_ key: String) -> Any? {
        guard let read = readFlag(key, reportsExposure: true) else { return nil }
        return EluFacadeJSON.flagValue(read.value)
    }

    func featureFlagPayload(_ key: String) -> Any? {
        // Payload reads do not report an exposure, matching the browser
        // facade and the current provider-backed behavior.
        guard let read = readFlag(key, reportsExposure: false),
              let payload = read.payload
        else {
            return nil
        }
        return EluFacadeJSON.payload(payload)
    }

    func featureFlagResult(_ key: String) -> EluFeatureFlagResult? {
        guard let read = readFlag(key, reportsExposure: true) else { return nil }
        return EluFeatureFlagResult(key: key, enabled: EluFacadeJSON.flagIsEnabled(read.value),
            variant: EluFacadeJSON.flagValue(read.value) as? String,
            payload: read.payload.map(EluFacadeJSON.payload))
    }

    func isFeatureEnabled(_ key: String) -> Bool {
        guard let read = readFlag(key, reportsExposure: true) else { return false }
        return EluFacadeJSON.flagIsEnabled(read.value)
    }

    func reloadFeatureFlags(_ completion: (() -> Void)?) {
        let callback = completion.map(EluFacadeCallback.init)
        // The completion is part of the facade contract: it runs once, on the
        // main queue, whatever the runtime does with the reload — including a
        // runtime that never opened.
        enqueue(
            whileShutDown: true,
            always: { callback?.deliverOnMainQueue() }
        ) { runtime, owner in
            guard !owner.isStopped else { return }
            await owner.reloadFlags(runtime)
        }
    }

    // MARK: - Flag snapshot, listeners, and exposure

    private func readFlag(
        _ key: String,
        reportsExposure: Bool
    ) -> (value: EluV1FlagValue, payload: EluV1FlagJSONValue?)? {
        guard !key.isEmpty else { return nil }
        lock.lock()
        guard !isShutDown, pendingFlagIntents.isEmpty, flagsLoadedState,
              let flagCache, flagCache.authority.isCurrent() else {
            lock.unlock()
            return nil
        }
        let lookup = flagCache.lookup(key)
        let generation = flagGeneration
        lock.unlock()

        switch lookup {
        case .missing:
            if reportsExposure { reportExposure(key, value: nil, payload: nil, projection: flagCache, generation: generation) }
            return nil
        case let .found(value, payload):
            if reportsExposure { reportExposure(key, value: value, payload: payload, projection: flagCache, generation: generation) }
            return (value, payload)
        }
    }

    /// Reports `$feature_flag_called` once per flag key and reported value for
    /// the current identity revision. A discarded report is withdrawn from the
    /// ledger so the next read of that value reports it again, as long as the
    /// identity revision that recorded it still stands.
    private func reportExposure(
        _ key: String,
        value: EluV1FlagValue?,
        payload: EluV1FlagJSONValue?,
        projection: EluV1FlagCacheProjection,
        generation: UUID
    ) {
        let ledgerKey = EluFacadeJSON.exposureKey(key, value: value)
        lock.lock()
        guard projectionIsCurrentLocked(projection, generation: generation), !exposures.contains(ledgerKey) else {
            lock.unlock()
            return
        }
        exposures.insert(ledgerKey)
        let revision = exposureIdentityRevision
        lock.unlock()

        var reported: [String: EluJSONValue] = ["$feature_flag": .string(key)]
        if let value {
            reported["$feature_flag_response"] = value.jsonValue.eluJSONValue
        } else {
            reported["$feature_flag_error"] = .string("flag_missing")
        }
        reported["$feature_flag_payload"] = payload?.eluJSONValue ?? .null
        let properties = reported

        enqueue { runtime, owner in
            let result = await runtime.capture("$feature_flag_called", properties: properties,
                admissionGuard: { owner.withLock { owner.projectionIsCurrentLocked(projection, generation: generation) } })
            owner.record(result)
            if case .rejected = result {
                owner.withdrawExposure(ledgerKey, recordedAt: revision)
            }
        }
    }

    private func withdrawExposure(_ ledgerKey: String, recordedAt revision: Int64?) {
        lock.lock()
        if exposureIdentityRevision == revision {
            exposures.remove(ledgerKey)
        }
        lock.unlock()
    }

    /// Reads the cached snapshot first so a launch reports the flags the last
    /// evaluation produced, then refreshes it.
    private func loadFlags(_ runtime: EluStandaloneRuntime) async {
        guard let client = currentFlagClient() else {
            publishFlagsLoaded()
            return
        }
        if let projection = await client.readProjection() { publish(projection) }
        await reloadFlags(runtime)
    }

    private func reloadFlags(_ runtime: EluStandaloneRuntime) async {
        guard let client = currentFlagClient() else {
            publishFlagsLoaded()
            return
        }
        for _ in 0 ..< Self.flagReloadAttempts {
            guard !isStopped else { return }
            if let projection = await client.reloadProjection() {
                publish(projection)
                return
            }
            guard !isStopped else { return }
        }
        publishFlagsLoaded()
    }

    private func scheduleFlagReload() {
        let alreadyScheduled = withLock { () -> Bool in
            guard !isShutDown, !flagLoadDeferred, !flagReloadScheduled else { return true }
            flagReloadScheduled = true
            return false
        }
        guard !alreadyScheduled else { return }
        enqueue { runtime, owner in
            owner.withLock { owner.flagReloadScheduled = false }
            await owner.reloadFlags(runtime)
        }
    }

    private func publish(_ projection: EluV1FlagCacheProjection) {
        lock.lock()
        guard !isShutDown, pendingFlagIntents.isEmpty, projection.authority.isCurrent() else { lock.unlock(); return }
        flagCache = projection
        flagsLoadedState = true
        let generation = flagGeneration
        lock.unlock()
        notifyFlags { [weak self] in
            self?.withLock { self?.projectionIsCurrentLocked(projection, generation: generation) ?? false } ?? false
        }
    }

    private func publishFlagsLoaded() {
        lock.lock()
        guard !isShutDown, pendingFlagIntents.isEmpty else { lock.unlock(); return }
        clearFlagsLocked()
        flagsLoadedState = true
        let generation = flagGeneration
        lock.unlock()
        notifyFlags { [weak self] in
            self?.withLock { self?.flagGeneration == generation && self?.isShutDown == false && self?.pendingFlagIntents.isEmpty == true } ?? false
        }
    }

    private func notifyFlags(_ isCurrent: @escaping @Sendable () -> Bool) {
        if let guardedFlagsDidLoad { guardedFlagsDidLoad(isCurrent) }
        else if isCurrent() { flagsDidLoad() }
    }

    private func projectionIsCurrentLocked(_ projection: EluV1FlagCacheProjection, generation: UUID) -> Bool {
        !isShutDown && pendingFlagIntents.isEmpty && flagGeneration == generation && projection.authority.isCurrent()
    }

    private func configurationIntent() {
        withLock { flagGeneration = UUID(); clearFlagsLocked() }
    }

    private func clearFlags() {
        lock.lock()
        clearFlagsLocked()
        lock.unlock()
    }

    private func clearFlagsLocked() {
        flagCache = nil
        flagsLoadedState = false
        exposures.removeAll(keepingCapacity: false)
    }

    private func currentFlagClient() -> EluV1FlagClient? {
        lock.lock()
        defer { lock.unlock() }
        return started?.flags
    }

    // MARK: - Identity mirror

    private func apply(_ snapshot: EluRuntimeQueueSnapshot?) {
        guard let snapshot else {
            count(.unauthorized)
            return
        }
        syncIdentity(snapshot.identity)
    }

    private func syncIdentity(_ next: EluIdentityState) {
        lock.lock()
        identity = next
        if exposureIdentityRevision != next.revision {
            exposures.removeAll(keepingCapacity: false)
            exposureIdentityRevision = next.revision
        }
        lock.unlock()
    }

    private func projectIdentity(_ project: (EluStandaloneFacadeRuntime) -> Void) {
        lock.lock()
        pendingIdentityOperations += 1
        project(self)
        lock.unlock()
    }

    private func settleIdentityProjection() {
        lock.lock()
        if pendingIdentityOperations > 0 { pendingIdentityOperations -= 1 }
        if pendingIdentityOperations == 0 { projectedDistinctId = nil }
        lock.unlock()
    }

    private func record(_ result: EluV1CaptureResult) {
        switch result {
        case let .accepted(_, snapshot):
            syncIdentity(snapshot.identity)
        case let .rejected(rejection, snapshot):
            syncIdentity(snapshot.identity)
            switch rejection {
            case .invalidEvent:
                count(.invalidInput)
            case .queueLimit, .storageProvenNotCommitted, .storageOutcomeUnknown:
                count(.storage)
            default:
                count(.unauthorized)
            }
        }
    }

    // MARK: - Ordering

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isShutDown
    }

    /// Chains one runtime call behind every call handed over before it. The
    /// chain is the ordering guarantee: nothing here runs concurrently with
    /// another facade call against the same runtime.
    private func enqueue(
        settlesProjection: Bool = false,
        affectsFlags: Bool = false,
        whileShutDown: Bool = false,
        always: (@Sendable () -> Void)? = nil,
        _ operation: @escaping @Sendable (EluStandaloneRuntime, EluStandaloneFacadeRuntime)
            async -> Void
    ) {
        lock.lock()
        let pending: EluStandaloneFacadePendingIntent?
        if affectsFlags {
            flagGeneration = UUID()
            clearFlagsLocked()
            let value = EluStandaloneFacadePendingIntent()
            if let runtime = started?.runtime { value.bind(runtime) }
            pendingFlagIntents[value.id] = value
            pending = value
        } else { pending = nil }
        let previous = tail
        tailVersion = UUID()
        tail = Task { [weak self] in
            await previous?.value
            guard let self else {
                always?()
                return
            }
            defer {
                if settlesProjection { self.settleIdentityProjection() }
                if let pending { self.finishPendingIntent(pending) }
                always?()
            }
            guard whileShutDown || !self.isStopped else {
                self.count(.unauthorized)
                return
            }
            guard let runtime = self.currentRuntime() else {
                self.count(.storage)
                return
            }
            await operation(runtime, self)
            runtime.reevaluateNativeReplay()
        }
        lock.unlock()
    }

    /// Called only while the facade lock is held; no database work occurs.
    private func bindPendingIntents(to runtime: EluStandaloneRuntime) {
        runtime.performanceLifecycleIntent(foreground: foregroundIntent)
        runtime.bindNativeLifecycle(nativeLifecycle)
        for intent in pendingFlagIntents.values { intent.bind(runtime) }
        if let consentProjection { runtime.acceptConsentIntent(consentProjection.id, optedOut: consentProjection.optedOut) }
    }

    private func finishPendingIntent(_ intent: EluStandaloneFacadePendingIntent) {
        withLock {
            guard pendingFlagIntents.removeValue(forKey: intent.id) != nil else { return }
            intent.finish()
            flagGeneration = UUID()
        }
    }

    private func currentRuntime() -> EluStandaloneRuntime? {
        lock.lock()
        defer { lock.unlock() }
        return started?.runtime
    }

    private func project(_ properties: [String: Any]?) -> [String: EluJSONValue] {
        let projected = EluFacadeJSON.properties(properties)
        count(.reservedProperty, times: projected.reserved)
        count(.invalidInput, times: projected.invalid)
        return projected.properties
    }

    private func count(_ reason: EluFacadeDropReason, times: Int = 1) {
        guard times > 0 else { return }
        lock.lock()
        dropped[reason, default: 0] += times
        lock.unlock()
    }

    /// Calls discarded since construction, by reason.
    var dropCounts: [EluFacadeDropReason: Int] {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    /// Resolves once every call handed over so far has reached the runtime.
    func settled() async {
        while true {
            let (current, version) = withLock { (tail, tailVersion) }
            await current?.value
            if withLock({ tailVersion == version }) { return }
        }
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private extension EluV1FlagJSONValue {
    /// Projects a decoded flag value onto the runtime's own JSON domain so it
    /// can be carried on an exposure event.
    var eluJSONValue: EluJSONValue {
        switch self {
        case .null:
            return .null
        case let .bool(value):
            return .bool(value)
        case let .number(value):
            return value.isFinite ? .number(value) : .null
        case let .string(units):
            return .string(String(decoding: units, as: UTF16.self))
        case let .array(values):
            return .array(values.map(\.eluJSONValue))
        case let .object(members):
            var object: [String: EluJSONValue] = [:]
            object.reserveCapacity(members.count)
            for member in members {
                object[String(decoding: member.name, as: UTF16.self)] = member.value.eluJSONValue
            }
            return .object(object)
        }
    }
}

/// Carries a customer callback across the ordered chain. The facade owns when
/// the callback runs — always once, on the main queue — so the callback itself
/// never has to be safe to call from the chain's execution context.
private final class EluFacadeCallback: @unchecked Sendable {
    private let body: () -> Void

    init(_ body: @escaping () -> Void) {
        self.body = body
    }

    func deliverOnMainQueue() {
        let body = self.body
        DispatchQueue.main.async(execute: body)
    }
}

private final class EluStandaloneFacadePendingIntent: @unchecked Sendable {
    let id = UUID()
    private var runtime: EluStandaloneRuntime?
    private var token: EluStandaloneFlagProjectionIntent?
    private var nativeToken: EluNativeReplayIntent?
    func bind(_ owner: EluStandaloneRuntime) {
        guard runtime == nil else { return }
        runtime = owner
        token = owner.beginFlagProjectionIntent()
        nativeToken = owner.beginNativeProjectionIntent()
    }
    func finish() {
        if let runtime, let token { runtime.finishFlagProjectionIntent(token) }
        if let runtime, let nativeToken { runtime.finishNativeProjectionIntent(nativeToken) }
        runtime = nil
        token = nil
        nativeToken = nil
    }
}

/// One lifecycle source drives source availability and ordered local runtime
/// facts. It owns no transport, provider, or authority of its own.
private final class EluStandaloneFacadeLifecycleSink: EluRuntimeLifecycleSink, @unchecked Sendable {
    private weak var owner: EluStandaloneFacadeRuntime?
    init(owner: EluStandaloneFacadeRuntime) { self.owner = owner }
    func applicationForegrounded(at occurredAt: Date, fromBackground: Bool) {
        owner?.applicationForegrounded(at: occurredAt, fromBackground: fromBackground)
    }
    func applicationBackgrounded(at occurredAt: Date) { owner?.applicationBackgrounded(at: occurredAt) }
    func screenViewed(_ name: String, at occurredAt: Date) { owner?.lifecycleScreen(name, at: occurredAt) }
}
