#if canImport(SwiftUI) && canImport(UIKit)
import CryptoKit
import Foundation

enum EluNativeRasterSealingError: Error, Equatable {
    case invalidBinding
    case withdrawn
    case sourceMismatch
    case invalidTimestamp
    case changedViewport
    case requestLimit
    case compression
    case sequenceExhausted
}

/// Descriptive retained policy input, not a grant or a substitute for the future
/// v3 resolver. In particular, an existing automatic-input v2 policy cannot be
/// projected here. The original owner must supply and retain that separate proof.
struct EluNativeRasterPolicyBinding: Equatable, Sendable {
    let policyRevision: String
    let effectivePolicyHash: String
    let contextRevision: Int64
    let maximumRequestBytes: Int

    init(policyRevision: String, effectivePolicyHash: String, contextRevision: Int64,
         maximumRequestBytes: Int) throws {
        guard EluV1Validation.validString(policyRevision, minimum: 1, maximum: 128),
              EluV1Validation.validPolicyHash(effectivePolicyHash),
              (0...9_007_199_254_740_991).contains(contextRevision),
              (1...EluNativeRasterPreparedRequest.maximumBytes).contains(maximumRequestBytes) else {
            throw EluNativeRasterSealingError.invalidBinding
        }
        self.policyRevision = policyRevision; self.effectivePolicyHash = effectivePolicyHash
        self.contextRevision = contextRevision; self.maximumRequestBytes = maximumRequestBytes
    }
}

/// Immutable original bytes for the existing queue's future admission/retry
/// path. There is deliberately no raw JSON, PNG or public submission initializer.
struct EluNativeRasterPreparedRequest: Equatable, Sendable {
    static let maximumBytes = 5_242_880
    let body: Data
    let requestId: String
    let digest: String
    let chunkId: String
    let replayId: String
    let sessionId: String
    let sequence: Int64
    let timestamp: Int64
    let contextRevision: Int64
    let effectivePolicyHash: String
    let width: Int
    let height: Int
    let sourceIdentity: EluSwiftUIReplaySourceIdentity

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.body == rhs.body && lhs.width == rhs.width && lhs.height == rhs.height
            && lhs.sourceIdentity === rhs.sourceIdentity
    }
    var codec: String { EluNativeRasterSealer.codec }
    var captureProtocolGeneration: String { EluNativeRasterSealer.protocolGeneration }

    fileprivate init(body: Data, requestId: String, chunkId: String, replayId: String,
                     sessionId: String, sequence: Int64, timestamp: Int64,
                     contextRevision: Int64, effectivePolicyHash: String, width: Int, height: Int, sourceIdentity: EluSwiftUIReplaySourceIdentity) {
        self.body = body; self.requestId = requestId; self.chunkId = chunkId
        digest = "sha256:" + EluNativeRasterSealer.digest(body)
        self.replayId = replayId; self.sessionId = sessionId; self.sequence = sequence
        self.timestamp = timestamp; self.contextRevision = contextRevision
        self.effectivePolicyHash = effectivePolicyHash; self.width = width; self.height = height
        self.sourceIdentity = sourceIdentity
    }
}

/// One serial, value-semantic epoch. No collection, source renewal, queue write
/// or authority installation occurs here. Keep a speculative copy until original
/// queue admission reports a known commit; retry that request's original bytes.
struct EluNativeRasterSealer: Sendable {
    static let codec = "elu-native-raster-v1"
    static let protocolGeneration = "native-raster-generation-v1"
    static let profileHash = "sha256:e374338e6100edcad1d11de079f6bdfc24df043107628b83a559bb3e87206422"
    static let maximumPayloadBytes = 2_800_000
    private typealias JSON = EluV1StrictCanonicalJSON.Value
    private let replayId: String
    private let sessionId: String
    private let identity: JSON
    private let versions: JSON
    private let privacy: JSON
    private let policy: EluNativeRasterPolicyBinding
    private let sourceIdentity: EluSwiftUIReplaySourceIdentity
    // Must close over the original source/identity/policy/local-intent witness.
    // There is no default-true path and no per-frame replacement witness.
    private let sourceIsCurrent: @Sendable () -> Bool
    private var nextSequence: Int64 = 0
    private var lastTimestamp: Int64?
    private var viewport: (width: Int, height: Int)?

