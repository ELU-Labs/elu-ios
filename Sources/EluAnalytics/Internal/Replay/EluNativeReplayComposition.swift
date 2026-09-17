import Foundation

/// This relay grants no authority. It only closes local intake or schedules a
/// new observation after the owner has completed its ordered mutation.
final class EluNativeReplayCompositionRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var composition: EluNativeReplayComposition?
    func attach(_ value: EluNativeReplayComposition) { lock.lock(); composition = value; lock.unlock() }
    private func value() -> EluNativeReplayComposition? { lock.lock(); defer { lock.unlock() }; return composition }
    func withdraw() { value()?.withdraw() }
    func withdrawCapture() { value()?.withdrawCapture() }
    func request() { value()?.requestReevaluation() }
}

private final class EluNativeReplayCompositionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    private var closed = false
    private var stopCapture: (@Sendable () -> Void)?
    func token() -> UUID { lock.lock(); defer { lock.unlock() }; return generation }
    func current(_ token: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return !closed && token == generation }
    func installCapture(_ stop: (@Sendable () -> Void)?) {
        lock.lock(); let denied = closed; if !denied { stopCapture = stop }; lock.unlock()
        if denied { stop?() }
    }
    func withdrawCapture() {
        lock.lock(); let stop = stopCapture; stopCapture = nil; lock.unlock(); stop?()
    }
    func withdraw(terminal: Bool = false) {
        lock.lock(); generation = UUID(); closed = closed || terminal
        let stop = stopCapture; stopCapture = nil; lock.unlock(); stop?()
    }
}

