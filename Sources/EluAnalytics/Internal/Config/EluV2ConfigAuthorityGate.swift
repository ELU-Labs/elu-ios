import Foundation

/// A source decision carried across asynchronous work. This is not channel authority.
/// Only the originating gate can consume it, and its original lease never renews.
struct EluV2ConfigAuthorityWitness: Equatable, Sendable {
    fileprivate let gateID: UUID
    fileprivate let token: EluV2ConfigLifecycleToken
    let data: Data
    let expiresAt: EluV1Timestamp
    let continuousDeadline: UInt64
}

/// Synchronous source fence shared by the lifecycle actor and final channel owners.
/// Consumers may hold this lock only for an in-memory check/publication, never SQLite,
/// network work, main-queue callbacks, or an actor suspension.
final class EluV2ConfigAuthorityGate: @unchecked Sendable {
    let siteKey: String
    private let id = UUID()
    private let clock: EluV2ConfigClock
    private let lock = NSLock()
    private var witness: EluV2ConfigAuthorityWitness?
    private var retainedLease: EluV2ConfigLease?
    private var closed = false
    private var suspension: UUID?
    private var clockFailed = false
    private var lastWall: Date?
    private var lastContinuous: UInt64?

    init(siteKey: String, clock: EluV2ConfigClock = .live) {
        self.siteKey = siteKey
        self.clock = clock
    }

    /// Lifecycle-only publication, before notifying queued consumers. A nil lease
    /// withdraws locally without changing any channel's config ordering boundary.
    func publish(token: EluV2ConfigLifecycleToken, lease: EluV2ConfigLease?) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !clockFailed, suspension == nil else { witness = nil; return }
        if let lease {
            let pinned: EluV2ConfigLease
            if let retainedLease, retainedLease.data == lease.data {
                pinned = EluV2ConfigLease(data: lease.data, expiresAt: retainedLease.expiresAt,
                    continuousDeadline: min(retainedLease.continuousDeadline, lease.continuousDeadline))
            } else {
                pinned = lease
            }
            retainedLease = pinned
            witness = EluV2ConfigAuthorityWitness(gateID: id, token: token, data: pinned.data,
                expiresAt: pinned.expiresAt, continuousDeadline: pinned.continuousDeadline)
        } else {
            witness = nil
        }
        if !isLiveLocked() { witness = nil }
    }

    func witness(for token: EluV2ConfigLifecycleToken) -> EluV2ConfigAuthorityWitness? {
        lock.lock()
        defer { lock.unlock() }
        guard isLiveLocked(), witness?.token == token else { return nil }
        return witness
    }

    func isCurrent(_ candidate: EluV2ConfigAuthorityWitness?, data: Data? = nil) -> Bool {
        consume(candidate, data: data) {}
    }

    @discardableResult
    func consume(
        _ candidate: EluV2ConfigAuthorityWitness?,
        data: Data? = nil,
        apply: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let candidate, isLiveLocked(), candidate.gateID == id,
              candidate == witness, data.map({ $0 == candidate.data }) ?? true
        else { return false }
        apply()
        return true
    }

    /// Synchronous application-lifecycle intent. An older queued foreground
    /// transition cannot undo a subsequently accepted background/close.
    func suspend() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        suspension = token
        witness = nil
        return token
    }

    @discardableResult
    func resume(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !clockFailed, suspension == token else { return false }
        suspension = nil
        return true
    }

    /// Terminal owner shutdown. Ordinary source withdrawal uses publish(nil).
    func close() {
        lock.lock()
        closed = true
        witness = nil
        lock.unlock()
    }

    private func isLiveLocked() -> Bool {
        guard !closed, !clockFailed, suspension == nil, let candidate = witness else { return false }
        let wall = clock.wallNow()
        let continuous = clock.continuousNow()
        guard (try? EluV1Timestamp.exactClock(wall)) != nil,
              lastWall.map({ wall >= $0 }) ?? true,
              lastContinuous.map({ continuous >= $0 }) ?? true
        else {
            clockFailed = true
            witness = nil
            return false
        }
        lastWall = wall
        lastContinuous = continuous
        guard !candidate.expiresAt.isAtOrBefore(wall), continuous < candidate.continuousDeadline else {
            witness = nil
            return false
        }
        return true
    }
}
