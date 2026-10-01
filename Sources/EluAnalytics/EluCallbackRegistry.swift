import Foundation

/// Registration-order callback storage. The owner mutates it on the SDK's
/// serial queue and chooses the public delivery queue explicitly.
struct EluCallbackRegistry {
    private var callbacks: [() -> Void] = []

    var count: Int { callbacks.count }

    mutating func append(_ callback: @escaping () -> Void) {
        callbacks.append(callback)
    }

    func dispatch(on queue: DispatchQueue, ifCurrent: @escaping @Sendable () -> Bool = { true }) {
        let snapshot = callbacks
        queue.async {
            for callback in snapshot {
                guard ifCurrent() else { return }
                callback()
            }
        }
    }
}

/// New subscriptions share the core's existing registration/delivery queues.
/// The legacy void registry remains unchanged.
struct EluFeatureFlagSubscriptionRegistry {
    struct Registration {
        let id: UUID
        let cancellation: EluFeatureFlagCancellation
        let callback: (EluFeatureFlagSnapshot) -> Void

        func deliver(_ publication: EluFeatureFlagPublication) {
            guard cancellation.admit(), publication.isCurrent() else { return }
            callback(publication.snapshot)
        }
    }
    private var registrations: [Registration] = []
    var count: Int { registrations.count }

    mutating func append(_ registration: Registration) {
        guard registration.cancellation.admit() else { return }
        registrations.append(registration)
    }
    mutating func remove(_ id: UUID) { registrations.removeAll { $0.id == id } }

    func dispatch(_ publication: EluFeatureFlagPublication, on queue: DispatchQueue) {
        let retained = registrations
        queue.async {
            for registration in retained { registration.deliver(publication) }
        }
    }
}
