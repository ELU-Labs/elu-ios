import Foundation

/// Closed disk values, never a live capture permit or a restored frame lease.
enum EluStoredReplayRecord: Equatable, Sendable {
    case wireframe(EluV2ReplayStoredChunk)
    case raster(EluNativeRasterStoredChunk)

    var ordinal: Int64 { switch self { case let .wireframe(v): return v.ordinal; case let .raster(v): return v.ordinal } }
    var siteId: String { switch self { case let .wireframe(v): return v.siteId; case let .raster(v): return v.siteId } }
    var body: Data { switch self { case let .wireframe(v): return v.prepared.body; case let .raster(v): return v.prepared.body } }
    var requestId: String { switch self { case let .wireframe(v): return v.prepared.requestId; case let .raster(v): return v.prepared.requestId } }
    var replayId: String { switch self { case let .wireframe(v): return v.prepared.replayId; case let .raster(v): return v.prepared.replayId } }
    var chunkId: String { switch self { case let .wireframe(v): return v.prepared.chunkId; case let .raster(v): return v.prepared.chunkId } }
    var sequence: Int64 { switch self { case let .wireframe(v): return v.prepared.sequence; case let .raster(v): return v.prepared.sequence } }
    var generation: String { switch self { case let .wireframe(v): return v.captureProtocolGeneration; case .raster: return EluNativeRasterStoredRequest.generation } }
    var profile: Data { switch self { case let .wireframe(v): return v.maskingProfile; case .raster: return EluNativeRasterStoredRequest.profile } }
    var startedAt: EluV1Timestamp { switch self { case let .wireframe(v): return v.prepared.startedAt; case let .raster(v): return v.prepared.time } }
    var endedAt: EluV1Timestamp { switch self { case let .wireframe(v): return v.prepared.endedAt; case let .raster(v): return v.prepared.time } }
}

struct EluNativeRasterStoredChunk: Equatable, Sendable {
    let ordinal: Int64
    let siteId: String
    let prepared: EluNativeRasterStoredRequest
    init(ordinal: Int64, siteId: String, prepared: EluNativeRasterStoredRequest) throws {
        guard ordinal >= 0, EluV1Validation.validString(siteId, minimum: 1, maximum: 128) else {
            throw EluRuntimeQueueError.invalidRecord
        }
        self.ordinal = ordinal; self.siteId = siteId; self.prepared = prepared
    }
}

