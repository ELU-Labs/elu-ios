import Foundation

/// A local strengthening epoch, independent of remote policy and the byte profile.
/// Buffered cleartext never survives a view restriction accepted after collection.
final class EluNativeViewPrivacy: @unchecked Sendable {
    static let shared = EluNativeViewPrivacy()
    private let lock = NSLock()
    private var revision = UUID()
    private var observers: [UUID: @Sendable () -> Void] = [:]

    func snapshot() -> UUID { lock.lock(); defer { lock.unlock() }; return revision }
    func isCurrent(_ value: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return revision == value
    }
    func strengthen() {
        lock.lock(); revision = UUID(); let callbacks = Array(observers.values); lock.unlock()
        for callback in callbacks { callback() }
    }
    func observe(_ callback: @escaping @Sendable () -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let key = UUID(); observers[key] = callback; return key
    }
    func removeObserver(_ key: UUID) { lock.lock(); observers.removeValue(forKey: key); lock.unlock() }
}
