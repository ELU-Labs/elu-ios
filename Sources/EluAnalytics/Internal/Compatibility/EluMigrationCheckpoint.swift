import Foundation

/// Persisted progress of one migration. `unseen` is the absence of a
/// checkpoint document and is never written; every stored document carries
/// one of the later phases, and a phase only ever moves forward.
enum EluMigrationPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case unseen
    case importing
    case committed
    case verified
    case complete
}

enum EluMigrationCheckpointError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion
    case invalidPhase
    case invalidIdentifier(String)
    case invalidContext
    case invalidStream
    case invalidQueuePrefix
    case invalidTimestamp
}

private func eluMigrationRequireAll<Key: CodingKey & CaseIterable>(
    _ keyType: Key.Type,
    from decoder: Decoder
) throws where Key.AllCases: Collection {
    try EluClosedRecord.requireOnly(keyType, from: decoder)
    let container = try decoder.container(keyedBy: keyType)
    for key in keyType.allCases where !container.contains(key) {
        throw DecodingError.keyNotFound(
            key,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing required key")
        )
    }
}

/// Where the imported state came from, kept with the checkpoint so a later
/// reader can tell which layout revision produced it.
struct EluMigrationSourceRecord: Codable, Equatable, Sendable {
    var sourceSchema: String
    var schemaVersion: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sourceSchema
        case schemaVersion
    }

    init(sourceSchema: String, schemaVersion: Int) throws {
        self.sourceSchema = sourceSchema
        self.schemaVersion = schemaVersion
        try validate()
    }

    init(descriptor: EluLegacyStateSourceDescriptor) throws {
        try self.init(
            sourceSchema: descriptor.sourceSchema,
            schemaVersion: descriptor.schemaVersion
        )
    }

    init(from decoder: Decoder) throws {
        try eluMigrationRequireAll(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceSchema = try container.decode(String.self, forKey: .sourceSchema)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceSchema, forKey: .sourceSchema)
        try container.encode(schemaVersion, forKey: .schemaVersion)
    }

    func validate() throws {
        guard EluIdentityState.valid(sourceSchema, maximumLength: 128) else {
            throw EluMigrationCheckpointError.invalidIdentifier("sourceSchema")
        }
        guard schemaVersion >= 1 else {
            throw EluMigrationCheckpointError.unsupportedSchemaVersion
        }
    }
}

struct EluMigrationIdentitySnapshot: Codable, Equatable, Sendable {
    var anonymousId: String
    var userId: String?
    var optedOut: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case anonymousId
        case userId
        case optedOut
    }

    init(anonymousId: String, userId: String?, optedOut: Bool) throws {
        self.anonymousId = anonymousId
        self.userId = userId
        self.optedOut = optedOut
        try validate()
    }

    init(from decoder: Decoder) throws {
        try eluMigrationRequireAll(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        anonymousId = try container.decode(String.self, forKey: .anonymousId)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        optedOut = try container.decode(Bool.self, forKey: .optedOut)
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
        try container.encode(optedOut, forKey: .optedOut)
    }

    func validate() throws {
        guard EluIdentityState.valid(anonymousId, maximumLength: 256) else {
            throw EluMigrationCheckpointError.invalidIdentifier("anonymousId")
        }
        if let userId, !EluIdentityState.valid(userId, maximumLength: 512) {
            throw EluMigrationCheckpointError.invalidIdentifier("userId")
        }
    }
}

