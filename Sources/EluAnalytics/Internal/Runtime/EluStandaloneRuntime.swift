import Foundation

enum EluStandaloneRuntimeError: Error, Equatable, Sendable {
    case invalidSiteKey
}

/// Where the runtime stands with respect to capture authority.
enum EluStandaloneRuntimePhase: Equatable, Sendable {
    case awaitingConfiguration
    case capturing
    case blocked(EluV1CaptureAuthorityTerminalReason)
    case closed
}

enum EluStandaloneConfigurationOutcome: Equatable, Sendable {
    case capturing(EluV1CaptureAuthoritySnapshot)
    case blocked(EluV1CaptureAuthorityTerminal)
    case closed
}

enum EluStandaloneDeliveryOutcome: Equatable, Sendable {
    /// No activated authority: nothing is sent and queued records stay durable.
    case unavailable
    case triggered(EluV1BatchDeliveryTriggerResult)
}

/// Application-level signals the lifecycle emitters feed into the runtime.
protocol EluRuntimeLifecycleSink: AnyObject, Sendable {
    func applicationForegrounded(at occurredAt: Date, fromBackground: Bool)
    func applicationBackgrounded(at occurredAt: Date)
    func screenViewed(_ name: String, at occurredAt: Date)
}

/// The finite execution window a backgrounded runtime hands one delivery pass
/// to. `start` returns false when no window could be obtained, in which case
/// the records stay durable until the next foreground pass.
struct EluStandaloneBackgroundHandoff: Sendable {
    let start: @Sendable (_ operation: @escaping @Sendable () async -> Void) async -> Bool
    let cancel: @Sendable () async -> Void
}

#if canImport(UIKit)
extension EluStandaloneBackgroundHandoff {
    /// Runs each backgrounded pass under one application background task that
    /// ends exactly once, whatever way the pass terminates.
    @MainActor
    static func applicationBackgroundTask(
        manager: any EluV1IOSBackgroundTaskManaging
    ) -> EluStandaloneBackgroundHandoff {
        let adapter = EluV1BatchBackgroundAdapter(manager: manager)
        return EluStandaloneBackgroundHandoff(
            start: { operation in
                await MainActor.run { adapter.start { await operation() } }
            },
            cancel: {
                await MainActor.run { adapter.cancel() }
            }
        )
    }
}
#endif

/// Carries the privacy state produced inside the queue operation back to the
/// runtime so delivery is authorized against the same identity witness.
private final class EluStandaloneProjectionHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (stateData: Data, witness: EluIdentitySnapshot)?

    func store(stateData: Data, witness: EluIdentitySnapshot) {
        lock.lock()
        stored = (stateData, witness)
        lock.unlock()
    }

    var value: (stateData: Data, witness: EluIdentitySnapshot)? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Composes the durable queue actor, privacy projection, capture authority,
