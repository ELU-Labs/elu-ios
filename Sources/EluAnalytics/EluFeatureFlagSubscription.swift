import Foundation

/// Retain this token to keep receiving flag snapshots. Cancellation is
/// idempotent and also happens on deinit. It prevents callbacks that have not
/// begun; a callback already admitted may finish.
public final class EluFeatureFlagSubscription {
    private let state: EluFeatureFlagCancellation
    private let remove: () -> Void

    init(state: EluFeatureFlagCancellation, remove: @escaping () -> Void) {
        self.state = state
        self.remove = remove
    }

    public func cancel() {
        if state.cancel() { remove() }
    }

    deinit { cancel() }
}

/// Only this Boolean crosses queues; every access is protected by the lock.
/// The registration owner removes the callback on its existing serial queue.
final class EluFeatureFlagCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        cancelled = true
        return true
    }

    /// Linearization point for callback admission, never held across client code.
    func admit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled
    }
}
