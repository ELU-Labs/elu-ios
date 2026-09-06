import Foundation

/// The only keys a compatibility reader may be asked for. A source answers
/// one explicit key at a time; there is no enumeration or container scan, so
/// a reader can never hand over records the coordinator did not request.
enum EluLegacyStateKey: String, CaseIterable, Sendable {
    case anonymousId
    case userId
    case optedOut
    case superProperties
    case groups
    case flagPersonProperties
    case flagGroupProperties
    case streamId
    case nextSequence

    /// Upper bound on the encoded size of a single value under this key.
    var maximumBytes: Int {
        switch self {
        case .anonymousId, .userId, .streamId:
            return 1_024
        case .optedOut, .nextSequence:
            return 64
        case .superProperties, .groups, .flagPersonProperties, .flagGroupProperties:
            return 256 * 1_024
        }
    }
}

/// A typed value read from a former storage layout. Sources decode their own
/// on-disk representation into one of these shapes; the coordinator applies
/// the per-key type, size, and validity rules before anything is written.
enum EluLegacyStateValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int64)
    case json(EluJSONValue)
}

/// Identifies which storage layout a source reads and which revision of that
/// layout it understands. A layout revision the coordinator does not know is
/// rejected without reading any value.
struct EluLegacyStateSourceDescriptor: Equatable, Sendable {
    var sourceSchema: String
    var schemaVersion: Int

    init(sourceSchema: String, schemaVersion: Int) {
        self.sourceSchema = sourceSchema
        self.schemaVersion = schemaVersion
    }
}

/// One record that was still waiting for delivery in the former queue.
/// Positions are the source's own delivery order and must strictly increase.
struct EluLegacyQueuedRecord: Equatable, Sendable {
    var position: Int64
    var payload: Data

    init(position: Int64, payload: Data) {
        self.position = position
        self.payload = payload
    }
}

enum EluLegacyStateSourceError: Error, Equatable, Sendable {
    case unavailable
    case unreadable(EluLegacyStateKey)
    case queueUnreadable
}

/// A bounded, read-only view of state written by an earlier release.
///
/// Conformers read only what is asked for, never delete or rewrite anything,
/// and stay within the byte and count limits they are handed. The coordinator
/// enforces the same limits again on every value it receives.
protocol EluLegacyStateSource: Sendable {
    var descriptor: EluLegacyStateSourceDescriptor { get }

    /// Returns the value stored under one allowlisted key, or nil when the
    /// key is absent. A value larger than `maximumBytes` may be returned as
    /// is; the coordinator rejects it.
    func readValue(for key: EluLegacyStateKey, maximumBytes: Int) throws -> EluLegacyStateValue?

    /// Returns up to `maximumCount` undelivered records in delivery order
    /// without exceeding `maximumBytes` of payload in total. The records stay
    /// in the source; nothing here acknowledges or removes them.
    func readQueuedRecords(maximumCount: Int, maximumBytes: Int) throws -> [EluLegacyQueuedRecord]
}
