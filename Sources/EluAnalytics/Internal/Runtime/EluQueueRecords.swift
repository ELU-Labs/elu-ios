import Foundation

enum EluQueueRecordValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion
    case invalidField(String)
    case malformedPayload
}

enum EluQueueRecordKind: String, Codable, Equatable, Sendable {
    case event
    case mutation
}

enum EluEventKind: String, Codable, Equatable, Sendable {
    case capture
    case screen
    case exception
    case diagnostic
}

struct EluVersionComponent: Codable, Equatable, Sendable {
    var name: String
    var version: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case version
    }

    init(name: String, version: String) throws {
        self.name = name
        self.version = version
        try validate()
    }

    init(from decoder: Decoder) throws {
        try EluQueueRecordCoding.requireAll(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
    }

    private func validate() throws {
        guard EluQueueRecordCoding.valid(name, maximumLength: 128),
              EluQueueRecordCoding.valid(version, maximumLength: 64)
        else {
            throw EluQueueRecordValidationError.invalidField("versionComponent")
        }
    }
}

struct EluVersionContext: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let contractVersion = "1.0.0"

    var schemaVersion: Int
    var contractVersion: String
    var platform: String
    var runtime: EluVersionComponent
    var facade: EluVersionComponent
    var build: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case contractVersion
        case platform
        case runtime
        case facade
        case build
    }

    private static let requiredKeys: Set<CodingKeys> = [
        .schemaVersion,
        .contractVersion,
        .platform,
        .runtime,
        .facade,
    ]

    init(
        schemaVersion: Int = Self.schemaVersion,
        contractVersion: String = Self.contractVersion,
        platform: String = "ios",
        runtime: EluVersionComponent,
        facade: EluVersionComponent,
        build: String? = nil
    ) throws {
        self.schemaVersion = schemaVersion
        self.contractVersion = contractVersion
        self.platform = platform
        self.runtime = runtime
        self.facade = facade
        self.build = build
        try validate()
    }

    init(from decoder: Decoder) throws {
        try EluQueueRecordCoding.require(
            CodingKeys.self,
            keys: Self.requiredKeys,
            from: decoder
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        contractVersion = try container.decode(String.self, forKey: .contractVersion)
        platform = try container.decode(String.self, forKey: .platform)
        runtime = try container.decode(EluVersionComponent.self, forKey: .runtime)
        facade = try container.decode(EluVersionComponent.self, forKey: .facade)
        if container.contains(.build) {
            guard try !container.decodeNil(forKey: .build) else {
                throw EluQueueRecordValidationError.invalidField("versions.build")
            }
            build = try container.decode(String.self, forKey: .build)
        } else {
            build = nil
        }
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(contractVersion, forKey: .contractVersion)
        try container.encode(platform, forKey: .platform)
        try container.encode(runtime, forKey: .runtime)
        try container.encode(facade, forKey: .facade)
        try container.encodeIfPresent(build, forKey: .build)
    }

    private func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw EluQueueRecordValidationError.unsupportedSchemaVersion
        }
        guard contractVersion == Self.contractVersion,
              platform == "ios",
              runtime.name.range(
                  of: #"^elu-[a-z0-9-]+$"#,
                  options: .regularExpression
              ) != nil,
              facade.name.range(
                  of: #"^[A-Za-z][A-Za-z0-9._-]+$"#,
                  options: .regularExpression
              ) != nil,
              build.map({ EluQueueRecordCoding.valid($0, maximumLength: 128) }) ?? true
        else {
            throw EluQueueRecordValidationError.invalidField("versions")
        }
    }
}

