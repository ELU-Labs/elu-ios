import CryptoKit
import Foundation

/// A storage value, not recorder/codec or privacy proof. Payload bytes stay opaque.
struct EluV2ReplayPreparedRequest: Equatable, Sendable {
    static let maximumBytes = 5_242_880
    let captureProtocolGeneration: String
    let body: Data
    let digest: String
    let requestId: String
    let replayId: String
    let sessionId: String
    let chunkId: String
    let sequence: Int64
    let startedAt: EluV1Timestamp
    let endedAt: EluV1Timestamp
    let anonymousId: String
    let userId: String?
    let identityRevision: Int64
    let contextRevision: Int64
    let codec: String
    let compression: String
    let maskingProfileHash: String
    let policyRevision: String
    let effectivePolicyHash: String

    init(_ data: Data, captureProtocolGeneration: String) throws {
        guard EluV1Validation.validString(captureProtocolGeneration, minimum: 1, maximum: 128) else { throw EluRuntimeQueueError.invalidRecord }
        self.captureProtocolGeneration = captureProtocolGeneration
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw EluRuntimeQueueError.invalidRecord }
        let document = try EluV1StrictCanonicalJSON.parse(data)
        let root = try ReplayJSON.object(document.value, keys: ["schemaVersion", "requestId", "chunk"])
        guard try ReplayJSON.integer(root["schemaVersion"]) == 2 else { throw EluRuntimeQueueError.invalidRecord }
        let chunkValue = try ReplayJSON.required(root["chunk"])
        let chunk = try ReplayJSON.object(chunkValue, keys: ["schemaVersion", "replayId", "sessionId", "chunkId", "sequence", "startedAt", "endedAt", "identity", "contextRevision", "codec", "compression", "contentEncoding", "payload", "privacy", "versions"])
        guard try ReplayJSON.integer(chunk["schemaVersion"]) == 2,
              ReplayJSON.string(chunk["contentEncoding"]) == "base64" else { throw EluRuntimeQueueError.invalidRecord }
        replayId = try ReplayJSON.boundedString(chunk["replayId"], maximum: 256)
        chunkId = try ReplayJSON.boundedString(chunk["chunkId"], maximum: 256)
        sessionId = try ReplayJSON.boundedString(chunk["sessionId"], maximum: 256)
        sequence = try ReplayJSON.integer(chunk["sequence"])
        contextRevision = try ReplayJSON.integer(chunk["contextRevision"])
        startedAt = try EluV1Timestamp(ReplayJSON.boundedString(chunk["startedAt"], maximum: 128))
        endedAt = try EluV1Timestamp(ReplayJSON.boundedString(chunk["endedAt"], maximum: 128))
        guard startedAt <= endedAt else { throw EluRuntimeQueueError.invalidRecord }
        let identity = try ReplayJSON.object(ReplayJSON.required(chunk["identity"]), keys: ["anonymousId", "userId", "revision"])
        anonymousId = try ReplayJSON.boundedString(identity["anonymousId"], maximum: 256)
        if case .null? = identity["userId"] { userId = nil }
        else { userId = try ReplayJSON.boundedString(identity["userId"], maximum: 512) }
        identityRevision = try ReplayJSON.integer(identity["revision"])
        codec = try ReplayJSON.boundedString(chunk["codec"], maximum: 68)
        compression = try ReplayJSON.boundedString(chunk["compression"], maximum: 4)
        guard ReplayJSON.matches(codec, "^elu-[a-z0-9][a-z0-9.-]{0,63}$"),
              ["none", "gzip"].contains(compression),
              let payload = ReplayJSON.string(chunk["payload"]), !payload.isEmpty,
              let bytes = Data(base64Encoded: payload), bytes.base64EncodedString() == payload else {
            throw EluRuntimeQueueError.invalidRecord
        }
        let privacy = try ReplayJSON.object(ReplayJSON.required(chunk["privacy"]), keys: ["policyRevision", "effectivePolicyHash", "maskingProfileHash", "appliedBeforeSerialization", "secureInputsMasked", "platformFallbackApplied"])
        policyRevision = try ReplayJSON.boundedString(privacy["policyRevision"], maximum: 128)
        effectivePolicyHash = try ReplayJSON.boundedString(privacy["effectivePolicyHash"], maximum: 71)
        maskingProfileHash = try ReplayJSON.boundedString(privacy["maskingProfileHash"], maximum: 71)
        guard ReplayJSON.matches(maskingProfileHash, "^sha256:[a-f0-9]{64}$"),
              ReplayJSON.matches(effectivePolicyHash, "^sha256:[a-f0-9]{64}$"),
              case .bool(true)? = privacy["appliedBeforeSerialization"],
              case .bool(true)? = privacy["secureInputsMasked"],
              case .bool? = privacy["platformFallbackApplied"] else { throw EluRuntimeQueueError.invalidRecord }
        try ReplayJSON.versions(ReplayJSON.required(chunk["versions"]))
        let canonicalChunk = try EluV1StrictCanonicalJSON.canonicalData(for: chunkValue)
        var material = Data("elu-sdk-replay-request-v2".utf8)
        material.append(0)
        var length = UInt32(canonicalChunk.count).bigEndian
        withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }
        material.append(canonicalChunk)
        let expected = "request_" + SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        guard ReplayJSON.string(root["requestId"]) == expected,
              document.canonicalData.count <= Self.maximumBytes else { throw EluRuntimeQueueError.invalidRecord }
        requestId = expected
        body = document.canonicalData
        digest = EluV1StrictCanonicalJSON.hash(body)
    }
}

