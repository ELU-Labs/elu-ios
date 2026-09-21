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
/// and batch delivery into one internal standalone event runtime. Public
/// bootstrap and default backend selection are separate integration boundaries.
///
/// The queue actor serializes every identity, session, and record mutation.
/// Disk work runs on that actor and network work on the transport, so no
/// entry point here blocks the caller or touches the main actor except to
/// obtain a background execution window.
private final class EluStandaloneDeliveryFence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = UUID()
    private var closed = false
    private var consentIntent: UUID?
    private var consentDenied = false
    func acceptConsent(_ id: UUID, optedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        consentIntent = id; consentDenied = consentDenied || optedOut; value = UUID()
    }
    func isLatestConsent(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && consentIntent == id
    }
    func commitConsent(_ id: UUID, optedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard consentIntent == id else { return }
        consentDenied = optedOut; value = UUID()
    }
    func advance() -> UUID { lock.lock(); defer { lock.unlock() }; value = UUID(); return value }
    func token() -> UUID { lock.lock(); defer { lock.unlock() }; return value }
    func isCurrent(_ token: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return !closed && !consentDenied && token == value }
    func invalidate(_ token: UUID) { lock.lock(); if value == token { value = UUID() }; lock.unlock() }
    func close() { lock.lock(); closed = true; value = UUID(); lock.unlock() }
}

