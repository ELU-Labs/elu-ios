import Foundation

enum EluIdentityStateError: Error, Equatable {
    case unsupportedSchemaVersion
    case invalidRevision
    case invalidIdentifier(String)
    case tooManyGroups
    case tooManySuperProperties
    case invalidPropertyKey
    case invalidSession
    case invalidMigration
    case invalidJSONNumber
    case jsonValueTooLarge
    case counterExhausted
}

enum EluSessionLifecycle: String, Codable, Sendable {
    case active
    case background
}

struct EluSessionState: Codable, Equatable, Sendable {
    static let requiredMaximumDurationSeconds = 86_400

    var id: String
    var startedAt: Date
    var lastActivityAt: Date
    var timeoutSeconds: Int
    var maximumDurationSeconds: Int
    var lifecycle: EluSessionLifecycle
    var backgroundedAt: Date?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case startedAt
        case lastActivityAt
        case timeoutSeconds
        case maximumDurationSeconds
        case lifecycle
        case backgroundedAt
    }

    init(
        id: String,
        startedAt: Date,
        lastActivityAt: Date,
        timeoutSeconds: Int,
        maximumDurationSeconds: Int = Self.requiredMaximumDurationSeconds,
        lifecycle: EluSessionLifecycle = .active,
        backgroundedAt: Date? = nil
    ) throws {
        self.id = id
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.timeoutSeconds = timeoutSeconds
        self.maximumDurationSeconds = maximumDurationSeconds
        self.lifecycle = lifecycle
        self.backgroundedAt = backgroundedAt
        try validate()
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        for key in CodingKeys.allCases where !container.contains(key) {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing required key")
            )
        }
        id = try container.decode(String.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        lastActivityAt = try container.decode(Date.self, forKey: .lastActivityAt)
        timeoutSeconds = try container.decode(Int.self, forKey: .timeoutSeconds)
        maximumDurationSeconds = try container.decode(Int.self, forKey: .maximumDurationSeconds)
        lifecycle = try container.decode(EluSessionLifecycle.self, forKey: .lifecycle)
        backgroundedAt = try container.decodeIfPresent(Date.self, forKey: .backgroundedAt)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(lastActivityAt, forKey: .lastActivityAt)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(maximumDurationSeconds, forKey: .maximumDurationSeconds)
        try container.encode(lifecycle, forKey: .lifecycle)
        if let backgroundedAt {
            try container.encode(backgroundedAt, forKey: .backgroundedAt)
        } else {
            try container.encodeNil(forKey: .backgroundedAt)
        }
    }

    func validate() throws {
        guard EluIdentityState.valid(id, maximumLength: 256),
              timeoutSeconds >= 60, timeoutSeconds <= 36_000,
              maximumDurationSeconds == Self.requiredMaximumDurationSeconds,
              startedAt.timeIntervalSinceReferenceDate.isFinite,
              lastActivityAt.timeIntervalSinceReferenceDate.isFinite,
              backgroundedAt?.timeIntervalSinceReferenceDate.isFinite ?? true
        else {
            throw EluIdentityStateError.invalidSession
        }
    }
}

struct EluIdentityMigration: Codable, Equatable, Sendable {
    var sourceSchema: String
    var completedAt: Date

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sourceSchema
        case completedAt
    }

    init(sourceSchema: String, completedAt: Date) throws {
        self.sourceSchema = sourceSchema
        self.completedAt = completedAt
        try validate()
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceSchema = try container.decode(String.self, forKey: .sourceSchema)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceSchema, forKey: .sourceSchema)
        try container.encode(completedAt, forKey: .completedAt)
    }

    func validate() throws {
        guard EluIdentityState.valid(sourceSchema, maximumLength: 128),
              completedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw EluIdentityStateError.invalidMigration
        }
    }
}