/// Exact schema3 envelope restoration. Inner gzip/image bytes stay opaque as
/// with v2 storage. This value cannot construct a Frame, sealer or admission.
struct EluNativeRasterStoredRequest: Equatable, Sendable {
    static let codec = "elu-native-raster-v1"
    static let generation = "native-raster-generation-v1"
    static let maximumBytes = 5_242_880
    static let profile = Data(#"{"automaticInputDiscovery":false,"contentAccess":"declared-root-raster","imageFormat":"opaque-png","inputCoverage":"declared-regions","privatePaint":"erase","profileKind":"elu-native-declared-regions-v1","redactionBoundary":"before-encoding","requiredBindingBehavior":"deny-incomplete-or-stale","schemaVersion":1,"unknownContentClassification":false}"#.utf8)
    static let profileHash = EluV1StrictCanonicalJSON.hash(profile)
    let body: Data
    let digest: String
    let requestId: String
    let replayId: String
    let sessionId: String
    let chunkId: String
    let sequence: Int64
    let time: EluV1Timestamp
    let anonymousId: String
    let userId: String?
    let identityRevision: Int64
    let contextRevision: Int64
    let policyRevision: String
    let effectivePolicyHash: String

    init(restoring data: Data) throws {
        typealias J = EluRasterStorageJSON
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw EluRuntimeQueueError.invalidRecord }
        let parsed = try EluV1StrictCanonicalJSON.parse(data)
        guard parsed.canonicalData == data else { throw EluRuntimeQueueError.invalidRecord }
        let root = try J.object(parsed.value, keys: ["schemaVersion", "requestId", "chunk"])
        let chunkValue = try J.required(root["chunk"])
        let chunk = try J.object(chunkValue, keys: ["schemaVersion", "replayId", "sessionId", "chunkId", "sequence", "startedAt", "endedAt", "identity", "contextRevision", "codec", "compression", "contentEncoding", "payload", "privacy", "versions"])
        guard try J.integer(root["schemaVersion"]) == 3, try J.integer(chunk["schemaVersion"]) == 3,
              J.string(chunk["codec"]) == Self.codec, J.string(chunk["compression"]) == "gzip",
              J.string(chunk["contentEncoding"]) == "base64",
              let payload = J.string(chunk["payload"]), !payload.isEmpty,
              let compressed = Data(base64Encoded: payload), !compressed.isEmpty,
              compressed.base64EncodedString() == payload else { throw EluRuntimeQueueError.invalidRecord }
        replayId = try J.text(chunk["replayId"], max: 256); sessionId = try J.text(chunk["sessionId"], max: 256)
        chunkId = try J.text(chunk["chunkId"], max: 256); sequence = try J.integer(chunk["sequence"])
        contextRevision = try J.integer(chunk["contextRevision"])
        let start = try J.text(chunk["startedAt"], max: 128), end = try J.text(chunk["endedAt"], max: 128)
        time = try EluV1Timestamp(start)
        guard EluV2ReplayText.equal(start, end), start.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\z"#, options: .regularExpression) != nil,
              !time.storageIsLeapSecond, (1...253_402_300_799_999).contains(time.floorUnixMilliseconds) else { throw EluRuntimeQueueError.invalidRecord }
        let identity = try J.object(J.required(chunk["identity"]), keys: ["anonymousId", "userId", "revision"])
        anonymousId = try J.text(identity["anonymousId"], max: 256)
        if case .null? = identity["userId"] { userId = nil } else { userId = try J.text(identity["userId"], max: 512) }
        identityRevision = try J.integer(identity["revision"])
        let privacy = try J.object(J.required(chunk["privacy"]), keys: ["schemaVersion", "policyRevision", "effectivePolicyHash", "maskingProfileHash", "inputCoverage", "automaticInputDiscovery", "unknownContentClassification", "appliedBeforeSerialization", "requiredRegionsRedacted", "platformFallbackApplied"])
        policyRevision = try J.text(privacy["policyRevision"], max: 128)
        effectivePolicyHash = try J.text(privacy["effectivePolicyHash"], max: 71)
        guard try J.integer(privacy["schemaVersion"]) == 1,
              EluV1Validation.validPolicyHash(effectivePolicyHash), J.string(privacy["maskingProfileHash"]) == Self.profileHash,
              J.string(privacy["inputCoverage"]) == "declared-regions",
              J.boolean(privacy["automaticInputDiscovery"], equals: false), J.boolean(privacy["unknownContentClassification"], equals: false),
              J.boolean(privacy["appliedBeforeSerialization"], equals: true), J.boolean(privacy["requiredRegionsRedacted"], equals: true),
              J.boolean(privacy["platformFallbackApplied"], equals: false) else { throw EluRuntimeQueueError.invalidRecord }
        let versions = try J.object(J.required(chunk["versions"]), keys: ["schemaVersion", "contractVersion", "platform", "runtime", "facade"], optional: ["build"])
        guard try J.integer(versions["schemaVersion"]) == 2, J.string(versions["contractVersion"]) == "2.0.0",
              J.string(versions["platform"]) == "ios" else { throw EluRuntimeQueueError.invalidRecord }
        for role in ["runtime", "facade"] {
            let member = try J.object(J.required(versions[role]), keys: ["name", "version"])
            let name = try J.text(member["name"], max: 512)
            guard name.range(of: role == "runtime" ? #"\Aelu-[a-z0-9-]+\z"# : #"\A[A-Za-z][A-Za-z0-9._-]+\z"#, options: .regularExpression) != nil else { throw EluRuntimeQueueError.invalidRecord }
            _ = try J.text(member["version"], max: 64)
        }
        if let build = versions["build"] { _ = try J.text(build, max: 128) }
        let canonicalChunk = try EluV1StrictCanonicalJSON.canonicalData(for: chunkValue)
        var material = Data("elu-sdk-replay-request-v3\0".utf8)
        var length = UInt32(canonicalChunk.count).bigEndian
        withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }; material.append(canonicalChunk)
        requestId = "request_" + String(EluV1StrictCanonicalJSON.hash(material).dropFirst(7))
        guard EluV2ReplayText.equal(J.string(root["requestId"]), requestId) else { throw EluRuntimeQueueError.invalidRecord }
        body = data; digest = EluV1StrictCanonicalJSON.hash(data)
    }
}

