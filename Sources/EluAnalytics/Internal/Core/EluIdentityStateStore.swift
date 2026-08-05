import CoreFoundation
import Foundation

enum EluStoredIdentityRecord: String, Sendable {
    case aggregate
    case identity
    case streamMetadata
    case flagContext
    case session
    case migration
}

enum EluIdentityStateStoreError: Error, Equatable {
    case corrupted(EluStoredIdentityRecord)
    case recordTooLarge(EluStoredIdentityRecord)
    case unsupportedRecordExtension(EluStoredIdentityRecord)
}

enum EluStateWriteMode: Equatable, Sendable {
    case normal
    case recovery
}

struct EluStreamMetadata: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var streamId: String
    var nextSequence: Int64

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case streamId
        case nextSequence
    }

    static let persistedKeys = Set(CodingKeys.allCases.map(\.stringValue))

    init(
        schemaVersion: Int = Self.schemaVersion,
        streamId: String,
        nextSequence: Int64 = 0
    ) throws {
        self.schemaVersion = schemaVersion
        self.streamId = streamId
        self.nextSequence = nextSequence
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
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        streamId = try container.decode(String.self, forKey: .streamId)
        nextSequence = try container.decode(Int64.self, forKey: .nextSequence)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(streamId, forKey: .streamId)
        try container.encode(nextSequence, forKey: .nextSequence)
    }

    func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw EluIdentityStateError.unsupportedSchemaVersion
        }
        guard EluIdentityState.valid(streamId, maximumLength: 256) else {
            throw EluIdentityStateError.invalidIdentifier("streamId")
        }
        guard nextSequence >= 0 else {
            throw EluIdentityStateError.invalidRevision
        }
    }
}

struct EluPersistedFlagContext: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumGroups = 64
    static let maximumProperties = 256

    var schemaVersion: Int
    var personProperties: [String: EluJSONValue]
    var groupProperties: [String: [String: EluJSONValue]]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case personProperties
        case groupProperties
    }

    static let persistedKeys = Set(CodingKeys.allCases.map(\.stringValue))

    init(
        schemaVersion: Int = Self.schemaVersion,
        personProperties: [String: EluJSONValue] = [:],
        groupProperties: [String: [String: EluJSONValue]] = [:]
    ) throws {
        self.schemaVersion = schemaVersion
        self.personProperties = personProperties
        self.groupProperties = groupProperties
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
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        personProperties = try container.decode(
            [String: EluJSONValue].self,
            forKey: .personProperties
        )
        groupProperties = try container.decode(
            [String: [String: EluJSONValue]].self,
            forKey: .groupProperties
        )
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(personProperties, forKey: .personProperties)
        try container.encode(groupProperties, forKey: .groupProperties)
    }

    func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw EluIdentityStateError.unsupportedSchemaVersion
        }
        try Self.validateProperties(personProperties)
        guard groupProperties.count <= Self.maximumGroups else {
            throw EluIdentityStateError.tooManyGroups
        }
        for (type, properties) in groupProperties {
            guard EluIdentityState.valid(type, maximumLength: 256) else {
                throw EluIdentityStateError.invalidIdentifier("flagGroupType")
            }
            try Self.validateProperties(properties)
        }
    }

    private static func validateProperties(_ properties: [String: EluJSONValue]) throws {
        guard properties.count <= Self.maximumProperties else {
            throw EluIdentityStateError.tooManySuperProperties
        }
        for (key, value) in properties {
            guard EluIdentityState.valid(key, maximumLength: 256) else {
                throw EluIdentityStateError.invalidPropertyKey
            }
            try value.validate()
        }
    }
}

struct EluPersistedState: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var identity: EluIdentityState
    var streamMetadata: EluStreamMetadata
    var flagContext: EluPersistedFlagContext

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case identity
        case streamMetadata
        case flagContext
    }

    static let persistedKeys = Set(CodingKeys.allCases.map(\.stringValue))

    init(
        schemaVersion: Int = Self.schemaVersion,
        identity: EluIdentityState,
        streamMetadata: EluStreamMetadata,
        flagContext: EluPersistedFlagContext
    ) throws {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.streamMetadata = streamMetadata
        self.flagContext = flagContext
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
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        identity = try container.decode(EluIdentityState.self, forKey: .identity)
        streamMetadata = try container.decode(EluStreamMetadata.self, forKey: .streamMetadata)
        flagContext = try container.decode(EluPersistedFlagContext.self, forKey: .flagContext)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(identity, forKey: .identity)
        try container.encode(streamMetadata, forKey: .streamMetadata)
        try container.encode(flagContext, forKey: .flagContext)
    }

    func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw EluIdentityStateError.unsupportedSchemaVersion
        }
        try identity.validate()
        try streamMetadata.validate()
        try flagContext.validate()
    }
}

