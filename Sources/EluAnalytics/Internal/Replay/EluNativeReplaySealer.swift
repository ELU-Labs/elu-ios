import CryptoKit
import Foundation
import zlib

enum EluNativeReplaySealingError: Error, Equatable {
    case invalidBinding
    case requestLimit
    case compression
}

/// Descriptive immutable recording data. It grants neither collection nor queue admission.
struct EluNativeReplaySealer: Sendable {
    private typealias JSON = EluV1StrictCanonicalJSON.Value
    private let replayId: String
    private let sessionId: String
    private let identity: JSON
    private let contextRevision: Int64
    private let privacy: JSON
    private let versions: JSON
    private let protocolGeneration: String
    private let maximumRequestBytes: Int
    private var encoder: EluNativeWireframeEncoder

    init(replayId: String, identity snapshot: EluIdentitySnapshot,
         authorization: EluV1ConfigResolution, privacy projected: EluProjectedPrivacyState,
         profile: EluNativeMaskingProfile, versions: EluVersionContext,
         limits: EluNativeWireframeEncoder.Limits = try! .init()) throws {
        _ = try JSONEncoder().encode(snapshot.identity)
        guard EluV1Validation.validString(replayId, minimum: 1, maximum: 256),
              let session = snapshot.identity.session,
              !snapshot.identity.optedOut,
              authorization.configSchemaVersion == 2,
              case .authorized = authorization.captureAuthorization,
              case let .authorized(pair) = authorization.replayAuthorization,
              pair.codec == "elu-native-wireframe-v1", pair.compression == .gzip,
              let generation = authorization.replayProtocolGeneration,
              authorization.decisionHash == projected.effectivePolicyHash,
              authorization.decisionContextRevision == snapshot.identity.contextRevision,
              (1 ... 65_536).contains(projected.stateData.count)
        else { throw EluNativeReplaySealingError.invalidBinding }
        let document = try EluV1StrictCanonicalJSON.parse(projected.stateData)
        guard document.canonicalData == projected.stateData, case let .object(members) = document.value
        else { throw EluNativeReplaySealingError.invalidBinding }
        let original = try JSONDecoder().decode(EluV1EffectivePrivacyState.self, from: projected.stateData)
        let hashName = Array("effectivePolicyHash".utf16)
        let withoutHash = JSON.object(members.filter { $0.name != hashName })
        guard try EluV1StrictCanonicalJSON.hash(withoutHash) == projected.effectivePolicyHash,
              original.effectivePolicyHash == projected.effectivePolicyHash,
              original.captureAllowed, original.replayAllowed, original.replaySampled,
              original.maskingValidated, original.replaySessionEligible, !original.identityOptedOut,
              original.replayBudgetRemainingSeconds > 0,
              original.contextRevision == snapshot.identity.contextRevision,
              original.replayTransport?.codec == pair.codec, original.replayTransport?.compression == pair.compression,
              original.effectiveMasking.secureInputsMasked,
              original.effectiveMasking.platformFallbackApplied == projected.platformFallbackApplied,
              profile == .blanketMask(), versions.platform == "ios"
        else { throw EluNativeReplaySealingError.invalidBinding }
        // Validate the existing version context before explicitly projecting its v2 wire wrapper.
        _ = try JSONEncoder().encode(versions)
        self.replayId = replayId; sessionId = session.id
        identity = Self.object([
            ("anonymousId", Self.string(snapshot.identity.anonymousId)),
            ("userId", snapshot.identity.userId.map(Self.string) ?? .null),
            ("revision", Self.integer(snapshot.identity.revision)),
        ])
        contextRevision = snapshot.identity.contextRevision
        privacy = Self.object([
            ("policyRevision", Self.string(original.policyRevision)),
            ("effectivePolicyHash", Self.string(projected.effectivePolicyHash)),
            ("maskingProfileHash", Self.string(profile.hash)),
            ("appliedBeforeSerialization", .bool(true)), ("secureInputsMasked", .bool(true)),
            ("platformFallbackApplied", .bool(original.effectiveMasking.platformFallbackApplied)),
        ])
        var versionFields: [(String, JSON)] = [
            ("schemaVersion", Self.integer(2)), ("contractVersion", Self.string("2.0.0")),
            ("platform", Self.string("ios")),
            ("runtime", Self.object([("name", Self.string(versions.runtime.name)), ("version", Self.string(versions.runtime.version))])),
            ("facade", Self.object([("name", Self.string(versions.facade.name)), ("version", Self.string(versions.facade.version))])),
        ]
        if let build = versions.build { versionFields.append(("build", Self.string(build))) }
        self.versions = Self.object(versionFields); protocolGeneration = generation
        maximumRequestBytes = min(authorization.limits.replayChunkBytes, EluV2ReplayPreparedRequest.maximumBytes)
        encoder = try EluNativeWireframeEncoder(limits: limits)
    }