struct EluEventIdentity: Codable, Equatable, Sendable {
    var anonymousId: String
    var userId: String?
    var revision: Int64

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case anonymousId
        case userId
        case revision
    }

    init(anonymousId: String, userId: String?, revision: Int64) throws {
        self.anonymousId = anonymousId
        self.userId = userId
        self.revision = revision
        try validate()
    }

    init(from decoder: Decoder) throws {
        try EluQueueRecordCoding.requireAll(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        anonymousId = try container.decode(String.self, forKey: .anonymousId)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        revision = try container.decode(Int64.self, forKey: .revision)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(anonymousId, forKey: .anonymousId)
        if let userId {
            try container.encode(userId, forKey: .userId)
        } else {
            try container.encodeNil(forKey: .userId)
        }
        try container.encode(revision, forKey: .revision)
    }

    private func validate() throws {
        guard EluQueueRecordCoding.valid(anonymousId, maximumLength: 256),
              userId.map({ EluQueueRecordCoding.valid($0, maximumLength: 512) }) ?? true,
              revision >= 0
        else {
            throw EluQueueRecordValidationError.invalidField("event.identity")
        }
    }
}

struct EluQueuedEvent: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var eventId: String
    var streamId: String
    var sequence: Int64
    var contextRevision: Int64
    var kind: EluEventKind
    var name: String
    var occurredAt: Date
    var identity: EluEventIdentity
    var sessionId: String
    var properties: [String: EluJSONValue]
    var groups: [String: String]
    var versions: EluVersionContext

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case eventId
        case streamId
        case sequence
        case contextRevision
        case kind
        case name
        case occurredAt
        case identity
        case sessionId
        case properties
        case groups
        case versions
    }

    init(
        schemaVersion: Int = Self.schemaVersion,
        eventId: String,
        streamId: String,
        sequence: Int64,
        contextRevision: Int64,
        kind: EluEventKind,
        name: String,
        occurredAt: Date,
        identity: EluEventIdentity,
        sessionId: String,
        properties: [String: EluJSONValue],
        groups: [String: String],
        versions: EluVersionContext
    ) throws {
        self.schemaVersion = schemaVersion
        self.eventId = eventId
        self.streamId = streamId
        self.sequence = sequence
        self.contextRevision = contextRevision
        self.kind = kind
        self.name = name
        self.occurredAt = occurredAt
        self.identity = identity
        self.sessionId = sessionId
        self.properties = properties
        self.groups = groups
        self.versions = versions
        try validate()
    }

    init(from decoder: Decoder) throws {
        try EluQueueRecordCoding.requireAll(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        eventId = try container.decode(String.self, forKey: .eventId)
        streamId = try container.decode(String.self, forKey: .streamId)
        sequence = try container.decode(Int64.self, forKey: .sequence)
        contextRevision = try container.decode(Int64.self, forKey: .contextRevision)
        kind = try container.decode(EluEventKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        identity = try container.decode(EluEventIdentity.self, forKey: .identity)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        properties = try container.decode([String: EluJSONValue].self, forKey: .properties)
        groups = try container.decode([String: String].self, forKey: .groups)
        versions = try container.decode(EluVersionContext.self, forKey: .versions)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(eventId, forKey: .eventId)
        try container.encode(streamId, forKey: .streamId)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(contextRevision, forKey: .contextRevision)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(identity, forKey: .identity)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(properties, forKey: .properties)
        try container.encode(groups, forKey: .groups)
        try container.encode(versions, forKey: .versions)
    }

    func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw EluQueueRecordValidationError.unsupportedSchemaVersion
        }
        guard EluQueueRecordCoding.valid(eventId, maximumLength: 256),
              EluQueueRecordCoding.valid(streamId, maximumLength: 256),
              sequence >= 0,
              contextRevision >= 0,
              EluQueueRecordCoding.valid(name, maximumLength: 512),
              occurredAt.timeIntervalSinceReferenceDate.isFinite,
              EluQueueRecordCoding.valid(sessionId, maximumLength: 256),
              groups.count <= EluIdentityState.maximumGroups
        else {
            throw EluQueueRecordValidationError.invalidField("event")
        }
        try EluQueueRecordCoding.validateProperties(properties)
        for (type, key) in groups {
            guard EluQueueRecordCoding.valid(type, maximumLength: 256),
                  EluQueueRecordCoding.valid(key, maximumLength: 512)
            else {
                throw EluQueueRecordValidationError.invalidField("event.groups")
            }
        }
    }
}

