import Foundation

/// In-memory intent fence. Durable continuity closes separately on the queue;
/// permission cannot reopen while any original closure remains unsettled.
final class EluNativeDiagnosticsGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    private var pending: Set<UUID> = []
    private var consentPending: Set<UUID> = []
    private var closed = false
    func begin() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID(); pending.insert(id); generation = UUID(); return id
    }
    func finish(_ id: UUID) { lock.lock(); pending.remove(id); lock.unlock() }
    func beginConsent(_ id: UUID) {
        lock.lock(); pending.insert(id); consentPending.insert(id); generation = UUID(); lock.unlock()
    }
    func consentIntents() -> Set<UUID> {
        lock.lock(); defer { lock.unlock() }; return consentPending
    }
    /// One accepted consent transaction closes all previously observed intervals.
    /// Never settle a new intent accepted while that transaction was in flight.
    func finishConsent(_ original: Set<UUID>) {
        lock.lock(); pending.subtract(original); consentPending.subtract(original); lock.unlock()
    }
    func token() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return !closed && pending.isEmpty ? generation : nil
    }
    func isCurrent(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && pending.isEmpty && generation == token
    }
    func invalidate() { lock.lock(); generation = UUID(); lock.unlock() }
    func close() { lock.lock(); closed = true; generation = UUID(); lock.unlock() }
}