/// and batch delivery into one standalone event runtime. Nothing in the public
/// facade constructs this type; it is reachable only from tests.
///
/// The queue actor serializes every identity, session, and record mutation.
/// Disk work runs on that actor and network work on the transport, so no
/// entry point here blocks the caller or touches the main actor except to
/// obtain a background execution window.
actor EluStandaloneRuntime {
    static let defaultFlushDelayNanoseconds: UInt64 = 10_000_000_000
    static let screenNameProperty = "$screen_name"
    static let applicationOpenedEvent = "Application Opened"
    static let applicationBackgroundedEvent = "Application Backgrounded"
    static let fromBackgroundProperty = "from_background"
    /// This runtime renders no replay frames, so every masking axis the policy
    /// can require is satisfied by construction.
    static let appliedMasking = EluPrivacyMaskingCapability(
        text: .all,
        inputs: .all,
        images: .block
    )

    private let queue: EluSQLiteRuntimeQueue
    private let siteKey: String
    private let versions: EluVersionContext
    private let configManager: EluV1ConfigManager
    private let transport: any EluV1BatchHTTPTransport
    private let backgroundHandoff: EluStandaloneBackgroundHandoff?
    private let clock: @Sendable () -> Date
    private let time: EluV1BatchTimeSource
    private let randomUnit: @Sendable () -> Double
    private let timeZoneIdentifier: @Sendable () -> String?
    private let replaySampleDraw: @Sendable () -> Double
    private let flushDelayNanoseconds: UInt64

    private var phase: EluStandaloneRuntimePhase = .awaitingConfiguration
    private var coordinator: EluV1BatchDeliveryCoordinator?
    private var flushTimer: Task<Void, Never>?
    private var lastSnapshot: EluRuntimeQueueSnapshot
    private var configurationTicket: UInt64 = 0
    private var appliedConfigurationTicket: UInt64 = 0
    /// The newest document the owner submitted that was not superseded by a
    /// newer one already held here. Identity changes resubmit it so authority
    /// is rederived against the witness they produced.
    private var configurationDocument: Data?

    private init(
        queue: EluSQLiteRuntimeQueue,
        initialSnapshot: EluRuntimeQueueSnapshot,
        siteKey: String,
        versions: EluVersionContext,
        transport: any EluV1BatchHTTPTransport,
        backgroundHandoff: EluStandaloneBackgroundHandoff?,
        clock: @escaping @Sendable () -> Date,
        time: EluV1BatchTimeSource,
        randomUnit: @escaping @Sendable () -> Double,
        timeZoneIdentifier: @escaping @Sendable () -> String?,
        replaySampleDraw: @escaping @Sendable () -> Double,
        flushDelayNanoseconds: UInt64
    ) {
        self.queue = queue
        lastSnapshot = initialSnapshot
        self.siteKey = siteKey
        self.versions = versions
        configManager = EluV1ConfigManager()
        self.transport = transport
        self.backgroundHandoff = backgroundHandoff
        self.clock = clock
        self.time = time
        self.randomUnit = randomUnit
        self.timeZoneIdentifier = timeZoneIdentifier
        self.replaySampleDraw = replaySampleDraw
        self.flushDelayNanoseconds = flushDelayNanoseconds
    }

    /// Opens the site-scoped durable queue off the main actor and composes the
    /// runtime over it. The site key is the bearer routing credential, so it
    /// must be a header-safe value.
    static func make(
        rootDirectoryURL: URL,
        siteKey: String,
        versions: EluVersionContext? = nil,
        limits: EluRuntimeQueueLimits? = nil,
        transport: any EluV1BatchHTTPTransport = EluV1URLSessionBatchTransport(),
        backgroundHandoff: EluStandaloneBackgroundHandoff? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        continuousClock: @escaping @Sendable () -> UInt64 = EluMachContinuousClock.now,
        continuousBudgetConverter: @escaping @Sendable (UInt64) -> UInt64? =
            EluMachContinuousClock.floorTicks,
        time: EluV1BatchTimeSource = .system,
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0 ... 1) },
        timeZoneIdentifier: @escaping @Sendable () -> String? = { TimeZone.current.identifier },
        replaySampleDraw: @escaping @Sendable () -> Double = { Double.random(in: 0 ..< 1) },
        flushDelayNanoseconds: UInt64 = EluStandaloneRuntime.defaultFlushDelayNanoseconds,
        anonymousIdGenerator: @escaping @Sendable () -> String = {
            "anon_\(EluStandaloneRuntime.compactUUID())"
        },
        streamIdGenerator: @escaping @Sendable () -> String = {
            "stream_\(EluStandaloneRuntime.compactUUID())"
        },
        sessionIdGenerator: @escaping @Sendable () -> String = {
            "session_\(EluStandaloneRuntime.compactUUID())"
        }
    ) async throws -> EluStandaloneRuntime {
        guard isHeaderSafeSiteKey(siteKey) else {
            throw EluStandaloneRuntimeError.invalidSiteKey
        }
        let resolvedVersions = try versions ?? defaultVersions()
        let resolvedLimits = try limits ?? EluRuntimeQueueLimits()
        let resolvedHandoff: EluStandaloneBackgroundHandoff?
        #if canImport(UIKit)
        if let backgroundHandoff {
            resolvedHandoff = backgroundHandoff
        } else {
            resolvedHandoff = await MainActor.run {
                EluStandaloneBackgroundHandoff.applicationBackgroundTask(
                    manager: EluV1UIApplicationBackgroundTaskManager()
                )
            }
        }
        #else
        resolvedHandoff = backgroundHandoff
        #endif

        let queue = try await EluSQLiteRuntimeQueue.openCaptureRuntime(
            rootDirectoryURL: rootDirectoryURL,
            exactConstructorSiteKey: siteKey,
            limits: resolvedLimits,
            clock: clock,
            continuousClock: continuousClock,
            continuousBudgetConverter: continuousBudgetConverter,
            anonymousIdGenerator: anonymousIdGenerator,
            streamIdGenerator: streamIdGenerator,
            sessionIdGenerator: sessionIdGenerator
        )
        let initialSnapshot: EluRuntimeQueueSnapshot
        do {
            initialSnapshot = try await queue.snapshot()
        } catch {
            await queue.close()
            throw error
        }
        return EluStandaloneRuntime(
            queue: queue,
            initialSnapshot: initialSnapshot,
            siteKey: siteKey,
            versions: resolvedVersions,
            transport: transport,
            backgroundHandoff: resolvedHandoff,
            clock: clock,
            time: time,
            randomUnit: randomUnit,
            timeZoneIdentifier: timeZoneIdentifier,
            replaySampleDraw: replaySampleDraw,
            flushDelayNanoseconds: flushDelayNanoseconds
        )
    }

    static func defaultVersions() throws -> EluVersionContext {
        try EluVersionContext(
            runtime: EluVersionComponent(name: "elu-ios", version: EluCore.sdkVersion),
            facade: EluVersionComponent(name: "Elu", version: String(EluCore.facadeVersion))
        )
    }

    static func isHeaderSafeSiteKey(_ siteKey: String) -> Bool {
        let scalars = siteKey.unicodeScalars
        guard (1 ... 512).contains(scalars.count) else { return false }
        return scalars.allSatisfy { scalar in
            switch scalar {
            case "a" ... "z", "A" ... "Z", "0" ... "9", ".", "_", "~", "-":
                return true
            default:
                return false
            }
        }
    }

    private static func compactUUID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    var currentPhase: EluStandaloneRuntimePhase { phase }

    var hasDeliveryAuthorization: Bool { coordinator != nil }

    /// The last identity, session, and queue state this runtime committed.
    var currentSnapshot: EluRuntimeQueueSnapshot { lastSnapshot }

    /// Composes the owned flag client over the same site-scoped store the
    /// capture path writes to, so flag evaluation reads the identity, groups,
    /// and flag context every capture is attributed to. The network transport
    /// stays a caller-supplied boundary.
    func flagClient(transport: any EluV1FlagTransport) async throws -> EluV1FlagClient {
        try await EluV1FlagClient.make(
            runtime: queue,
            transport: transport,
            versions: versions
        )
    }

    func queueSnapshot() async throws -> EluRuntimeQueueSnapshot {
        let snapshot = try await queue.snapshot()
        lastSnapshot = snapshot
        return snapshot
    }

    /// Validates one raw config document, projects the effective privacy state
    /// for the identity witness read inside the same queue operation, and
    /// activates or terminates capture authority. An activated authority also
    /// installs a delivery coordinator bound to that config's endpoint, expiry,
    /// and batch limits; anything else retires delivery.
    func applyConfiguration(_ configData: Data) async -> EluStandaloneConfigurationOutcome {
        guard phase != .closed else { return .closed }
        let acceptedDocument = configurationDocument
        configurationDocument = configData
        let outcome = await submitConfiguration(configData)
        // A document older than the newest validated one installs nothing, so
        // the document the queue accepted stays the one every later renewal
        // resubmits. Every other verdict fails closed and keeps the document
        // that produced it.
        if case let .blocked(terminal) = outcome, terminal.reason == .stale {
            configurationDocument = acceptedDocument
        }
        return outcome
    }

    private func submitConfiguration(_ configData: Data) async -> EluStandaloneConfigurationOutcome {
        configurationTicket += 1
        let ticket = configurationTicket
        let now = clock()
        let handoff = EluStandaloneProjectionHandoff()
        let manager = configManager
        let readTimeZoneIdentifier = timeZoneIdentifier
        let drawReplaySample = replaySampleDraw
        let result = await queue.submitCaptureAuthority(configData: configData) { witness in
            Self.projectPrivacyState(
                configData: configData,
                witness: witness,
                now: now,
                manager: manager,
                timeZoneIdentifier: readTimeZoneIdentifier(),
                replaySampleDraw: drawReplaySample(),
                handoff: handoff
            )
        }
        guard phase != .closed else { return .closed }
        // Queue operations are applied in call order; a continuation that
        // resumes after a newer document has already been applied must not
        // overwrite the newer delivery decision.
        guard ticket > appliedConfigurationTicket else {
            return Self.outcome(for: result)
        }
        appliedConfigurationTicket = ticket

        switch result {
        case let .activated(authority):
            // Every transition below is decided without a further suspension,
            // so a slower continuation can never reinstate an older decision
            // over a newer one.
            phase = .capturing
            if let projection = handoff.value {
                await installDelivery(
                    privacyStateData: projection.stateData,
                    witness: projection.witness,
                    now: now
                )
            } else {
                await retireDelivery()
            }
            return .capturing(authority)
        case let .terminated(terminal):
            phase = .blocked(terminal.reason)
            await retireDelivery()
            return .blocked(terminal)
        }
    }

    func capture(
        _ name: String,
        properties: [String: EluJSONValue] = [:],
        occurredAt: Date? = nil
    ) async -> EluV1CaptureResult {
        await submit(
            EluV1CaptureCommand(
                kind: .capture,
                name: name,
                occurredAt: occurredAt ?? clock(),
                properties: properties,
                versions: versions
            )
        )
    }

    func screen(
        _ name: String,
        properties: [String: EluJSONValue] = [:],
        occurredAt: Date? = nil
    ) async -> EluV1CaptureResult {
        var merged = properties
        merged[Self.screenNameProperty] = .string(name)
        return await submit(
            EluV1CaptureCommand(
                kind: .screen,
                name: name,
                occurredAt: occurredAt ?? clock(),
                properties: merged,
                versions: versions
            )
        )
    }

    /// Records an exception whose fields the caller already serialized. The
    /// facade serializes on its own queue so no `Error` reference crosses into
    /// the runtime.
    func captureException(
        properties: [String: EluJSONValue],
        occurredAt: Date? = nil
    ) async -> EluV1CaptureResult {
        await submit(
            EluV1CaptureCommand(
                kind: .exception,
                name: EluExceptionSerializer.eventName,
                occurredAt: occurredAt ?? clock(),
                properties: properties,
                versions: versions
            )
        )
    }

    /// Serializes the error on the caller's side so only bounded, JSON-safe
    /// fields cross into the runtime.
    nonisolated func captureException(
        _ error: any Error,
        properties: [String: EluJSONValue] = [:],
        occurredAt: Date? = nil
    ) async -> EluV1CaptureResult {
        let command = EluExceptionSerializer.command(
            for: error,
            occurredAt: occurredAt ?? clock(),
            versions: versions,
            explicitProperties: properties
        )
        return await submit(command)
    }

    // MARK: - Identity

    /// Links this device's activity to a customer-supplied id and carries the
    /// supplied properties into the person state flag evaluation reads.
    @discardableResult
    func identify(
        _ userId: String,
        properties: [String: EluJSONValue] = [:]
    ) async -> EluRuntimeQueueSnapshot? {
        await mutate(.identify(userId: userId, set: properties, setOnce: [:]))
    }

    /// Links a second id to the identified one. The queue rejects an alias
    /// raised before an identity exists, because there is nothing to link to.
    @discardableResult
    func alias(_ aliasId: String) async -> EluRuntimeQueueSnapshot? {
        await mutate(.linkAlias(aliasId: aliasId))
    }

    @discardableResult
    func setPersonProperties(
        _ properties: [String: EluJSONValue]
    ) async -> EluRuntimeQueueSnapshot? {
        guard !properties.isEmpty else { return nil }
        return await mutate(.setPersonProperties(set: properties, setOnce: [:], unset: []))
    }

    /// Associates a group, and describes it in the same transition when
    /// properties are supplied.
    @discardableResult
    func group(
        type: String,
        key: String,
        properties: [String: EluJSONValue] = [:]
    ) async -> EluRuntimeQueueSnapshot? {
        if properties.isEmpty {
            return await mutate(.associateGroup(groupType: type, groupKey: key))
        }
        return await mutate(
            .group(groupType: type, groupKey: key, set: properties, setOnce: [:], unset: [])
        )
    }

    @discardableResult
    func registerSuperProperties(
        _ properties: [String: EluJSONValue]
    ) async -> EluRuntimeQueueSnapshot? {
        guard phase == .capturing, !properties.isEmpty else { return nil }
        guard let snapshot = try? await queue.registerStandaloneSuperProperties(properties) else {
            return nil
        }
        return await commit(snapshot)
    }

    @discardableResult
    func unregisterSuperProperty(_ key: String) async -> EluRuntimeQueueSnapshot? {
        guard phase == .capturing else { return nil }
        guard let snapshot = try? await queue.unregisterStandaloneSuperProperty(key) else {
            return nil
        }
        return await commit(snapshot)
    }

    @discardableResult
    func setFlagPersonProperties(
        _ properties: [String: EluJSONValue]
    ) async -> EluRuntimeQueueSnapshot? {
        guard phase == .capturing, !properties.isEmpty else { return nil }
        guard let generation = try? await queue.snapshot().generation,
              let snapshot = try? await queue.setFlagPersonProperties(
                  properties,
                  versions: versions,
                  expectedGeneration: generation
              )
        else {
            return nil
        }
        return await commit(snapshot)
    }

    /// Group properties describe the group this device is currently
    /// associated with, so a type with no association has nothing to describe.
    @discardableResult
    func setFlagGroupProperties(
        type: String,
        properties: [String: EluJSONValue]
    ) async -> EluRuntimeQueueSnapshot? {
        guard phase == .capturing, !properties.isEmpty else { return nil }
        guard let snapshot = try? await queue.snapshot(),
              let key = snapshot.identity.groups[type]
        else {
            return nil
        }
        return await mutate(
            .setGroupProperties(
                groupType: type,
                groupKey: key,
                set: properties,
                setOnce: [:],
                unset: []
            )
        )
    }

    /// Ends the current identity: a fresh anonymous id is minted and groups,
    /// super properties, session, and flag context are cleared. Unlike every
    /// other identity call this is allowed without capture authority, because
    /// it only discards identity and enqueues nothing.
    @discardableResult
    func resetIdentity() async -> EluRuntimeQueueSnapshot? {
        guard phase != .closed else { return nil }
        guard let generation = try? await queue.snapshot().generation,
              let snapshot = try? await queue.reset(expectedGeneration: generation)
        else {
            return nil
        }
        return await commit(snapshot)
    }

    /// An identity mutation is a durable write, so it needs the same capture
    /// authority a captured event needs. A blocked, revoked, or expired
    /// runtime stores no identity at all.
    private func mutate(
        _ transition: EluRuntimeMutationTransition
    ) async -> EluRuntimeQueueSnapshot? {
        guard phase == .capturing else { return nil }
        guard let generation = try? await queue.snapshot().generation,
              let snapshot = try? await queue.applyOwnedMutation(
                  transition,
                  versions: versions,
                  expectedGeneration: generation
              )
        else {
            return nil
        }
        return await commit(snapshot)
    }

    /// Identity, super-property, group, and flag-context changes each advance
    /// the context revision capture authority is bound to, so the stored
    /// document is resubmitted before the next capture can proceed.
    private func commit(_ snapshot: EluRuntimeQueueSnapshot) async -> EluRuntimeQueueSnapshot? {
        lastSnapshot = snapshot
        guard let configurationDocument else { return snapshot }
        _ = await submitConfiguration(configurationDocument)
        if let renewed = try? await queue.snapshot() {
            lastSnapshot = renewed
        }
        return lastSnapshot
    }

    /// Persists the background transition first, then hands one bounded
    /// delivery pass to the background execution window.
    func markBackgrounded(at occurredAt: Date? = nil) async -> EluV1BackgroundResult? {
        guard phase != .closed else { return nil }
        let result = try? await queue.markStandaloneBackgrounded(at: occurredAt ?? clock())
        switch result {
        case let .changed(snapshot)?, let .unchanged(snapshot)?, let .rejectedOptedOut(snapshot)?:
            lastSnapshot = snapshot
        case nil:
            break
        }
        await startBackgroundPass()
        return result
    }

    /// Foreground starts a fresh pass from durable storage; an in-flight
    /// background pass is coalesced by the coordinator rather than duplicated.
    func markForegrounded() {
        guard phase != .closed else { return }
        scheduleFlush()
    }

    /// Triggers delivery now; without an activated authority nothing is sent.
    func flush() async -> EluStandaloneDeliveryOutcome {
        guard let coordinator else { return .unavailable }
        return .triggered(await coordinator.trigger())
    }

    nonisolated func lifecycleSink() -> EluStandaloneLifecycleSink {
        EluStandaloneLifecycleSink(runtime: self)
    }

    /// Idempotent. Retires delivery, releases the background window, and
    /// closes the queue so another runtime may own the same site directory.
    func close() async {
        guard phase != .closed else { return }
        phase = .closed
        configurationDocument = nil
        flushTimer?.cancel()
        flushTimer = nil
        await retireDelivery()
        await backgroundHandoff?.cancel()
        await queue.close()
    }

    private func submit(_ command: EluV1CaptureCommand) async -> EluV1CaptureResult {
        guard phase != .closed else {
            return .rejected(.authorityAbsent, snapshot: lastSnapshot)
        }
        var result = await record(command)
        // Authority is bound to the identity witness it was derived from. If
        // that witness moved under this call, one renewal decides whether the
        // call proceeds or is discarded with the new reason.
        if case .rejected(.authorityWitnessChanged, _) = result,
           let configurationDocument
        {
            _ = await submitConfiguration(configurationDocument)
            guard phase != .closed else {
                return .rejected(.authorityAbsent, snapshot: lastSnapshot)
            }
            result = await record(command)
        }
        return result
    }

    private func record(_ command: EluV1CaptureCommand) async -> EluV1CaptureResult {
        let result = await queue.capture(command)
        switch result {
        case let .accepted(_, snapshot):
            lastSnapshot = snapshot
            armFlushTimer()
        case let .rejected(_, snapshot):
            lastSnapshot = snapshot
        }
        return result
    }

    private func armFlushTimer() {
        guard flushTimer == nil, phase != .closed else { return }
        let delay = flushDelayNanoseconds
        let sleep = time.sleep
        flushTimer = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            await self?.flushTimerFired()
        }
    }

    private func flushTimerFired() async {
        flushTimer = nil
        _ = await flush()
    }

    private func scheduleFlush() {
        Task { [weak self] in
            _ = await self?.flush()
        }
    }

    private func startBackgroundPass() async {
        guard phase != .closed, coordinator != nil else { return }
        guard let backgroundHandoff else {
            scheduleFlush()
            return
        }
        _ = await backgroundHandoff.start { [weak self] in
            _ = await self?.flush()
        }
    }

    private func installDelivery(
        privacyStateData: Data,
        witness: EluIdentitySnapshot,
        now: Date
    ) async {
        let replacement: EluV1BatchDeliveryCoordinator
        do {
            let resolution = try configManager.authorize(
                effectivePrivacyStateData: privacyStateData,
                identity: witness,
                now: now
            )
            guard resolution.captureAuthorization == .authorized,
                  let eventsEndpoint = resolution.endpoints[.events]
            else {
                await retireDelivery()
                return
            }
            let authorization = try EluV1BatchAuthorizationSnapshot(
                siteKey: siteKey,
                eventsEndpoint: eventsEndpoint,
                expiresAt: resolution.expiresAt,
                eventBatchCount: resolution.limits.eventBatchCount,
                eventBatchBytes: resolution.limits.eventBatchBytes
            )
            replacement = EluV1BatchDeliveryCoordinator(
                queue: queue,
                authorization: authorization,
                transport: transport,
                time: time,
                randomUnit: randomUnit
            )
        } catch {
            await retireDelivery()
            return
        }
        let previous = coordinator
        coordinator = replacement
        await previous?.cancel()
    }

    private func retireDelivery() async {
        guard let previous = coordinator else { return }
        coordinator = nil
        await previous.cancel()
    }

    private static func outcome(
        for result: EluV1CaptureAuthorityUpdateResult
    ) -> EluStandaloneConfigurationOutcome {
        switch result {
        case let .activated(authority):
            return .capturing(authority)
        case let .terminated(terminal):
            return .blocked(terminal)
        }
    }

    /// Runs inside the queue operation. A document the manager rejects or that
    /// is not enabled yields no privacy state; the queue then classifies the
    /// same document and terminates authority with the matching reason.
    private static func projectPrivacyState(
        configData: Data,
        witness: EluRuntimeQueueSnapshot,
        now: Date,
        manager: EluV1ConfigManager,
        timeZoneIdentifier: String?,
        replaySampleDraw: Double,
        handoff: EluStandaloneProjectionHandoff
    ) -> Data? {
        do {
            guard case .enabled = try manager.update(configData: configData, now: now) else {
                return nil
            }
            let projected = try EluPrivacyStateProjector.project(
                context: try manager.activePrivacyProjectionContext(now: now),
                input: EluPrivacyProjectionInput(
                    contextRevision: witness.identity.contextRevision,
                    identityOptedOut: witness.identity.optedOut,
                    timeZoneIdentifier: timeZoneIdentifier,
                    evaluatedAt: now,
                    appliedMasking: appliedMasking,
                    replaySampleDraw: replaySampleDraw,
                    replaySessionEligible: false,
                    replayBudgetRemainingSeconds: 0,
                    localReplayTransports: []
                )
            )
            handoff.store(
                stateData: projected.stateData,
                witness: EluIdentitySnapshot(
                    identity: witness.identity,
                    streamId: witness.streamId,
                    nextSequence: witness.nextSequence,
                    flagContext: witness.flagContext
                )
            )
            return projected.stateData
        } catch {
            return nil
        }
    }
}