struct EluMutationSubject: Codable, Equatable, Sendable {
    var anonymousId: String
    var userId: String?
    var identityRevision: Int64

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case anonymousId
        case userId
        case identityRevision
    }

    init(anonymousId: String, userId: String?, identityRevision: Int64) throws {
        self.anonymousId = anonymousId
        self.userId = userId
        self.identityRevision = identityRevision
        try validate()
    }

    init(from decoder: Decoder) throws {
        try EluQueueRecordCoding.requireAll(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        anonymousId = try container.decode(String.self, forKey: .anonymousId)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        identityRevision = try container.decode(Int64.self, forKey: .identityRevision)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(anonymousId, forKey: .anonymousId)
        if let userId {
            try container.encode(userId, forKey: .userId)
        } else {
            try container.encodeNil(forKey: .userId)
        }
        try container.encode(identityRevision, forKey: .identityRevision)
    }

    private func validate() throws {
        guard EluQueueRecordCoding.valid(anonymousId, maximumLength: 256),
              userId.map({ EluQueueRecordCoding.valid($0, maximumLength: 512) }) ?? true,
              identityRevision >= 0
        else {
            throw EluQueueRecordValidationError.invalidField("mutation.subject")
        }
    }
}

enum EluMutationChange: Codable, Equatable, Sendable {
    case identify(userId: String, set: [String: EluJSONValue], setOnce: [String: EluJSONValue])
    case linkAlias(aliasId: String, canonicalId: String)
    case setPersonProperties(
        set: [String: EluJSONValue],
        setOnce: [String: EluJSONValue],
        unset: [String]
    )
    case associateGroup(groupType: String, groupKey: String)
    case setGroupProperties(
        groupType: String,
        groupKey: String,
        set: [String: EluJSONValue],
        setOnce: [String: EluJSONValue],
        unset: [String]
    )

    private enum ChangeType: String, Codable {
        case identify
        case linkAlias
        case setPersonProperties
        case associateGroup
        case setGroupProperties
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case userId
        case set
        case setOnce
        case aliasId
        case canonicalId
        case unset
        case groupType
        case groupKey
    }

