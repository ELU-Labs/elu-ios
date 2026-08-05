import Foundation

enum EluV1FlagContractError: Error, Equatable, Sendable {
    case malformedRequest
    case malformedResponse
    case responseTooLarge
    case requestTooLarge
    case unsupportedSchemaVersion
    case echoMismatch
    case invalidTimestamp
    case expiredResponse
    case invalidFlagValue
    case invalidIdentifier
    case invalidRevision
    case cacheTooLarge
    case malformedCache
}

struct EluV1StoredTimestamp: Codable, Equatable, Sendable {
    let source: String
    let day: Int64
    let secondOfDay: Int64
    let isLeapSecond: Bool
    let fractionalDigits: String

    init(_ timestamp: EluV1Timestamp) {
        source = timestamp.source
        day = timestamp.storageDay
        secondOfDay = timestamp.storageSecondOfDay
        isLeapSecond = timestamp.storageIsLeapSecond
        fractionalDigits = timestamp.storageFractionDigits
    }

    func validated() throws -> EluV1Timestamp {
        let timestamp: EluV1Timestamp
        do {
            timestamp = try EluV1Timestamp(source)
        } catch {
            throw EluV1FlagContractError.invalidTimestamp
        }
        guard timestamp.storageDay == day,
              timestamp.storageSecondOfDay == secondOfDay,
              timestamp.storageIsLeapSecond == isLeapSecond,
              timestamp.storageFractionDigits == fractionalDigits
        else {
            throw EluV1FlagContractError.invalidTimestamp
        }
        return timestamp
    }
}

struct EluV1FlagDurableAuthority: Codable, Equatable, Sendable {
    static let storageSchema = 1

    var storageSchema: Int = Self.storageSchema
    var initialized: Bool
    var barrierGeneration: Int64
    var lastObservedWall: EluV1StoredTimestamp?
    var ordering: EluV1StoredTimestamp?
    var semanticHash: String?
    var restriction: EluV1FlagRestriction?
    var exactConstructorSiteKey: String?
    var siteNamespaceDigest: String?
    var siteId: String?
    var configRevision: String?
    var endpoint: String?
    var configExpiresAt: EluV1StoredTimestamp?

    static func uninitialized(
        exactConstructorSiteKey: String,
        siteNamespaceDigest: String
    ) -> EluV1FlagDurableAuthority {
        EluV1FlagDurableAuthority(
            initialized: false,
            barrierGeneration: 0,
            lastObservedWall: nil,
            ordering: nil,
            semanticHash: nil,
            restriction: nil,
            exactConstructorSiteKey: exactConstructorSiteKey,
            siteNamespaceDigest: siteNamespaceDigest,
            siteId: nil,
            configRevision: nil,
            endpoint: nil,
            configExpiresAt: nil
        )
    }

    var isAllowed: Bool {
        initialized && ordering != nil && restriction == nil && endpoint != nil
    }

    func validate() throws {
        guard storageSchema == Self.storageSchema,
              EluV1FlagEvaluationWitness.safeRevision(barrierGeneration)
        else {
            throw EluV1FlagContractError.malformedCache
        }
        if !initialized {
            guard barrierGeneration == 0,
                  lastObservedWall == nil,
                  ordering == nil,
                  semanticHash == nil,
                  restriction == nil,
                  Self.validIdentifier(exactConstructorSiteKey, maximum: 512),
                  Self.validDigest(siteNamespaceDigest, prefixed: false),
                  siteId == nil,
                  configRevision == nil,
                  endpoint == nil,
                  configExpiresAt == nil
            else {
                throw EluV1FlagContractError.malformedCache
            }
            return
        }

        guard barrierGeneration > 0,
              let lastObservedWall,
              Self.validIdentifier(exactConstructorSiteKey, maximum: 512),
              Self.validDigest(siteNamespaceDigest, prefixed: false)
        else {
            throw EluV1FlagContractError.malformedCache
        }
        _ = try lastObservedWall.validated()

        let projectedFields: [Any?] = [ordering, semanticHash, configRevision, configExpiresAt]
        let hasProjection = projectedFields.allSatisfy { $0 != nil }
        guard hasProjection || projectedFields.allSatisfy({ $0 == nil }) else {
            throw EluV1FlagContractError.malformedCache
        }

        if hasProjection {
            guard let ordering,
                  let semanticHash,
                  let configRevision,
                  let configExpiresAt,
                  Self.validDigest(semanticHash, prefixed: true),
                  Self.validIdentifier(configRevision, maximum: 128),
                  siteId.map({ Self.validIdentifier($0, maximum: 128) }) ?? true,
                  endpoint.map(Self.validEndpoint) ?? true,
                  endpoint == nil || siteId != nil,
                  restriction != .missing,
                  restriction != .wallRollback,
                  restriction != .storageUnavailable,
                  try ordering.validated() < configExpiresAt.validated()
            else {
                throw EluV1FlagContractError.malformedCache
            }
            if restriction == nil, siteId == nil || endpoint == nil {
                throw EluV1FlagContractError.malformedCache
            }
        } else {
            guard siteId == nil,
                  endpoint == nil,
                  restriction == .malformed || restriction == .terminal
            else {
                throw EluV1FlagContractError.malformedCache
            }
        }
    }