/// Orders lifecycle signals into the runtime. Notification handlers call it
/// synchronously from any thread; each signal is chained behind the previous
/// one so the queued records preserve emission order.
final class EluStandaloneLifecycleSink: EluRuntimeLifecycleSink, @unchecked Sendable {
    private let runtime: EluStandaloneRuntime
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    init(runtime: EluStandaloneRuntime) {
        self.runtime = runtime
    }

    func applicationForegrounded(at occurredAt: Date, fromBackground: Bool) {
        enqueue { runtime in
            _ = await runtime.capture(
                EluStandaloneRuntime.applicationOpenedEvent,
                properties: [EluStandaloneRuntime.fromBackgroundProperty: .bool(fromBackground)],
                occurredAt: occurredAt
            )
            await runtime.markForegrounded()
        }
    }

    func applicationBackgrounded(at occurredAt: Date) {
        // The event is ordered before the background transition so it lands
        // in the session being suspended; the same-instant transition then
        // records the background state.
        enqueue { runtime in
            _ = await runtime.capture(
                EluStandaloneRuntime.applicationBackgroundedEvent,
                occurredAt: occurredAt
            )
            _ = await runtime.markBackgrounded(at: occurredAt)
        }
    }

    func screenViewed(_ name: String, at occurredAt: Date) {
        enqueue { runtime in
            _ = await runtime.screen(name, occurredAt: occurredAt)
        }
    }

    /// Waits for every signal accepted so far to reach the runtime.
    func drain() async {
        lock.lock()
        let current = tail
        lock.unlock()
        await current?.value
    }

    private func enqueue(
        _ operation: @escaping @Sendable (EluStandaloneRuntime) async -> Void
    ) {
        let runtime = self.runtime
        lock.lock()
        let previous = tail
        tail = Task {
            await previous?.value
            await operation(runtime)
        }
        lock.unlock()
    }
}