    init(replayId: String, identity snapshot: EluIdentitySnapshot,
         policy: EluNativeRasterPolicyBinding, versions: EluVersionContext,
         sourceIdentity: EluSwiftUIReplaySourceIdentity,
         sourceIsCurrent: @escaping @Sendable () -> Bool) throws {
        _ = try JSONEncoder().encode(snapshot.identity)
        _ = try JSONEncoder().encode(versions)
        guard sourceIsCurrent() else { throw EluNativeRasterSealingError.withdrawn }
        guard EluV1Validation.validString(replayId, minimum: 1, maximum: 256),
              let session = snapshot.identity.session, !snapshot.identity.optedOut,
              snapshot.identity.revision <= 9_007_199_254_740_991,
              snapshot.identity.contextRevision == policy.contextRevision,
              versions.platform == "ios" else { throw EluNativeRasterSealingError.invalidBinding }
        self.replayId = replayId; sessionId = session.id; self.policy = policy
        self.sourceIsCurrent = sourceIsCurrent
        self.sourceIdentity = sourceIdentity
        identity = Self.object([
            ("anonymousId", Self.string(snapshot.identity.anonymousId)),
            ("userId", snapshot.identity.userId.map(Self.string) ?? .null),
            ("revision", Self.integer(snapshot.identity.revision)),
        ])
        privacy = Self.object([
            ("schemaVersion", Self.integer(1)),
            ("policyRevision", Self.string(policy.policyRevision)),
            ("effectivePolicyHash", Self.string(policy.effectivePolicyHash)),
            ("maskingProfileHash", Self.string(Self.profileHash)),
            ("inputCoverage", Self.string("declared-regions")),
            ("automaticInputDiscovery", .bool(false)),
            ("unknownContentClassification", .bool(false)),
            ("appliedBeforeSerialization", .bool(true)),
            ("requiredRegionsRedacted", .bool(true)),
            ("platformFallbackApplied", .bool(false)),
        ])
        var fields: [(String, JSON)] = [
            ("schemaVersion", Self.integer(2)), ("contractVersion", Self.string("2.0.0")),
            ("platform", Self.string("ios")),
            ("runtime", Self.object([("name", Self.string(versions.runtime.name)), ("version", Self.string(versions.runtime.version))])),
            ("facade", Self.object([("name", Self.string(versions.facade.name)), ("version", Self.string(versions.facade.version))])),
        ]
        if let build = versions.build { fields.append(("build", Self.string(build))) }
        self.versions = Self.object(fields)
    }

