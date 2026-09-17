import Foundation

/// Closed bounded persistence metadata. Missing/unknown/partial metadata is not
/// a pending row; callers preserve the bytes and fail delivery closed.
struct EluV2ReplayDeliveryState: Codable, Equatable, Sendable {
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    static let maximumDelayMillis: Int64 = 86_400_000
    struct Retry: Codable, Equatable, Sendable {
        let recordedAt: String
        let delayMillis: Int64
        let ownerEpoch: String
        let authorizationWitness: String
    }
    struct Block: Codable, Equatable, Sendable {
        let reason: String
        let recordedAt: String
        let credentialWitness: String
        let scopeWitness: String
        let protocolGeneration: String
    }
    let schemaVersion: Int
    var attemptCount: Int64
    var retry: Retry?
    var blocked: Block?
    static let pending = EluV2ReplayDeliveryState(schemaVersion: 1, attemptCount: 0)

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        let raw = try encoder.encode(self)
        let result = try EluV1StrictCanonicalJSON.parse(raw).canonicalData
        _ = try Self.decode(result)
        return result
    }
    static func decode(_ raw: Data) throws -> Self {
        guard (1...16_384).contains(raw.count) else { throw EluRuntimeQueueError.corruptStorage }
        let document = try EluV1StrictCanonicalJSON.parse(raw)
        let fields = try object(document.value, required: ["schemaVersion", "attemptCount"], optional: ["retry", "blocked"])
        if let retry = fields["retry"] { _ = try object(retry, required: ["recordedAt", "delayMillis", "ownerEpoch", "authorizationWitness"]) }
        if let blocked = fields["blocked"] { _ = try object(blocked, required: ["reason", "recordedAt", "credentialWitness", "scopeWitness", "protocolGeneration"]) }
        let value = try JSONDecoder().decode(Self.self, from: document.canonicalData)
        guard value.schemaVersion == 1, (0...maximumSafeInteger).contains(value.attemptCount), value.retry == nil || value.blocked == nil else { throw EluRuntimeQueueError.corruptStorage }
        if let retry = value.retry {
            guard (try? EluV1Timestamp(retry.recordedAt)) != nil, (0...maximumDelayMillis).contains(retry.delayMillis),
                  UUID(uuidString: retry.ownerEpoch) != nil, hash(retry.authorizationWitness) else { throw EluRuntimeQueueError.corruptStorage }
        }
        if let block = value.blocked {
            guard ["credential-401", "credential-403", "protocol"].contains(block.reason),
                  (try? EluV1Timestamp(block.recordedAt)) != nil, hash(block.credentialWitness), hash(block.scopeWitness),
                  EluV1Validation.validString(block.protocolGeneration, minimum: 1, maximum: 128) else { throw EluRuntimeQueueError.corruptStorage }
        }
        return value
    }
    private static func hash(_ value: String) -> Bool { value.range(of: #"\Asha256:[a-f0-9]{64}\z"#, options: .regularExpression) != nil }
    private static func object(_ value: EluV1StrictCanonicalJSON.Value, required: Set<String>, optional: Set<String> = []) throws -> [String: EluV1StrictCanonicalJSON.Value] {
        guard case let .object(members) = value else { throw EluRuntimeQueueError.corruptStorage }
        let actual = Set(members.map(\.name)), needed = Set(required.map { Array($0.utf16) })
        guard actual.count == members.count, needed.isSubset(of: actual), actual.isSubset(of: needed.union(optional.map { Array($0.utf16) })) else { throw EluRuntimeQueueError.corruptStorage }
        return Dictionary(uniqueKeysWithValues: members.map { (String(decoding: $0.name, as: UTF16.self), $0.value) })
    }
}
