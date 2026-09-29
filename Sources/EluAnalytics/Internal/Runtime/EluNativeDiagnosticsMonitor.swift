import Foundation
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

/// Registration is lazy and local opt-in only. No access to pastPayloads,
/// JSON/dictionary representations, metadata or call-stack trees. Report detail
/// getters additionally require their own original local and remote permission.
final class EluNativeDiagnosticsMonitor: @unchecked Sendable {
    struct Receiver: Sendable {
        let includeLaunch: Bool
        let includeCrashReports: Bool
        let crashReportDetails: Bool
        let reportProjection: EluMetricKitCrashProjection?
        let reportClock: @Sendable () -> Date
        let receiveReports: @Sendable (EluMetricKitCrashBatch, @escaping @Sendable () -> Bool) async -> Void
        let current: @Sendable () -> Bool
        let receive: @Sendable (EluNativeDiagnosticSummary) -> Void
    }
    private let lock = NSLock()
    private let registration = DispatchQueue(label: "dev.elu.diagnostics")
    private var stopped = false
    private var receiver: (id: UUID, value: Receiver)?
    private var reportIntake: ReportIntake?
    #if canImport(MetricKit) && os(iOS)
    private var subscriber: EluMetricKitSubscriber?
    #endif
    @discardableResult
    func publish(includeLaunch: Bool, includeCrashReports: Bool = false, crashReportDetails: Bool = false,
                 reportProjection: EluMetricKitCrashProjection? = nil, reportClock: @escaping @Sendable () -> Date = { Date() },
                 receiveReports: @escaping @Sendable (EluMetricKitCrashBatch, @escaping @Sendable () -> Bool) async -> Void = { _, _ in },
                 current: @escaping @Sendable () -> Bool,
                 receive: @escaping @Sendable (EluNativeDiagnosticSummary) -> Void) -> UUID? {
        withdraw()
        lock.lock()
        guard !stopped, current() else { lock.unlock(); return nil }
        let id = UUID()
        receiver = (id, Receiver(includeLaunch: includeLaunch, includeCrashReports: includeCrashReports,
            crashReportDetails: crashReportDetails, reportProjection: reportProjection, reportClock: reportClock,
            receiveReports: receiveReports, current: current, receive: receive))
        #if canImport(MetricKit) && os(iOS)
        let value = EluMetricKitSubscriber(owner: self, receiverID: id) { [weak self] in self?.currentReceiver(id) }
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
        return id
    }
    private func currentReceiver(_ id: UUID) -> Receiver? {
        lock.lock(); let value = receiver; let stopped = stopped; lock.unlock()
        guard !stopped, value?.id == id, let receiver = value?.value, receiver.current() else { return nil }
        return receiver
    }
    /// One original slot covers OS projection, the full bounded batch, and its
    /// actor/SQL settlement. Concurrent/reentrant batches do not read details.
    func receiveCrashReports(receiverID: UUID,
        project: (EluMetricKitCrashProjection, @Sendable () -> Bool) throws -> EluMetricKitCrashBatch) {
        guard let receiver = currentReceiver(receiverID), receiver.includeCrashReports,
              let projection = receiver.reportProjection, projection.epoch.details == receiver.crashReportDetails else { return }
        lock.lock()
        guard !stopped, self.receiver?.id == receiverID, reportIntake == nil else { lock.unlock(); return }
        let intake = ReportIntake()
        reportIntake = intake
        lock.unlock()
        let current: @Sendable () -> Bool = { [weak self] in self?.currentReceiver(receiverID) != nil }
        do {
            guard current() else { finish(intake); return }
            let batch = try project(projection, current)
            guard current(), batch.items.allSatisfy({ $0.report.detailsPermitted == projection.epoch.details
                && projection.permits(begin: $0.report.begin, end: $0.report.end, at: receiver.reportClock()) }) else {
                finish(intake); return
            }
            // There is at most one such Task, regardless of callback/report count.
            Task {
                await receiver.receiveReports(batch, current)
                self.finish(intake)
            }
        } catch { finish(intake) }
    }
    private final class ReportIntake: @unchecked Sendable {
        let completion = DispatchGroup()
        init() { completion.enter() }
    }
    private func finish(_ original: ReportIntake) {
        lock.lock()
        guard reportIntake === original else { lock.unlock(); return }
        reportIntake = nil
        original.completion.leave()
        lock.unlock()
    }
    private func currentIntake() -> ReportIntake? {
        lock.lock(); defer { lock.unlock() }; return reportIntake
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
        let original = currentIntake()
        await withCheckedContinuation { continuation in registration.async { continuation.resume() } }
        if let original {
            await withCheckedContinuation { continuation in
                original.completion.notify(queue: registration) { continuation.resume() }
            }
        }
    }
    deinit { stop() }
}