struct EluRecoverablePersistedState: Equatable, Sendable {
    var identity: EluIdentityState?
    var streamMetadata: EluStreamMetadata?
    var flagContext: EluPersistedFlagContext?
    var forceOptOut: Bool
}

enum EluPersistedStateLoadResult: Equatable, Sendable {
    case missing
    case loaded(EluPersistedState)
    case recoverable(EluRecoverablePersistedState)
}

protocol EluIdentityStateStore: Sendable {
    func load() throws -> EluPersistedStateLoadResult
    func save(_ state: EluPersistedState, mode: EluStateWriteMode) throws
}

final class EluFileIdentityStateStore: EluIdentityStateStore, @unchecked Sendable {
    static let stateFilename = "identity-state-v1.json"
    static let backupFilename = "identity-state-v1.backup.json"

    private static let maximumAggregateBytes = 2 * 1_024 * 1_024

    let directoryURL: URL
    let stateFileURL: URL
    let backupFileURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()

    init(directoryURL: URL, fileManager: FileManager = .default) throws {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        stateFileURL = directoryURL.appendingPathComponent(Self.stateFilename, isDirectory: false)
        backupFileURL = directoryURL.appendingPathComponent(Self.backupFilename, isDirectory: false)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    func load() throws -> EluPersistedStateLoadResult {
        try withLock {
            if fileManager.fileExists(atPath: stateFileURL.path) {
                switch try readCandidate(from: stateFileURL) {
                case let .loaded(state):
                    return .loaded(state)
                case let .recoverable(components):
                    return .recoverable(components)
                case .unreadable:
                    return try recoverFromBackupOrCorruption()
                }
            }

            guard fileManager.fileExists(atPath: backupFileURL.path) else {
                return .missing
            }
            return try recoverFromBackupOrCorruption()
        }
    }

    func save(_ state: EluPersistedState, mode: EluStateWriteMode) throws {
        try withLock {
            try state.validate()
            let data = try EluStateCoding.encoder().encode(state)
            guard data.count <= Self.maximumAggregateBytes else {
                throw EluIdentityStateStoreError.recordTooLarge(.aggregate)
            }

            if mode == .normal,
               let currentData = try readBoundedDataIfPresent(from: stateFileURL),
               case .loaded = try decodeCandidate(currentData)
            {
                try install(currentData, at: backupFileURL)
            }

            try install(data, at: stateFileURL)
        }
    }

    private enum Candidate {
        case loaded(EluPersistedState)
        case recoverable(EluRecoverablePersistedState)
        case unreadable
    }

    private func recoverFromBackupOrCorruption() throws -> EluPersistedStateLoadResult {
        guard fileManager.fileExists(atPath: backupFileURL.path) else {
            return .recoverable(
                EluRecoverablePersistedState(
                    identity: nil,
                    streamMetadata: nil,
                    flagContext: nil,
                    forceOptOut: true
                )
            )
        }

        switch try readCandidate(from: backupFileURL) {
        case let .loaded(state):
            return .recoverable(
                EluRecoverablePersistedState(
                    identity: state.identity,
                    streamMetadata: state.streamMetadata,
                    flagContext: state.flagContext,
                    forceOptOut: true
                )
            )
        case let .recoverable(components):
            var failClosedComponents = components
            failClosedComponents.forceOptOut = true
            return .recoverable(failClosedComponents)
        case .unreadable:
            return .recoverable(
                EluRecoverablePersistedState(
                    identity: nil,
                    streamMetadata: nil,
                    flagContext: nil,
                    forceOptOut: true
                )
            )
        }
    }

    private func readCandidate(from url: URL) throws -> Candidate {
        guard let data = try readBoundedDataIfPresent(from: url) else {
            return .unreadable
        }
        return try decodeCandidate(data)
    }

    private func readBoundedDataIfPresent(from url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumAggregateBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= Self.maximumAggregateBytes else { return nil }
        return data
    }

    private func decodeCandidate(_ data: Data) throws -> Candidate {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable
        }

        try rejectUnsupportedVersion(in: root, expected: EluPersistedState.schemaVersion)
        try rejectUnsupportedNestedVersion(
            key: "identity",
            in: root,
            expected: EluIdentityState.schemaVersion
        )
        try rejectUnsupportedNestedVersion(
            key: "streamMetadata",
            in: root,
            expected: EluStreamMetadata.schemaVersion
        )
        try rejectUnsupportedNestedVersion(
            key: "flagContext",
            in: root,
            expected: EluPersistedFlagContext.schemaVersion
        )
        try rejectUnknownKeys(
            in: root,
            allowed: EluPersistedState.persistedKeys,
            record: .aggregate
        )
        try rejectUnknownNestedKeys(
            key: "identity",
            in: root,
            allowed: EluIdentityState.persistedKeys,
            record: .identity
        )
        try rejectUnknownNestedKeys(
            key: "streamMetadata",
            in: root,
            allowed: EluStreamMetadata.persistedKeys,
            record: .streamMetadata
        )
        try rejectUnknownNestedKeys(
            key: "flagContext",
            in: root,
            allowed: EluPersistedFlagContext.persistedKeys,
            record: .flagContext
        )
        if let identity = root["identity"] as? [String: Any] {
            try rejectUnknownNestedKeys(
                key: "session",
                in: identity,
                allowed: EluSessionState.persistedKeys,
                record: .session
            )
            try rejectUnknownNestedKeys(
                key: "migration",
                in: identity,
                allowed: EluIdentityMigration.persistedKeys,
                record: .migration
            )
        }

        if let state = try? EluStateCoding.decoder().decode(EluPersistedState.self, from: data) {
            return .loaded(state)
        }

        return .recoverable(
            EluRecoverablePersistedState(
                identity: decodeNested(EluIdentityState.self, key: "identity", from: root),
                streamMetadata: decodeNested(
                    EluStreamMetadata.self,
                    key: "streamMetadata",
                    from: root
                ),
                flagContext: decodeNested(
                    EluPersistedFlagContext.self,
                    key: "flagContext",
                    from: root
                ),
                forceOptOut: false
            )
        )
    }