struct EluMigrationContextSnapshot: Codable, Equatable, Sendable {
    var superProperties: [String: EluJSONValue]
    var groups: [String: String]
    var flagPersonProperties: [String: EluJSONValue]
    var flagGroupProperties: [String: [String: EluJSONValue]]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case superProperties
        case groups
        case flagPersonProperties
        case flagGroupProperties
    }

    init(
        superProperties: [String: EluJSONValue] = [:],
        groups: [String: String] = [:],
        flagPersonProperties: [String: EluJSONValue] = [:],
        flagGroupProperties: [String: [String: EluJSONValue]] = [:]
    ) throws {
        self.superProperties = superProperties
        self.groups = groups
        self.flagPersonProperties = flagPersonProperties
        self.flagGroupProperties = flagGroupProperties
        try validate()
    }

    init(from decoder: Decoder) throws {
        try eluMigrationRequireAll(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        superProperties = try container.decode([String: EluJSONValue].self, forKey: .superProperties)
        groups = try container.decode([String: String].self, forKey: .groups)
        flagPersonProperties = try container.decode(
            [String: EluJSONValue].self,
            forKey: .flagPersonProperties
        )
        flagGroupProperties = try container.decode(
            [String: [String: EluJSONValue]].self,
            forKey: .flagGroupProperties
        )
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(superProperties, forKey: .superProperties)
        try container.encode(groups, forKey: .groups)
        try container.encode(flagPersonProperties, forKey: .flagPersonProperties)
        try container.encode(flagGroupProperties, forKey: .flagGroupProperties)
    }

    func validate() throws {
        guard superProperties.count <= EluIdentityState.maximumSuperProperties else {
            throw EluMigrationCheckpointError.invalidContext
        }
        try Self.validateProperties(superProperties)

        guard groups.count <= EluIdentityState.maximumGroups else {
            throw EluMigrationCheckpointError.invalidContext
        }
        for (type, key) in groups {
            guard EluIdentityState.valid(type, maximumLength: 256),
                  EluIdentityState.valid(key, maximumLength: 512)
            else {
                throw EluMigrationCheckpointError.invalidContext
            }
        }

        guard flagPersonProperties.count <= EluPersistedFlagContext.maximumProperties else {
            throw EluMigrationCheckpointError.invalidContext
        }
        try Self.validateProperties(flagPersonProperties)

        guard flagGroupProperties.count <= EluPersistedFlagContext.maximumGroups else {
            throw EluMigrationCheckpointError.invalidContext
        }
        for (type, properties) in flagGroupProperties {
            guard EluIdentityState.valid(type, maximumLength: 256),
                  properties.count <= EluPersistedFlagContext.maximumProperties
            else {
                throw EluMigrationCheckpointError.invalidContext
            }
            try Self.validateProperties(properties)
        }
    }

    private static func validateProperties(_ properties: [String: EluJSONValue]) throws {
        for (key, value) in properties {
            guard EluIdentityState.valid(key, maximumLength: 256) else {
                throw EluMigrationCheckpointError.invalidContext
            }
            do {
                try value.validate()
            } catch {
                throw EluMigrationCheckpointError.invalidContext
            }
        }
    }
}

struct EluMigrationStreamSnapshot: Codable, Equatable, Sendable {
    var streamId: String
    var nextSequence: Int64

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case streamId
        case nextSequence
    }

    init(streamId: String, nextSequence: Int64) throws {
        self.streamId = streamId
        self.nextSequence = nextSequence
        try validate()
    }

    init(from decoder: Decoder) throws {
        try eluMigrationRequireAll(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamId = try container.decode(String.self, forKey: .streamId)
        nextSequence = try container.decode(Int64.self, forKey: .nextSequence)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(streamId, forKey: .streamId)
        try container.encode(nextSequence, forKey: .nextSequence)
    }

    func validate() throws {
        guard EluIdentityState.valid(streamId, maximumLength: 256), nextSequence >= 0 else {
            throw EluMigrationCheckpointError.invalidStream
        }
    }
}

struct EluMigrationQueuedRecord: Codable, Equatable, Sendable {
    static let maximumPayloadBytes = 64 * 1_024