    private static func validIdentifier(_ value: String?, maximum: Int) -> Bool {
        guard let value else { return false }
        return EluV1FlagEvaluationWitness.validIdentifier(value, maximum: maximum)
    }

    private static func validDigest(_ value: String?, prefixed: Bool) -> Bool {
        guard let value else { return false }
        let hex = prefixed ? String(value.dropFirst("sha256:".count)) : value
        guard (!prefixed || value.hasPrefix("sha256:")), hex.count == 64 else { return false }
        return hex.utf8.allSatisfy {
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains($0)
        }
    }

    private static func validEndpoint(_ source: String) -> Bool {
        guard source.unicodeScalars.count <= 2_048,
              let components = URLComponents(string: source)
        else {
            return false
        }
        return components.scheme == "https"
            && components.host != nil
            && components.user == nil
            && components.password == nil
            && components.fragment == nil
    }
}

struct EluV1FlagRequestCacheState: Codable, Equatable, Sendable {
    static let storageSchema = 1

    var storageSchema: Int = Self.storageSchema
    var storeEpoch: String
    var requestGeneration: Int64
    var activeRequestId: String?
    var barrierGeneration: Int64
    var activeWitnessHash: String?
    var cacheRecordId: String?
    var cachedWitnessHash: String?
    var flagsRevision: String?
    var evaluatedAt: EluV1StoredTimestamp?
    var responseExpiresAt: EluV1StoredTimestamp?
    var effectiveExpiresAt: EluV1StoredTimestamp?

    func validate() throws {
        guard storageSchema == Self.storageSchema,
              EluV1FlagEvaluationWitness.validIdentifier(storeEpoch, maximum: 256),
              (1 ... 9_007_199_254_740_991).contains(requestGeneration),
              (1 ... 9_007_199_254_740_991).contains(barrierGeneration),
              activeRequestId.map({ EluV1FlagEvaluationWitness.validIdentifier($0, maximum: 256) }) ?? true
        else {
            throw EluV1FlagContractError.malformedCache
        }
        let cacheFields: [Any?] = [
            cacheRecordId, cachedWitnessHash, flagsRevision, evaluatedAt,
            responseExpiresAt, effectiveExpiresAt,
        ]
        guard cacheFields.allSatisfy({ $0 != nil }) || cacheFields.allSatisfy({ $0 == nil }) else {
            throw EluV1FlagContractError.malformedCache
        }
        if let evaluatedAt, let responseExpiresAt, let effectiveExpiresAt {
            let evaluated = try evaluatedAt.validated()
            let responseExpiry = try responseExpiresAt.validated()
            let effectiveExpiry = try effectiveExpiresAt.validated()
            guard evaluated < effectiveExpiry,
                  evaluated < responseExpiry,
                  effectiveExpiry == responseExpiry || effectiveExpiry < responseExpiry
            else {
                throw EluV1FlagContractError.malformedCache
            }
        }
        guard (activeRequestId == nil) == (activeWitnessHash == nil),
              activeWitnessHash.map(Self.validHash) ?? true,
              cacheRecordId.map({ EluV1FlagEvaluationWitness.validIdentifier($0, maximum: 256) }) ?? true,
              cachedWitnessHash.map(Self.validHash) ?? true,
              flagsRevision.map({ EluV1FlagEvaluationWitness.validIdentifier($0, maximum: 128) }) ?? true
        else {
            throw EluV1FlagContractError.malformedCache
        }
    }

    private static func validHash(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value.count == 71 else { return false }
        return value.dropFirst(7).utf8.allSatisfy {
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains($0)
        }
    }
}

enum EluV1FlagStorageCodec {
    static let maximumMetadataBytes = 1_048_576

    static func encodeAuthority(_ value: EluV1FlagDurableAuthority) throws -> Data {
        try value.validate()
        return try encode(value)
    }

    static func decodeAuthority(_ data: Data) throws -> EluV1FlagDurableAuthority {
        let value: EluV1FlagDurableAuthority = try decode(
            data,
            allowedKeys: [
                "storageSchema", "initialized", "barrierGeneration", "lastObservedWall",
                "ordering", "semanticHash", "restriction", "exactConstructorSiteKey",
                "siteNamespaceDigest", "siteId", "configRevision", "endpoint",
                "configExpiresAt",
            ]
        )
        try value.validate()
        return value
    }

