import Foundation

/// Closed semantic projection only. This cannot install a source, renew a lease,
/// grant consent or replace the original queue/configuration authority.
enum EluNativeV3ConfigParser {
    private typealias JSON = EluV1StrictCanonicalJSON.Value
    static let maximumBytes = 65_536
    static let profileHash = "sha256:e374338e6100edcad1d11de079f6bdfc24df043107628b83a559bb3e87206422"
    private static let policyDomain = "elu-native-raster-effective-policy-v1\0"

    enum Failure: Error, Equatable {
        case tooLarge, malformed, incompatibleBase, mismatchedRaster
    }

    struct RasterPolicy: Sendable {
        let endpoint: URL
        let revision: String
        let effectivePolicyHash: String
        let maximumRequestBytes: Int
        fileprivate init(endpoint: URL, revision: String, effectivePolicyHash: String,
                         maximumRequestBytes: Int) {
            self.endpoint = endpoint; self.revision = revision
            self.effectivePolicyHash = effectivePolicyHash
            self.maximumRequestBytes = maximumRequestBytes
        }
    }

    struct Parsed: Sendable {
        /// Original envelope receipt bytes, never replaced by a canonical projection.
        let data: Data
        /// Original embedded JSON value bytes, for the existing base parser/receipt.
        let configV2Data: Data
        let base: EluV1ConfigDocument
        let canonicalData: Data
        let semanticHash: String
        let baseCanonicalData: Data
        let baseSemanticHash: String
        let basePrivacyHash: String?
        let raster: RasterPolicy?
        fileprivate init(data: Data, configV2Data: Data, base: EluV1ConfigDocument,
                         canonicalData: Data, baseCanonicalData: Data,
                         baseSemanticHash: String, basePrivacyHash: String?, raster: RasterPolicy?) {
            self.data = data; self.configV2Data = configV2Data; self.base = base
            self.canonicalData = canonicalData
            semanticHash = EluV1StrictCanonicalJSON.hash(canonicalData)
            self.baseCanonicalData = baseCanonicalData; self.baseSemanticHash = baseSemanticHash
            self.basePrivacyHash = basePrivacyHash; self.raster = raster
        }
    }

    static func parse(_ data: Data, endpointPolicy: EluEndpointPolicy = .cloud) throws -> Parsed {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let extracted = try EluV1StrictCanonicalJSON.parse(data, retainingRootProperty: "configV2")
        let envelope = extracted.document
        guard case let .object(members) = envelope.value,
              Set(members.map { String(decoding: $0.name, as: UTF16.self) })
                .isSubset(of: ["schemaVersion", "configV2", "raster"]),
              let version = try envelope.objectProperty("schemaVersion"),
              try EluV1StrictCanonicalJSON.canonicalData(for: version) == Data("3".utf8),
              let baseData = extracted.propertyData else { throw Failure.malformed }
        let prepared = try EluV1ConfigManager.prepareConfig(baseData, endpointPolicy: endpointPolicy)
        guard prepared.document.schemaVersion == 2 else { throw Failure.incompatibleBase }
        let raster = try envelope.objectProperty("raster").map {
            try validateRaster($0, base: prepared.document, baseData: baseData,
                               events: prepared.trustedEndpoints?[.events])
        }
        return Parsed(data: data, configV2Data: baseData, base: prepared.document,
                      canonicalData: envelope.canonicalData,
                      baseCanonicalData: prepared.canonicalData,
                      baseSemanticHash: prepared.semanticHash,
                      basePrivacyHash: prepared.policySourceHash, raster: raster)
    }

