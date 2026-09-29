import Foundation
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

/// Registration is lazy and local opt-in only. No access to pastPayloads,
/// JSON/dictionary representations, metadata or call-stack trees.
final class EluNativeDiagnosticsMonitor: @unchecked Sendable {
    struct Receiver: Sendable {
        let includeLaunch: Bool
        let current: @Sendable () -> Bool
        let receive: @Sendable (EluNativeDiagnosticSummary) -> Void
    }
    private let lock = NSLock()
    private let registration = DispatchQueue(label: "dev.elu.diagnostics")
    private var stopped = false
    private var receiver: (id: UUID, value: Receiver)?
    #if canImport(MetricKit) && os(iOS)
    private var subscriber: EluMetricKitSubscriber?
    #endif
    func publish(includeLaunch: Bool, current: @escaping @Sendable () -> Bool,
                 receive: @escaping @Sendable (EluNativeDiagnosticSummary) -> Void) {
        withdraw()
        lock.lock()
        guard !stopped, current() else { lock.unlock(); return }
        let id = UUID()
        receiver = (id, Receiver(includeLaunch: includeLaunch, current: current, receive: receive))
        #if canImport(MetricKit) && os(iOS)
        let value = EluMetricKitSubscriber { [weak self] in self?.currentReceiver(id) }
        subscriber = value
        #endif
        lock.unlock()
        #if canImport(MetricKit) && os(iOS)
        registration.async { [weak self] in
            guard self?.currentReceiver(id) != nil else { return }
            MXMetricManager.shared.add(value)
            if self?.currentReceiver(id) == nil { MXMetricManager.shared.remove(value) }
        }
        #endif
    }
    private func currentReceiver(_ id: UUID) -> Receiver? {
        lock.lock(); let value = receiver; let stopped = stopped; lock.unlock()
        guard !stopped, value?.id == id, let receiver = value?.value, receiver.current() else { return nil }
        return receiver
    }
    func withdraw() {
        lock.lock(); receiver = nil
        #if canImport(MetricKit) && os(iOS)
        let original = subscriber; subscriber = nil
        #endif
        lock.unlock()
        #if canImport(MetricKit) && os(iOS)
        if let original { registration.async { MXMetricManager.shared.remove(original) } }
        #endif
    }
    func stop() { lock.lock(); stopped = true; lock.unlock(); withdraw() }
    func closeAndWait() async {
        stop()
        await withCheckedContinuation { continuation in registration.async { continuation.resume() } }
    }
    deinit { stop() }
}