    static func encodeRequestState(_ value: EluV1FlagRequestCacheState) throws -> Data {
        try value.validate()
        return try encode(value)
    }

    static func decodeRequestState(_ data: Data) throws -> EluV1FlagRequestCacheState {
        let value: EluV1FlagRequestCacheState = try decode(
            data,
            allowedKeys: [
                "storageSchema", "storeEpoch", "requestGeneration", "activeRequestId",
                "barrierGeneration", "activeWitnessHash", "cacheRecordId",
                "cachedWitnessHash", "flagsRevision", "evaluatedAt", "responseExpiresAt",
                "effectiveExpiresAt",
            ]
        )
        try value.validate()
        return value
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoded = try EluStateCoding.encoder().encode(value)
        let ast = try EluV1FlagJSON.parse(encoded, maximumBytes: maximumMetadataBytes)
        return try EluV1FlagJSON.canonicalData(for: ast, maximumBytes: maximumMetadataBytes)
    }

    private static func decode<Value: Decodable>(
        _ data: Data,
        allowedKeys: Set<String>
    ) throws -> Value {
        let ast = try EluV1FlagJSON.parse(data, maximumBytes: maximumMetadataBytes)
        let allowedUnits = Set(allowedKeys.map { Array($0.utf16) })
        guard case let .object(members) = ast,
              members.allSatisfy({ allowedUnits.contains($0.name) })
        else {
            throw EluV1FlagContractError.malformedCache
        }
        let canonical = try EluV1FlagJSON.canonicalData(
            for: ast,
            maximumBytes: maximumMetadataBytes
        )
        do {
            return try EluStateCoding.decoder().decode(Value.self, from: canonical)
        } catch {
            throw EluV1FlagContractError.malformedCache
        }
    }
}

struct EluV1FlagEvaluationWitness: Equatable, Sendable {
    let exactConstructorSiteKey: String
    let siteNamespaceDigest: String
    let siteId: String
    let configRevision: String
    let configIssuedAt: EluV1StoredTimestamp
    let configSemanticHash: String
    let endpoint: String
    let barrierGeneration: Int64
    let configExpiresAt: EluV1StoredTimestamp
    let anonymousId: String
    let userId: String?
    let identityRevision: Int64
    let contextRevision: Int64
    let optedOut: Bool
    let personProperties: EluV1FlagJSONValue
    let groups: EluV1FlagJSONValue
    let groupProperties: EluV1FlagJSONValue
    let versions: EluV1FlagJSONValue

    init(
        authorization: EluV1FlagAuthorizationSnapshot,
        runtime: EluRuntimeQueueSnapshot,
        versions: EluVersionContext
    ) throws {
        let identity = runtime.identity
        guard Self.validIdentifier(authorization.exactConstructorSiteKey, maximum: 512),
              Self.validIdentifier(authorization.siteNamespaceDigest, maximum: 128),
              Self.validIdentifier(authorization.siteId, maximum: 256),
              Self.validIdentifier(authorization.configRevision, maximum: 256),
              Self.validIdentifier(authorization.configSemanticHash, maximum: 128),
              Self.validIdentifier(authorization.endpoint.absoluteString, maximum: 2_048),
              Self.validIdentifier(identity.anonymousId, maximum: 256),
              identity.userId.map({ Self.validIdentifier($0, maximum: 512) }) ?? true,
              Self.safeRevision(identity.revision),
              Self.safeRevision(identity.contextRevision),
              Self.safeRevision(authorization.barrierGeneration)
        else {
            throw EluV1FlagContractError.invalidRevision
        }

        let person = try EluV1FlagJSON.fromLegacyObject(runtime.flagContext.personProperties)
        let groupPairs = try identity.groups.map { key, value in
            (key, try EluV1FlagJSON.string(value))
        }
        let groups = try EluV1FlagJSON.object(groupPairs)
        var associatedProperties: [(String, EluV1FlagJSONValue)] = []
        associatedProperties.reserveCapacity(identity.groups.count)
        for groupType in identity.groups.keys {
            guard let properties = runtime.flagContext.groupProperties[groupType] else { continue }
            associatedProperties.append(
                (groupType, try EluV1FlagJSON.fromLegacyObject(properties))
            )
        }
        let groupProperties = try EluV1FlagJSON.object(associatedProperties)
        let versionsData = try EluStateCoding.encoder().encode(versions)
        let versionsValue = try EluV1FlagJSON.parse(versionsData)
        guard case .object = versionsValue else {
            throw EluV1FlagContractError.malformedRequest
        }

        exactConstructorSiteKey = authorization.exactConstructorSiteKey
        siteNamespaceDigest = authorization.siteNamespaceDigest
        siteId = authorization.siteId
        configRevision = authorization.configRevision
        configIssuedAt = EluV1StoredTimestamp(authorization.configIssuedAt)
        configSemanticHash = authorization.configSemanticHash
        endpoint = authorization.endpoint.absoluteString
        barrierGeneration = authorization.barrierGeneration
        configExpiresAt = EluV1StoredTimestamp(authorization.configExpiresAt)
        anonymousId = identity.anonymousId
        userId = identity.userId
        identityRevision = identity.revision
        contextRevision = identity.contextRevision
        optedOut = identity.optedOut
        personProperties = person
        self.groups = groups
        self.groupProperties = groupProperties
        self.versions = versionsValue
    }

