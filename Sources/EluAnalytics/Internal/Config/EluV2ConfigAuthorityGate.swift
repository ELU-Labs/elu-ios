import Foundation

/// A source decision carried across asynchronous work. This is not channel authority.
/// Only the originating gate can consume it, and its original lease never renews.
struct EluV2ConfigAuthorityWitness: Equatable, Sendable {
    fileprivate let gateID: UUID
    fileprivate let token: EluV2ConfigLifecycleToken
    let data: Data
    let expiresAt: EluV1Timestamp
    let continuousDeadline: UInt64
    let nativeV3: EluNativeV3ConfigParser.Parsed?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.gateID == rhs.gateID && lhs.token == rhs.token && lhs.data == rhs.data
            && lhs.expiresAt == rhs.expiresAt && lhs.continuousDeadline == rhs.continuousDeadline
            && lhs.nativeV3?.data == rhs.nativeV3?.data
    }
}

/// Synchronous source fence shared by the lifecycle actor and final channel owners.
/// Consumers may hold this lock only for an in-memory check/publication, never SQLite,
/// network work, main-queue callbacks, or an actor suspension.
final class EluV2ConfigAuthorityGate: @unchecked Sendable {
    let siteKey: String
    private let id = UUID()
    private let clock: EluV2ConfigClock
    private let sourceDenials: EluV2ConfigSourceDenials?
    private let lock = NSLock()
    private var witness: EluV2ConfigAuthorityWitness?
    private var retainedLease: EluV2ConfigLease?
    private var closed = false
    private var suspension: UUID?
    private var clockFailed = false
    private var lastWall: Date?
    private var lastContinuous: UInt64?

    init(siteKey: String, clock: EluV2ConfigClock = .live,
         sourceDenials: EluV2ConfigSourceDenials? = nil) {
        self.siteKey = siteKey
        self.clock = clock
        self.sourceDenials = sourceDenials?.belongs(to: siteKey) == true ? sourceDenials : nil
    }

    // Denial access deliberately survives source expiry, suspension and close.
    // No gate lock is held while the original queue performs durable work.
    func pendingDenial() -> EluV2ConfigSourceDenial? {
        lock.lock(); defer { lock.unlock() }
        let pending = sourceDenials?.pending()
        if pending != nil { witness = nil }
        return pending
    }
    func retainsDenial(_ candidate: EluV2ConfigSourceDenial) -> Bool {
        sourceDenials?.contains(candidate) == true
    }
    func acknowledgeDenial(_ candidate: EluV2ConfigSourceDenial) {
        lock.lock(); defer { lock.unlock() }
        guard sourceDenials?.contains(candidate) == true else { return }
        witness = nil
        sourceDenials?.acknowledge(candidate)
    }

    /// Lifecycle-only publication, before notifying queued consumers. A nil lease
    /// withdraws locally without changing any channel's config ordering boundary.
    func publish(token: EluV2ConfigLifecycleToken, lease: EluV2ConfigLease?) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !clockFailed, suspension == nil else { witness = nil; return }
        if let lease {
            // A v3 witness must carry the original parser-owned receipt for this
            // exact embedded base, never a policy paired with unrelated bytes.
            guard lease.nativeV3.map({ $0.configV2Data == lease.data && $0.base.expiresAt == lease.expiresAt }) ?? true else {
                witness = nil; return
            }
            let pinned: EluV2ConfigLease
            if let retainedLease, retainedLease.receiptData == lease.receiptData {
                pinned = EluV2ConfigLease(data: lease.data, expiresAt: retainedLease.expiresAt,
                    continuousDeadline: min(retainedLease.continuousDeadline, lease.continuousDeadline),
                    nativeV3: lease.nativeV3)
            } else {
                pinned = lease
            }
            retainedLease = pinned
            witness = EluV2ConfigAuthorityWitness(gateID: id, token: token, data: pinned.data,
                expiresAt: pinned.expiresAt, continuousDeadline: pinned.continuousDeadline, nativeV3: pinned.nativeV3)
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
        if sourceDenials?.pending() != nil { witness = nil; return false }
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
