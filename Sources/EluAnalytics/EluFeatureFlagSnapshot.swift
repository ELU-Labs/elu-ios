import Foundation

/// A detached value from one validated flag publication. Retaining this value
/// does not keep its identity, configuration or cache authority current.
public struct EluFeatureFlagSnapshot: Sendable {
    public enum Source: String, Sendable { case remote, cache, unavailable }
    public enum LoadError: String, Sendable { case transport, invalidResponse }
    public struct Entry: Sendable {
        public enum Value: Sendable {
            case bool(Bool), string(String), number(Double), null
        }
        public let key: String
        public let value: Value
        /// Canonical JSON; nil means absent, while JSON null is retained as bytes.
        public let payloadJSON: Data?
    }

    public let source: Source
    public let error: LoadError?
    public let entries: [Entry]
    /// Complete canonical objects preserve exact Unicode keys and all payloads.
    public let flagsJSON: Data
    public let payloadsJSON: Data
    public let requestId: String?
    public let flagsRevision: String?
    /// Original validated response timestamps, represented at millisecond precision.
    public let evaluatedAt: Date?
    /// Response expiry, not a promise that configuration or identity stays valid.
    public let expiresAt: Date?
    public var isAvailable: Bool { source != .unavailable }

    /// Exact decoded UTF-16 lookup; canonically equivalent keys remain distinct.
    public func entry(forKey key: String) -> Entry? {
        let units = Array(key.utf16)
        return entries.first { Array($0.key.utf16) == units }
    }

    init(response: EluV1FlagResponse, source: Source, error: LoadError?) throws {
        self.source = source
        self.error = error
        entries = try response.flags.map { member in
            let value: Entry.Value
            switch member.value {
            case let .bool(v): value = .bool(v)
            case let .string(v): value = .string(String(decoding: v, as: UTF16.self))
            case let .number(v): value = .number(v)
            case .null: value = .null
            default: throw EluV1FlagContractError.invalidFlagValue
            }
            return Entry(key: String(decoding: member.name, as: UTF16.self), value: value,
                payloadJSON: try response.payload(units: member.name).map { try EluV1FlagJSON.canonicalData(for: $0) })
        }
        flagsJSON = try EluV1FlagJSON.canonicalData(for: .object(response.flags))
        payloadsJSON = try EluV1FlagJSON.canonicalData(for: .object(response.payloads))
        requestId = response.requestId
        flagsRevision = response.flagsRevision
        evaluatedAt = Date(timeIntervalSince1970: Double(try response.evaluatedAt.validated().floorUnixMilliseconds) / 1_000)
        expiresAt = Date(timeIntervalSince1970: Double(try response.expiresAt.validated().floorUnixMilliseconds) / 1_000)
    }

    init(unavailable error: LoadError?) {
        source = .unavailable
        self.error = error
        entries = []
        flagsJSON = Data("{}".utf8)
        payloadsJSON = Data("{}".utf8)
        requestId = nil
        flagsRevision = nil
        evaluatedAt = nil
        expiresAt = nil
    }
}

/// Snapshot and predicate travel together; a queue hop cannot substitute a
/// newer publication's values for an older notification.
struct EluFeatureFlagPublication: Sendable {
    let snapshot: EluFeatureFlagSnapshot
    let isCurrent: @Sendable () -> Bool
}