    static func safeRevision(_ value: Int64) -> Bool {
        (0 ... 9_007_199_254_740_991).contains(value)
    }

    static func validIdentifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= maximum
    }
}

struct EluV1FlagRequest: Equatable, Sendable {
    let requestId: String
    let witness: EluV1FlagEvaluationWitness
    let canonicalData: Data
    let canonicalHash: String
}

enum EluV1FlagValue: Equatable, Sendable {
    case bool(Bool)
    case string([UInt16])
    case number(Double)
    case null

    var jsonValue: EluV1FlagJSONValue {
        switch self {
        case let .bool(value): return .bool(value)
        case let .string(units): return .string(units)
        case let .number(value): return .number(value)
        case .null: return .null
        }
    }
}

struct EluV1FlagResponse: Equatable, Sendable {
    let requestId: String
    let contextRevision: Int64
    let identityRevision: Int64
    let flagsRevision: String
    let evaluatedAt: EluV1StoredTimestamp
    let expiresAt: EluV1StoredTimestamp
    let flags: [EluV1FlagJSONMember]
    let payloads: [EluV1FlagJSONMember]

    func flag(units: [UInt16]) -> EluV1FlagValue? {
        guard let value = flags.first(where: { $0.name == units })?.value else { return nil }
        switch value {
        case let .bool(value): return .bool(value)
        case let .string(value): return .string(value)
        case let .number(value): return .number(value)
        case .null: return .null
        default: return nil
        }
    }

    func payload(units: [UInt16]) -> EluV1FlagJSONValue? {
        payloads.first(where: { $0.name == units })?.value
    }
}

enum EluV1FlagLookup: Equatable, Sendable {
    case missing
    case found(value: EluV1FlagValue, payload: EluV1FlagJSONValue?)
}

struct EluV1FlagBeginToken: Equatable, Sendable {
    let storeEpoch: String
    let requestGeneration: Int64
    let barrierGeneration: Int64
    let requestId: String
    let witnessHash: String
    let activationGeneration: Int64
    let witness: EluV1FlagEvaluationWitness
    let versions: EluVersionContext
}

struct EluV1FlagBegunRequest: Equatable, Sendable {
    let token: EluV1FlagBeginToken
    let endpoint: URL
    let request: EluV1FlagRequest
}

enum EluV1FlagBeginResult: Equatable, Sendable {
    case begun(EluV1FlagBegunRequest)
    case restricted(EluV1FlagRestriction)
    case terminal
}

enum EluV1FlagCommitResult: Equatable, Sendable {
    case updated
    case stale
    case restricted(EluV1FlagRestriction)
    case terminal
}

enum EluV1FlagSendResult: Equatable, Sendable {
    case allowed
    case stale
    case restricted(EluV1FlagRestriction)
    case terminal
}

struct EluV1FlagCacheSnapshot: Equatable, Sendable {
    let witness: EluV1FlagEvaluationWitness
    let response: EluV1FlagResponse

    func lookup(units: [UInt16]) -> EluV1FlagLookup {
        guard let value = response.flag(units: units) else { return .missing }
        return .found(value: value, payload: response.payload(units: units))
    }

    func lookup(_ key: String) -> EluV1FlagLookup {
        lookup(units: Array(key.utf16))
    }
}

enum EluV1FlagCacheReadResult: Equatable, Sendable {
    case hit(EluV1FlagCacheSnapshot)
    case miss
    case restricted(EluV1FlagRestriction)
    case terminal
}

enum EluV1FlagReloadResult: Equatable, Sendable {
    case updated(EluV1FlagCacheSnapshot)
    case cached(EluV1FlagCacheSnapshot)
    case stale
    case restricted(EluV1FlagRestriction)
    case terminal
}