    var position: Int64
    var payload: Data

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case position
        case payload
    }

    init(position: Int64, payload: Data) throws {
        self.position = position
        self.payload = payload
        try validate()
    }

    init(from decoder: Decoder) throws {
        try eluMigrationRequireAll(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decode(Int64.self, forKey: .position)
        payload = try container.decode(Data.self, forKey: .payload)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(position, forKey: .position)
        try container.encode(payload, forKey: .payload)
    }

    func validate() throws {
        guard position >= 0, !payload.isEmpty, payload.count <= Self.maximumPayloadBytes else {
            throw EluMigrationCheckpointError.invalidQueuePrefix
        }
    }
}

/// The bounded head of the former delivery queue captured with the identity
/// it belongs to. `truncated` records that the source held more than the
/// caps allowed; those records remain in the source untouched.
struct EluMigrationQueuePrefix: Codable, Equatable, Sendable {
    static let maximumRecords = 1_000
    static let maximumBytes = 256 * 1_024

    var records: [EluMigrationQueuedRecord]
    var truncated: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case records
        case truncated
    }

    init(records: [EluMigrationQueuedRecord], truncated: Bool) throws {
        self.records = records
        self.truncated = truncated
        try validate()
    }

    init(from decoder: Decoder) throws {
        try eluMigrationRequireAll(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decode([EluMigrationQueuedRecord].self, forKey: .records)
        truncated = try container.decode(Bool.self, forKey: .truncated)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(records, forKey: .records)
        try container.encode(truncated, forKey: .truncated)
    }

    func validate() throws {
        guard records.count <= Self.maximumRecords else {
            throw EluMigrationCheckpointError.invalidQueuePrefix
        }
        var totalBytes = 0
        var previousPosition: Int64?
        for record in records {
            try record.validate()
            if let previousPosition, record.position <= previousPosition {
                throw EluMigrationCheckpointError.invalidQueuePrefix
            }
            previousPosition = record.position
            totalBytes += record.payload.count
        }
        guard totalBytes <= Self.maximumBytes else {
            throw EluMigrationCheckpointError.invalidQueuePrefix
        }
    }
}

/// Everything the coordinator read from the source in its single pass. Once
/// persisted, this is the only input later phases use; the source is never
/// consulted again for the same migration.
struct EluMigrationSnapshot: Codable, Equatable, Sendable {
    var identity: EluMigrationIdentitySnapshot
    var context: EluMigrationContextSnapshot
    var stream: EluMigrationStreamSnapshot
    var queuePrefix: EluMigrationQueuePrefix

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case identity
        case context
        case stream
        case queuePrefix
    }

    init(
        identity: EluMigrationIdentitySnapshot,
        context: EluMigrationContextSnapshot,
        stream: EluMigrationStreamSnapshot,
        queuePrefix: EluMigrationQueuePrefix
    ) throws {
        self.identity = identity
        self.context = context
        self.stream = stream
        self.queuePrefix = queuePrefix
        try validate()
    }

    init(from decoder: Decoder) throws {
        try eluMigrationRequireAll(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(EluMigrationIdentitySnapshot.self, forKey: .identity)
        context = try container.decode(EluMigrationContextSnapshot.self, forKey: .context)
        stream = try container.decode(EluMigrationStreamSnapshot.self, forKey: .stream)
        queuePrefix = try container.decode(EluMigrationQueuePrefix.self, forKey: .queuePrefix)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identity, forKey: .identity)
        try container.encode(context, forKey: .context)
        try container.encode(stream, forKey: .stream)
        try container.encode(queuePrefix, forKey: .queuePrefix)
    }

    func validate() throws {
        try identity.validate()
        try context.validate()
        try stream.validate()
        try queuePrefix.validate()
    }
}

