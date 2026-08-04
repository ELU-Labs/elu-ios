import Foundation

/// Registration-order callback storage. The owner mutates it on the SDK's
/// serial queue and chooses the public delivery queue explicitly.
struct EluCallbackRegistry {
    private var callbacks: [() -> Void] = []

    var count: Int { callbacks.count }

    mutating func append(_ callback: @escaping () -> Void) {
        callbacks.append(callback)
    }

    func dispatch(on queue: DispatchQueue) {
        let snapshot = callbacks
        queue.async {
            snapshot.forEach { $0() }
        }
    }
}