actor EluStandaloneRuntime {
    // Locally qualified recorder, stored readback, and playback support.
    // Remote configuration must still pass the independent admission gates.
    static let readbackProvenReplayCapabilities = EluNativeReplayCapabilities(
        readbackProvenTransports: [EluV1ReplayTransportSelection(
            codec: "elu-native-wireframe-v1", compression: .gzip)!],
        readbackProvenProtocolGenerations: ["protocol-generation-v1"])

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

    private nonisolated let queue: EluSQLiteRuntimeQueue
    private nonisolated let nativeAuthority: EluNativeReplayAuthority
    private nonisolated let replayRelay = EluNativeReplayCompositionRelay()
    private var replayComposition: EluNativeReplayComposition?
    private var viewPrivacyObserver: UUID?
    private var closeTask: Task<Void, Never>?
    private(set) var nativeReplayCompositionSettlement: EluNativeReplayComposition.CloseOutcome?
    private let nativeContinuousNow: @Sendable () -> UInt64?
    private nonisolated let deliveryFence = EluStandaloneDeliveryFence()
    private let configurationGate: EluV2ConfigAuthorityGate?
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
    private var configurationWitness: EluV2ConfigAuthorityWitness?

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
        flushDelayNanoseconds: UInt64,
        configurationGate: EluV2ConfigAuthorityGate?,
        nativeContinuousNow: @escaping @Sendable () -> UInt64?
    ) {
        self.nativeContinuousNow = nativeContinuousNow
        self.configurationGate = configurationGate
        self.queue = queue
        nativeAuthority = EluNativeReplayAuthority(queue: queue, clock: clock)
        lastSnapshot = initialSnapshot
        self.siteKey = siteKey
        self.versions = versions
        configManager = EluV1ConfigManager(readbackProvenReplayTransports: Self.readbackProvenReplayCapabilities.transports)
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
        configurationGate: EluV2ConfigAuthorityGate? = nil,
        backgroundHandoff: EluStandaloneBackgroundHandoff? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        continuousClock: @escaping @Sendable () -> UInt64 = EluMachContinuousClock.now,
        continuousBudgetConverter: @escaping @Sendable (UInt64) -> UInt64? =
            EluMachContinuousClock.floorTicks,
        nativeContinuousNanoseconds: @escaping @Sendable (UInt64) -> UInt64? = EluV2ConfigClock.live.floorNanoseconds,
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
        },
        legacyStartupSource: EluLegacyStartupSource? = nil
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
            nativeContinuousNanoseconds: nativeContinuousNanoseconds,
            anonymousIdGenerator: anonymousIdGenerator,
            streamIdGenerator: streamIdGenerator,
            sessionIdGenerator: sessionIdGenerator,
            configurationGate: configurationGate,
            legacyStartupSource: legacyStartupSource
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
            flushDelayNanoseconds: flushDelayNanoseconds,
            configurationGate: configurationGate,
            nativeContinuousNow: { nativeContinuousNanoseconds(continuousClock()) }
        )
    }

    deinit {
        // Original worker tasks retain physical/receipt cleanup independently.
        // Destruction only closes local intake; it creates no database task.
        deliveryFence.close()
        if let viewPrivacyObserver { EluNativeViewPrivacy.shared.removeObserver(viewPrivacyObserver) }
        nativeAuthority.invalidateForOwnerDestruction()
        replayRelay.withdraw()
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
    nonisolated func acceptConsentIntent(_ id: UUID, optedOut: Bool) {
        deliveryFence.acceptConsent(id, optedOut: optedOut)
        if optedOut { invalidateAuthority() }
    }

    /// Commit consent before reopening any transport. Reset preserves this bit.
    @discardableResult
    func setOptedOut(_ optedOut: Bool, intent: UUID) async -> EluRuntimeQueueSnapshot? {
        let fence = deliveryFence
        guard phase != .closed, fence.isLatestConsent(intent) else { return nil }
        guard let generation = try? await queue.snapshot().generation,
              let snapshot = try? await queue.setOptedOut(optedOut, expectedGeneration: generation,
                  admissionGuard: { fence.isLatestConsent(intent) }) else {
            return nil
        }
        deliveryFence.commitConsent(intent, optedOut: optedOut)
        return await commit(snapshot)
    }

    nonisolated func beginFlagProjectionIntent() -> EluV1FlagProjectionIntent { queue.beginFlagProjectionIntent() }
    nonisolated func finishFlagProjectionIntent(_ intent: EluV1FlagProjectionIntent) { queue.finishFlagProjectionIntent(intent); replayRelay.request() }
    nonisolated func invalidateAuthority() {
        replayRelay.withdraw()
        nativeAuthority.withdraw()
        _ = deliveryFence.advance()
        queue.invalidateFlagProjection()
    }

    nonisolated func beginNativeProjectionIntent() -> EluNativeReplayIntent {
        replayRelay.withdrawCapture()
        nativeAuthority.withdraw()
        return queue.beginNativeProjectionIntent()
    }
    nonisolated func finishNativeProjectionIntent(_ intent: EluNativeReplayIntent) { queue.finishNativeProjectionIntent(intent); replayRelay.request() }
    nonisolated func bindNativeLifecycle(_ lifecycle: EluNativeReplayLifecycle) {
        let owner = nativeAuthority, relay = replayRelay
        lifecycle.observeWithdrawal { [weak owner] in owner?.withdraw(); relay.withdrawCapture() }
    }

    /// Capture readiness is deliberately absent from this original-source observation.
    func currentSealedReplayDelivery(capabilities: EluNativeReplayCapabilities) async throws -> EluV2ReplayDeliveryAuthority? {
        guard phase != .closed, let source = configurationWitness,
              configurationDocument == source.data else { return nil }
        let decision = deliveryFence.token()
        let zone = timeZoneIdentifier()
        guard deliveryFence.isCurrent(decision), configurationGate?.isCurrent(source) == true else { return nil }
        let value = try await queue.currentSealedReplayDelivery(source: source,
            capabilities: capabilities, timeZoneIdentifier: zone)
        guard phase != .closed, deliveryFence.isCurrent(decision),
              configurationWitness == source, configurationDocument == source.data,
              configurationGate?.isCurrent(source) == true, value?.isCurrent() == true else { return nil }
        let fence = deliveryFence, readZone = timeZoneIdentifier
        let bound = value?.requiringCurrent {
            guard fence.isCurrent(decision) else { return false }
            guard readZone() == zone else { fence.invalidate(decision); return false }
            return fence.isCurrent(decision)
        }
        return bound?.isCurrent() == true ? bound : nil
    }

    nonisolated func nativePrivacyContextChanged() {
        nativeAuthority.withdraw(); replayRelay.withdraw(); _ = deliveryFence.advance()
        Task { await self.refreshNativePrivacyContext() }
    }
    private func refreshNativePrivacyContext() async {
        guard phase != .closed, let data = configurationDocument, let source = configurationWitness,
              data == source.data, configurationGate?.isCurrent(source) == true else { return }
        _ = await submitConfiguration(data)
        replayRelay.request()
    }

    @discardableResult
    func installNativeReplayComposition(lifecycle: EluNativeReplayLifecycle,
        capabilities: EluNativeReplayCapabilities = EluNativeReplayCapabilities(),
        deferredUntilActivation: Bool = false,
        transport: any EluV2ReplayHTTPTransport = EluV2URLSessionReplayTransport()) -> EluNativeReplayComposition? {
        guard phase != .closed else { return nil }
        if let replayComposition { return replayComposition }
        viewPrivacyObserver = EluNativeViewPrivacy.shared.observe { [weak self] in self?.nativePrivacyContextChanged() }
        let delivery = EluV2ReplayDeliveryCoordinator(queue: queue, transport: transport,
            wallNow: clock, sleep: time.sleep)
        let composition = EluNativeReplayComposition(runtime: self, lifecycle: lifecycle,
            capabilities: capabilities, delivery: delivery, initiallyActive: !deferredUntilActivation)
        replayComposition = composition
        replayRelay.attach(composition)
        lifecycle.observeReevaluation { [weak composition] in composition?.requestReevaluation() }
        lifecycle.observePrivacyChange { [weak self] in self?.nativePrivacyContextChanged() }
        composition.requestReevaluation()
        return composition
    }
    func activateNativeReplayComposition() async { await replayComposition?.activate() }
    nonisolated func reevaluateNativeReplay() { replayRelay.request() }

    #if canImport(UIKit)
    func makeNativeReplayCapture(prepared: EluNativeReplayPreparedAuthority,
        selection: EluNativeReplaySelection, onCommitted: @escaping @Sendable () -> Void) -> EluNativeReplayCaptureOwner? {
        guard phase != .closed, nativeAuthority.ownsPrepared(prepared),
              prepared.isCurrent(), selection.isCurrent(), prepared.supportedProtocolGeneration != nil else { return nil }
        return EluNativeReplayCaptureOwner(queue: queue, authority: nativeAuthority,
            prepared: prepared, selection: selection, versions: versions, wallClock: clock,
            continuousNanoseconds: nativeContinuousNow, onCommitted: onCommitted)
    }
    #endif

    /// Internal proof preparation only; the public stack supplies no native
    /// capability set and this method constructs no physical recorder.
    func prepareNativeReplay(capabilities: EluNativeReplayCapabilities) async throws -> EluNativeReplayPreparedAuthority {
        guard phase != .closed, let source = configurationWitness,
              configurationDocument == source.data else { throw EluNativeReplayAuthorityError.unavailable }
        let value = try await nativeAuthority.prepare(source: source, capabilities: capabilities,
            timeZoneIdentifier: timeZoneIdentifier())
        guard phase != .closed, configurationWitness == source, configurationDocument == source.data,
              value.isCurrent() else { nativeAuthority.withdraw(); throw EluNativeReplayAuthorityError.stale }
        return value
    }
    func startNativeReplay(_ prepared: EluNativeReplayPreparedAuthority,
                           selection: EluNativeReplaySelection) async throws -> EluNativeReplayPermit? {
        guard phase != .closed, prepared.isCurrent() else { return nil }
        return try await nativeAuthority.start(prepared, selection: selection)
    }
    func stopNativeReplay() async throws { try await nativeAuthority.stop() }

    func applyConfiguration(_ configData: Data, sourceWitness: EluV2ConfigAuthorityWitness? = nil) async -> EluStandaloneConfigurationOutcome {
        defer { replayRelay.request() }
        guard phase != .closed else { return .closed }
        guard configurationGate?.isCurrent(sourceWitness, data: configData) ?? true else {
            return .blocked(sourceUnavailable())
        }
        let acceptedDocument = configurationDocument
        let acceptedWitness = configurationWitness
        let acceptedDecision = deliveryFence.advance()
        configurationDocument = configData
        configurationWitness = sourceWitness
        let outcome = await submitConfiguration(configData)
        if case let .blocked(terminal) = outcome, terminal.reason == .stale,
           deliveryFence.isCurrent(acceptedDecision),
           configurationDocument == configData, configurationWitness == sourceWitness {
            configurationDocument = acceptedDocument
            configurationWitness = acceptedWitness
            if let acceptedDocument { _ = await submitConfiguration(acceptedDocument) }
        }
        // A foreground pass can finish before its configuration arrives. Wake
        // an existing durable backlog after the source decision has settled;
        // ordinary identity reprojection keeps its existing capture batching.
        if lastSnapshot.queuedCount > 0, coordinator != nil,
           deliveryFence.isCurrent(acceptedDecision),
           configurationDocument == configData, configurationWitness == sourceWitness,
           configurationGate?.isCurrent(sourceWitness, data: configData) ?? true {
            scheduleFlush()
        }
        return outcome
    }

    func withdrawConfiguration(ifCurrent: @Sendable () -> Bool = { true }) async {
        defer { replayRelay.request() }
        guard phase != .closed, ifCurrent() else { return }
        invalidateAuthority()
        configurationDocument = nil
        configurationWitness = nil
        phase = .awaitingConfiguration
        await retireDelivery()
    }

    private func sourceUnavailable() -> EluV1CaptureAuthorityTerminal {
        EluV1CaptureAuthorityTerminal(ownerEpoch: 0, trustedConfigBoundary: nil,
            candidateConfigBoundary: nil, policySourceHash: nil, contextRevision: nil, reason: .stale)
    }

    private func submitConfiguration(_ configData: Data) async -> EluStandaloneConfigurationOutcome {
        let sourceWitness = configurationWitness
        let decision = deliveryFence.token()
        guard configurationGate?.isCurrent(sourceWitness, data: configData) ?? true else {
            return .blocked(sourceUnavailable())
        }
        configurationTicket += 1
        let ticket = configurationTicket
        let now = clock()
        let handoff = EluStandaloneProjectionHandoff()
        let manager = configManager
        let readTimeZoneIdentifier = timeZoneIdentifier
        let drawReplaySample = replaySampleDraw
        let result = await queue.submitCaptureAuthority(configData: configData, sourceWitness: sourceWitness) { witness in
            Self.projectPrivacyState(configData: configData, witness: witness, now: now, manager: manager,
                timeZoneIdentifier: readTimeZoneIdentifier(), replaySampleDraw: drawReplaySample(), handoff: handoff)
        }
        guard phase != .closed else { return .closed }
        guard deliveryFence.isCurrent(decision), configurationGate?.isCurrent(sourceWitness, data: configData) ?? true,
              ticket > appliedConfigurationTicket else { return .blocked(sourceUnavailable()) }
        appliedConfigurationTicket = ticket
        let publish = {
            switch result {
            case .activated: self.phase = .capturing
            case let .terminated(terminal): self.phase = .blocked(terminal.reason)
            }
        }
        if let configurationGate {
            guard configurationGate.consume(sourceWitness, data: configData, apply: publish) else {
                return .blocked(sourceUnavailable())
            }
        } else { publish() }
        // Delivery is derived from configuration/privacy and sealed queue legality.
        // A capture session terminal does not revoke previously lawful records.
        if let projection = handoff.value {
            await installDelivery(privacyStateData: projection.stateData, witness: projection.witness,
                now: now, sourceWitness: sourceWitness, decision: decision)
        } else {
            await retireDelivery()
        }
        guard deliveryFence.isCurrent(decision), configurationGate?.isCurrent(sourceWitness) ?? true else {
            return .blocked(sourceUnavailable())
        }
        return Self.outcome(for: result)
    }

    func capture(
        _ name: String,
        properties: [String: EluJSONValue] = [:],
        occurredAt: Date? = nil,
        admissionGuard: (@Sendable () -> Bool)? = nil
    ) async -> EluV1CaptureResult {
        await submit(
            EluV1CaptureCommand(
                kind: .capture,
                name: name,
                occurredAt: occurredAt ?? clock(),
                properties: properties,
                versions: versions
            ),
            admissionGuard: admissionGuard
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
        _ properties: [String: EluJSONValue],
        onlyIfAbsent: Bool = false,
        defaultValue: EluJSONValue? = nil
    ) async -> EluRuntimeQueueSnapshot? {
        guard phase != .closed, !properties.isEmpty else { return nil }
        guard let snapshot = try? await queue.registerStandaloneSuperProperties(properties, onlyIfAbsent: onlyIfAbsent, defaultValue: defaultValue) else {
            return nil
        }
        return await commit(snapshot)
    }

    @discardableResult
    func unregisterSuperProperty(_ key: String) async -> EluRuntimeQueueSnapshot? {
        guard phase != .closed else { return nil }
        guard let snapshot = try? await queue.unregisterStandaloneSuperProperty(key) else {
            return nil
        }
        return await commit(snapshot)
    }

    @discardableResult
    func setFlagPersonProperties(
        _ properties: [String: EluJSONValue]
    ) async -> EluRuntimeQueueSnapshot? {
        guard phase != .closed, !properties.isEmpty else { return nil }
        return await mutate(.setPersonProperties(set: properties, setOnce: [:], unset: []))
    }

    /// Group properties describe the group this device is currently
    /// associated with, so a type with no association has nothing to describe.
    @discardableResult
    func setFlagGroupProperties(
        type: String,
        properties: [String: EluJSONValue]
    ) async -> EluRuntimeQueueSnapshot? {
        guard phase != .closed, !properties.isEmpty else { return nil }
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
    /// super properties, session, and flag context are cleared. This local
    /// operation is available without capture authority and enqueues no wire record.
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

    /// Local identity/context remains available when capture is off. The owner
    /// creates wire drafts only under current capture authority; there is no backfill.
    private func mutate(
        _ transition: EluRuntimeMutationTransition
    ) async -> EluRuntimeQueueSnapshot? {
        guard phase != .closed else { return nil }
        let fence = deliveryFence
        let decision = fence.token()
        guard let generation = try? await queue.snapshot().generation,
              let snapshot = try? await queue.applyOwnedMutation(
                  transition,
                  versions: versions,
                  expectedGeneration: generation,
                  allowWire: phase == .capturing,
                  wireGuard: { fence.isCurrent(decision) }
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
        defer { replayRelay.request() }
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
        defer { replayRelay.request() }
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
        defer { replayRelay.request() }
        guard phase != .closed else { return }
        scheduleFlush()
    }

    /// Triggers delivery now; without an activated authority nothing is sent.
    func flush() async -> EluStandaloneDeliveryOutcome {
        guard deliveryFence.isCurrent(deliveryFence.token()) else { return .unavailable }
        guard let coordinator else { return .unavailable }
        return .triggered(await coordinator.trigger())
    }

    nonisolated func lifecycleSink() -> EluStandaloneLifecycleSink {
        EluStandaloneLifecycleSink(runtime: self)
    }

    /// Joins the original shutdown. Unresolved replay receipts remain explicit
    /// quarantine and retain installation ownership when the queue closes.
    func close() async {
        if let closeTask { await closeTask.value; return }
        nativeAuthority.withdraw()
        replayRelay.withdraw()
        phase = .closed
        deliveryFence.close()
        configurationDocument = nil
        configurationWitness = nil
        flushTimer?.cancel()
        flushTimer = nil
        let task = Task { await self.finishClose() }
        closeTask = task
        await task.value
    }
    private func finishClose() async {
        nativeReplayCompositionSettlement = await replayComposition?.closeAndWait()
        await retireDelivery()
        await backgroundHandoff?.cancel()
        await nativeAuthority.close()
        await queue.close()
    }

    private func submit(_ command: EluV1CaptureCommand, admissionGuard: (@Sendable () -> Bool)? = nil) async -> EluV1CaptureResult {
        defer { replayRelay.request() }
        guard phase != .closed else {
            return .rejected(.authorityAbsent, snapshot: lastSnapshot)
        }
        var result = await record(command, admissionGuard: admissionGuard)
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
            result = await record(command, admissionGuard: admissionGuard)
        }
        return result
    }

    private func record(_ command: EluV1CaptureCommand, admissionGuard: (@Sendable () -> Bool)? = nil) async -> EluV1CaptureResult {
        let fence = deliveryFence
        let decision = fence.token()
        let result = await queue.capture(command, admissionGuard: {
            fence.isCurrent(decision) && (admissionGuard?() ?? true)
        })
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
        now: Date,
        sourceWitness: EluV2ConfigAuthorityWitness?,
        decision: UUID
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
            var selectedTransport = transport
            if configurationGate != nil {
                guard let concrete = transport as? any EluV1AuthorizedBatchTransport,
                      let ownerGuard = await queue.queuedEventDeliveryGuard(sourceWitness: sourceWitness),
                      deliveryFence.isCurrent(decision), ownerGuard.isCurrent() else { return }
                let fence = deliveryFence
                let owner = queue
                selectedTransport = EluV1BoundBatchTransport(transport: concrete, authority: EluV1TransportAuthority(
                    revalidate: { await owner.queuedEventDeliveryGuard(sourceWitness: sourceWitness) != nil &&
                        fence.isCurrent(decision) && ownerGuard.isCurrent() },
                    isCurrent: { fence.isCurrent(decision) && ownerGuard.isCurrent() }))
            }
            guard deliveryFence.isCurrent(decision) else { return }
            replacement = EluV1BatchDeliveryCoordinator(
                queue: queue,
                authorization: authorization,
                transport: selectedTransport,
                time: time,
                randomUnit: randomUnit
            )
        } catch {
            await retireDelivery()
            return
        }
        guard deliveryFence.isCurrent(decision), configurationGate?.isCurrent(sourceWitness) ?? true else { return }
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