    private func rejectUnsupportedNestedVersion(
        key: String,
        in root: [String: Any],
        expected: Int
    ) throws {
        guard let nested = root[key] as? [String: Any] else { return }
        try rejectUnsupportedVersion(in: nested, expected: expected)
    }

    private func rejectUnknownNestedKeys(
        key: String,
        in root: [String: Any],
        allowed: Set<String>,
        record: EluStoredIdentityRecord
    ) throws {
        guard let nested = root[key] as? [String: Any] else { return }
        try rejectUnknownKeys(in: nested, allowed: allowed, record: record)
    }

    private func rejectUnknownKeys(
        in object: [String: Any],
        allowed: Set<String>,
        record: EluStoredIdentityRecord
    ) throws {
        guard object.keys.allSatisfy(allowed.contains) else {
            throw EluIdentityStateStoreError.unsupportedRecordExtension(record)
        }
    }

    private func rejectUnsupportedVersion(in object: [String: Any], expected: Int) throws {
        guard let value = object["schemaVersion"],
              let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID(),
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(Int.min),
              number.doubleValue <= Double(Int.max)
        else {
            return
        }
        guard number.intValue == expected else {
            throw EluIdentityStateError.unsupportedSchemaVersion
        }
    }

    private func decodeNested<Value: Decodable>(
        _ type: Value.Type,
        key: String,
        from root: [String: Any]
    ) -> Value? {
        guard let object = root[key],
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            return nil
        }
        return try? EluStateCoding.decoder().decode(type, from: data)
    }

    private func install(_ data: Data, at targetURL: URL) throws {
        let stagedURL = directoryURL.appendingPathComponent(
            ".\(targetURL.lastPathComponent).\(UUID().uuidString).staged",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: stagedURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fileManager.removeItem(at: stagedURL) }

        let handle = try FileHandle(forWritingTo: stagedURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        if fileManager.fileExists(atPath: targetURL.path) {
            _ = try fileManager.replaceItemAt(
                targetURL,
                withItemAt: stagedURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: stagedURL, to: targetURL)
        }

        // Tightening after the atomic install is best-effort so no post-commit
        // error can make the caller believe an unpublished write occurred.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
    }

    private func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        // This lock coordinates one store instance only. The store provides no
        // cross-instance or cross-process coordination; integration must keep
        // one live runtime owner for each persistence directory.
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
