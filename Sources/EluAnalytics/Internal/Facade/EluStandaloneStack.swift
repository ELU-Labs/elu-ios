import Foundation

/// Internal composition only. The public bootstrap selects no new backend here.
/// One source and one physical transport per channel live for the entire stack.
final class EluStandaloneStack: @unchecked Sendable {
    let runtime: EluStandaloneRuntime
    let flags: EluV1FlagClient
    let lifecycle: EluV2ConfigLifecycle
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var latestDecision = UUID()
    private var started = false
    private var foreground = false
    private var closed = false
    private var onIntent: (@Sendable () -> Void)?
    private var onSettled: (@Sendable () -> Void)?
    private var onReady: (@Sendable (@escaping @Sendable () -> Bool) -> Void)?

    private init(runtime: EluStandaloneRuntime, flags: EluV1FlagClient, lifecycle: EluV2ConfigLifecycle) {
        self.runtime = runtime
        self.flags = flags
        self.lifecycle = lifecycle
    }

    static func make(
        rootDirectoryURL: URL,
        siteKey: String,
        configHost: URL,
        configTransport: any EluV2ConfigTransport = EluV2URLSessionConfigTransport(),
        eventTransport: any EluV1AuthorizedBatchTransport = EluV1URLSessionBatchTransport(),
        flagTransport: (any EluV1AuthorizedFlagTransport)? = nil,
        clock: EluV2ConfigClock = .live,
        scheduler: any EluV2ConfigLifecycleScheduler = EluV2TaskConfigScheduler(),
        versions: EluVersionContext? = nil,
        timeZoneIdentifier: @escaping @Sendable () -> String? = { TimeZone.current.identifier },
        performance: EluPerformanceOptions = .init()
    ) async throws -> EluStandaloneStack {
        let relay = EluStandaloneConfigRelay()
        let lifecycle = try EluV2ConfigLifecycle(siteKey: siteKey, configHost: configHost,
            transport: configTransport, clock: clock, scheduler: scheduler,
            onChange: { relay.publish($0) })
        _ = lifecycle.authorityGate.suspend()
        let runtime = try await EluStandaloneRuntime.make(rootDirectoryURL: rootDirectoryURL,
            siteKey: siteKey, versions: versions, transport: eventTransport,
            configurationGate: lifecycle.authorityGate, clock: clock.wallNow,
            continuousClock: clock.continuousNow, continuousBudgetConverter: clock.floorTicks,
            nativeContinuousNanoseconds: clock.floorNanoseconds,
            time: EluV1BatchTimeSource(wallNow: clock.wallNow,
                monotonicNow: { clock.floorNanoseconds(clock.continuousNow()) ?? UInt64.max },
                sleep: { try await Task.sleep(nanoseconds: $0) }),
            timeZoneIdentifier: timeZoneIdentifier, performance: performance)
        do {
            let selectedFlags = try flagTransport ?? EluV1URLSessionFlagTransport(siteKey: siteKey)
            let flags = try await runtime.flagClient(transport: selectedFlags)
            let stack = EluStandaloneStack(runtime: runtime, flags: flags, lifecycle: lifecycle)
            relay.attach(stack)
            return stack
        } catch {
            await lifecycle.close()
            await runtime.close()
            throw error
        }
    }

    func observe(onIntent: @escaping @Sendable () -> Void, onSettled: @escaping @Sendable () -> Void,
                 onReady: (@Sendable (@escaping @Sendable () -> Bool) -> Void)? = nil) {
        lock.lock()
        self.onIntent = onIntent
        self.onSettled = onSettled
        self.onReady = onReady
        lock.unlock()
    }

    /// Starts denied. Only a subsequently observed active application opens it.
    func start() {
        lock.lock()
        guard !started, !closed else { lock.unlock(); return }
        started = true
        enqueueLocked { [lifecycle] in
            await lifecycle.setForeground(false)
            await lifecycle.start()
        }
        lock.unlock()
    }

    func setForeground(_ foreground: Bool, ifCurrent: () -> Bool = { true }) {
        lock.lock()
        guard started, !closed, ifCurrent(), self.foreground != foreground else { lock.unlock(); return }
        self.foreground = foreground
        latestDecision = UUID()
        let transition = lifecycle.authorityGate.suspend()
        runtime.invalidateAuthority()
        let notify = onIntent
        enqueueLocked { [lifecycle] in
            if foreground {
                guard lifecycle.authorityGate.resume(transition) else { return }
                await lifecycle.setForeground(true)
            } else {
                await lifecycle.setForeground(false)
            }
        }
        lock.unlock()
        notify?()
    }

    fileprivate func accept(_ token: EluV2ConfigLifecycleToken) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        let decision = UUID()
        latestDecision = decision
        let witness = lifecycle.authorityGate.witness(for: token)
        runtime.invalidateAuthority()
        let intent = runtime.beginFlagProjectionIntent()
        let notify = onIntent
        let ready = EluStandaloneNotificationSignal()
        enqueueLocked { [weak self, runtime, flags] in
            await ready.wait()
            defer { runtime.finishFlagProjectionIntent(intent) }
            guard let self, self.isCurrent(decision) else { return }
            if let witness {
                _ = await runtime.applyConfiguration(witness.data, sourceWitness: witness)
                guard self.isCurrent(decision) else { return }
                _ = await flags.applyConfig(witness.data, sourceWitness: witness)
            } else {
                await runtime.withdrawConfiguration(ifCurrent: { self.isCurrent(decision) })
                guard self.isCurrent(decision) else { return }
                await flags.withdrawConfiguration()
            }
            guard self.isCurrent(decision) else { return }
            // Finish before notifying so the resulting projection can be exported.
            runtime.finishFlagProjectionIntent(intent)
            self.notifySettled(witness: witness, decision: decision)
        }
        lock.unlock()
        notify?()
        ready.release()
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        latestDecision = UUID()
        lifecycle.authorityGate.close()
        runtime.invalidateAuthority()
        let notify = onIntent
        enqueueLocked { [lifecycle, flags, runtime] in
            await lifecycle.close()
            await flags.close()
            await runtime.close()
        }
        lock.unlock()
        notify?()
    }

    private func isCurrent(_ decision: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && decision == latestDecision
    }

    private func notifySettled(witness: EluV2ConfigAuthorityWitness?, decision: UUID) {
        lock.lock(); let notify = onSettled; let ready = onReady; lock.unlock()
        if let witness {
            ready? { [weak self, lifecycle] in
                self?.isCurrent(decision) == true && lifecycle.authorityGate.isCurrent(witness)
            }
        }
        notify?()
    }

    private func enqueueLocked(_ operation: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task { await previous?.value; await operation() }
    }

    func settled() async {
        lock.lock(); let current = tail; lock.unlock()
        await current?.value
    }
}

private final class EluStandaloneConfigRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stack: EluStandaloneStack?
    func attach(_ stack: EluStandaloneStack) { lock.lock(); self.stack = stack; lock.unlock() }
    func publish(_ token: EluV2ConfigLifecycleToken) {
        lock.lock(); let current = stack; lock.unlock()
        current?.accept(token)
    }
}

/// Orders an in-memory intent notification before its asynchronous application,
/// without running callbacks under the stack or source gate lock.
private final class EluStandaloneNotificationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released { lock.unlock(); continuation.resume() }
            else { waiter = continuation; lock.unlock() }
        }
    }
    func release() {
        lock.lock(); released = true; let current = waiter; waiter = nil; lock.unlock()
        current?.resume()
    }
}
