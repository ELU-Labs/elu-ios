import Foundation

enum EluNativeReplayAuthorityError: Error, Equatable {
    case unavailable
    case stale
    case incompatibleProfile
    case unsupportedCapability
}

struct EluNativeReplayIntent: Sendable {
    fileprivate let owner: UUID
    fileprivate let token: UUID
}

/// Only memory and clock checks run under this lock. UIKit, database work and
/// caller callbacks are always outside it. A session's clock denial is local.
final class EluNativeReplayScope: @unchecked Sendable {
    private let lock = NSLock()
    private let owner = UUID()
    private var generation = UUID()
    private var pending: Set<UUID> = []
    private var terminal = false
    private var session: EluSessionState?
    private var lastWall: Date?
    private var lastContinuous: UInt64?
    private var clockDenied = false
    private var lastDeniedKey: EluNativeReplaySessionState.Key?

    func token() -> UUID { lock.lock(); defer { lock.unlock() }; return generation }
    func invalidate(terminal: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); self.terminal = self.terminal || terminal
    }
    func beginIntent() -> EluNativeReplayIntent {
        lock.lock(); defer { lock.unlock() }
        let token = UUID(); pending.insert(token); generation = UUID()
        return EluNativeReplayIntent(owner: owner, token: token)
    }
    func finish(_ intent: EluNativeReplayIntent) {
        lock.lock(); defer { lock.unlock() }
        guard intent.owner == owner, pending.remove(intent.token) != nil else { return }
        generation = UUID()
    }
    func publishSession(_ value: EluSessionState?) {
        lock.lock(); defer { lock.unlock() }
        let sameID = session.map { old in value.map { EluNativeReplaySessionState.same(old.id, $0.id) } ?? false } ?? (value == nil)
        if !sameID || session?.startedAt != value?.startedAt {
            generation = UUID(); lastWall = nil; lastContinuous = nil; clockDenied = false
        }
        session = value
    }
    func current(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !terminal && !clockDenied && pending.isEmpty && generation == token
    }
    func retainedClockDenial() -> EluNativeReplaySessionState.Key? {
        lock.lock(); defer { lock.unlock() }; return lastDeniedKey
    }
    /// The queue calls this only after a committed exact denial or a successful
    /// out-of-transaction read proving this original key no longer needs denial.
    func resolveClockDenial(_ key: EluNativeReplaySessionState.Key) {
        lock.lock(); defer { lock.unlock() }
        if lastDeniedKey == key { lastDeniedKey = nil }
    }
    func sample(_ token: UUID, key: EluNativeReplaySessionState.Key? = nil, wall: () -> Date, continuous: () -> UInt64) -> (Date, UInt64, EluSessionState)? {
        lock.lock(); defer { lock.unlock() }
        guard !terminal, !clockDenied, pending.isEmpty, generation == token, let session else { return nil }
        if let key {
            guard EluNativeReplaySessionState.same(key.sessionId, session.id),
                  EluNativeReplaySessionState.same(key.sessionStartedAt, EluRFC3339.string(from: session.startedAt)) else { return nil }
        }
        let now = wall(), ticks = continuous()
        guard (try? EluV1Timestamp.exactClock(now)) != nil,
              lastWall.map({ now >= $0 }) ?? true, lastContinuous.map({ ticks >= $0 }) ?? true
        else { clockDenied = true; if let key { lastDeniedKey = key }; return nil }
        lastWall = now; lastContinuous = ticks
        return (now, ticks, session)
    }
}

/// This check is intentionally opaque. A projection is descriptive without its
/// original owner/source check; reading it never renews a source or budget lease.
final class EluNativeReplaySynchronousGuard: @unchecked Sendable {
    private let validate: @Sendable () -> Bool
    init(_ validate: @escaping @Sendable () -> Bool) { self.validate = validate }
    func isCurrent() -> Bool { validate() }
}

/// Explicit trusted local proof input. The public stack never constructs one.
/// A remote advertisement or masking profile cannot produce this value.
struct EluNativeReplayCapabilities: Sendable {
    let transports: Set<EluV1ReplayTransportSelection>
    let readbackProvenProtocolGenerations: Set<String>
    init(readbackProvenTransports: Set<EluV1ReplayTransportSelection> = [],
         readbackProvenProtocolGenerations: Set<String> = []) {
        self.readbackProvenProtocolGenerations = readbackProvenProtocolGenerations
        transports = readbackProvenTransports.filter {
            $0.codec == "elu-native-wireframe-v1" && $0.compression == .gzip
        }
    }
    func supportedProtocolGeneration(_ generation: String?) -> String? {
        guard let generation, readbackProvenProtocolGenerations.contains(where: {
            $0.utf8.elementsEqual(generation.utf8)
        }) else { return nil }
        return generation
    }
    var pairs: [EluV1ReplayTransportPair] {
        transports.map { EluV1ReplayTransportPair(codec: $0.codec, compression: $0.compression) }
    }
}

