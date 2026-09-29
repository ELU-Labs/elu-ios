import CryptoKit
import Foundation

enum EluNativeDiagnosticsCloseSettlement: Equatable, Sendable { case settled, unresolvedStorage }

enum EluNativeDiagnosticKind: String, Codable, Sendable {
    case diagnostic, launch
    var eventName: String { self == .diagnostic ? "$native_diagnostic" : "$native_launch" }
}

/// Only detached, whitelisted numeric summaries cross the OS receiver boundary.
struct EluNativeDiagnosticSummary: Sendable {
    let kind: EluNativeDiagnosticKind
    let begin: Date
    let end: Date
    let fields: [String: EluJSONValue]

    static let diagnosticFields: Set<String> = [
        "$crash_count", "$hang_count", "$hang_duration_total_ms", "$hang_duration_max_ms",
        "$cpu_exception_count", "$cpu_time_total_ms", "$cpu_sample_time_total_ms",
    ]
    static let launchFields = Set(["first_draw", "resume"].flatMap { prefix in
        ["$launch_\(prefix)_count", "$launch_\(prefix)_lower_bound_ms", "$launch_\(prefix)_upper_bound_ms"]
    }).union(["$launch_diagnostic_count", "$launch_diagnostic_duration_total_ms", "$launch_diagnostic_duration_max_ms"])

    init(kind: EluNativeDiagnosticKind, begin: Date, end: Date, fields: [String: EluJSONValue]) throws {
        guard let canonicalBegin = Self.canonical(begin), let canonicalEnd = Self.canonical(end),
              canonicalBegin < canonicalEnd, !fields.isEmpty,
              Set(fields.keys).isSubset(of: kind == .diagnostic ? Self.diagnosticFields : Self.launchFields)
        else { throw EluRuntimeQueueError.invalidRecord }
        for (key, value) in fields {
            if key.hasSuffix("_count") {
                guard case let .integer(count) = value, (0...1_000_000).contains(count) else { throw EluRuntimeQueueError.invalidRecord }
            } else {
                guard case let .number(number) = value, number.isFinite,
                      (0...9_007_199_254_740_991).contains(number) else { throw EluRuntimeQueueError.invalidRecord }
            }
        }
        // Counts and their duration bounds are one summary, not independent
        // fields. Reject malformed OS adapters instead of publishing partial data.
        let groups: [(String, String, String, Bool)] = kind == .diagnostic ? [
            ("$hang_count", "$hang_duration_max_ms", "$hang_duration_total_ms", true),
            ("$cpu_exception_count", "$cpu_time_total_ms", "$cpu_sample_time_total_ms", false),
        ] : [
            ("$launch_first_draw_count", "$launch_first_draw_lower_bound_ms", "$launch_first_draw_upper_bound_ms", true),
            ("$launch_resume_count", "$launch_resume_lower_bound_ms", "$launch_resume_upper_bound_ms", true),
            ("$launch_diagnostic_count", "$launch_diagnostic_duration_max_ms", "$launch_diagnostic_duration_total_ms", true),
        ]
        for (countKey, firstKey, secondKey, ordered) in groups {
            let count: Int64
            if case let .integer(value)? = fields[countKey] { count = value } else { count = 0 }
            if count > 0 {
                guard case let .number(first)? = fields[firstKey], case let .number(second)? = fields[secondKey],
                      !ordered || first <= second else { throw EluRuntimeQueueError.invalidRecord }
            } else if fields[firstKey] != nil || fields[secondKey] != nil { throw EluRuntimeQueueError.invalidRecord }
        }
        guard fields.contains(where: { key, value in
            if key.hasSuffix("_count"), case let .integer(count) = value { return count > 0 }; return false
        }) else { throw EluRuntimeQueueError.invalidRecord }
        self.kind = kind; self.begin = canonicalBegin; self.end = canonicalEnd; self.fields = fields
    }

    var properties: [String: EluJSONValue] {
        var result = fields
        result["$diagnostic_platform"] = .string("ios")
        result["$diagnostic_source"] = .string("metrickit")
        result["$diagnostic_interval_start"] = .string(EluRFC3339.string(from: begin))
        result["$diagnostic_interval_end"] = .string(EluRFC3339.string(from: end))
        return result
    }
    func fingerprint() throws -> String {
        let encoded = try JSONEncoder().encode(properties)
        let canonical = try EluV1StrictCanonicalJSON.parse(encoded).canonicalData
        return SHA256.hash(data: Data(kind.rawValue.utf8) + Data([0]) + canonical).map { String(format: "%02x", $0) }.joined()
    }
    static func canonical(_ date: Date) -> Date? {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return EluRFC3339.date(from: EluRFC3339.string(from: date))
    }
}