    init(from decoder: Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: CodingKeys.self)
        let type = try typeContainer.decode(ChangeType.self, forKey: .type)
        switch type {
        case .identify:
            try Self.require(
                [.type, .userId, .set, .setOnce],
                from: decoder
            )
            self = .identify(
                userId: try typeContainer.decode(String.self, forKey: .userId),
                set: try typeContainer.decode([String: EluJSONValue].self, forKey: .set),
                setOnce: try typeContainer.decode([String: EluJSONValue].self, forKey: .setOnce)
            )
        case .linkAlias:
            try Self.require([.type, .aliasId, .canonicalId], from: decoder)
            self = .linkAlias(
                aliasId: try typeContainer.decode(String.self, forKey: .aliasId),
                canonicalId: try typeContainer.decode(String.self, forKey: .canonicalId)
            )
        case .setPersonProperties:
            try Self.require([.type, .set, .setOnce, .unset], from: decoder)
            self = .setPersonProperties(
                set: try typeContainer.decode([String: EluJSONValue].self, forKey: .set),
                setOnce: try typeContainer.decode([String: EluJSONValue].self, forKey: .setOnce),
                unset: try typeContainer.decode([String].self, forKey: .unset)
            )
        case .associateGroup:
            try Self.require([.type, .groupType, .groupKey], from: decoder)
            self = .associateGroup(
                groupType: try typeContainer.decode(String.self, forKey: .groupType),
                groupKey: try typeContainer.decode(String.self, forKey: .groupKey)
            )
        case .setGroupProperties:
            try Self.require(
                [.type, .groupType, .groupKey, .set, .setOnce, .unset],
                from: decoder
            )
            self = .setGroupProperties(
                groupType: try typeContainer.decode(String.self, forKey: .groupType),
                groupKey: try typeContainer.decode(String.self, forKey: .groupKey),
                set: try typeContainer.decode([String: EluJSONValue].self, forKey: .set),
                setOnce: try typeContainer.decode([String: EluJSONValue].self, forKey: .setOnce),
                unset: try typeContainer.decode([String].self, forKey: .unset)
            )
        }
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .identify(userId, set, setOnce):
            try container.encode(ChangeType.identify, forKey: .type)
            try container.encode(userId, forKey: .userId)
            try container.encode(set, forKey: .set)
            try container.encode(setOnce, forKey: .setOnce)
        case let .linkAlias(aliasId, canonicalId):
            try container.encode(ChangeType.linkAlias, forKey: .type)
            try container.encode(aliasId, forKey: .aliasId)
            try container.encode(canonicalId, forKey: .canonicalId)
        case let .setPersonProperties(set, setOnce, unset):
            try container.encode(ChangeType.setPersonProperties, forKey: .type)
            try container.encode(set, forKey: .set)
            try container.encode(setOnce, forKey: .setOnce)
            try container.encode(unset, forKey: .unset)
        case let .associateGroup(groupType, groupKey):
            try container.encode(ChangeType.associateGroup, forKey: .type)
            try container.encode(groupType, forKey: .groupType)
            try container.encode(groupKey, forKey: .groupKey)
        case let .setGroupProperties(groupType, groupKey, set, setOnce, unset):
            try container.encode(ChangeType.setGroupProperties, forKey: .type)
            try container.encode(groupType, forKey: .groupType)
            try container.encode(groupKey, forKey: .groupKey)
            try container.encode(set, forKey: .set)
            try container.encode(setOnce, forKey: .setOnce)
            try container.encode(unset, forKey: .unset)
        }
    }

    func validate() throws {
        switch self {
        case let .identify(userId, set, setOnce):
            guard EluQueueRecordCoding.valid(userId, maximumLength: 512) else {
                throw EluQueueRecordValidationError.invalidField("mutation.identify.userId")
            }
            try EluQueueRecordCoding.validateProperties(set)
            try EluQueueRecordCoding.validateProperties(setOnce)
        case let .linkAlias(aliasId, canonicalId):
            guard EluQueueRecordCoding.valid(aliasId, maximumLength: 512),
                  EluQueueRecordCoding.valid(canonicalId, maximumLength: 512)
            else {
                throw EluQueueRecordValidationError.invalidField("mutation.linkAlias")
            }
        case let .setPersonProperties(set, setOnce, unset):
            try EluQueueRecordCoding.validateProperties(set)
            try EluQueueRecordCoding.validateProperties(setOnce)
            try EluQueueRecordCoding.validateUnset(unset)
        case let .associateGroup(groupType, groupKey):
            try EluQueueRecordCoding.validateGroup(type: groupType, key: groupKey)
        case let .setGroupProperties(groupType, groupKey, set, setOnce, unset):
            try EluQueueRecordCoding.validateGroup(type: groupType, key: groupKey)
            try EluQueueRecordCoding.validateProperties(set)
            try EluQueueRecordCoding.validateProperties(setOnce)
            try EluQueueRecordCoding.validateUnset(unset)
        }
    }

    private static func require(_ keys: Set<CodingKeys>, from decoder: Decoder) throws {
        try EluQueueRecordCoding.require(CodingKeys.self, keys: keys, from: decoder)
    }
}

struct EluQueuedMutation: Codable, Equatable, Sendable {
    var mutationId: String
    var sequence: Int64
    var contextRevision: Int64
    var occurredAt: Date
    var subject: EluMutationSubject
    var change: EluMutationChange

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case mutationId
        case sequence
        case contextRevision
        case occurredAt
        case subject
        case change
    }

    init(
        mutationId: String,
        sequence: Int64,
        contextRevision: Int64,
        occurredAt: Date,
        subject: EluMutationSubject,
        change: EluMutationChange
    ) throws {
        self.mutationId = mutationId
        self.sequence = sequence
        self.contextRevision = contextRevision
        self.occurredAt = occurredAt
        self.subject = subject
        self.change = change
        try validate()
    }

    init(from decoder: Decoder) throws {
        try EluQueueRecordCoding.requireAll(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mutationId = try container.decode(String.self, forKey: .mutationId)
        sequence = try container.decode(Int64.self, forKey: .sequence)
        contextRevision = try container.decode(Int64.self, forKey: .contextRevision)
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        subject = try container.decode(EluMutationSubject.self, forKey: .subject)
        change = try container.decode(EluMutationChange.self, forKey: .change)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mutationId, forKey: .mutationId)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(contextRevision, forKey: .contextRevision)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(subject, forKey: .subject)
        try container.encode(change, forKey: .change)
    }

    func validate() throws {
        guard EluQueueRecordCoding.valid(mutationId, maximumLength: 256),
              sequence >= 0,
              contextRevision >= 0,
              occurredAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw EluQueueRecordValidationError.invalidField("mutation")
        }
        try change.validate()
    }
}

