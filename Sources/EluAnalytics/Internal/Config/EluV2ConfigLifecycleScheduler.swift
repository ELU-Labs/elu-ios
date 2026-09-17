import Foundation

protocol EluV2ConfigScheduledTask: Sendable {
    func cancel()
}

protocol EluV2ConfigLifecycleScheduler: Sendable {
    func schedule(
        afterNanoseconds delay: UInt64,
        action: @escaping @Sendable () async -> Void
    ) -> any EluV2ConfigScheduledTask
}

struct EluV2TaskConfigScheduler: EluV2ConfigLifecycleScheduler {
    func schedule(
        afterNanoseconds delay: UInt64,
        action: @escaping @Sendable () async -> Void
    ) -> any EluV2ConfigScheduledTask {
        EluV2ConfigTaskTimer(task: Task {
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !Task.isCancelled else { return }
            await action()
        })
    }
}

private struct EluV2ConfigTaskTimer: EluV2ConfigScheduledTask {
    let task: Task<Void, Never>
    func cancel() { task.cancel() }
}
