import Foundation

struct EluV2ConfigLifecycleToken: Equatable, Sendable {
    fileprivate let value = UUID()
    init() {}
}

enum EluV2ConfigWithdrawal: Equatable, Sendable {
    case notStarted
    case loading
    case background
    case refreshFailed
    case expired
    case invalidClock
    case closed
}

enum EluV2ConfigLifecycleState: Equatable, Sendable {
    /// Validated raw data, including disabled/revoked config; not channel authority.
    case document(Data)
    case unavailable(EluV2ConfigWithdrawal)
}

/// Internal lifecycle owner. Production facade selection remains unchanged.
///
/// `onChange` only notifies/enqueues an opaque token. Consume it synchronously
/// through `consumeCurrent` so queued notifications cannot install old data.
/// The consumer must apply its existing persisted privacy/identity fences; this
/// source never grants channel authorization. Neither callback may block or do
/// network I/O. Platform lifecycle hooks will call this owner during composition.
actor EluV2ConfigLifecycle {
    private struct ActiveFetch {
        let id: UUID
        let epoch: UUID
        let task: Task<Void, Never>
    }

    nonisolated let authorityGate: EluV2ConfigAuthorityGate
    private let source: EluV2ConfigSource
    private let clock: EluV2ConfigClock
    private let scheduler: any EluV2ConfigLifecycleScheduler
    private let onChange: @Sendable (EluV2ConfigLifecycleToken) -> Void
    private var started = false
    private var foreground = true
    private var closed = false
    private var epoch = UUID()
    private var activeFetch: ActiveFetch?
    private var refreshWanted = false
    private var invalidations = 0
    private var failures = 0
    private var publishedLease: EluV2ConfigLease?
    private var state: EluV2ConfigLifecycleState = .unavailable(.notStarted)
    private var token = EluV2ConfigLifecycleToken()
    private var expiryTimer: (UUID, any EluV2ConfigScheduledTask)?
    private var refreshTimer: (UUID, any EluV2ConfigScheduledTask)?
    private var lastWall: Date?
    private var lastContinuous: UInt64?
    private var clockFailed = false

    init(
        siteKey: String,
        configHost: URL = URL(string: "https://elu.dev")!,
        transport: any EluV2ConfigTransport = EluV2URLSessionConfigTransport(),
        clock: EluV2ConfigClock = .live,
        scheduler: any EluV2ConfigLifecycleScheduler = EluV2TaskConfigScheduler(),
        onChange: @escaping @Sendable (EluV2ConfigLifecycleToken) -> Void
    ) throws {
        source = try EluV2ConfigSource(siteKey: siteKey, configHost: configHost, transport: transport, clock: clock)
        authorityGate = EluV2ConfigAuthorityGate(siteKey: siteKey, clock: clock)
        self.clock = clock
        self.scheduler = scheduler
        self.onChange = onChange
    }

    func start() {
        guard !started, !closed else { return }
        started = true
        publish(.unavailable(foreground ? .loading : .background))
        refreshWanted = foreground
        launchIfNeeded()
    }

    func setForeground(_ value: Bool) {
        guard !closed, foreground != value else { return }
        foreground = value
        guard started else { return }
        if value {
            publish(.unavailable(.loading))
            refreshWanted = true
            launchIfNeeded()
        } else {
            invalidate(.background, resume: false)
        }
    }

    /// Coalesces repeated requests while the sole physical fetch is occupied.
    func refresh() {
        guard started, foreground, !closed else { return }
        refreshWanted = true
        launchIfNeeded()
    }

    func close() {
        guard !closed else { return }
        closed = true
        authorityGate.close()
        started = false
        invalidate(.closed, resume: false)
        let source = source
        Task { await source.close() }
    }

    /// The callback receives data only while its notification token is current.
    /// Application runs without an actor suspension between the check and use.
    @discardableResult
    func consumeCurrent(
        _ candidate: EluV2ConfigLifecycleToken,
        apply: @Sendable (EluV2ConfigLifecycleState) -> Void
    ) -> Bool {
        validatePublishedLease()
        guard candidate == token else { return false }
        apply(state)
        return true
    }

    private func launchIfNeeded() {
        guard started, foreground, !closed, !clockFailed,
              refreshWanted, activeFetch == nil, invalidations == 0
        else { return }
        guard sampleClock() != nil else {
            invalidate(.invalidClock, resume: false)
            return
        }
        refreshWanted = false
        cancelRefreshTimer()
        let id = UUID()
        let fetchEpoch = epoch
        let source = source
        let task = Task<Void, Never> { [weak self] in
            let result = await source.refresh()
            await self?.finishFetch(id: id, fetchEpoch: fetchEpoch, result: result)
        }
        activeFetch = ActiveFetch(id: id, epoch: fetchEpoch, task: task)
    }

    private func finishFetch(id: UUID, fetchEpoch: UUID, result: EluV2ConfigRefreshResult) async {
        guard activeFetch?.id == id else { return }
        guard accepts(fetchEpoch) else {
            await discardCompletedFetch()
            return
        }
        let lease: EluV2ConfigLease?
        if case .document = result { lease = await source.currentLease() } else { lease = nil }
        guard accepts(fetchEpoch) else {
            await discardCompletedFetch()
            return
        }
        activeFetch = nil
        if let lease, let remaining = remainingNanoseconds(lease), remaining > 0 {
            failures = 0
            publishedLease = lease
            publish(.document(lease.data))
            armExpiry(after: remaining)
            // Avoid an increasingly tight refresh loop near the end of a lease.
            if remaining > Self.second {
                let lead = min(60 * Self.second, remaining / 5)
                armRefresh(after: max(Self.second, remaining - lead))
            }
        } else if clockFailed {
            invalidate(.invalidClock, resume: false)
        } else {
            publishedLease = nil
            cancelExpiryTimer()
            publish(.unavailable(.refreshFailed))
            failures = min(failures + 1, 7)
            let delay = min(UInt64(1 << (failures - 1)), 60) * Self.second
            armRefresh(after: delay)
        }
        launchIfNeeded()
    }

    private func accepts(_ candidate: UUID) -> Bool {
        started && foreground && !closed && candidate == epoch
    }

    private func discardCompletedFetch() async {
        activeFetch = nil
        // A noncooperative request might have begun just after a prior
        // withdrawal. Clear it before allowing the pending foreground fetch.
        invalidations += 1
        await source.withdraw()
        invalidations -= 1
        launchIfNeeded()
    }

    private func invalidate(_ reason: EluV2ConfigWithdrawal, resume: Bool) {
        epoch = UUID()
        publishedLease = nil
        cancelExpiryTimer()
        cancelRefreshTimer()
        activeFetch?.task.cancel()
        refreshWanted = resume && started && foreground && !closed
        publish(.unavailable(reason))
        invalidations += 1
        let source = source
        Task { [weak self] in
            await source.withdraw()
            await self?.finishedInvalidation()
        }
    }

    private func finishedInvalidation() {
        invalidations -= 1
        launchIfNeeded()
    }

    private func validatePublishedLease() {
        guard let lease = publishedLease else { return }
        guard let remaining = remainingNanoseconds(lease), remaining > 0 else {
            if clockFailed {
                invalidate(.invalidClock, resume: false)
            } else {
                // Withdraw the expired publication independently. A bounded
                // renewal already in flight may still install a newer lease.
                publishedLease = nil
                cancelExpiryTimer()
                cancelRefreshTimer()
                publish(.unavailable(.expired))
                if activeFetch == nil {
                    refreshWanted = true
                    launchIfNeeded()
                }
            }
            return
        }
    }

    private func armExpiry(after delay: UInt64) {
        cancelExpiryTimer()
        let id = UUID()
        let timer = scheduler.schedule(afterNanoseconds: delay) { [weak self] in
            await self?.expiryFired(id)
        }
        expiryTimer = (id, timer)
    }

    private func expiryFired(_ id: UUID) {
        guard expiryTimer?.0 == id, started, foreground, !closed else { return }
        expiryTimer = nil
        validatePublishedLease()
        if let lease = publishedLease, let remaining = remainingNanoseconds(lease), remaining > 0 {
            armExpiry(after: remaining)
        }
    }

    private func armRefresh(after delay: UInt64) {
        cancelRefreshTimer()
        let id = UUID()
        let timer = scheduler.schedule(afterNanoseconds: delay) { [weak self] in
            await self?.refreshFired(id)
        }
        refreshTimer = (id, timer)
    }

    private func refreshFired(_ id: UUID) {
        guard refreshTimer?.0 == id, started, foreground, !closed else { return }
        refreshTimer = nil
        refreshWanted = true
        // Expiry validation can start this request itself. Do not queue a
        // second refresh after it consumes the pending flag.
        validatePublishedLease()
        launchIfNeeded()
    }

    private func cancelExpiryTimer() { expiryTimer?.1.cancel(); expiryTimer = nil }
    private func cancelRefreshTimer() { refreshTimer?.1.cancel(); refreshTimer = nil }

    private func publish(_ next: EluV2ConfigLifecycleState) {
        guard next != state else { return }
        state = next
        token = EluV2ConfigLifecycleToken()
        authorityGate.publish(token: token, lease: publishedLease)
        onChange(token)
    }

    private func remainingNanoseconds(_ lease: EluV2ConfigLease) -> UInt64? {
        guard let sample = sampleClock(),
              !lease.expiresAt.isAtOrBefore(sample.wall),
              sample.continuous < lease.continuousDeadline,
              let wallBudget = lease.expiresAt.floorNanoseconds(after: sample.wall),
              let continuousBudget = clock.floorNanoseconds(lease.continuousDeadline - sample.continuous)
        else { return nil }
        return min(wallBudget, continuousBudget)
    }

    private func sampleClock() -> (wall: Date, continuous: UInt64)? {
        guard !clockFailed else { return nil }
        let wall = clock.wallNow()
        let continuous = clock.continuousNow()
        guard (try? EluV1Timestamp.exactClock(wall)) != nil,
              lastWall.map({ wall >= $0 }) ?? true,
              lastContinuous.map({ continuous >= $0 }) ?? true
        else {
            clockFailed = true
            return nil
        }
        lastWall = wall
        lastContinuous = continuous
        return (wall, continuous)
    }

    private static let second: UInt64 = 1_000_000_000
}