struct EluEventDraft: Equatable, Sendable {
    var kind: EluEventKind
    var name: String
    var occurredAt: Date
    var expectedSessionId: String
    var properties: [String: EluJSONValue]
    var versions: EluVersionContext
}

enum EluRuntimeEventSessionUpdate: Equatable, Sendable {
    case preserve
    case replace(expectedCurrentSessionId: String?, session: EluSessionState)
}

enum EluRuntimeMutationTransition: Equatable, Sendable {
    case identify(
        userId: String,
        set: [String: EluJSONValue],
        setOnce: [String: EluJSONValue]
    )
    case linkAlias(aliasId: String)
    case setPersonProperties(
        set: [String: EluJSONValue],
        setOnce: [String: EluJSONValue],
        unset: [String]
    )
    case associateGroup(groupType: String, groupKey: String)
    case setGroupProperties(
        groupType: String,
        groupKey: String,
        set: [String: EluJSONValue],
        setOnce: [String: EluJSONValue],
        unset: [String]
    )
    case group(
        groupType: String,
        groupKey: String,
        set: [String: EluJSONValue],
        setOnce: [String: EluJSONValue],
        unset: [String]
    )
}

enum EluQueuedRecord: Equatable, Sendable {
    case event(EluQueuedEvent)
    case mutation(EluQueuedMutation, versions: EluVersionContext)

    var sequence: Int64 {
        switch self {
        case let .event(event): event.sequence
        case let .mutation(mutation, _): mutation.sequence
        }
    }

    var kind: EluQueueRecordKind {
        switch self {
        case .event: .event
        case .mutation: .mutation
        }
    }

    var recordId: String {
        switch self {
        case let .event(event): event.eventId
        case let .mutation(mutation, _): mutation.mutationId
        }
    }

    var occurredAt: Date {
        switch self {
        case let .event(event): event.occurredAt
        case let .mutation(mutation, _): mutation.occurredAt
        }
    }

    var versions: EluVersionContext {
        switch self {
        case let .event(event): event.versions
        case let .mutation(_, versions): versions
        }
    }
}

struct EluQueueAcknowledgementReference: Equatable, Sendable {
    var streamId: String
    var sequence: Int64
    var kind: EluQueueRecordKind
    var recordId: String
}

enum EluQueueRecordCodec {
    static func encode(_ record: EluQueuedRecord) throws -> Data {
        let encoder = EluStateCoding.encoder()
        switch record {
        case let .event(event):
            try event.validate()
            return try encoder.encode(event)
        case let .mutation(mutation, _):
            try mutation.validate()
            return try encoder.encode(mutation)
        }
    }

    static func decode(
        kind: EluQueueRecordKind,
        data: Data,
        versions: EluVersionContext
    ) throws -> EluQueuedRecord {
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else {
            throw EluQueueRecordValidationError.malformedPayload
        }
        do {
            switch kind {
            case .event:
                let event = try EluStateCoding.decoder().decode(EluQueuedEvent.self, from: data)
                guard event.versions == versions else {
                    throw EluQueueRecordValidationError.invalidField("event.versions")
                }
                return .event(event)
            case .mutation:
                return .mutation(
                    try EluStateCoding.decoder().decode(EluQueuedMutation.self, from: data),
                    versions: versions
                )
            }
        } catch let error as EluQueueRecordValidationError {
            throw error
        } catch {
            throw EluQueueRecordValidationError.malformedPayload
        }
    }
}

