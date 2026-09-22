import Foundation

protocol EluV2ReplayHTTPTransport: Sendable {
    /// Implementations must apply the original synchronous check immediately
    /// before physical dispatch and retain their slot through physical cleanup.
    func send(_ dispatch: EluV2ReplayDispatch) async throws -> EluV1BatchHTTPResponse
}

struct EluV2ReplayDeliverySummary: Equatable, Sendable {
    var attempted = 0
    var accepted = 0
    var discardedTooLarge = 0
    var blocked = 0
    var retried = 0
    var stopped: Stop = .idle
    enum Stop: Equatable, Sendable { case idle, occupied, deferred, withdrawn, closed, bounded, storageFailure }
}

/// One physical replay slot, independent of the events/flags slots. This internal
/// driver is deliberately not constructed by public selection or recorder code.
private final class EluReplayPassFence: @unchecked Sendable {
    private let lock = NSLock()
    private var current = UUID()
    func token() -> UUID { lock.lock(); defer { lock.unlock() }; return current }
    func invalidate() { lock.lock(); current = UUID(); lock.unlock() }
    func contains(_ token: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return current == token }
}

actor EluV2ReplayDeliveryCoordinator {
    enum CloseOutcome: Equatable, Sendable { case settled, quarantined }
    static let maximumRequestsPerPass = 16
    private let queue: EluSQLiteRuntimeQueue
    private let transport: any EluV2ReplayHTTPTransport
    private let wallNow: @Sendable () -> Date
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var retryTimer: Task<Void, Never>?
    private var running = false
    private var credentialRefusedAuthority: EluV2ReplayDeliveryAuthority?
    private var closed = false
    private let passFence = EluReplayPassFence()
    private var generation: UUID { passFence.token() }
    private var retryTimerID: UUID?
    private var requestTask: Task<EluV1BatchHTTPResponse, Error>?
    private var receiptQuarantined = false
    private var closeWaiters: [CheckedContinuation<CloseOutcome, Never>] = []

    init(queue: EluSQLiteRuntimeQueue, transport: any EluV2ReplayHTTPTransport,
         wallNow: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.queue = queue; self.transport = transport; self.wallNow = wallNow; self.sleep = sleep
    }

    /// Logical withdrawal cancels work but never releases a physical slot early.
    func withdraw() { passFence.invalidate(); retryTimerID = nil; retryTimer?.cancel(); retryTimer = nil; requestTask?.cancel() }
    func close() { closed = true; withdraw() }

    /// Join the entire original pass, including physical cleanup and its durable
    /// receipt. Cancellation of a caller cannot turn unfinished work into release.
    func closeAndWait() async -> CloseOutcome {
        close()
        guard running else { return receiptQuarantined ? .quarantined : .settled }
        return await withCheckedContinuation { closeWaiters.append($0) }
    }

    /// Join an already-running external or timer pass without changing its authority.
    func waitForCurrentPass() async -> CloseOutcome {
        guard running else { return receiptQuarantined ? .quarantined : .settled }
        return await withCheckedContinuation { closeWaiters.append($0) }
    }

    /// Read-only test observation; callers cannot create or settle a waiter.
    func registeredCloseWaiterCountForTesting() -> Int { closeWaiters.count }

    private func finishPass() {
        running = false
        requestTask = nil
        let waiters = closeWaiters
        closeWaiters.removeAll()
        let outcome: CloseOutcome = receiptQuarantined ? .quarantined : .settled
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    /// A released claim still has an original queue receipt obligation. Keep a
    /// failed cleanup observable to every close waiter and forbid replacement.
    private func releaseClaim(_ claim: EluV2ReplayClaim) async -> Bool {
        do { _ = try await queue.finishReplayClaim(claim, completion: .released); return true }
        catch { receiptQuarantined = true; return false }
    }

    func trigger(_ authority: EluV2ReplayDeliveryAuthority) async -> EluV2ReplayDeliverySummary {
        var summary = EluV2ReplayDeliverySummary()
        guard !closed else { summary.stopped = .closed; return summary }
        guard !receiptQuarantined else { summary.stopped = .storageFailure; return summary }
        guard !running else { summary.stopped = .occupied; return summary }
        guard credentialRefusedAuthority?.hasSameSource(as: authority) != true else { summary.stopped = .withdrawn; return summary }
        retryTimerID = nil; retryTimer?.cancel(); retryTimer = nil
        running = true
        defer { finishPass() }
        let pass = generation
        while summary.attempted < Self.maximumRequestsPerPass {
            guard !Task.isCancelled, !closed, pass == generation, authority.isCurrent() else {
                summary.stopped = closed ? .closed : .withdrawn; return summary
            }
            let claim: EluV2ReplayClaim
            do {
                switch try await queue.claimNextReplay(authority) {
                case let .claimed(value): claim = value
                case .idle: return summary
                case .occupied: summary.stopped = .occupied; return summary
                case let .deferred(delay):
                    scheduleRetry(authority, after: delay, pass: pass)
                    summary.stopped = .deferred; return summary
                }
            } catch { summary.stopped = authority.isCurrent() ? .storageFailure : .withdrawn; return summary }
            guard !Task.isCancelled, pass == generation, !closed, claim.isCurrent() else {
                summary.stopped = await releaseClaim(claim) ? .withdrawn : .storageFailure
                return summary
            }
            let dispatch: EluV2ReplayDispatch
            do {
                let fence = passFence
                guard let enrolled = try await queue.enrollReplayDispatch(claim, dispatchAllowed: { fence.contains(pass) }) else {
                    summary.stopped = await releaseClaim(claim) ? .withdrawn : .storageFailure
                    return summary
                }
                dispatch = enrolled
                guard !closed, !Task.isCancelled, pass == generation, claim.isCurrent() else {
                    dispatch.cancelUnused()
                    summary.stopped = await releaseClaim(claim) ? .withdrawn : .storageFailure
                    return summary
                }
            } catch {
                _ = await releaseClaim(claim)
                summary.stopped = .storageFailure; return summary
            }
            let transport = self.transport
            let task = Task { try await transport.send(dispatch) }
            requestTask = task
            summary.attempted += 1
            let completion: EluV2ReplayClaimCompletion
            var outcome: EluV2ReplayResponseOutcome?
            do {
                let response = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                let value = EluV2ReplayResponse.classify(response, request: claim.row.prepared, now: wallNow())
                outcome = value; completion = .response(value)
            } catch is CancellationError {
                completion = .released
            } catch let error as EluV1BoundTransportError {
                completion = .released
                if error == .occupied { summary.stopped = .occupied }
            } catch let error as EluV1BatchDeliveryError {
                if error == .malformedResponse || error == .responseTooLarge {
                    outcome = .protocolBlocked; completion = .response(.protocolBlocked)
                } else { completion = .released }
            } catch { completion = .networkFailure }
            requestTask = nil
            dispatch.cancelUnused()
            do {
                if try await queue.finishReplayClaim(claim, completion: completion) {
                    switch outcome {
                    case .accepted: summary.accepted += 1
                    case .rejectedTooLarge: summary.discardedTooLarge += 1
                    case .credentialBlocked, .protocolBlocked: summary.blocked += 1
                    case .retry, .endpointCooldown: summary.retried += 1
                    case nil: if case .networkFailure = completion { summary.retried += 1 }
                    }
                }
            } catch { receiptQuarantined = true; summary.stopped = .storageFailure; return summary }
            if case .released = completion { summary.stopped = .withdrawn; return summary }
            if case .credentialBlocked(status: 401) = outcome {
                credentialRefusedAuthority = authority
                summary.stopped = .withdrawn; return summary
            }
            if case let .endpointCooldown(seconds) = outcome {
                scheduleRetry(authority, after: UInt64(ceil(seconds * 1_000_000_000)), pass: pass)
                summary.stopped = .deferred; return summary
            }
        }
        // Yield the actor/executor between bounded passes while preserving the
        // original withdrawal fence. The seventeenth ready row is not stranded.
        scheduleRetry(authority, after: 1, pass: pass)
        summary.stopped = .bounded
        return summary
    }
    private func scheduleRetry(_ authority: EluV2ReplayDeliveryAuthority, after delay: UInt64, pass: UUID) {
        guard !closed, pass == generation, authority.isCurrent() else { return }
        retryTimer?.cancel()
        let timerID = UUID(), sleep = self.sleep
        retryTimerID = timerID
        retryTimer = Task { [weak self] in
            do { try await sleep(max(1, delay)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.retryFired(authority, pass: pass, timerID: timerID)
        }
    }
    private func retryFired(_ authority: EluV2ReplayDeliveryAuthority, pass: UUID, timerID: UUID) async {
        guard !closed, generation == pass, retryTimerID == timerID else { return }
        retryTimerID = nil
        retryTimer = nil
        _ = await trigger(authority)
    }

}