#if canImport(MetricKit) && os(iOS)
private final class EluMetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    private let readReceiver: @Sendable () -> EluNativeDiagnosticsMonitor.Receiver?
    private weak var owner: EluNativeDiagnosticsMonitor?
    private let receiverID: UUID
    init(owner: EluNativeDiagnosticsMonitor, receiverID: UUID,
         readReceiver: @escaping @Sendable () -> EluNativeDiagnosticsMonitor.Receiver?) {
        self.owner = owner; self.receiverID = receiverID; self.readReceiver = readReceiver
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
        if receiver.includeCrashReports {
            owner?.receiveCrashReports(receiverID: receiverID) { projection, current in
                // Reject the entire oversized input before any report detail read.
                let counts = payloads.map { $0.crashDiagnostics?.count ?? 0 }
                guard counts.allSatisfy({ $0 <= EluMetricKitCrashBatch.maximumReports }),
                      counts.reduce(0, +) <= EluMetricKitCrashBatch.maximumReports else {
                    throw EluRuntimeQueueError.invalidRecord
                }
                var reports: [EluMetricKitCrashReport] = []
                for payload in payloads {
                    guard current() else { throw EluRuntimeQueueError.sourceAuthorityUnavailable }
                    // Original OS interval facts precede every optional detail getter.
                    let begin = payload.timeStampBegin, end = payload.timeStampEnd
                    guard projection.permits(begin: begin, end: end, at: receiver.reportClock()), current() else {
                        throw EluRuntimeQueueError.sourceAuthorityUnavailable
                    }
                    for crash in payload.crashDiagnostics ?? [] {
                        let report = try projection.project(begin: begin, end: end, clock: receiver.reportClock,
                            current: current, readCodes: {
                                let mach = try Self.integer(crash.exceptionType)
                                guard current() else { throw EluRuntimeQueueError.sourceAuthorityUnavailable }
                                return (mach, try Self.integer(crash.signal))
                            }, readDetails: { permitted in
                                guard permitted() else { throw EluRuntimeQueueError.sourceAuthorityUnavailable }
                                if #available(iOS 17.0, *), let original = crash.exceptionReason {
                                    // Retained bounds do not bound the original OS getter.
                                    guard permitted() else { throw EluRuntimeQueueError.sourceAuthorityUnavailable }
                                    let name = original.exceptionName
                                    guard permitted() else { throw EluRuntimeQueueError.sourceAuthorityUnavailable }
                                    let className = original.className
                                    guard permitted() else { throw EluRuntimeQueueError.sourceAuthorityUnavailable }
                                    let message = original.composedMessage
                                    return .init(name: name, className: className, message: message)
                                }
                                return nil
                            })
                        reports.append(report)
                    }
                }
                return try EluMetricKitCrashBatch(reports)
            }
        }
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
    private static func integer(_ value: NSNumber?) throws -> Int64? {
        guard let value else { return nil }
        let integer = value.int64Value
        guard value == NSNumber(value: integer) else { throw EluRuntimeQueueError.invalidRecord }
        return integer
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