/// Durable consent/identity continuity, independent of expiring config leases.
/// An old/unknown store begins closed; it cannot import past OS reports.
struct EluNativeDiagnosticsState: Codable, Equatable, Sendable {
    struct Epoch: Codable, Equatable, Sendable {
        let id: String
        let identityRevision: Int64
        let begin: String
        let launchSummaries: Bool
    }
    struct Receipts: Codable, Equatable, Sendable {
        let end: String
        var fingerprints: [String]
    }
    var epoch: Epoch?
    var observedAt: String?
    var diagnostic: Receipts?
    var launch: Receipts?
    static let maximumBytes = 8_192
    static let closed = Self(epoch: nil, observedAt: nil, diagnostic: nil, launch: nil)

    func closing(at date: Date? = nil) -> Self {
        var result = Self.closed
        result.observedAt = observedAt
        if let date, let now = EluNativeDiagnosticSummary.canonical(date),
           observedAt.flatMap(EluRFC3339.date(from:)).map({ now >= $0 }) ?? true {
            result.observedAt = EluRFC3339.string(from: now)
        }
        return result
    }

    func reconciled(at date: Date, identityRevision: Int64, mayOpen: Bool, launchSummaries: Bool) -> Self {
        guard let now = EluNativeDiagnosticSummary.canonical(date), identityRevision >= 0,
              observedAt.flatMap(EluRFC3339.date(from:)).map({ now >= $0 }) ?? true
        else { return closing() }
        var result = self
        if let epoch, epoch.identityRevision != identityRevision || epoch.launchSummaries != launchSummaries {
            result = closing(at: now)
        }
        if result.epoch == nil, mayOpen {
            result.epoch = Epoch(id: UUID().uuidString.lowercased(), identityRevision: identityRevision,
                                 begin: EluRFC3339.string(from: now), launchSummaries: launchSummaries)
        }
        result.observedAt = EluRFC3339.string(from: now)
        return result
    }

    /// The returned dedupe update must commit in the same transaction as the event.
    func accepting(_ summary: EluNativeDiagnosticSummary, at date: Date, identityRevision: Int64) throws -> Self? {
        guard let now = EluNativeDiagnosticSummary.canonical(date), let epoch,
              epoch.identityRevision == identityRevision,
              summary.kind != .launch || epoch.launchSummaries,
              let begin = EluRFC3339.date(from: epoch.begin), summary.begin >= begin,
              summary.end <= now,
              observedAt.flatMap(EluRFC3339.date(from:)).map({ now >= $0 }) == true else { return nil }
        let fingerprint = try summary.fingerprint(), end = EluRFC3339.string(from: summary.end)
        var receipts = summary.kind == .diagnostic ? diagnostic : launch
        if let old = receipts, let oldEnd = EluRFC3339.date(from: old.end) {
            guard summary.end >= oldEnd else { return nil }
            if summary.end > oldEnd { receipts = nil }
        }
        if receipts == nil { receipts = Receipts(end: end, fingerprints: []) }
        guard var accepted = receipts, accepted.fingerprints.count < 32,
              !accepted.fingerprints.contains(fingerprint) else { return nil }
        accepted.fingerprints.append(fingerprint)
        var result = self
        result.observedAt = EluRFC3339.string(from: now)
        if summary.kind == .diagnostic { result.diagnostic = accepted } else { result.launch = accepted }
        return result
    }

    func encoded() throws -> Data {
        try validate()
        let value = try EluV1StrictCanonicalJSON.parse(JSONEncoder().encode(self)).canonicalData
        guard value.count <= Self.maximumBytes else { throw EluRuntimeQueueError.corruptStorage }
        return value
    }
    static func decode(_ data: Data) throws -> Self {
        guard (1...maximumBytes).contains(data.count) else { throw EluRuntimeQueueError.corruptStorage }
        let parsed = try EluV1StrictCanonicalJSON.parse(data)
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard parsed.canonicalData == data, try decoded.encoded() == data else { throw EluRuntimeQueueError.corruptStorage }
        return decoded
    }
    private func validate() throws {
        func date(_ value: String) throws -> Date {
            guard let parsed = try? EluV1Timestamp(value), !parsed.storageIsLeapSecond,
                  EluRFC3339.string(from: parsed.date) == value else { throw EluRuntimeQueueError.corruptStorage }
            return parsed.date
        }
        let observed = try observedAt.map(date)
        if let epoch {
            guard UUID(uuidString: epoch.id)?.uuidString.lowercased() == epoch.id,
                  epoch.identityRevision >= 0, let observed, try date(epoch.begin) <= observed else { throw EluRuntimeQueueError.corruptStorage }
        } else if diagnostic != nil || launch != nil { throw EluRuntimeQueueError.corruptStorage }
        for receipt in [diagnostic, launch].compactMap({ $0 }) {
            guard let epoch, let observed, try date(receipt.end) >= date(epoch.begin),
                  try date(receipt.end) <= observed, (1...32).contains(receipt.fingerprints.count),
                  Set(receipt.fingerprints).count == receipt.fingerprints.count,
                  receipt.fingerprints.allSatisfy({ $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } })
            else { throw EluRuntimeQueueError.corruptStorage }
        }
    }
}
