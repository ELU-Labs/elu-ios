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
    /// This runtime records no replay frames, so it offers no replay control
    /// and the facade's replay budget never applies to it.
    let replayControl: (any EluReplayControl)? = nil

    private let flagsDidLoad: () -> Void
    private let flagTransport: (any EluV1FlagTransport)?
    private let lock = NSLock()

    private var tail: Task<Void, Never>?
    private var started: Started?

    private var identity: EluIdentityState?
    private var projectedDistinctId: String?
    private var pendingIdentityOperations = 0

    private var flagCache: EluV1FlagCacheSnapshot?
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
        flagTransport: (any EluV1FlagTransport)? = nil
    ) {
        flagsDidLoad = context.flagsDidLoad
        self.flagTransport = flagTransport
        let document = context.configDocument
        tail = Task { [weak self] in
            await self?.start(open: open, configDocument: document)
        }
    }

    /// Opens the site-scoped runtime under the ELU support directory with the
    /// production transports.
    static func make(context: EluRuntimeBackendContext) -> EluStandaloneFacadeRuntime? {
        guard let rootDirectoryURL = runtimeDirectoryURL() else { return nil }
        let siteKey = context.siteKey
        return EluStandaloneFacadeRuntime(
            context: context,
            open: {
                try await EluStandaloneRuntime.make(
                    rootDirectoryURL: rootDirectoryURL,
                    siteKey: siteKey
                )
            }
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
        configDocument: Data?
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
        withLock { started = Started(runtime: runtime, flags: client) }
        syncIdentity(snapshot.identity)
        attachLifecycle(to: runtime)
    }

    private func attachLifecycle(to runtime: EluStandaloneRuntime) {
        #if canImport(UIKit)
            // Application lifecycle events are on, per the facade contract.
            // Automatic screen views are not: this runtime installs no view
            // controller interception, so SwiftUI and UIKit screens are
            // reported through `Elu.screen`.
            let emitter = EluApplicationLifecycleEmitter(
                tracker: EluApplicationLifecycleTracker(sink: runtime.lifecycleSink())
            )
            lock.lock()
            let shuttingDown = isShutDown
            if !shuttingDown { lifecycleEmitter = emitter }
            lock.unlock()
            guard !shuttingDown else { return }
            emitter.attach()
        #endif
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

        case let .identify(distinctId, userProperties):
            guard let userId = EluFacadeJSON.identifier(distinctId, maximumLength: 512) else {
                count(.invalidInput)
                return
            }
            let projected = project(userProperties)
            // The synchronous getter follows call order: the new id is
            // reported from the moment `identify` is accepted, and the
            // projection is withdrawn once the call settles.
            projectIdentity { $0.projectedDistinctId = userId }
            enqueue(settlesProjection: true) { runtime, owner in
                owner.apply(await runtime.identify(userId, properties: projected))
                owner.scheduleFlagReload()
            }

        case let .alias(alias):
            guard let aliasId = EluFacadeJSON.identifier(alias, maximumLength: 512) else {
                count(.invalidInput)
                return
            }
            enqueue { runtime, owner in
                owner.apply(await runtime.alias(aliasId))
            }

        case let .register(properties):
            let projected = project(properties)
            guard !projected.isEmpty else { return }
            enqueue { runtime, owner in
                owner.apply(await runtime.registerSuperProperties(projected))
            }

        case let .unregister(key):
            guard EluFacadeJSON.isStorableKey(key) else {
                count(.invalidInput)
                return
            }
            guard !EluFacadeJSON.isReservedKey(key) else { return }
            enqueue { runtime, owner in
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
            enqueue { runtime, owner in
                owner.apply(
                    await runtime.group(type: groupType, key: groupKey, properties: projected)
                )
                // The association and its properties are part of the flag
                // evaluation context, so the next evaluation sees the group
                // the caller just described.
                owner.scheduleFlagReload()
            }

        case let .setPersonProperties(properties):
            let projected = project(properties)
            guard !projected.isEmpty else { return }
            enqueue { runtime, owner in
                owner.apply(await runtime.setPersonProperties(projected))
                owner.scheduleFlagReload()
            }

        case let .setPersonPropertiesForFlags(properties):
            let projected = project(properties)
            guard !projected.isEmpty else { return }
            enqueue { runtime, owner in
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
            enqueue { runtime, owner in
                owner.apply(
                    await runtime.setFlagGroupProperties(type: groupType, properties: projected)
                )
                owner.scheduleFlagReload()
            }

        case .reset:
            // The loaded flags belong to the identity that is ending, so a
            // read before the queued call runs must not report them or
            // attribute an exposure to the identity replacing it.
            projectIdentity { $0.clearFlagsLocked() }
            enqueue(settlesProjection: true) { runtime, owner in
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
        #if canImport(UIKit)
            let emitter = lifecycleEmitter
            lifecycleEmitter = nil
        #endif
        lock.unlock()
        #if canImport(UIKit)
            emitter?.detach()
        #endif
        enqueue(whileShutDown: true) { runtime, _ in
            await runtime.close()
        }
    }

    // MARK: - Getters

    func distinctId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let projectedDistinctId { return projectedDistinctId }
        guard let identity else { return nil }
        return identity.userId ?? identity.anonymousId
    }

    var flagsAreLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flagsLoadedState
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
        guard !isShutDown, flagsLoadedState, let flagCache else {
            lock.unlock()
            return nil
        }
        let lookup = flagCache.lookup(key)
        lock.unlock()

        switch lookup {
        case .missing:
            if reportsExposure { reportExposure(key, value: nil, payload: nil) }
            return nil
        case let .found(value, payload):
            if reportsExposure { reportExposure(key, value: value, payload: payload) }
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
        payload: EluV1FlagJSONValue?
    ) {
        let ledgerKey = EluFacadeJSON.exposureKey(key, value: value)
        lock.lock()
        guard !exposures.contains(ledgerKey) else {
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
            let result = await runtime.capture("$feature_flag_called", properties: properties)
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
        if case let .hit(snapshot) = await client.readAll() {
            publish(snapshot)
        }
        await reloadFlags(runtime)
    }

    private func reloadFlags(_ runtime: EluStandaloneRuntime) async {
        guard let client = currentFlagClient() else {
            publishFlagsLoaded()
            return
        }
        for _ in 0 ..< Self.flagReloadAttempts {
            guard !isStopped else { return }
            switch await client.reload() {
            case let .updated(snapshot), let .cached(snapshot):
                publish(snapshot)
                return
            case .stale:
                // Superseded by an identity or configuration change; the next
                // attempt evaluates the current witness.
                continue
            case .restricted, .terminal:
                publishFlagsLoaded()
                return
            }
        }
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

    private func publish(_ snapshot: EluV1FlagCacheSnapshot) {
        lock.lock()
        flagCache = snapshot
        flagsLoadedState = true
        lock.unlock()
        flagsDidLoad()
    }

    /// Flags finished loading without a snapshot to publish. Registered
    /// callbacks still run: the contract is that they fire every time flags
    /// finish loading, not only when the values changed.
    private func publishFlagsLoaded() {
        lock.lock()
        flagsLoadedState = true
        lock.unlock()
        flagsDidLoad()
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
        whileShutDown: Bool = false,
        always: (@Sendable () -> Void)? = nil,
        _ operation: @escaping @Sendable (EluStandaloneRuntime, EluStandaloneFacadeRuntime)
            async -> Void
    ) {
        lock.lock()
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self else {
                always?()
                return
            }
            defer {
                if settlesProjection { self.settleIdentityProjection() }
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
        }
        lock.unlock()
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
        await withLock { tail }?.value
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