    /// Serial value operation: only a fully prepared request advances this encoder history.
    mutating func seal(_ snapshots: [EluNativeMaskedSnapshot]) throws -> EluV2ReplayPreparedRequest {
        var next = encoder
        let chunk = try next.encode(snapshots)
        let chunkIdentity = Self.object([
            ("domain", Self.string("elu-native-replay-chunk-v1")),
            ("replayId", Self.string(replayId)), ("sequence", Self.integer(chunk.sequence)),
        ])
        let chunkID = "chunk_" + Self.digest(try EluV1StrictCanonicalJSON.canonicalData(for: chunkIdentity))
        let start = try Self.timestamp(chunk.firstTimestamp), end = try Self.timestamp(chunk.lastTimestamp)
        func value(payload: String) -> JSON {
            Self.object([
                ("schemaVersion", Self.integer(2)), ("replayId", Self.string(replayId)),
                ("sessionId", Self.string(sessionId)), ("chunkId", Self.string(chunkID)),
                ("sequence", Self.integer(chunk.sequence)),
                ("startedAt", Self.string(start)), ("endedAt", Self.string(end)),
                ("identity", identity), ("contextRevision", Self.integer(contextRevision)),
                ("codec", Self.string("elu-native-wireframe-v1")), ("compression", Self.string("gzip")),
                ("contentEncoding", Self.string("base64")), ("payload", Self.string(payload)),
                ("privacy", privacy), ("versions", versions),
            ])
        }
        // Canonical base64 needs no escaping; determine its allowance before compression or expansion.
        let emptyEnvelope = try EluV1StrictCanonicalJSON.canonicalData(for: Self.envelope(
            value(payload: ""), requestId: "request_" + String(repeating: "0", count: 64)))
        guard emptyEnvelope.count < maximumRequestBytes else { throw EluNativeReplaySealingError.requestLimit }
        let compressedLimit = ((maximumRequestBytes - emptyEnvelope.count) / 4) * 3
        let compressed = try Self.gzip(chunk.data, maximumBytes: compressedLimit)
        let canonicalChunk = try EluV1StrictCanonicalJSON.canonicalData(for: value(payload: compressed.base64EncodedString()))
        var material = Data("elu-sdk-replay-request-v2".utf8); material.append(0)
        var length = UInt32(canonicalChunk.count).bigEndian
        withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }; material.append(canonicalChunk)
        let requestId = "request_" + Self.digest(material)
        let parsedChunk = try EluV1StrictCanonicalJSON.parse(canonicalChunk)
        let body = try EluV1StrictCanonicalJSON.canonicalData(for: Self.envelope(parsedChunk.value, requestId: requestId))
        guard body.count <= maximumRequestBytes else { throw EluNativeReplaySealingError.requestLimit }
        let prepared = try EluV2ReplayPreparedRequest(body, captureProtocolGeneration: protocolGeneration)
        encoder = next
        return prepared
    }

    private static func object(_ fields: [(String, JSON)]) -> JSON {
        .object(fields.map { .init(name: Array($0.0.utf16), value: $0.1) })
    }
    private static func string(_ value: String) -> JSON { .string(Array(value.utf16)) }
    private static func integer(_ value: Int64) -> JSON { .number(String(value)) }
    private static func envelope(_ chunk: JSON, requestId: String) -> JSON {
        object([("schemaVersion", integer(2)), ("requestId", string(requestId)), ("chunk", chunk)])
    }
    private static func digest(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
    private static func timestamp(_ milliseconds: Int64) throws -> String {
        guard (1 ... 253_402_300_799_999).contains(milliseconds) else { throw EluNativeEncodingError.invalidTimestamp }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.formatOptions = [.withInternetDateTime]
        let seconds = formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds / 1_000)))
        guard seconds.hasSuffix("Z") else { throw EluNativeEncodingError.invalidTimestamp }
        let value = String(seconds.dropLast()) + String(format: ".%03lldZ", milliseconds % 1_000)
        _ = try EluV1Timestamp(value)
        return value
    }
    private static func gzip(_ input: Data, maximumBytes: Int) throws -> Data {
        guard (1 ... 16_777_216).contains(input.count), maximumBytes >= 18
        else { throw EluNativeReplaySealingError.requestLimit }
        var stream = z_stream()
        guard deflateInit2_(&stream, 6, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw EluNativeReplaySealingError.compression }
        defer { deflateEnd(&stream) }
        return try input.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var output = Data()
            while true {
                var block = Data(count: min(65_536, maximumBytes - output.count + 1))
                let capacity = block.count
                let result = block.withUnsafeMutableBytes { bytes -> Int32 in
                    stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    return deflate(&stream, Z_FINISH)
                }
                let produced = capacity - Int(stream.avail_out)
                guard produced <= maximumBytes - output.count else { throw EluNativeReplaySealingError.requestLimit }
                guard result == Z_OK || result == Z_STREAM_END else { throw EluNativeReplaySealingError.compression }
                output.append(block.prefix(produced))
                if result == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw EluNativeReplaySealingError.compression }
                    return output
                }
                guard produced > 0 else { throw EluNativeReplaySealingError.compression }
            }
        }
    }
}