enum EluQueueBatchCodec {
    static func encodeRecord(_ record: EluQueuedRecord) throws -> Data {
        try EluStateCoding.encoder().encode(EluOutboundBatchRecord(record: record))
    }

    static func encodeBatch(
        requestId: String,
        streamId: String,
        sentAt: Date,
        versions: EluVersionContext,
        records: [EluQueuedRecord]
    ) throws -> Data {
        guard EluQueueRecordCoding.valid(requestId, maximumLength: 256),
              EluQueueRecordCoding.valid(streamId, maximumLength: 256),
              sentAt.timeIntervalSinceReferenceDate.isFinite,
              (1 ... 1_000).contains(records.count),
              records.allSatisfy({ $0.versions == versions }),
              records.allSatisfy({ record in
                  if case let .event(event) = record {
                      return event.streamId == streamId
                  }
                  return true
              })
        else {
            throw EluQueueRecordValidationError.invalidField("batch")
        }
        return try EluStateCoding.encoder().encode(
            EluOutboundBatchEnvelope(
                requestId: requestId,
                streamId: streamId,
                sentAt: sentAt,
                versions: versions,
                records: records.map { EluOutboundBatchRecord(record: $0) }
            )
        )
    }
}

private struct EluOutboundBatchEnvelope: Encodable {
    let schemaVersion = 1
    var requestId: String
    var streamId: String
    var sentAt: Date
    var versions: EluVersionContext
    var records: [EluOutboundBatchRecord]
}

private enum EluOutboundBatchRecord: Encodable {
    case event(EluQueuedEvent)
    case mutation(EluQueuedMutation)

    private enum CodingKeys: String, CodingKey {
        case kind
        case event
        case mutation
    }

    init(record: EluQueuedRecord) {
        switch record {
        case let .event(event):
            self = .event(event)
        case let .mutation(mutation, _):
            self = .mutation(mutation)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .event(event):
            try container.encode(EluQueueRecordKind.event, forKey: .kind)
            try container.encode(event, forKey: .event)
        case let .mutation(mutation):
            try container.encode(EluQueueRecordKind.mutation, forKey: .kind)
            try container.encode(mutation, forKey: .mutation)
        }
    }
}

private enum EluQueueRecordCoding {
    static func requireAll<Key: CodingKey & CaseIterable & Hashable>(
        _ keyType: Key.Type,
        from decoder: Decoder
    ) throws where Key.AllCases: Collection {
        try require(keyType, keys: Set(keyType.allCases), from: decoder)
    }

    static func require<Key: CodingKey & CaseIterable & Hashable>(
        _ keyType: Key.Type,
        keys: Set<Key>,
        from decoder: Decoder
    ) throws where Key.AllCases: Collection {
        let container = try decoder.container(keyedBy: EluDynamicCodingKey.self)
        let allowed = Set(keyType.allCases.map(\.stringValue))
        let required = Set(keys.map(\.stringValue))
        let actual = Set(container.allKeys.map(\.stringValue))
        guard actual.isSubset(of: allowed), required.isSubset(of: actual) else {
            throw EluQueueRecordValidationError.malformedPayload
        }
    }

    static func valid(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= maximumLength
    }

    static func validateProperties(_ properties: [String: EluJSONValue]) throws {
        guard properties.count <= 1_024 else {
            throw EluQueueRecordValidationError.invalidField("properties")
        }
        for (key, value) in properties {
            guard valid(key, maximumLength: 256) else {
                throw EluQueueRecordValidationError.invalidField("propertyKey")
            }
            do {
                try value.validate()
            } catch {
                throw EluQueueRecordValidationError.invalidField("propertyValue")
            }
        }
    }

    static func validateUnset(_ values: [String]) throws {
        guard values.count <= 256,
              Set(values).count == values.count,
              values.allSatisfy({ valid($0, maximumLength: 512) })
        else {
            throw EluQueueRecordValidationError.invalidField("unset")
        }
    }

    static func validateGroup(type: String, key: String) throws {
        guard valid(type, maximumLength: 256), valid(key, maximumLength: 512) else {
            throw EluQueueRecordValidationError.invalidField("group")
        }
    }
}