enum EluV1FlagCodec {
    static let schemaVersion: Int64 = 1

    static func makeRequest(
        requestId: String,
        witness: EluV1FlagEvaluationWitness
    ) throws -> EluV1FlagRequest {
        guard EluV1FlagEvaluationWitness.validIdentifier(requestId, maximum: 256) else {
            throw EluV1FlagContractError.invalidIdentifier
        }
        let identity = try EluV1FlagJSON.object([
            ("anonymousId", try EluV1FlagJSON.string(witness.anonymousId)),
            ("userId", try witness.userId.map(EluV1FlagJSON.string) ?? .null),
            ("revision", try EluV1FlagJSON.safeInteger(witness.identityRevision)),
        ])
        let root = try EluV1FlagJSON.object([
            ("schemaVersion", .number(1)),
            ("requestId", try EluV1FlagJSON.string(requestId)),
            ("contextRevision", try EluV1FlagJSON.safeInteger(witness.contextRevision)),
            ("identity", identity),
            ("personProperties", witness.personProperties),
            ("groups", witness.groups),
            ("groupProperties", witness.groupProperties),
            ("versions", witness.versions),
        ])
        let data: Data
        do {
            data = try EluV1FlagJSON.canonicalData(
                for: root,
                maximumBytes: EluV1FlagJSON.maximumWireBytes
            )
        } catch EluV1FlagJSONError.payloadTooLarge {
            throw EluV1FlagContractError.requestTooLarge
        } catch {
            throw EluV1FlagContractError.malformedRequest
        }
        return EluV1FlagRequest(
            requestId: requestId,
            witness: witness,
            canonicalData: data,
            canonicalHash: EluV1FlagJSON.hash(data)
        )
    }

    static func decodeResponse(
        _ data: Data,
        for request: EluV1FlagRequest
    ) throws -> EluV1FlagResponse {
        let root: EluV1FlagJSONValue
        do {
            root = try EluV1FlagJSON.parse(data, maximumBytes: EluV1FlagJSON.maximumWireBytes)
        } catch EluV1FlagJSONError.payloadTooLarge {
            throw EluV1FlagContractError.responseTooLarge
        } catch {
            throw EluV1FlagContractError.malformedResponse
        }
        let members = try closedObject(
            root,
            keys: [
                "schemaVersion", "requestId", "contextRevision", "identityRevision",
                "flagsRevision", "evaluatedAt", "expiresAt", "flags", "payloads",
            ]
        )
        guard try integer(members, "schemaVersion") == schemaVersion else {
            throw EluV1FlagContractError.unsupportedSchemaVersion
        }
        let requestId = try string(members, "requestId", maximum: 256)
        let contextRevision = try revision(members, "contextRevision")
        let identityRevision = try revision(members, "identityRevision")
        guard requestId == request.requestId,
              contextRevision == request.witness.contextRevision,
              identityRevision == request.witness.identityRevision
        else {
            throw EluV1FlagContractError.echoMismatch
        }
        let flagsRevision = try string(members, "flagsRevision", maximum: 128)
        let evaluatedSource = try string(members, "evaluatedAt", maximum: 256)
        let expiresSource = try string(members, "expiresAt", maximum: 256)
        let evaluated: EluV1Timestamp
        let expires: EluV1Timestamp
        do {
            evaluated = try EluV1Timestamp(evaluatedSource)
            expires = try EluV1Timestamp(expiresSource)
        } catch {
            throw EluV1FlagContractError.invalidTimestamp
        }
        guard evaluated < expires else { throw EluV1FlagContractError.invalidTimestamp }
        let flags = try objectMembers(members, "flags")
        let payloads = try objectMembers(members, "payloads")
        guard flags.count <= 1_024, payloads.count <= 1_024 else {
            throw EluV1FlagContractError.malformedResponse
        }
        for member in flags {
            guard !member.name.isEmpty else { throw EluV1FlagContractError.invalidIdentifier }
            switch member.value {
            case .bool, .string, .number, .null: break
            default: throw EluV1FlagContractError.invalidFlagValue
            }
        }
        guard payloads.allSatisfy({ !$0.name.isEmpty }) else {
            throw EluV1FlagContractError.invalidIdentifier
        }
        return EluV1FlagResponse(
            requestId: requestId,
            contextRevision: contextRevision,
            identityRevision: identityRevision,
            flagsRevision: flagsRevision,
            evaluatedAt: EluV1StoredTimestamp(evaluated),
            expiresAt: EluV1StoredTimestamp(expires),
            flags: flags,
            payloads: payloads
        )
    }