/// The versioned document the coordinator writes atomically at every phase
/// change. A document without a snapshot is the witness that the source held
/// no identity to carry over and is only ever written as `complete`.
struct EluMigrationCheckpoint: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var checkpointId: String
    var phase: EluMigrationPhase
    var source: EluMigrationSourceRecord
    var snapshot: EluMigrationSnapshot?
    var importedAt: Date
    var committedAt: Date?
    var verifiedAt: Date?
    var completedAt: Date?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case checkpointId
        case phase
        case source
        case snapshot
        case importedAt
        case committedAt
        case verifiedAt
        case completedAt
    }

    static let persistedKeys = Set(CodingKeys.allCases.map(\.stringValue))

    init(
        schemaVersion: Int = Self.schemaVersion,
        checkpointId: String,
        phase: EluMigrationPhase,
        source: EluMigrationSourceRecord,
        snapshot: EluMigrationSnapshot?,
        importedAt: Date,
        committedAt: Date? = nil,
        verifiedAt: Date? = nil,
        completedAt: Date? = nil
    ) throws {
        self.schemaVersion = schemaVersion
        self.checkpointId = checkpointId
        self.phase = phase
        self.source = source
        self.snapshot = snapshot
        self.importedAt = importedAt
        self.committedAt = committedAt
        self.verifiedAt = verifiedAt
        self.completedAt = completedAt
        try validate()
    }

    init(from decoder: Decoder) throws {
        try eluMigrationRequireAll(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        checkpointId = try container.decode(String.self, forKey: .checkpointId)
        phase = try container.decode(EluMigrationPhase.self, forKey: .phase)
        source = try container.decode(EluMigrationSourceRecord.self, forKey: .source)
        snapshot = try container.decodeIfPresent(EluMigrationSnapshot.self, forKey: .snapshot)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        committedAt = try container.decodeIfPresent(Date.self, forKey: .committedAt)
        verifiedAt = try container.decodeIfPresent(Date.self, forKey: .verifiedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(checkpointId, forKey: .checkpointId)
        try container.encode(phase, forKey: .phase)
        try container.encode(source, forKey: .source)
        try Self.encodeOptional(snapshot, forKey: .snapshot, into: &container)
        try container.encode(importedAt, forKey: .importedAt)
        try Self.encodeOptional(committedAt, forKey: .committedAt, into: &container)
        try Self.encodeOptional(verifiedAt, forKey: .verifiedAt, into: &container)
        try Self.encodeOptional(completedAt, forKey: .completedAt, into: &container)
    }

    private static func encodeOptional<Value: Encodable>(
        _ value: Value?,
        forKey key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }

    func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw EluMigrationCheckpointError.unsupportedSchemaVersion
        }
        guard EluIdentityState.valid(checkpointId, maximumLength: 128) else {
            throw EluMigrationCheckpointError.invalidIdentifier("checkpointId")
        }
        try source.validate()
        try snapshot?.validate()
        guard importedAt.timeIntervalSinceReferenceDate.isFinite,
              committedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              verifiedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              completedAt?.timeIntervalSinceReferenceDate.isFinite ?? true
        else {
            throw EluMigrationCheckpointError.invalidTimestamp
        }
        // Phases are stamped in the order they were reached, so the stamps
        // that are present must never move backwards.
        let stamps = [importedAt, committedAt, verifiedAt, completedAt].compactMap { $0 }
        guard zip(stamps, stamps.dropFirst()).allSatisfy({ $0 <= $1 }) else {
            throw EluMigrationCheckpointError.invalidTimestamp
        }

        let reached: [EluMigrationPhase]
        switch phase {
        case .unseen:
            throw EluMigrationCheckpointError.invalidPhase
        case .importing:
            reached = [.importing]
        case .committed:
            reached = [.importing, .committed]
        case .verified:
            reached = [.importing, .committed, .verified]
        case .complete:
            reached = [.importing, .committed, .verified, .complete]
        }
        guard (committedAt != nil) == reached.contains(.committed),
              (verifiedAt != nil) == reached.contains(.verified),
              (completedAt != nil) == reached.contains(.complete)
        else {
            throw EluMigrationCheckpointError.invalidPhase
        }
        if snapshot == nil {
            guard phase == .complete else {
                throw EluMigrationCheckpointError.invalidPhase
            }
        }
    }
}