private enum ReplayJSON {
    typealias Value = EluV1StrictCanonicalJSON.Value
    static func required(_ value: Value?) throws -> Value {
        guard let value else { throw EluRuntimeQueueError.invalidRecord }; return value
    }
    static func object(_ value: Value, keys: Set<String>, optional: Set<String> = []) throws -> [String: Value] {
        guard case let .object(members) = value else { throw EluRuntimeQueueError.invalidRecord }
        // Compare exact UTF-16 names before entering a Swift dictionary.
        let expected = Set(keys.map { Array($0.utf16) })
        let allowed = expected.union(optional.map { Array($0.utf16) })
        let actual = Set(members.map(\.name))
        guard actual.isSuperset(of: expected), actual.isSubset(of: allowed), actual.count == members.count else { throw EluRuntimeQueueError.invalidRecord }
        return Dictionary(uniqueKeysWithValues: members.map { (String(decoding: $0.name, as: UTF16.self), $0.value) })
    }
    static func string(_ value: Value?) -> String? {
        guard case let .string(units)? = value else { return nil }; return String(decoding: units, as: UTF16.self)
    }
    static func boundedString(_ value: Value?, maximum: Int) throws -> String {
        guard let text = string(value), (1...maximum).contains(text.unicodeScalars.count) else { throw EluRuntimeQueueError.invalidRecord }; return text
    }
    static func integer(_ value: Value?) throws -> Int64 {
        let canonical = try EluV1StrictCanonicalJSON.canonicalData(for: required(value))
        guard case .number? = value, let number = Int64(String(decoding: canonical, as: UTF8.self)), (0...9_007_199_254_740_991).contains(number) else { throw EluRuntimeQueueError.invalidRecord }; return number
    }
    static func matches(_ string: String, _ expression: String) -> Bool {
        string.range(of: expression, options: .regularExpression) != nil
    }
    static func versions(_ value: Value) throws {
        let root = try object(value, keys: ["schemaVersion", "contractVersion", "platform", "runtime", "facade"], optional: ["build"])
        guard try integer(root["schemaVersion"]) == 2,
              string(root["contractVersion"]) == "2.0.0",
              ["browser", "android", "ios"].contains(string(root["platform"]) ?? "") else { throw EluRuntimeQueueError.invalidRecord }
        for role in ["runtime", "facade"] {
            let child = try object(required(root[role]), keys: ["name", "version"])
            let name = try boundedString(child["name"], maximum: 512)
            guard matches(name, role == "runtime" ? "^elu-[a-z0-9-]+$" : "^[A-Za-z][A-Za-z0-9._-]+$") else { throw EluRuntimeQueueError.invalidRecord }
            _ = try boundedString(child["version"], maximum: 64)
        }
        if let build = root["build"] { _ = try boundedString(build, maximum: 128) }
    }
}