/// Whole original wrapper ordering, not a cached permission or config body.
struct EluNativeRasterSourceLedger: Equatable, Sendable {
    let issuedAt: EluV1Timestamp
    let semanticHash: String
    var conflicted: Bool
    func encoded() throws -> Data {
        try EluV1StrictCanonicalJSON.canonicalData(for: .object([
            .init(name: Array("issuedAt".utf16), value: .string(Array(issuedAt.source.utf16))),
            .init(name: Array("semanticHash".utf16), value: .string(Array(semanticHash.utf16))),
            .init(name: Array("conflicted".utf16), value: .bool(conflicted)),
        ]))
    }
    init(issuedAt: EluV1Timestamp, semanticHash: String, conflicted: Bool = false) {
        self.issuedAt = issuedAt; self.semanticHash = semanticHash; self.conflicted = conflicted
    }
    init(_ data: Data) throws {
        guard data.count <= 1_024 else { throw EluRuntimeQueueError.corruptStorage }
        let parsed = try EluV1StrictCanonicalJSON.parse(data)
        let object = try EluRasterStorageJSON.object(parsed.value, keys: ["issuedAt", "semanticHash", "conflicted"])
        issuedAt = try EluV1Timestamp(EluRasterStorageJSON.text(object["issuedAt"], max: 128))
        semanticHash = try EluRasterStorageJSON.text(object["semanticHash"], max: 71)
        guard parsed.canonicalData == data, EluV1Validation.validPolicyHash(semanticHash), case let .bool(conflict)? = object["conflicted"] else { throw EluRuntimeQueueError.corruptStorage }
        conflicted = conflict
    }
}

private enum EluRasterStorageJSON {
    typealias Value = EluV1StrictCanonicalJSON.Value
    static func required(_ value: Value?) throws -> Value { guard let value else { throw EluRuntimeQueueError.invalidRecord }; return value }
    static func object(_ value: Value, keys: Set<String>, optional: Set<String> = []) throws -> [String: Value] {
        guard case let .object(members) = value else { throw EluRuntimeQueueError.invalidRecord }
        let names = Set(members.map(\.name)), required = Set(keys.map { Array($0.utf16) })
        guard required.isSubset(of: names), names.isSubset(of: required.union(optional.map { Array($0.utf16) })), names.count == members.count else { throw EluRuntimeQueueError.invalidRecord }
        return Dictionary(uniqueKeysWithValues: members.map { (String(decoding: $0.name, as: UTF16.self), $0.value) })
    }
    static func boolean(_ value: Value?, equals expected: Bool) -> Bool {
        guard case let .bool(actual)? = value else { return false }; return actual == expected
    }
    static func string(_ value: Value?) -> String? { guard case let .string(units)? = value else { return nil }; return String(decoding: units, as: UTF16.self) }
    static func text(_ value: Value?, max: Int) throws -> String {
        guard let string = string(value), EluV1Validation.validString(string, minimum: 1, maximum: max) else { throw EluRuntimeQueueError.invalidRecord }; return string
    }
    static func integer(_ value: Value?) throws -> Int64 {
        guard case .number? = value, let number = Int64(String(decoding: try EluV1StrictCanonicalJSON.canonicalData(for: required(value)), as: UTF8.self)), (0...9_007_199_254_740_991).contains(number) else { throw EluRuntimeQueueError.invalidRecord }; return number
    }
}