    private static func validateRaster(_ candidate: JSON, base: EluV1ConfigDocument,
                                       baseData: Data, events: URL?) throws -> RasterPolicy {
        guard base.status == .enabled,
              base.features?.capture == true, base.features?.replay == true,
              let privacy = base.privacy, privacy.capture.enabled, privacy.replay.enabled,
              privacy.regionPolicy.mode != .block,
              privacy.masking.text == .sensitive, privacy.masking.images == .allow,
              privacy.masking.platformRules?.contains(where: { $0.platform != .browser }) != true,
              let replay = base.capabilities?.replay,
              replay.advertisedTransports.count == 1,
              let pair = replay.advertisedTransports.first,
              EluNativeReplayProtocol.matching(codec: pair.codec,
                compression: pair.compression.rawValue, generation: replay.replayProtocolGeneration) != nil,
              let limits = base.limits, let events,
              var origin = URLComponents(url: events, resolvingAgainstBaseURL: false) else {
            throw Failure.incompatibleBase
        }
        origin.path = ""; origin.query = nil; origin.fragment = nil
        // This leaf implements the frozen public issuer's two origins. Local
        // endpoint policy was already applied to every original base endpoint.
        guard let originString = origin.string,
              ["https://ingest.elu.dev", "https://35-224-68-29.sslip.io"].contains(originString),
              let endpoint = URL(string: originString + "/v3/replay") else {
            throw Failure.incompatibleBase
        }
        let baseDocument = try EluV1StrictCanonicalJSON.parse(baseData)
        guard let basePrivacy = try baseDocument.objectProperty("privacy") else { throw Failure.incompatibleBase }
        let material = object([
            ("schemaVersion", integer(1)), ("policyRevision", string(privacy.revision)),
            ("basePolicyRevision", string(privacy.revision)), ("basePrivacy", basePrivacy),
            ("replayAudience", string(base.replayAudience ?? "all-devices")),
            ("declaredRegionsAllowed", .bool(true)), ("inputCoverage", string("declared-regions")),
            ("automaticInputDiscovery", .bool(false)), ("unknownContentClassification", .bool(false)),
            ("redactionBoundary", string("before-encoding")),
            ("requiredBindingBehavior", string("deny-incomplete-or-stale")),
            ("maskingProfileHash", string(profileHash)), ("limits", rasterLimits),
        ])
        let hash = EluV1StrictCanonicalJSON.hash(Data(policyDomain.utf8)
            + (try EluV1StrictCanonicalJSON.canonicalData(for: material)))
        let expected = object([
            ("schemaVersion", integer(1)), ("endpoint", string(endpoint.absoluteString)),
            ("replayContractVersion", string("3.0.0")), ("replaySchemaVersion", integer(3)),
            ("ackSchemaVersion", integer(3)),
            ("replayProtocolGeneration", string("native-raster-generation-v1")),
            ("codec", string("elu-native-raster-v1")), ("compression", string("gzip")),
            ("platforms", .array([string("android"), string("ios")])),
            ("privacy", object([
                ("schemaVersion", integer(1)), ("revision", string(privacy.revision)),
                ("effectivePolicyHash", string(hash)), ("maskingProfileHash", string(profileHash)),
                ("declaredRegionsAllowed", .bool(true)), ("inputCoverage", string("declared-regions")),
                ("automaticInputDiscovery", .bool(false)), ("unknownContentClassification", .bool(false)),
                ("redactionBoundary", string("before-encoding")),
                ("requiredBindingBehavior", string("deny-incomplete-or-stale")),
            ])),
            ("limits", rasterLimits),
        ])
        // Equality against the complete expected shape rejects every missing,
        // extra, null, crossed-profile and mismatched-policy member recursively.
        guard try EluV1StrictCanonicalJSON.canonicalData(for: candidate)
            == EluV1StrictCanonicalJSON.canonicalData(for: expected) else { throw Failure.mismatchedRaster }
        return RasterPolicy(endpoint: endpoint, revision: privacy.revision, effectivePolicyHash: hash,
                            maximumRequestBytes: min(limits.replayChunkBytes, 5_242_880))
    }

    private static var rasterLimits: JSON {
        object([("requestBytes", integer(5_242_880)), ("decodedPayloadBytes", integer(2_800_000)),
                ("pngBytes", integer(2_097_152)), ("imageEdgePixels", integer(2_048)),
                ("imagePixels", integer(1_048_576)), ("viewportEdge", integer(16_384)),
                ("minimumFrameIntervalSeconds", integer(1)), ("framesPerChunk", integer(1))])
    }
    private static func object(_ values: [(String, JSON)]) -> JSON {
        .object(values.map { .init(name: Array($0.0.utf16), value: $0.1) })
    }
    private static func string(_ value: String) -> JSON { .string(Array(value.utf16)) }
    private static func integer(_ value: Int) -> JSON { .number(String(value)) }
}