#if canImport(MetricKit) && os(iOS)
private final class EluMetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    private let readReceiver: @Sendable () -> EluNativeDiagnosticsMonitor.Receiver?
    init(readReceiver: @escaping @Sendable () -> EluNativeDiagnosticsMonitor.Receiver?) {
        self.readReceiver = readReceiver
    }
    private func deliver(_ summary: EluNativeDiagnosticSummary, to receiver: EluNativeDiagnosticsMonitor.Receiver) {
        if receiver.current() { receiver.receive(summary) }
    }
    func didReceive(_ payloads: [MXMetricPayload]) {
        guard let receiver = readReceiver(), receiver.includeLaunch, payloads.count <= 16 else { return }
        for payload in payloads {
            guard receiver.current() else { return }
            guard let launch = payload.applicationLaunchMetrics else { continue }
            do {
                var fields = try histogram(launch.histogrammedTimeToFirstDraw, prefix: "first_draw")
                fields.merge(try histogram(launch.histogrammedApplicationResumeTime, prefix: "resume"), uniquingKeysWith: { _, right in right })
                deliver(try EluNativeDiagnosticSummary(kind: .launch, begin: payload.timeStampBegin, end: payload.timeStampEnd, fields: fields), to: receiver)
            } catch { continue }
        }
    }
    @available(iOS 14.0, *)
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let receiver = readReceiver(), payloads.count <= 16 else { return }
        for payload in payloads {
            guard receiver.current() else { return }
            do {
                let crashes = payload.crashDiagnostics?.count ?? 0
                let hangs = payload.hangDiagnostics ?? [], cpu = payload.cpuExceptionDiagnostics ?? []
                guard crashes <= 1_000, hangs.count <= 1_000, cpu.count <= 1_000 else { continue }
                var fields: [String: EluJSONValue] = ["$crash_count": .integer(Int64(crashes)),
                    "$hang_count": .integer(Int64(hangs.count)), "$cpu_exception_count": .integer(Int64(cpu.count))]
                if !hangs.isEmpty {
                    let durations = try hangs.map { try duration($0.hangDuration) }
                    fields["$hang_duration_total_ms"] = .number(try sum(durations))
                    fields["$hang_duration_max_ms"] = .number(durations.max()!)
                }
                if !cpu.isEmpty {
                    fields["$cpu_time_total_ms"] = .number(try sum(cpu.map { try duration($0.totalCPUTime) }))
                    fields["$cpu_sample_time_total_ms"] = .number(try sum(cpu.map { try duration($0.totalSampledTime) }))
                }
                if crashes + hangs.count + cpu.count > 0 {
                    deliver(try EluNativeDiagnosticSummary(kind: .diagnostic, begin: payload.timeStampBegin, end: payload.timeStampEnd, fields: fields), to: receiver)
                }
                if #available(iOS 16.0, *), receiver.includeLaunch, receiver.current(), let launches = payload.appLaunchDiagnostics, !launches.isEmpty {
                    guard launches.count <= 1_000 else { continue }
                    let values = try launches.map { try duration($0.launchDuration) }
                    deliver(try EluNativeDiagnosticSummary(kind: .launch, begin: payload.timeStampBegin, end: payload.timeStampEnd, fields: [
                        "$launch_diagnostic_count": .integer(Int64(values.count)),
                        "$launch_diagnostic_duration_total_ms": .number(try sum(values)),
                        "$launch_diagnostic_duration_max_ms": .number(values.max()!),
                    ]), to: receiver)
                }
            } catch { continue }
        }
    }
    private func histogram(_ value: MXHistogram<UnitDuration>, prefix: String) throws -> [String: EluJSONValue] {
        guard value.totalBucketCount <= 128 else { throw EluRuntimeQueueError.invalidRecord }
        var count: Int64 = 0, seen = 0
        var lower: Double?, upper: Double?, previousEnd: Double?
        let iterator = value.bucketEnumerator
        while let object = iterator.nextObject() {
            guard let bucket = object as? MXHistogramBucket<UnitDuration> else { throw EluRuntimeQueueError.invalidRecord }
            seen += 1
            guard seen <= 128, bucket.bucketCount <= 1_000_000 else { throw EluRuntimeQueueError.invalidRecord }
            let start = try duration(bucket.bucketStart), end = try duration(bucket.bucketEnd)
            guard end >= start, previousEnd.map({ start >= $0 }) ?? true else { throw EluRuntimeQueueError.invalidRecord }
            previousEnd = end
            if bucket.bucketCount > 0 {
                count += Int64(bucket.bucketCount)
                guard count <= 1_000_000 else { throw EluRuntimeQueueError.invalidRecord }
                lower = lower ?? start; upper = end
            }
        }
        guard seen == Int(value.totalBucketCount) else { throw EluRuntimeQueueError.invalidRecord }
        guard count > 0, let lower, let upper else { return [:] }
        return ["$launch_\(prefix)_count": .integer(count), "$launch_\(prefix)_lower_bound_ms": .number(lower),
                "$launch_\(prefix)_upper_bound_ms": .number(upper)]
    }
    private func duration(_ value: Measurement<UnitDuration>) throws -> Double {
        let number = value.converted(to: .milliseconds).value
        guard number.isFinite, (0...9_007_199_254_740_991).contains(number) else { throw EluRuntimeQueueError.invalidRecord }
        return number
    }
    private func sum(_ values: [Double]) throws -> Double {
        let total = values.reduce(0, +)
        guard total.isFinite, total <= 9_007_199_254_740_991 else { throw EluRuntimeQueueError.invalidRecord }
        return total
    }
}
#endif