    /// Timestamp is the original capture's wall-clock integer millisecond value,
    /// never adjusted to satisfy pacing. The collector/owner separately enforce
    /// monotonic work limits. Every path consumes/closes the one-shot candidate.
    mutating func seal(_ frame: EluSwiftUIReplayFrame, timestamp: Int64) throws -> EluNativeRasterPreparedRequest {
        defer { frame.close() }
        try checkSource()
        guard frame.sourceIdentity === sourceIdentity else { throw EluNativeRasterSealingError.sourceMismatch }
        guard nextSequence <= 9_007_199_254_740_991 else { throw EluNativeRasterSealingError.sequenceExhausted }
        guard (1...253_402_300_799_999).contains(timestamp),
              lastTimestamp.map({ timestamp >= $0 && timestamp - $0 >= 1_000 }) ?? true else {
            throw EluNativeRasterSealingError.invalidTimestamp
        }
        if let viewport, viewport.width != frame.width || viewport.height != frame.height {
            throw EluNativeRasterSealingError.changedViewport
        }
        let time = try EluNativeReplaySealer.timestamp(timestamp)
        var png = try frame.encodePNG()
        defer { png.resetBytes(in: 0..<png.count) }
        try checkSource()
        // The collector retains an inward-rounded, one-pixel-per-point crop.
        // Its logical extent is that actual crop, not the stretched outer root.
        var payload = try EluV1StrictCanonicalJSON.canonicalData(for: .array([Self.object([
            ("schemaVersion", Self.integer(1)), ("type", Self.string("frame")),
            ("timestamp", Self.integer(timestamp)),
            ("image", Self.object([("width", Self.integer(Int64(frame.width))),
                ("height", Self.integer(Int64(frame.height))), ("png", Self.string(png.base64EncodedString()))])),
            ("viewport", Self.object([("width", Self.integer(Int64(frame.width))),
                ("height", Self.integer(Int64(frame.height)))])),
        ])]))
        defer { payload.resetBytes(in: 0..<payload.count) }
        guard payload.count <= Self.maximumPayloadBytes else { throw EluNativeRasterSealingError.requestLimit }
        try checkSource()
        let chunkIdentity = Self.object([("domain", Self.string("elu-native-raster-chunk-v1")),
            ("replayId", Self.string(replayId)), ("sequence", Self.integer(nextSequence))])
        let chunkId = "chunk_" + Self.digest(try EluV1StrictCanonicalJSON.canonicalData(for: chunkIdentity))
        func chunk(_ payload: String) -> JSON {
            Self.object([
                ("schemaVersion", Self.integer(3)), ("replayId", Self.string(replayId)),
                ("sessionId", Self.string(sessionId)), ("chunkId", Self.string(chunkId)),
                ("sequence", Self.integer(nextSequence)), ("startedAt", Self.string(time)), ("endedAt", Self.string(time)),
                ("identity", identity), ("contextRevision", Self.integer(policy.contextRevision)),
                ("codec", Self.string(Self.codec)), ("compression", Self.string("gzip")),
                ("contentEncoding", Self.string("base64")), ("payload", Self.string(payload)),
                ("privacy", privacy), ("versions", versions),
            ])
        }
        let empty = try EluV1StrictCanonicalJSON.canonicalData(for: Self.envelope(chunk(""),
            requestId: "request_" + String(repeating: "0", count: 64)))
        guard empty.count < policy.maximumRequestBytes else { throw EluNativeRasterSealingError.requestLimit }
        var compressed: Data
        do {
            compressed = try EluNativeReplaySealer.gzip(payload,
                maximumBytes: ((policy.maximumRequestBytes - empty.count) / 4) * 3)
        } catch EluNativeReplaySealingError.requestLimit {
            throw EluNativeRasterSealingError.requestLimit
        } catch {
            throw EluNativeRasterSealingError.compression
        }
        defer { compressed.resetBytes(in: 0..<compressed.count) }
        let canonicalChunk = try EluV1StrictCanonicalJSON.canonicalData(for: chunk(compressed.base64EncodedString()))
        var material = Data("elu-sdk-replay-request-v3".utf8); material.append(0)
        var length = UInt32(canonicalChunk.count).bigEndian
        withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }; material.append(canonicalChunk)
        let requestId = "request_" + Self.digest(material)
        let parsed = try EluV1StrictCanonicalJSON.parse(canonicalChunk)
        var body = try EluV1StrictCanonicalJSON.canonicalData(for: Self.envelope(parsed.value, requestId: requestId))
        var accepted = false
        defer { if !accepted { body.resetBytes(in: 0..<body.count) } }
        guard body.count <= policy.maximumRequestBytes else { throw EluNativeRasterSealingError.requestLimit }
        try checkSource()
        let prepared = EluNativeRasterPreparedRequest(body: body, requestId: requestId, chunkId: chunkId,
            replayId: replayId, sessionId: sessionId, sequence: nextSequence, timestamp: timestamp,
            contextRevision: policy.contextRevision, effectivePolicyHash: policy.effectivePolicyHash,
            width: frame.width, height: frame.height, sourceIdentity: sourceIdentity)
        // Recheck after the final digest/copy as well as after encoding. The
        // existing admission path must check this original witness again at SQL.
        try checkSource()
        nextSequence += 1; lastTimestamp = timestamp; viewport = (frame.width, frame.height)
        accepted = true
        return prepared
    }

    private func checkSource() throws {
        guard sourceIsCurrent() else { throw EluNativeRasterSealingError.withdrawn }
    }
    private static func object(_ fields: [(String, JSON)]) -> JSON {
        .object(fields.map { .init(name: Array($0.0.utf16), value: $0.1) })
    }
    private static func string(_ value: String) -> JSON { .string(Array(value.utf16)) }
    private static func integer(_ value: Int64) -> JSON { .number(String(value)) }
    private static func envelope(_ chunk: JSON, requestId: String) -> JSON {
        object([("schemaVersion", integer(3)), ("requestId", string(requestId)), ("chunk", chunk)])
    }
    fileprivate static func digest(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