/// Prepared source/privacy proof, before a selected scene or start accounting.
/// Its initializer is owned by the authority coordinator below.
struct EluNativeReplayPreparedAuthority: Sendable {
    let privacy: EluProjectedPrivacyState
    let profile: EluNativeMaskingProfile
    let resolution: EluV1ConfigResolution
    let supportedProtocolGeneration: String?
    fileprivate let owner: UUID
    fileprivate let invocation: UUID
    fileprivate let projection: EluNativeReplayProjectionInput
    func isCurrent() -> Bool { projection.isCurrent() }
}

/// An internal permit, not physical capture enrollment. N3c must acquire its own
/// installation occupancy before any collector or encoder is constructed.
struct EluNativeReplayPermit: Sendable {
    let replayId: String
    let privacy: EluProjectedPrivacyState
    let profile: EluNativeMaskingProfile
    let resolution: EluV1ConfigResolution
    let identity: EluIdentitySnapshot
    let selection: EluNativeReplaySelection
    fileprivate let receipt: EluNativeReplayStartReceipt
    fileprivate let authority: EluNativeReplaySynchronousGuard
    fileprivate let invocation: UUID
    func isCurrent() -> Bool { authority.isCurrent() && selection.isCurrent() }
}

/// Serializes proof/start/stop only. This owner creates no physical capture work.
actor EluNativeReplayAuthority {
    private nonisolated let fence = EluNativeReplayScope()
    private let id = UUID()
    private let queue: EluSQLiteRuntimeQueue
    private let clock: @Sendable () -> Date
    private var prepared: EluNativeReplayPreparedAuthority?
    private var active: EluNativeReplayPermit?
    private var unresolvedReceipt: EluNativeReplayStartReceipt?
    private var captureUse: EluNativeReplayCapturePhysicalUse?
    private var activeProjection: EluNativeReplayProjectionInput?
    private var closed = false

    init(queue: EluSQLiteRuntimeQueue, clock: @escaping @Sendable () -> Date) {
        self.queue = queue; self.clock = clock
    }

    /// Local ownership only; rejecting a foreign or withdrawn preparation must
    /// not sample its persistable source/clock guard.
    nonisolated func ownsPrepared(_ value: EluNativeReplayPreparedAuthority) -> Bool {
        value.owner == id && fence.current(value.invocation)
    }

    nonisolated func withdraw() {
        fence.invalidate()
        queue.invalidateNativeProjection()
        Task { await self.settleWithdrawn() }
    }

    /// Owner destruction may close local intake only. Original physical tasks
    /// and the queue retain responsibility for durable settlement/quarantine.
    /// This method must never create a task, sample a clock or perform SQL.
    nonisolated func invalidateForOwnerDestruction() {
        fence.invalidate(terminal: true)
        queue.invalidateNativeProjection()
    }

    func prepare(source: EluV2ConfigAuthorityWitness, capabilities: EluNativeReplayCapabilities,
                 timeZoneIdentifier: String?) async throws -> EluNativeReplayPreparedAuthority {
        guard !closed, queue.nativeSourceIsCurrent(source) else { throw EluNativeReplayAuthorityError.stale }
        guard !capabilities.transports.isEmpty else { withdraw(); throw EluNativeReplayAuthorityError.unsupportedCapability }
        if let prepared, prepared.projection.source == source,
           fence.current(prepared.invocation), prepared.projection.isCurrent(),
           EluV2ReplayText.equal(prepared.supportedProtocolGeneration,
               capabilities.supportedProtocolGeneration(prepared.resolution.replayProtocolGeneration)) { return prepared }
        fence.invalidate(); let invocation = fence.token()
        prepared = nil
        try await settleActive()
        guard !closed, fence.current(invocation), queue.nativeSourceIsCurrent(source), unresolvedReceipt == nil, captureUse == nil else { throw EluNativeReplayAuthorityError.stale }
        // These are explicit optional storage migrations, not readiness claims.
        try await queue.ensureReplaySchema()
        guard fence.current(invocation), queue.nativeSourceIsCurrent(source) else { throw EluNativeReplayAuthorityError.stale }
        try await queue.ensureReplayDeliverySchema()
        guard fence.current(invocation), queue.nativeSourceIsCurrent(source) else { throw EluNativeReplayAuthorityError.stale }
        try await queue.ensureNativeReplayAuthoritySchema()
        guard fence.current(invocation), queue.nativeSourceIsCurrent(source) else { throw EluNativeReplayAuthorityError.stale }
        let original = try await queue.nativeReplayProjection(source: source)
        guard fence.current(invocation), original.source == source, original.isCurrent() else { throw EluNativeReplayAuthorityError.stale }
        let profile = EluNativeMaskingProfile.select(for: original.context.policy.masking, platform: .ios)
        let privacy = try EluPrivacyStateProjector.projectNative(observation: original, profile: profile,
            capabilities: capabilities, evaluatedAt: clock(), timeZoneIdentifier: timeZoneIdentifier)
        guard fence.current(invocation), original.isCurrent() else { throw EluNativeReplayAuthorityError.stale }
        let installed = try await queue.installNativeReplayPrivacy(original, privacy: privacy)
        guard fence.current(invocation), installed.source == source, installed.isCurrent() else { throw EluNativeReplayAuthorityError.stale }
        let manager = EluV1ConfigManager(readbackProvenReplayTransports: capabilities.transports)
        _ = try manager.update(configData: source.data, now: clock())
        let resolution = try manager.authorize(effectivePrivacyStateData: privacy.stateData, identity: installed.identity, now: clock())
        guard fence.current(invocation), installed.isCurrent(), resolution.decisionHash == privacy.effectivePolicyHash
        else { throw EluNativeReplayAuthorityError.stale }
        let value = EluNativeReplayPreparedAuthority(privacy: privacy, profile: profile, resolution: resolution,
            supportedProtocolGeneration: capabilities.supportedProtocolGeneration(resolution.replayProtocolGeneration), owner: id, invocation: invocation, projection: installed)
        prepared = value
        return value
    }

    func start(_ value: EluNativeReplayPreparedAuthority,
               selection: EluNativeReplaySelection) async throws -> EluNativeReplayPermit? {
        try await startCurrent(value, selection: selection, physicalUse: nil)
    }

    func start(_ value: EluNativeReplayPreparedAuthority, selection: EluNativeReplaySelection,
               physicalUse: EluNativeReplayCapturePhysicalUse) async throws -> EluNativeReplayPermit? {
        try await startCurrent(value, selection: selection, physicalUse: physicalUse)
    }

    private func startCurrent(_ value: EluNativeReplayPreparedAuthority, selection: EluNativeReplaySelection,
               physicalUse: EluNativeReplayCapturePhysicalUse?) async throws -> EluNativeReplayPermit? {
        guard !closed, active == nil, unresolvedReceipt == nil, captureUse == nil, value.owner == id,
              fence.current(value.invocation), value.projection.isCurrent(), selection.isCurrent(),
              case .authorized = value.resolution.replayAuthorization else { return nil }
        if physicalUse != nil {
            guard let supported = value.supportedProtocolGeneration,
                  EluV2ReplayText.equal(supported, value.resolution.replayProtocolGeneration) else { return nil }
        }
        let selected = await selection.validateCurrent()
        guard selected, !closed, active == nil, unresolvedReceipt == nil, captureUse == nil,
              fence.current(value.invocation), value.projection.isCurrent(), selection.isCurrent() else { return nil }
        // Retain the physical capability before crossing the queue boundary: a
        // begin may commit without returning its receipt to this actor.
        captureUse = physicalUse
        let started: EluNativeReplayStartReceipt?
        if let physicalUse { started = try await queue.beginNativeReplayStartAccounting(value.projection, physicalUse: physicalUse) }
        else { started = try await queue.beginNativeReplayStartAccounting(value.projection) }
        guard let receipt = started else { return nil }
        unresolvedReceipt = receipt
        guard !closed, fence.current(value.invocation), value.projection.isCurrent(), selection.isCurrent() else {
            try await settleActive(); return nil
        }
        let guardValue = try await queue.nativeReplayPermitGuard(input: value.projection, receipt: receipt, resolution: value.resolution)
        guard let guardValue, fence.current(value.invocation), guardValue.isCurrent(), selection.isCurrent() else {
            try await settleActive(); return nil
        }
        let stillSelected = await selection.validateCurrent()
        guard stillSelected, !closed, fence.current(value.invocation), guardValue.isCurrent(), selection.isCurrent() else {
            try await settleActive(); return nil
        }
        let ownerFence = fence, invocation = value.invocation
        let combined = EluNativeReplaySynchronousGuard {
            ownerFence.current(invocation) && guardValue.isCurrent() && selection.isCurrent() && ownerFence.current(invocation)
        }
        let permit = EluNativeReplayPermit(replayId: receipt.replayId, privacy: value.privacy, profile: value.profile,
            resolution: value.resolution, identity: value.projection.identity, selection: selection,
            receipt: receipt, authority: combined, invocation: invocation)
        guard permit.isCurrent() else { try await settleActive(); return nil }
        active = permit; activeProjection = value.projection; unresolvedReceipt = nil
        return permit
    }

    func captureAdmission(for permit: EluNativeReplayPermit,
                          physicalUse: EluNativeReplayCapturePhysicalUse) async throws -> EluNativeReplayCaptureAdmission {
        guard !closed, captureUse === physicalUse,
              active?.invocation == permit.invocation, active?.replayId == permit.replayId,
              let projection = activeProjection, projection.isCurrent(), permit.isCurrent(),
              let supported = prepared?.supportedProtocolGeneration,
              EluV2ReplayText.equal(supported, permit.resolution.replayProtocolGeneration),
              let originalPolicy = (try? JSONDecoder().decode(EluV1ConfigDocument.self, from: projection.source.data))?.privacy?.masking,
              permit.profile.compatibility(with: originalPolicy, platform: .ios) == .compatible
        else { throw EluNativeReplayAuthorityError.stale }
        // Storage compatibility is an explicit local proof, distinct from a
        // remote advertisement. Missing policy must never become a purge rule.
        _ = try await queue.reconcileReplayConfiguration(configData: projection.source.data,
            expectedConfigWitness: EluV2ReplayConfigWitness(issuedAt: permit.resolution.exactIssuedAt,
                semanticHash: permit.resolution.configSemanticHash), sourceWitness: projection.source,
            supportedProtocolGeneration: supported,
            mayRetainProfile: { EluNativeMaskingProfile.retention(of: $0, required: originalPolicy, platform: .ios) == .compatible })
        guard !closed, captureUse === physicalUse, active?.invocation == permit.invocation,
              active?.replayId == permit.replayId, projection.isCurrent(), permit.isCurrent()
        else { throw EluNativeReplayAuthorityError.stale }
        let value = try await queue.makeNativeReplayCaptureAdmission(input: projection, receipt: permit.receipt,
            permit: permit, physicalUse: physicalUse)
        guard !closed, captureUse === physicalUse, active?.invocation == permit.invocation,
              active?.replayId == permit.replayId, value.isCurrent()
        else { throw EluNativeReplayAuthorityError.stale }
        return value
    }

    @discardableResult
    func stop() async throws -> EluNativeReplayStopOutcome {
        fence.invalidate(); queue.invalidateNativeProjection(); prepared = nil
        return try await settleActive()
    }
    func close() async {
        closed = true; fence.invalidate(terminal: true); queue.invalidateNativeProjection(); prepared = nil
        do { try await settleActive() } catch { /* Original unresolved epoch remains fail-closed. */ }
    }
    private func settleWithdrawn() async {
        if let active, active.isCurrent() { return }
        if let prepared, fence.current(prepared.invocation), prepared.projection.isCurrent(), unresolvedReceipt == nil { return }
        prepared = nil
        do { try await settleActive() } catch { /* No automatic retry or replacement interval. */ }
    }
    @discardableResult
    private func settleActive() async throws -> EluNativeReplayStopOutcome {
        if let active { unresolvedReceipt = active.receipt; self.active = nil }
        activeProjection = nil
        if let use = captureUse {
            let result = try await queue.stopNativeReplayCaptureAccounting(use)
            guard result == .settled else { return result }
            if captureUse === use { captureUse = nil; unresolvedReceipt = nil }
            return .settled
        }
        guard let receipt = unresolvedReceipt else { try await queue.persistNativeReplayClockDenial(); return .settled }
        guard try await queue.stopNativeReplayAccounting(receipt) else { throw EluNativeReplayAuthorityError.stale }
        if unresolvedReceipt?.replayId == receipt.replayId { unresolvedReceipt = nil }
        return .settled
    }
}

extension EluNativeReplayPermit {
    @MainActor func isCurrentForCollection() -> Bool {
        isCurrent() && selection.validateCurrent() && isCurrent()
    }
}
