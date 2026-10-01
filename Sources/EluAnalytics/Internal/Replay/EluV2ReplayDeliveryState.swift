import Foundation

enum EluReplayDeliveryFormat: String, Codable, Sendable { case wireframe, raster }

/// Explicit internal support selection; the production caller remains wireframe-only.
enum EluReplayDeliverySupport: Equatable, Sendable { case wireframeOnly, includingRaster }

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
    struct EndpointRetries: Codable, Equatable, Sendable {
        var wireframe: Retry?
        var raster: Retry?
    }
    struct RasterBlock: Codable, Equatable, Sendable {
        let reason: String
        let recordedAt: String
        let credentialWitness: String
        let scopeWitness: String
        let replayId: String
        let requestId: String
        let chunkId: String
        let sequence: Int64
        let requestDigest: String
    }
    var schemaVersion: Int
    var attemptCount: Int64
    var retry: Retry?
    var blocked: Block?
    var endpointRetries: EndpointRetries?
    var rasterBlock: RasterBlock?
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
        let fields = try object(document.value, required: ["schemaVersion", "attemptCount"], optional: ["retry", "blocked", "endpointRetries", "rasterBlock"])
        if let retry = fields["retry"] { _ = try object(retry, required: ["recordedAt", "delayMillis", "ownerEpoch", "authorizationWitness"]) }
        if let blocked = fields["blocked"] { _ = try object(blocked, required: ["reason", "recordedAt", "credentialWitness", "scopeWitness", "protocolGeneration"]) }
        if let endpoints = fields["endpointRetries"] {
            let values = try object(endpoints, required: [], optional: ["wireframe", "raster"])
            for retry in values.values { _ = try object(retry, required: ["recordedAt", "delayMillis", "ownerEpoch", "authorizationWitness"]) }
        }
        if let block = fields["rasterBlock"] {
            _ = try object(block, required: ["reason", "recordedAt", "credentialWitness", "scopeWitness", "replayId", "requestId", "chunkId", "sequence", "requestDigest"])
        }
        let value = try JSONDecoder().decode(Self.self, from: document.canonicalData)
        guard (1...2).contains(value.schemaVersion), (0...maximumSafeInteger).contains(value.attemptCount),
              value.retry == nil || value.blocked == nil,
              value.schemaVersion == 2 || (value.endpointRetries == nil && value.rasterBlock == nil),
              value.schemaVersion == 1 || (value.retry == nil && value.blocked == nil &&
                ((value.endpointRetries != nil) != (value.rasterBlock != nil))) else { throw EluRuntimeQueueError.corruptStorage }
        func validateRetry(_ retry: Retry) throws {
            guard (try? EluV1Timestamp(retry.recordedAt)) != nil, (0...maximumDelayMillis).contains(retry.delayMillis),
                  UUID(uuidString: retry.ownerEpoch) != nil, hash(retry.authorizationWitness) else { throw EluRuntimeQueueError.corruptStorage }
        }
        if let retry = value.retry {
            try validateRetry(retry)
        }
        if let endpoints = value.endpointRetries {
            guard value.attemptCount == 0 else { throw EluRuntimeQueueError.corruptStorage }
            if let retry = endpoints.wireframe { try validateRetry(retry) }
            if let retry = endpoints.raster { try validateRetry(retry) }
        }
        if let block = value.rasterBlock {
            guard ["request", "chunk", "sequence", "too-large"].contains(block.reason),
                  (try? EluV1Timestamp(block.recordedAt)) != nil, hash(block.credentialWitness), hash(block.scopeWitness),
                  EluV1Validation.validString(block.replayId, minimum: 1, maximum: 256),
                  EluV1Validation.validString(block.chunkId, minimum: 1, maximum: 256),
                  block.requestId.range(of: #"\Arequest_[a-f0-9]{64}\z"#, options: .regularExpression) != nil,
                  (0...maximumSafeInteger).contains(block.sequence), hash(block.requestDigest) else { throw EluRuntimeQueueError.corruptStorage }
        }
        if let block = value.blocked {
            guard ["credential-401", "credential-403", "protocol"].contains(block.reason),
                  (try? EluV1Timestamp(block.recordedAt)) != nil, hash(block.credentialWitness), hash(block.scopeWitness),
                  EluV1Validation.validString(block.protocolGeneration, minimum: 1, maximum: 128) else { throw EluRuntimeQueueError.corruptStorage }
        }
        return value
    }

    func endpointRetry(for format: EluReplayDeliveryFormat) -> Retry? {
        if let endpointRetries { return format == .wireframe ? endpointRetries.wireframe : endpointRetries.raster }
        return format == .wireframe ? retry : nil
    }

    mutating func setEndpointRetry(_ value: Retry, for format: EluReplayDeliveryFormat) {
        if format == .wireframe && endpointRetries == nil { retry = value; return }
        if endpointRetries == nil { endpointRetries = EndpointRetries(wireframe: retry, raster: nil); retry = nil; schemaVersion = 2 }
        if format == .wireframe { endpointRetries?.wireframe = value } else { endpointRetries?.raster = value }
    }
    private static func hash(_ value: String) -> Bool { value.range(of: #"\Asha256:[a-f0-9]{64}\z"#, options: .regularExpression) != nil }
    private static func object(_ value: EluV1StrictCanonicalJSON.Value, required: Set<String>, optional: Set<String> = []) throws -> [String: EluV1StrictCanonicalJSON.Value] {
        guard case let .object(members) = value else { throw EluRuntimeQueueError.corruptStorage }
        let actual = Set(members.map(\.name)), needed = Set(required.map { Array($0.utf16) })
        guard actual.count == members.count, needed.isSubset(of: actual), actual.isSubset(of: needed.union(optional.map { Array($0.utf16) })) else { throw EluRuntimeQueueError.corruptStorage }
        return Dictionary(uniqueKeysWithValues: members.map { (String(decoding: $0.name, as: UTF16.self), $0.value) })
    }
}