    static func encodeCache(
        witness: EluV1FlagEvaluationWitness,
        response: EluV1FlagResponse
    ) throws -> Data {
        let root = try EluV1FlagJSON.object([
            ("schemaVersion", .number(1)),
            ("witness", try witnessValue(witness)),
            ("response", try responseValue(response)),
        ])
        do {
            return try EluV1FlagJSON.canonicalData(
                for: root,
                maximumBytes: EluV1FlagJSON.maximumCacheBytes
            )
        } catch EluV1FlagJSONError.payloadTooLarge {
            throw EluV1FlagContractError.cacheTooLarge
        } catch {
            throw EluV1FlagContractError.malformedCache
        }
    }

    static func decodeCache(
        _ data: Data
    ) throws -> (witness: EluV1FlagEvaluationWitness, response: EluV1FlagResponse) {
        if EluV1FlagJSON.declaresFutureTopLevelSchema(data) {
            throw EluV1FlagContractError.unsupportedSchemaVersion
        }
        let root: EluV1FlagJSONValue
        do {
            root = try EluV1FlagJSON.parse(data, maximumBytes: EluV1FlagJSON.maximumCacheBytes)
        } catch EluV1FlagJSONError.payloadTooLarge {
            throw EluV1FlagContractError.cacheTooLarge
        } catch {
            throw EluV1FlagContractError.malformedCache
        }
        guard case let .object(rootMembers) = root else {
            throw EluV1FlagContractError.malformedCache
        }
        guard try integer(rootMembers, "schemaVersion") == schemaVersion else {
            throw EluV1FlagContractError.unsupportedSchemaVersion
        }
        let members = try closedObject(
            root,
            keys: ["schemaVersion", "witness", "response"]
        )
        guard let witnessNode = property(members, "witness"),
              let responseNode = property(members, "response")
        else {
            throw EluV1FlagContractError.malformedCache
        }
        let witness = try decodeWitness(witnessNode)
        let response = try decodeStoredResponse(responseNode)
        return (witness, response)
    }

    static func witnessHash(_ witness: EluV1FlagEvaluationWitness) throws -> String {
        try EluV1FlagJSON.hash(witnessValue(witness))
    }

    private static func witnessValue(
        _ witness: EluV1FlagEvaluationWitness
    ) throws -> EluV1FlagJSONValue {
        try EluV1FlagJSON.object([
            ("exactConstructorSiteKey", try EluV1FlagJSON.string(witness.exactConstructorSiteKey)),
            ("siteNamespaceDigest", try EluV1FlagJSON.string(witness.siteNamespaceDigest)),
            ("siteId", try EluV1FlagJSON.string(witness.siteId)),
            ("configRevision", try EluV1FlagJSON.string(witness.configRevision)),
            ("configIssuedAt", try timestampValue(witness.configIssuedAt)),
            ("configSemanticHash", try EluV1FlagJSON.string(witness.configSemanticHash)),
            ("endpoint", try EluV1FlagJSON.string(witness.endpoint)),
            ("barrierGeneration", try EluV1FlagJSON.safeInteger(witness.barrierGeneration)),
            ("configExpiresAt", try timestampValue(witness.configExpiresAt)),
            ("anonymousId", try EluV1FlagJSON.string(witness.anonymousId)),
            ("userId", try witness.userId.map(EluV1FlagJSON.string) ?? .null),
            ("identityRevision", try EluV1FlagJSON.safeInteger(witness.identityRevision)),
            ("contextRevision", try EluV1FlagJSON.safeInteger(witness.contextRevision)),
            ("optedOut", .bool(witness.optedOut)),
            ("personProperties", witness.personProperties),
            ("groups", witness.groups),
            ("groupProperties", witness.groupProperties),
            ("versions", witness.versions),
        ])
    }

    private static func timestampValue(
        _ timestamp: EluV1StoredTimestamp
    ) throws -> EluV1FlagJSONValue {
        try EluV1FlagJSON.object([
            ("source", try EluV1FlagJSON.string(timestamp.source)),
            ("day", try EluV1FlagJSON.safeInteger(timestamp.day)),
            ("secondOfDay", try EluV1FlagJSON.safeInteger(timestamp.secondOfDay)),
            ("isLeapSecond", .bool(timestamp.isLeapSecond)),
            ("fractionalDigits", try EluV1FlagJSON.string(timestamp.fractionalDigits)),
        ])
    }

    private static func responseValue(
        _ response: EluV1FlagResponse
    ) throws -> EluV1FlagJSONValue {
        try EluV1FlagJSON.object([
            ("schemaVersion", .number(1)),
            ("requestId", try EluV1FlagJSON.string(response.requestId)),
            ("contextRevision", try EluV1FlagJSON.safeInteger(response.contextRevision)),
            ("identityRevision", try EluV1FlagJSON.safeInteger(response.identityRevision)),
            ("flagsRevision", try EluV1FlagJSON.string(response.flagsRevision)),
            ("evaluatedAt", try timestampValue(response.evaluatedAt)),
            ("expiresAt", try timestampValue(response.expiresAt)),
            ("flags", .object(response.flags)),
            ("payloads", .object(response.payloads)),
        ])
    }