/// Separate lanes share the original runtime and physical transport. Sealed
/// delivery never asks for a root, fresh capture projection, sample or budget.
actor EluNativeReplayComposition {
    enum CloseOutcome: Equatable, Sendable { case settled, quarantined }
    private weak var runtime: EluStandaloneRuntime?
    private let lifecycle: EluNativeReplayLifecycle
    private let capabilities: EluNativeReplayCapabilities
    private let delivery: EluV2ReplayDeliveryCoordinator
    private nonisolated let fence = EluNativeReplayCompositionFence()
    private var closed = false
    private var active: Bool
    private var evaluating = false
    private var needsEvaluation = false
    private var evaluationWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeTask: Task<CloseOutcome, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var deliveryTaskID: UUID?
    private var deliveryNeedsPass = false
    private var deliveryAuthority: EluV2ReplayDeliveryAuthority?
    private var captureQuarantined = false
    #if canImport(UIKit)
    private var selection: EluNativeReplaySelection?
    private var capture: EluNativeReplayCaptureOwner?
    private var capturePrepared: EluNativeReplayPreparedAuthority?
    private var captureID: UUID?
    #endif

    init(runtime: EluStandaloneRuntime, lifecycle: EluNativeReplayLifecycle,
         capabilities: EluNativeReplayCapabilities, delivery: EluV2ReplayDeliveryCoordinator,
         initiallyActive: Bool = true) {
        active = initiallyActive
        self.runtime = runtime; self.lifecycle = lifecycle
        self.capabilities = capabilities; self.delivery = delivery
    }

    deinit { fence.withdraw(terminal: true) }

    nonisolated func withdraw() { fence.withdraw() }
    nonisolated func withdrawCapture() { fence.withdrawCapture() }
    nonisolated func requestReevaluation() { Task { await self.reevaluate() } }

    func activate() async {
        guard !closed, !active else { return }
        active = true
        await reevaluate()
    }
    func reevaluate() async {
        guard !closed, active else { return }
        needsEvaluation = true
        guard !evaluating else { return }
        evaluating = true
        defer {
            evaluating = false
            let waiters = evaluationWaiters; evaluationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        while needsEvaluation && !closed {
            needsEvaluation = false
            let token = fence.token()
            guard let runtime else { break }
            let current = try? await runtime.currentSealedReplayDelivery(capabilities: capabilities)
            guard !closed, fence.current(token) else { continue }
            deliveryAuthority = current
            if let current {
                deliveryNeedsPass = true
                startDelivery(current)
            } else {
                deliveryNeedsPass = false
                await delivery.withdraw()
            }
            guard !closed, fence.current(token) else { continue }
            #if canImport(UIKit)
            await evaluateCapture(runtime, token: token)
            #endif
        }
    }

    private func startDelivery(_ authority: EluV2ReplayDeliveryAuthority) {
        guard !closed, deliveryTask == nil, authority.isCurrent() else { return }
        deliveryNeedsPass = false
        let id = UUID(), delivery = self.delivery
        deliveryTaskID = id
        deliveryTask = Task { [weak self] in
            let result = await delivery.trigger(authority)
            if result.stopped == .occupied {
                _ = await delivery.waitForCurrentPass()
                await self?.deliveryWasOccupied(id)
            }
            await self?.deliveryFinished(id)
        }
    }
    private func deliveryWasOccupied(_ id: UUID) {
        guard !closed, deliveryTaskID == id else { return }
        deliveryNeedsPass = true
    }
    private func deliveryFinished(_ id: UUID) {
        guard deliveryTaskID == id else { return }
        deliveryTask = nil; deliveryTaskID = nil
        guard !closed, deliveryNeedsPass, let authority = deliveryAuthority else { return }
        startDelivery(authority)
    }

    #if canImport(UIKit)
    private func evaluateCapture(_ runtime: EluStandaloneRuntime, token: UUID) async {
        guard !captureQuarantined, !capabilities.transports.isEmpty,
              !capabilities.readbackProvenProtocolGenerations.isEmpty else { return }
        let discovered = await lifecycle.selectCurrentRoot(reusing: selection)
        if let capture, let prepared = capturePrepared, let selection,
           prepared.isCurrent(), selection.isCurrent() {
            if !closed, fence.current(token), discovered?.isCurrent() == true, prepared.isCurrent() { return }
            capture.withdraw()
        }
        if let original = capture {
            let outcome = await original.stop()
            capture = nil; capturePrepared = nil; captureID = nil
            fence.installCapture(nil)
            if case .quarantined = outcome { captureQuarantined = true; return }
        }
        guard !closed, fence.current(token), !capabilities.transports.isEmpty,
              !capabilities.readbackProvenProtocolGenerations.isEmpty else { return }
        guard !closed, fence.current(token), let selected = discovered, selected.isCurrent() else { return }
        selection = selected
        guard let prepared = try? await runtime.prepareNativeReplay(capabilities: capabilities),
              !closed, fence.current(token), prepared.isCurrent(), selected.isCurrent() else { return }
        let original = await runtime.makeNativeReplayCapture(prepared: prepared, selection: selected,
            onCommitted: { [weak self] in self?.requestReevaluation() })
        guard let original else { return }
        capture = original; capturePrepared = prepared
        let id = UUID(); captureID = id
        fence.installCapture { [weak original] in original?.withdraw() }
        if closed || !fence.current(token) { original.withdraw() }
        Task { [weak self] in
            let outcome = await original.finished()
            await self?.captureFinished(id, outcome: outcome)
        }
    }
    private func captureFinished(_ id: UUID, outcome: EluNativeReplayCaptureOutcome) {
        guard captureID == id else { return }
        capture = nil; capturePrepared = nil; captureID = nil
        fence.installCapture(nil)
        if case .quarantined = outcome { captureQuarantined = true }
    }
    #endif

    /// Joins the retained current trigger and any timer-origin pass it encountered.
    func waitForCurrentDelivery() async {
        await deliveryTask?.value
        _ = await delivery.waitForCurrentPass()
    }

    /// Read-only causal test observation of the actual coordinator barrier.
    func registeredDeliveryWaitersForTesting() async -> Int {
        await delivery.registeredCloseWaiterCountForTesting()
    }

    /// A duplicate close joins the original close task. The active observation
    /// must finish before queue shutdown, as must timer-origin HTTP receipts.
    func closeAndWait() async -> CloseOutcome {
        if let closeTask { return await closeTask.value }
        closed = true; needsEvaluation = false; fence.withdraw(terminal: true)
        let task = Task { await self.finishClose() }
        closeTask = task
        return await task.value
    }
    private func finishClose() async -> CloseOutcome {
        if evaluating { await withCheckedContinuation { evaluationWaiters.append($0) } }
        #if canImport(UIKit)
        if let capture, case .quarantined = await capture.stop() { captureQuarantined = true }
        self.capture = nil; capturePrepared = nil; captureID = nil
        #endif
        let delivered = await delivery.closeAndWait()
        await deliveryTask?.value
        return captureQuarantined || delivered == .quarantined ? .quarantined : .settled
    }
}
