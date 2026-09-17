import Foundation

/// Internal injected transport boundary. Concrete transports are constructed
/// only by the separately selected runtime composition.
protocol EluV1FlagTransport: Sendable {
    func send(endpoint: URL, requestBody: Data) async throws -> Data
}

actor EluV1FlagClient {
    private typealias ReloadContinuation = CheckedContinuation<EluV1FlagReloadResult, Never>

    private struct ActiveReload {
        let witnessHash: String?
        let generation: UUID
        let task: Task<EluV1FlagReloadResult, Never>
        var waiters: [ReloadContinuation]
        var isInvalidated: Bool
    }

    private struct PendingReload {
        let witnessHash: String?
        var waiters: [ReloadContinuation]
    }

    private let runtime: EluSQLiteRuntimeQueue
    private let transport: any EluV1FlagTransport
    private let versions: EluVersionContext
    private let requestIdGenerator: @Sendable () -> String
    private var activeReload: ActiveReload?
    private var pendingReload: PendingReload?
    private var generation = UUID()
    private var closed = false
    private var configurationWithdrawn = false

    private init(
        runtime: EluSQLiteRuntimeQueue,
        transport: any EluV1FlagTransport,
        versions: EluVersionContext,
        requestIdGenerator: @escaping @Sendable () -> String
    ) {
        self.runtime = runtime
        self.transport = transport
        self.versions = versions
        self.requestIdGenerator = requestIdGenerator
    }

    static func make(
        runtime: EluSQLiteRuntimeQueue,
        transport: any EluV1FlagTransport,
        versions: EluVersionContext,
        requestIdGenerator: @escaping @Sendable () -> String = {
            "flags_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        }
    ) async throws -> EluV1FlagClient {
        try await runtime.ensureFlagSchema()
        return EluV1FlagClient(
            runtime: runtime,
            transport: transport,
            versions: versions,
            requestIdGenerator: requestIdGenerator
        )
    }

    func applyConfig(_ data: Data, sourceWitness: EluV2ConfigAuthorityWitness? = nil) async -> EluV1FlagAuthorization {
        guard !closed else { return .restricted(.missing) }
        generation = UUID()
        let acceptedGeneration = generation
        configurationWithdrawn = true
        let intent = runtime.beginFlagProjectionIntent()
        defer { runtime.finishFlagProjectionIntent(intent) }
        invalidateActiveReload()
        if let pendingReload {
            pendingReload.waiters.forEach { $0.resume(returning: .stale) }
            self.pendingReload = nil
        }
        let result = await runtime.submitFlagConfig(data, sourceWitness: sourceWitness)
        guard !closed, generation == acceptedGeneration else { return .restricted(.missing) }
        // Preserve the owner's terminal/revoked/opaque-storage classifications.
        // Missing source alone stays withdrawn until an explicit current apply.
        configurationWithdrawn = result == .restricted(.missing)
        return result
    }

    func reload() async -> EluV1FlagReloadResult {
        guard !closed, !configurationWithdrawn else { return .stale }
        let acceptedGeneration = generation
        let fingerprint = await runtime.flagWitnessFingerprint(versions: versions)
        guard !closed, generation == acceptedGeneration else { return .stale }
        return await withCheckedContinuation { continuation in
            enqueueReload(fingerprint: fingerprint, continuation: continuation)
        }
    }

    private func enqueueReload(
        fingerprint: String?,
        continuation: ReloadContinuation
    ) {
        if var activeReload,
           !activeReload.isInvalidated,
           activeReload.witnessHash == fingerprint
        {
            activeReload.waiters.append(continuation)
            self.activeReload = activeReload
            return
        }
        if var pendingReload, pendingReload.witnessHash == fingerprint {
            pendingReload.waiters.append(continuation)
            self.pendingReload = pendingReload
            return
        }
        guard activeReload != nil else {
            startReload(fingerprint: fingerprint, waiters: [continuation])
            return
        }

        invalidateActiveReload()
        if let replaced = pendingReload {
            replaced.waiters.forEach { $0.resume(returning: .stale) }
        }
        pendingReload = PendingReload(
            witnessHash: fingerprint,
            waiters: [continuation]
        )
    }

    private func startReload(
        fingerprint: String?,
        waiters: [ReloadContinuation]
    ) {
        precondition(activeReload == nil)
        let generation = UUID()
        let requestId = requestIdGenerator()
        let runtime = self.runtime
        let transport = self.transport
        let versions = self.versions
        let task = Task<EluV1FlagReloadResult, Never> {
            await Self.performReload(
                runtime: runtime,
                transport: transport,
                versions: versions,
                requestId: requestId
            )
        }
        activeReload = ActiveReload(
            witnessHash: fingerprint,
            generation: generation,
            task: task,
            waiters: waiters,
            isInvalidated: false
        )
        Task {
            let result = await task.value
            self.finishReload(generation: generation, result: result)
        }
    }

    private func finishReload(
        generation: UUID,
        result: EluV1FlagReloadResult
    ) {
        guard let completed = activeReload, completed.generation == generation else { return }
        activeReload = nil
        if !completed.isInvalidated {
            completed.waiters.forEach { $0.resume(returning: result) }
        }
        if let pendingReload {
            self.pendingReload = nil
            startReload(
                fingerprint: pendingReload.witnessHash,
                waiters: pendingReload.waiters
            )
        }
    }

    /// Logical cancellation and physical transport occupancy are separate.
    /// A non-cooperative transport may ignore Task cancellation, so callers
    /// are released exactly once here while its task continues to own the sole
    /// physical slot until `finishReload` observes actual completion.
    private func invalidateActiveReload() {
        guard var activeReload else { return }
        activeReload.task.cancel()
        guard !activeReload.isInvalidated else { return }
        let waiters = activeReload.waiters
        activeReload.waiters.removeAll(keepingCapacity: false)
        activeReload.isInvalidated = true
        self.activeReload = activeReload
        waiters.forEach { $0.resume(returning: .stale) }
    }

    /// Withdraw only published source authority; preserve ordering and original
    /// cache deadlines so a same-document recovery cannot renew a lease.
    func withdrawConfiguration() {
        guard !closed else { return }
        configurationWithdrawn = true
        generation = UUID()
        runtime.invalidateFlagProjection()
        invalidateActiveReload()
        if let pendingReload {
            pendingReload.waiters.forEach { $0.resume(returning: .stale) }
            self.pendingReload = nil
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        generation = UUID()
        runtime.invalidateFlagProjection()
        invalidateActiveReload()
        if let pendingReload {
            pendingReload.waiters.forEach { $0.resume(returning: .stale) }
            self.pendingReload = nil
        }
    }

    func read(_ key: String) async -> EluV1FlagLookup {
        await readProjection()?.lookup(key) ?? .missing
    }

    /// Raw compatibility result for internal callers; retaining it does not
    /// preserve authority. Synchronous facade getters must retain readProjection.
    func readAll() async -> EluV1FlagCacheReadResult {
        guard !closed, !configurationWithdrawn else { return .restricted(.missing) }
        let acceptedGeneration = generation
        let result = await runtime.readFlagCache(versions: versions)
        guard !closed, generation == acceptedGeneration else { return .restricted(.missing) }
        return result
    }

    func readProjection() async -> EluV1FlagCacheProjection? {
        guard !closed, !configurationWithdrawn else { return nil }
        let acceptedGeneration = generation
        let projection = await runtime.readFlagProjection(versions: versions)
        guard !closed, generation == acceptedGeneration, projection?.authority.isCurrent() == true else { return nil }
        return projection
    }

    func reloadProjection() async -> EluV1FlagCacheProjection? {
        let result = await reload()
        let snapshot: EluV1FlagCacheSnapshot
        switch result {
        case let .updated(value), let .cached(value): snapshot = value
        default: return nil
        }
        guard let projection = await readProjection(), projection.snapshot == snapshot else { return nil }
        return projection
    }

    private static func performReload(
        runtime: EluSQLiteRuntimeQueue,
        transport: any EluV1FlagTransport,
        versions: EluVersionContext,
        requestId: String
    ) async -> EluV1FlagReloadResult {
        let begun = await runtime.beginFlagReload(
            requestId: requestId,
            versions: versions
        )
        let request: EluV1FlagBegunRequest
        switch begun {
        case let .begun(value): request = value
        case let .restricted(reason): return .restricted(reason)
        case .terminal: return .terminal
        }
        guard !Task.isCancelled else { return .stale }

        switch await runtime.authorizeFlagSend(token: request.token) {
        case .allowed:
            break
        case .stale:
            return .stale
        case let .restricted(reason):
            return .restricted(reason)
        case .terminal:
            return .terminal
        }
        guard !Task.isCancelled else { return .stale }

        let responseData: Data
        do {
            if let bound = transport as? any EluV1AuthorizedFlagTransport {
                guard let source = await runtime.flagSendGuard(token: request.token), !Task.isCancelled else { return .stale }
                let authority = EluV1TransportAuthority(
                    revalidate: { await runtime.authorizeFlagSend(token: request.token) == .allowed },
                    isCurrent: { source.isCurrent() }
                )
                responseData = try await bound.send(endpoint: request.endpoint,
                    requestBody: request.request.canonicalData, authority: authority)
            } else {
                guard !runtime.requiresBoundFlagTransport else { return .stale }
                responseData = try await transport.send(
                    endpoint: request.endpoint,
                    requestBody: request.request.canonicalData
                )
            }
        } catch {
            if Task.isCancelled { return .stale }
            return await retainedCache(runtime: runtime, versions: versions, expected: request.token)
        }
        guard !Task.isCancelled else { return .stale }

        let response: EluV1FlagResponse
        do {
            response = try EluV1FlagCodec.decodeResponse(
                responseData,
                for: request.request
            )
        } catch {
            return await retainedCache(runtime: runtime, versions: versions, expected: request.token)
        }

        switch await runtime.commitFlagReload(token: request.token, response: response) {
        case .updated:
            switch await runtime.finalizeFlagReload(
                token: request.token,
                versions: versions
            ) {
            case let .hit(snapshot): return .updated(snapshot)
            case let .restricted(reason): return .restricted(reason)
            case .terminal: return .terminal
            case .miss: return .stale
            }
        case .stale:
            return .stale
        case let .restricted(reason):
            return .restricted(reason)
        case .terminal:
            return .terminal
        }
    }

    private static func retainedCache(
        runtime: EluSQLiteRuntimeQueue,
        versions: EluVersionContext,
        expected: EluV1FlagBeginToken
    ) async -> EluV1FlagReloadResult {
        guard await runtime.authorizeFlagSend(token: expected) == .allowed else { return .stale }
        switch await runtime.readFlagCache(versions: versions) {
        case let .hit(snapshot): return snapshot.witness == expected.witness ? .cached(snapshot) : .stale
        case let .restricted(reason): return .restricted(reason)
        case .terminal: return .terminal
        case .miss: return .stale
        }
    }
}
