import Foundation
import Darwin

struct EluNativePerformanceSettings: Equatable, Sendable {
    let memory: Bool
    let mainThreadStalls: Bool
    let intervalMilliseconds: Int
    let thresholdMilliseconds: Int

    static func resolve(_ local: EluPerformanceOptions, remote: EluCapturePerformancePolicy?) -> Self? {
        guard local.enabled, let remote,
              (5_000 ... 2_147_483_647).contains(local.sampleIntervalMilliseconds),
              (100 ... 60_000).contains(local.mainThreadStallThresholdMilliseconds) else { return nil }
        let memory = local.memory && remote.memory
        let stalls = local.mainThreadStalls && remote.mainThreadStalls
        guard memory || stalls else { return nil }
        return Self(memory: memory, mainThreadStalls: stalls,
            intervalMilliseconds: max(local.sampleIntervalMilliseconds, remote.sampleIntervalMilliseconds),
            thresholdMilliseconds: local.mainThreadStallThresholdMilliseconds)
    }
}

/// One outstanding main-thread probe; counters are bounded and retain no stacks,
/// messages, URLs, or view content. Unfinished stalls are counted after recovery.
struct EluNativePerformanceWindow {
    let settings: EluNativePerformanceSettings
    private var began: UInt64
    private var last: UInt64
    private var pending: UInt64?
    private var count: Int64 = 0
    private var total: Double = 0
    private var maximum: Double = 0

    init(settings: EluNativePerformanceSettings, now: UInt64) {
        self.settings = settings; began = now; last = now
    }
    mutating func acknowledge(at now: UInt64) -> Bool {
        guard now >= last else { return false }
        last = now
        guard let pending else { return true }
        let delay = Double(now - pending) / 1_000_000
        self.pending = nil
        if delay >= Double(settings.thresholdMilliseconds) {
            count = min(count + 1, 10_000)
            total = min(total + delay, 9_007_199_254_740_991)
            maximum = max(maximum, delay)
        }
        return true
    }
    mutating func tick(at now: UInt64, canProbe: Bool = true) -> (probe: Bool, fields: [String: EluJSONValue]?)? {
        guard now >= last else { return nil }
        last = now
        let probe = canProbe && settings.mainThreadStalls && pending == nil
        if probe { pending = now }
        guard now - began >= UInt64(settings.intervalMilliseconds) * 1_000_000 else { return (probe, nil) }
        var fields: [String: EluJSONValue] = [:]
        if settings.mainThreadStalls {
            fields["$main_thread_stall_count"] = .integer(count)
            fields["$main_thread_stall_total_ms"] = .number(total)
            fields["$main_thread_stall_max_ms"] = .number(maximum)
            fields["$main_thread_stall_threshold_ms"] = .integer(Int64(settings.thresholdMilliseconds))
        }
        began = now; count = 0; total = 0; maximum = 0
        return (probe, fields)
    }
}

final class EluNativePerformanceMonitor: @unchecked Sendable {
    private struct Run {
        let id: UUID
        var window: EluNativePerformanceWindow
        let authority: @Sendable () -> Bool
        let emit: @Sendable (UUID, [String: EluJSONValue]) -> Void
    }
    private let lock = NSLock()
    private let lane = DispatchQueue(label: "dev.elu.performance", qos: .utility)
    private var run: Run?
    private var timer: DispatchSourceTimer?
    private var index: Int64 = 0
    private var pendingMainProbe = false
    private var mutations: Set<UUID> = []
    private var foreground = false
    private let now: @Sendable () -> UInt64
    private let footprint: @Sendable () -> UInt64?
    init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         footprint: @escaping @Sendable () -> UInt64? = { processFootprint() }) {
        self.now = now; self.footprint = footprint
    }
    deinit { invalidate() }
    func invalidate() {
        lock.lock(); run = nil; let old = timer; timer = nil; lock.unlock()
        old?.cancel()
    }
    func setForeground(_ value: Bool) {
        lock.lock(); foreground = value; lock.unlock()
        if !value { invalidate() }
    }
    func beginMutation() -> UUID {
        lock.lock(); let id = UUID(); mutations.insert(id)
        run = nil; let old = timer; timer = nil; lock.unlock(); old?.cancel()
        return id
    }
    func finishMutation(_ id: UUID) {
        lock.lock(); mutations.remove(id); lock.unlock()
    }
    func isCurrent(_ id: UUID) -> Bool {
        lock.lock(); let value = run; let allowed = foreground && mutations.isEmpty; lock.unlock()
        return allowed && value?.id == id && value?.authority() == true
    }
    func start(settings: EluNativePerformanceSettings, authority: @escaping @Sendable () -> Bool,
               emit: @escaping @Sendable (UUID, [String: EluJSONValue]) -> Void) {
        invalidate()
        guard authority() else { return }
        let id = UUID(), source = DispatchSource.makeTimerSource(queue: lane)
        source.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
        source.setEventHandler { [weak self] in self?.tick(id) }
        lock.lock()
        guard foreground, mutations.isEmpty else { lock.unlock(); source.resume(); source.cancel(); return }
        run = Run(id: id, window: .init(settings: settings, now: now()), authority: authority, emit: emit)
        timer = source
        lock.unlock()
        source.resume()
    }
    private func tick(_ id: UUID) {
        guard isCurrent(id) else { invalidateIfCurrent(id); return }
        lock.lock()
        guard var value = run, value.id == id else { lock.unlock(); return }
        guard let tick = value.window.tick(at: now(), canProbe: !pendingMainProbe) else { lock.unlock(); invalidateIfCurrent(id); return }
        run = value
        if tick.probe { pendingMainProbe = true }
        var fields = tick.fields
        if fields != nil {
            guard index < 9_007_199_254_740_991 else { lock.unlock(); invalidateIfCurrent(id); return }
            index += 1
            fields?["$performance_sample_index"] = .integer(index)
        }
        lock.unlock()
        if tick.probe {
            DispatchQueue.main.async { [weak self] in self?.acknowledge(id) }
        }
        guard var fields, isCurrent(id) else { return }
        if value.window.settings.memory, let bytes = footprint(), bytes <= UInt64(Int64.max) {
            fields["$memory_process_footprint_bytes"] = .integer(Int64(bytes))
        }
        guard value.window.settings.mainThreadStalls || fields["$memory_process_footprint_bytes"] != nil else { return }
        fields["$performance_platform"] = .string("ios")
        fields["$app_foreground"] = .bool(true)
        fields["$performance_sample_interval_ms"] = .integer(Int64(value.window.settings.intervalMilliseconds))
        if isCurrent(id) { value.emit(id, fields) }
    }
    private func acknowledge(_ id: UUID) {
        lock.lock()
        pendingMainProbe = false
        guard var value = run, value.id == id, foreground, mutations.isEmpty else { lock.unlock(); return }
        let valid = value.window.acknowledge(at: now())
        if valid { run = value }
        lock.unlock()
        if !valid { invalidateIfCurrent(id) }
    }
    private func invalidateIfCurrent(_ id: UUID) {
        lock.lock()
        guard run?.id == id else { lock.unlock(); return }
        run = nil; let old = timer; timer = nil; lock.unlock(); old?.cancel()
    }
    static func processFootprint() -> UInt64? {
        var information = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? information.phys_footprint : nil
    }
}