    private static func decodeWitness(
        _ value: EluV1FlagJSONValue
    ) throws -> EluV1FlagEvaluationWitness {
        let members = try closedObject(
            value,
            keys: [
                "exactConstructorSiteKey", "siteNamespaceDigest", "siteId", "configRevision",
                "configIssuedAt", "configSemanticHash", "endpoint",
                "barrierGeneration", "configExpiresAt", "anonymousId", "userId",
                "identityRevision", "contextRevision", "optedOut", "personProperties",
                "groups", "groupProperties", "versions",
            ]
        )
        let userNode = property(members, "userId")
        let userId: String?
        if userNode == .null {
            userId = nil
        } else {
            userId = try string(members, "userId", maximum: 512)
        }
        guard let optedNode = property(members, "optedOut"),
              case let .bool(optedOut) = optedNode,
              let person = property(members, "personProperties"), case .object = person,
              let groups = property(members, "groups"), case .object = groups,
              let groupProperties = property(members, "groupProperties"), case .object = groupProperties,
              let versions = property(members, "versions"), case .object = versions,
              let issuedNode = property(members, "configIssuedAt"),
              let expiresNode = property(members, "configExpiresAt")
        else {
            throw EluV1FlagContractError.malformedCache
        }
        return EluV1FlagEvaluationWitness(
            exactConstructorSiteKey: try string(members, "exactConstructorSiteKey", maximum: 512),
            siteNamespaceDigest: try string(members, "siteNamespaceDigest", maximum: 128),
            siteId: try string(members, "siteId", maximum: 256),
            configRevision: try string(members, "configRevision", maximum: 256),
            configIssuedAt: try decodeTimestamp(issuedNode),
            configSemanticHash: try string(members, "configSemanticHash", maximum: 128),
            endpoint: try string(members, "endpoint", maximum: 2_048),
            barrierGeneration: try revision(members, "barrierGeneration"),
            configExpiresAt: try decodeTimestamp(expiresNode),
            anonymousId: try string(members, "anonymousId", maximum: 256),
            userId: userId,
            identityRevision: try revision(members, "identityRevision"),
            contextRevision: try revision(members, "contextRevision"),
            optedOut: optedOut,
            personProperties: person,
            groups: groups,
            groupProperties: groupProperties,
            versions: versions
        )
    }

    private static func decodeStoredResponse(
        _ value: EluV1FlagJSONValue
    ) throws -> EluV1FlagResponse {
        let members = try closedObject(
            value,
            keys: [
                "schemaVersion", "requestId", "contextRevision", "identityRevision",
                "flagsRevision", "evaluatedAt", "expiresAt", "flags", "payloads",
            ]
        )
        guard try integer(members, "schemaVersion") == 1,
              let evaluatedNode = property(members, "evaluatedAt"),
              let expiresNode = property(members, "expiresAt")
        else {
            throw EluV1FlagContractError.malformedCache
        }
        let flags = try objectMembers(members, "flags")
        for member in flags {
            guard !member.name.isEmpty else { throw EluV1FlagContractError.malformedCache }
            switch member.value {
            case .bool, .string, .number, .null: break
            default: throw EluV1FlagContractError.malformedCache
            }
        }
        let payloads = try objectMembers(members, "payloads")
        guard payloads.allSatisfy({ !$0.name.isEmpty }) else {
            throw EluV1FlagContractError.malformedCache
        }
        let response = EluV1FlagResponse(
            requestId: try string(members, "requestId", maximum: 256),
            contextRevision: try revision(members, "contextRevision"),
            identityRevision: try revision(members, "identityRevision"),
            flagsRevision: try string(members, "flagsRevision", maximum: 128),
            evaluatedAt: try decodeTimestamp(evaluatedNode),
            expiresAt: try decodeTimestamp(expiresNode),
            flags: flags,
            payloads: payloads
        )
        guard try response.evaluatedAt.validated() < response.expiresAt.validated() else {
            throw EluV1FlagContractError.malformedCache
        }
        return response
    }

