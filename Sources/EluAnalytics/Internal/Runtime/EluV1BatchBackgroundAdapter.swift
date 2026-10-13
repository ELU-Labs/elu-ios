#if canImport(UIKit)
import UIKit

@MainActor
protocol EluV1IOSBackgroundTaskManaging: AnyObject {
    func begin(
        name: String,
        expiration: @escaping @MainActor @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier
    func end(_ identifier: UIBackgroundTaskIdentifier)
}

@MainActor
final class EluV1UIApplicationBackgroundTaskManager: EluV1IOSBackgroundTaskManaging {
    func begin(
        name: String,
        expiration: @escaping @MainActor @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name) {
            Task { @MainActor in expiration() }
        }
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

/// Runs one finite foreground-session delivery pass under an iOS background
/// assertion. It never owns a background URLSession and it ends the assertion
/// exactly once on success, error, cancellation, or expiration.
@MainActor
final class EluV1BatchBackgroundAdapter {
    private final class IdentifierBox {
        var value = UIBackgroundTaskIdentifier.invalid
        var expiredBeforeInstallation = false
    }

    private struct ActivePass {
        let identifier: UIBackgroundTaskIdentifier
        let task: Task<Void, Never>
    }

    private let manager: any EluV1IOSBackgroundTaskManaging
    private var active: ActivePass?

    init(manager: any EluV1IOSBackgroundTaskManaging) {
        self.manager = manager
    }

    @discardableResult
    func start(
        operation: @escaping @Sendable () async throws -> Void
    ) -> Bool {
        guard active == nil else { return false }

        let identifierBox = IdentifierBox()
        let identifier = manager.begin(name: "ELU event delivery") { [weak self] in
            guard identifierBox.value != .invalid else {
                identifierBox.expiredBeforeInstallation = true
                return
            }
            self?.expire(identifier: identifierBox.value)
        }
        identifierBox.value = identifier
        guard identifier != .invalid else { return false }

        let task = Task { [self] in
            do {
                try await operation()
            } catch {
                // Queue state remains durable. Ending the finite assertion is
                // required regardless of how the pass terminates.
            }
            self.finish(identifier: identifier)
        }
        active = ActivePass(identifier: identifier, task: task)
        if identifierBox.expiredBeforeInstallation {
            expire(identifier: identifier)
        }
        return true
    }

    func cancel() {
        guard let active else { return }
        active.task.cancel()
        finish(identifier: active.identifier)
    }

    private func expire(identifier: UIBackgroundTaskIdentifier) {
        guard let active, active.identifier == identifier else { return }
        active.task.cancel()
        finish(identifier: identifier)
    }

    private func finish(identifier: UIBackgroundTaskIdentifier) {
        guard active?.identifier == identifier else { return }
        active = nil
        manager.end(identifier)
    }
}
#endif
