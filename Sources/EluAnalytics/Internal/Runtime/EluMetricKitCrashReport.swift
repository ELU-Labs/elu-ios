import CryptoKit
import Foundation

/// A detached OS report, never an Error/NSException supplied by the application.
/// Dates describe the OS payload interval, not the instant or session of a crash.
struct EluMetricKitCrashReport: Sendable {
    struct Details: Sendable {
        let name: String?
        let className: String?
        let message: String?
        init(name: String?, className: String?, message: String?) {
            self.name = Self.bounded(name, limit: 256)
            self.className = Self.bounded(className, limit: 256)
            self.message = Self.bounded(message, limit: 1_024)
        }
        private static func bounded(_ value: String?, limit: Int) -> String? {
            guard let value, !value.isEmpty else { return nil }
            // Output bounds do not bound the original OS getter's allocation/time.
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: value.unicodeScalars.prefix(limit))
            return String(scalars)
        }
    }
    let begin: Date
    let end: Date
    let machException: Int64?
    let signal: Int64?
    let detailsPermitted: Bool
    let details: Details?
    static let maximumBytes = 16_384

    init(begin: Date, end: Date, machException: Int64?, signal: Int64?,
         detailsPermitted: Bool, details: Details? = nil) throws {
        guard let begin = EluNativeDiagnosticSummary.canonical(begin),
              let end = EluNativeDiagnosticSummary.canonical(end), begin < end,
              machException.map({ (1...Int64(Int32.max)).contains($0) }) ?? true,
              signal.map({ (1...255).contains($0) }) ?? true,
              detailsPermitted || details == nil,
              machException != nil || signal != nil || details?.name != nil || details?.message != nil
        else { throw EluRuntimeQueueError.invalidRecord }
        self.begin = begin; self.end = end; self.machException = machException
        self.signal = signal; self.detailsPermitted = detailsPermitted; self.details = details
        guard try canonicalProperties().count <= Self.maximumBytes else {
            throw EluRuntimeQueueError.invalidRecord
        }
    }

    var properties: [String: EluJSONValue] {
        let type = details?.name ?? "MetricKitCrash"
        var entry: [String: EluJSONValue] = [
            "type": .string(type), "value": details?.message.map(EluJSONValue.string) ?? .null,
            "mechanism": .object(["type": .string("metrickit"), "handled": .bool(false)]),
        ]
        if let value = details?.className { entry["class"] = .string(value) }
        var result: [String: EluJSONValue] = [
            "$exception_type": .string(type),
            "$exception_message": details?.message.map(EluJSONValue.string) ?? .null,
            "$exception_list": .array([.object(entry)]),
            "$diagnostic_platform": .string("ios"), "$diagnostic_source": .string("metrickit"),
            "$diagnostic_interval_start": .string(EluRFC3339.string(from: begin)),
            "$diagnostic_interval_end": .string(EluRFC3339.string(from: end)),
            "$native_crash_details_permitted": .bool(detailsPermitted),
            "$native_crash_details_available": .bool(details != nil),
            "$native_crash_stack_collected": .bool(false),
            "$native_crash_exact_time_available": .bool(false),
            "$native_crash_session_attribution": .string("receipt-only"),
        ]
        if let machException { result["$native_crash_mach_exception"] = .integer(machException) }
        if let signal { result["$native_crash_signal"] = .integer(signal) }
        return result
    }
    private func canonicalProperties() throws -> Data {
        try EluV1StrictCanonicalJSON.parse(JSONEncoder().encode(properties)).canonicalData
    }
    func contentDigest() throws -> String {
        SHA256.hash(data: try canonicalProperties()).map { String(format: "%02x", $0) }.joined()
    }
}

/// Detached from the original persisted state under the runtime's source/intent
/// fence. It grants no SQL authority; it prevents ineligible OS detail acquisition.
struct EluMetricKitCrashProjection: Sendable {
    let epoch: EluNativeDiagnosticsState.ReportEpoch
    private let observedAt: Date
    init?(state: EluNativeDiagnosticsState, identityRevision: Int64, optedOut: Bool, details: Bool) {
        guard !optedOut, let epoch = state.reportEpoch,
              epoch.identityRevision == identityRevision, epoch.details == details,
              UUID(uuidString: epoch.id)?.uuidString.lowercased() == epoch.id,
              let begin = EluRFC3339.date(from: epoch.begin),
              let observed = state.observedAt.flatMap(EluRFC3339.date(from:)), begin <= observed else { return nil }
        self.epoch = epoch; self.observedAt = observed
    }
    func permits(begin: Date, end: Date, at date: Date) -> Bool {
        guard let begin = EluNativeDiagnosticSummary.canonical(begin),
              let end = EluNativeDiagnosticSummary.canonical(end),
              let now = EluNativeDiagnosticSummary.canonical(date),
              let consentBegin = EluRFC3339.date(from: epoch.begin) else { return false }
        return begin < end && begin >= consentBegin && end <= now && now >= observedAt
    }
    /// The OS adapter reads interval facts first. Neither optional detail closure
    /// nor its first OS getter may run for a historical/future/revoked interval.
    func project(begin: Date, end: Date, clock: @escaping () -> Date, current: @escaping () -> Bool,
                 readCodes: () throws -> (Int64?, Int64?),
                 readDetails: (_ current: () -> Bool) throws -> EluMetricKitCrashReport.Details?) throws -> EluMetricKitCrashReport {
        func permitted() -> Bool { current() && permits(begin: begin, end: end, at: clock()) && current() }
        guard permitted() else { throw EluRuntimeQueueError.sourceAuthorityUnavailable }
        let (mach, signal) = try readCodes()
        guard permitted() else { throw EluRuntimeQueueError.sourceAuthorityUnavailable }
        let details = epoch.details ? try readDetails(permitted) : nil
        guard permitted() else { throw EluRuntimeQueueError.sourceAuthorityUnavailable }
        return try .init(begin: begin, end: end, machException: mach, signal: signal,
                         detailsPermitted: epoch.details, details: details)
    }
}

/// Rejects the whole oversized input. Occurrences belong to an identical content
/// group, not an arbitrary OS array prefix/order. This is payload dedupe, not an
/// OS-issued globally unique crash identity.
struct EluMetricKitCrashBatch: Sendable {
    struct Item: Sendable {
        let report: EluMetricKitCrashReport
        let digest: String
        let occurrence: Int
        fileprivate init(report: EluMetricKitCrashReport, digest: String, occurrence: Int) {
            self.report = report; self.digest = digest; self.occurrence = occurrence
        }
        func receiptFingerprint(epochID: String) -> String {
            let input = epochID + ":" + digest + ":" + String(occurrence)
            return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
    static let maximumReports = 4
    let items: [Item]
    init(_ reports: [EluMetricKitCrashReport]) throws {
        guard !reports.isEmpty, reports.count <= Self.maximumReports else {
            throw EluRuntimeQueueError.invalidRecord
        }
        let ordered = try reports.map { (try $0.contentDigest(), $0) }.sorted {
            // Older OS ends first so a newer watermark does not discard a report
            // belonging to this same bounded batch.
            if $0.1.end != $1.1.end { return $0.1.end < $1.1.end }
            return $0.0 < $1.0
        }
        var occurrences: [String: Int] = [:]
        items = ordered.map { digest, report in
            let occurrence = occurrences[digest, default: 0]
            occurrences[digest] = occurrence + 1
            return Item(report: report, digest: digest, occurrence: occurrence)
        }
    }
}