    private static func decodeTimestamp(
        _ value: EluV1FlagJSONValue
    ) throws -> EluV1StoredTimestamp {
        let members = try closedObject(
            value,
            keys: ["source", "day", "secondOfDay", "isLeapSecond", "fractionalDigits"]
        )
        guard let leapNode = property(members, "isLeapSecond"),
              case let .bool(isLeapSecond) = leapNode
        else {
            throw EluV1FlagContractError.invalidTimestamp
        }
        let timestamp = EluV1StoredTimestamp(
            source: try string(members, "source", maximum: 256),
            day: try integer(members, "day"),
            secondOfDay: try integer(members, "secondOfDay"),
            isLeapSecond: isLeapSecond,
            fractionalDigits: try stringAllowEmpty(members, "fractionalDigits", maximum: 1_024)
        )
        _ = try timestamp.validated()
        return timestamp
    }

    private static func closedObject(
        _ value: EluV1FlagJSONValue,
        keys: Set<String>
    ) throws -> [EluV1FlagJSONMember] {
        let expectedUnits = Set(keys.map { Array($0.utf16) })
        guard case let .object(members) = value,
              members.count == keys.count,
              Set(members.map(\.name)) == expectedUnits
        else {
            throw EluV1FlagContractError.malformedResponse
        }
        return members
    }

    private static func property(
        _ members: [EluV1FlagJSONMember],
        _ name: String
    ) -> EluV1FlagJSONValue? {
        let units = Array(name.utf16)
        return members.first(where: { $0.name == units })?.value
    }

    private static func integer(
        _ members: [EluV1FlagJSONMember],
        _ name: String
    ) throws -> Int64 {
        guard let result = property(members, name)?.safeIntegerValue else {
            throw EluV1FlagContractError.invalidRevision
        }
        return result
    }

    private static func revision(
        _ members: [EluV1FlagJSONMember],
        _ name: String
    ) throws -> Int64 {
        let result = try integer(members, name)
        guard EluV1FlagEvaluationWitness.safeRevision(result) else {
            throw EluV1FlagContractError.invalidRevision
        }
        return result
    }

    private static func string(
        _ members: [EluV1FlagJSONMember],
        _ name: String,
        maximum: Int
    ) throws -> String {
        let result = try stringAllowEmpty(members, name, maximum: maximum)
        guard !result.isEmpty else { throw EluV1FlagContractError.invalidIdentifier }
        return result
    }

    private static func stringAllowEmpty(
        _ members: [EluV1FlagJSONMember],
        _ name: String,
        maximum: Int
    ) throws -> String {
        guard let units = property(members, name)?.stringUnits else {
            throw EluV1FlagContractError.malformedResponse
        }
        let result = String(decoding: units, as: UTF16.self)
        guard result.unicodeScalars.count <= maximum else {
            throw EluV1FlagContractError.invalidIdentifier
        }
        return result
    }

    private static func objectMembers(
        _ members: [EluV1FlagJSONMember],
        _ name: String
    ) throws -> [EluV1FlagJSONMember] {
        guard let value = property(members, name), case let .object(result) = value else {
            throw EluV1FlagContractError.malformedResponse
        }
        return result
    }
}

private extension EluV1FlagEvaluationWitness {
    init(
        exactConstructorSiteKey: String,
        siteNamespaceDigest: String,
        siteId: String,
        configRevision: String,
        configIssuedAt: EluV1StoredTimestamp,
        configSemanticHash: String,
        endpoint: String,
        barrierGeneration: Int64,
        configExpiresAt: EluV1StoredTimestamp,
        anonymousId: String,
        userId: String?,
        identityRevision: Int64,
        contextRevision: Int64,
        optedOut: Bool,
        personProperties: EluV1FlagJSONValue,
        groups: EluV1FlagJSONValue,
        groupProperties: EluV1FlagJSONValue,
        versions: EluV1FlagJSONValue
    ) {
        self.exactConstructorSiteKey = exactConstructorSiteKey
        self.siteNamespaceDigest = siteNamespaceDigest
        self.siteId = siteId
        self.configRevision = configRevision
        self.configIssuedAt = configIssuedAt
        self.configSemanticHash = configSemanticHash
        self.endpoint = endpoint
        self.barrierGeneration = barrierGeneration
        self.configExpiresAt = configExpiresAt
        self.anonymousId = anonymousId
        self.userId = userId
        self.identityRevision = identityRevision
        self.contextRevision = contextRevision
        self.optedOut = optedOut
        self.personProperties = personProperties
        self.groups = groups
        self.groupProperties = groupProperties
        self.versions = versions
    }
}

private extension EluV1StoredTimestamp {
    init(
        source: String,
        day: Int64,
        secondOfDay: Int64,
        isLeapSecond: Bool,
        fractionalDigits: String
    ) {
        self.source = source
        self.day = day
        self.secondOfDay = secondOfDay
        self.isLeapSecond = isLeapSecond
        self.fractionalDigits = fractionalDigits
    }
}