struct EluIdentityState: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumGroups = 64
    static let maximumSuperProperties = 256

    var schemaVersion: Int
    var revision: Int64
    var contextRevision: Int64
    var anonymousId: String
    var userId: String?
    var groups: [String: String]
    var superProperties: [String: EluJSONValue]
    var session: EluSessionState?
    var optedOut: Bool
    var updatedAt: Date
    var migration: EluIdentityMigration?

    var identityRevision: Int64 { revision }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case revision
        case contextRevision
        case anonymousId
        case userId
        case groups
        case superProperties
        case session
        case optedOut
        case updatedAt
        case migration
    }

    private static let requiredKeys: Set<CodingKeys> = [
        .schemaVersion,
        .revision,
        .contextRevision,
        .anonymousId,
        .userId,
        .groups,
        .superProperties,
        .session,
        .optedOut,
        .updatedAt,
    ]

    init(
        schemaVersion: Int = Self.schemaVersion,
        revision: Int64,
        contextRevision: Int64,
        anonymousId: String,
        userId: String?,
        groups: [String: String],
        superProperties: [String: EluJSONValue],
        session: EluSessionState?,
        optedOut: Bool,
        updatedAt: Date,
        migration: EluIdentityMigration? = nil
    ) throws {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.contextRevision = contextRevision
        self.anonymousId = anonymousId
        self.userId = userId
        self.groups = groups
        self.superProperties = superProperties
        self.session = session
        self.optedOut = optedOut
        self.updatedAt = updatedAt
        self.migration = migration
        try validate()
    }

    init(from decoder: Decoder) throws {
        try EluClosedRecord.requireOnly(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        for key in Self.requiredKeys where !container.contains(key) {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing required key")
            )
        }
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        revision = try container.decode(Int64.self, forKey: .revision)
        contextRevision = try container.decode(Int64.self, forKey: .contextRevision)
        anonymousId = try container.decode(String.self, forKey: .anonymousId)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        groups = try container.decode([String: String].self, forKey: .groups)
        superProperties = try container.decode([String: EluJSONValue].self, forKey: .superProperties)
        session = try container.decodeIfPresent(EluSessionState.self, forKey: .session)
        optedOut = try container.decode(Bool.self, forKey: .optedOut)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        migration = try container.decodeIfPresent(EluIdentityMigration.self, forKey: .migration)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encode(contextRevision, forKey: .contextRevision)
        try container.encode(anonymousId, forKey: .anonymousId)
        if let userId {
            try container.encode(userId, forKey: .userId)
        } else {
            try container.encodeNil(forKey: .userId)
        }
        try container.encode(groups, forKey: .groups)
        try container.encode(superProperties, forKey: .superProperties)
        if let session {
            try container.encode(session, forKey: .session)
        } else {
            try container.encodeNil(forKey: .session)
        }
        try container.encode(optedOut, forKey: .optedOut)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(migration, forKey: .migration)
    }

    func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw EluIdentityStateError.unsupportedSchemaVersion
        }
        guard revision >= 0, contextRevision >= 0 else {
            throw EluIdentityStateError.invalidRevision
        }
        guard Self.valid(anonymousId, maximumLength: 256) else {
            throw EluIdentityStateError.invalidIdentifier("anonymousId")
        }
        if let userId, !Self.valid(userId, maximumLength: 512) {
            throw EluIdentityStateError.invalidIdentifier("userId")
        }
        guard groups.count <= Self.maximumGroups else {
            throw EluIdentityStateError.tooManyGroups
        }
        for (type, key) in groups {
            guard Self.valid(type, maximumLength: 256), Self.valid(key, maximumLength: 512) else {
                throw EluIdentityStateError.invalidIdentifier("groups")
            }
        }
        guard superProperties.count <= Self.maximumSuperProperties else {
            throw EluIdentityStateError.tooManySuperProperties
        }
        for (key, value) in superProperties {
            guard Self.valid(key, maximumLength: 256) else {
                throw EluIdentityStateError.invalidPropertyKey
            }
            try value.validate()
        }
        try session?.validate()
        try migration?.validate()
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw EluIdentityStateError.invalidRevision
        }
    }

    static func valid(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty && value.count <= maximumLength
    }
}

enum EluClosedRecord {
    static func requireOnly<Key: CodingKey & CaseIterable>(
        _ keyType: Key.Type,
        from decoder: Decoder
    ) throws where Key.AllCases: Collection {
        let container = try decoder.container(keyedBy: EluDynamicCodingKey.self)
        let allowed = Set(keyType.allCases.map(\.stringValue))
        let unknown = container.allKeys.first { !allowed.contains($0.stringValue) }
        if let unknown {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath + [unknown],
                    debugDescription: "Unknown key in closed record"
                )
            )
        }
    }
}

enum EluRFC3339 {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }
}

enum EluStateCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(EluRFC3339.string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = EluRFC3339.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an RFC3339 timestamp"
                )
            }
            return date
        }
        return decoder
    }
}
