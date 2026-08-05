import CoreFoundation
import Darwin
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
    case backupCommitDurabilityUnconfirmed
    case primaryCommitDurabilityUnconfirmed
}

enum EluStateWriteMode: Equatable, Sendable {
    case normal
    case recovery
}

protocol EluDirectorySynchronizing: Sendable {
    func synchronize(directoryURL: URL) throws
}

struct EluDarwinDirectorySynchronizer: EluDirectorySynchronizing {
    func synchronize(directoryURL: URL) throws {
        let descriptor = directoryURL.path.withCString { path in
            Darwin.open(path, O_RDONLY)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }

        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

protocol EluPersistedStateEncoding: Sendable {
    func encode(_ state: EluPersistedState) throws -> Data
}

struct EluJSONPersistedStateEncoder: EluPersistedStateEncoding {
    func encode(_ state: EluPersistedState) throws -> Data {
        try EluStateCoding.encoder().encode(state)
    }
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

private struct EluPersistedStateBudget {
    private static let maximumNodes = 65_536
    private static let fixedEnvelopeBytes = 4_096

    private var remainingBytes: Int
    private var remainingNodes = Self.maximumNodes

    init(maximumBytes: Int) throws {
        guard maximumBytes >= Self.fixedEnvelopeBytes else {
            throw EluIdentityStateStoreError.recordTooLarge(.aggregate)
        }
        remainingBytes = maximumBytes
        try consume(bytes: Self.fixedEnvelopeBytes, nodes: 4)
    }

    static func validate(_ state: EluPersistedState, maximumBytes: Int) throws {
        var budget = try Self(maximumBytes: maximumBytes)
        try budget.consumeString(state.identity.anonymousId)
        if let userId = state.identity.userId {
            try budget.consumeString(userId)
        }
        try budget.consumeString(state.streamMetadata.streamId)

        try budget.consumeStringMap(state.identity.groups)
        try budget.consumeProperties(state.identity.superProperties)
        if let session = state.identity.session {
            try budget.consumeString(session.id)
        }
        if let migration = state.identity.migration {
            try budget.consumeString(migration.sourceSchema)
        }

        try budget.consumeProperties(state.flagContext.personProperties)
        try budget.consume(bytes: 2, nodes: 1)
        for (type, properties) in state.flagContext.groupProperties {
            try budget.consumeString(type, asKey: true)
            try budget.consume(bytes: 2)
            try budget.consumeProperties(properties)
        }
    }

    private mutating func consumeStringMap(_ values: [String: String]) throws {
        try consume(bytes: 2, nodes: 1)
        for (key, value) in values {
            try consumeString(key, asKey: true)
            try consume(bytes: 2)
            try consumeString(value)
        }
    }

    private mutating func consumeProperties(_ properties: [String: EluJSONValue]) throws {
        try consume(bytes: 2, nodes: 1)
        for (key, value) in properties {
            try consumeString(key, asKey: true)
            try consume(bytes: 2)
            try consume(value)
        }
    }

    private mutating func consume(_ value: EluJSONValue) throws {
        try consume(nodes: 1)
        switch value {
        case .null:
            try consume(bytes: 4)
        case .bool:
            try consume(bytes: 5)
        case .integer:
            try consume(bytes: 32)
        case .number:
            try consume(bytes: 64)
        case let .string(value):
            try consumeString(value)
        case let .array(values):
            try consume(bytes: 2)
            for value in values {
                try consume(bytes: 1)
                try consume(value)
            }
        case let .object(values):
            try consume(bytes: 2)
            for (key, value) in values {
                try consumeString(key, asKey: true)
                try consume(bytes: 2)
                try consume(value)
            }
        }
    }

    private mutating func consumeString(_ value: String, asKey: Bool = false) throws {
        try consume(bytes: 2, nodes: asKey ? 1 : 0)
        for scalar in value.unicodeScalars {
            let scalarValue = scalar.value
            let encodedBytes: Int
            if (0 ... 7).contains(scalarValue)
                || scalarValue == 11
                || (14 ... 31).contains(scalarValue)
            {
                encodedBytes = 6
            } else if (8 ... 10).contains(scalarValue)
                || (12 ... 13).contains(scalarValue)
                || scalarValue == 34
                || scalarValue == 47
                || scalarValue == 92
            {
                encodedBytes = 2
            } else if scalarValue == 0x2028 || scalarValue == 0x2029 {
                encodedBytes = 6
            } else if scalarValue <= 0x7F {
                encodedBytes = 1
            } else if scalarValue <= 0x7FF {
                encodedBytes = 2
            } else if scalarValue <= 0xFFFF {
                encodedBytes = 3
            } else {
                encodedBytes = 4
            }
            try consume(bytes: encodedBytes)
        }
    }

    private mutating func consume(bytes: Int = 0, nodes: Int = 0) throws {
        guard bytes >= 0,
              nodes >= 0,
              bytes <= remainingBytes,
              nodes <= remainingNodes
        else {
            throw EluIdentityStateStoreError.recordTooLarge(.aggregate)
        }
        remainingBytes -= bytes
        remainingNodes -= nodes
    }
}

final class EluFileIdentityStateStore: EluIdentityStateStore, @unchecked Sendable {
    static let stateFilename = "identity-state-v1.json"
    static let backupFilename = "identity-state-v1.backup.json"

    static let maximumAggregateBytes = 1_024 * 1_024

    let directoryURL: URL
    let stateFileURL: URL
    let backupFileURL: URL

    private let fileManager: FileManager
    private let directorySynchronizer: any EluDirectorySynchronizing
    private let stateEncoder: any EluPersistedStateEncoding
    private let lock = NSLock()

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        directorySynchronizer: any EluDirectorySynchronizing = EluDarwinDirectorySynchronizer(),
        stateEncoder: any EluPersistedStateEncoding = EluJSONPersistedStateEncoder()
    ) throws {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.directorySynchronizer = directorySynchronizer
        self.stateEncoder = stateEncoder
        stateFileURL = directoryURL.appendingPathComponent(Self.stateFilename, isDirectory: false)
        backupFileURL = directoryURL.appendingPathComponent(Self.backupFilename, isDirectory: false)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    func load() throws -> EluPersistedStateLoadResult {
        try withLock {
            if fileManager.fileExists(atPath: stateFileURL.path) {
                let primary = try readCandidate(from: stateFileURL)
                try inspectBackupCompatibilityIfPresent()
                switch primary {
                case let .loaded(state):
                    return .loaded(state)
                case let .recoverable(components):
                    return .recoverable(components)
                case .unreadable:
                    return failClosedPrimaryCorruption()
                }
            }

            guard fileManager.fileExists(atPath: backupFileURL.path) else {
                return .missing
            }
            return try recoverFromBackupWhenPrimaryIsMissing()
        }
    }

    func save(_ state: EluPersistedState, mode: EluStateWriteMode) throws {
        try withLock {
            try state.validate()
            try EluPersistedStateBudget.validate(
                state,
                maximumBytes: Self.maximumAggregateBytes
            )
            let data = try stateEncoder.encode(state)
            guard data.count <= Self.maximumAggregateBytes else {
                throw EluIdentityStateStoreError.recordTooLarge(.aggregate)
            }

            try inspectBackupCompatibilityIfPresent()
            let previousPrimary = try validDataIfPresent(at: stateFileURL)
            if mode == .normal, let previousPrimary {
                try installDurably(
                    previousPrimary,
                    at: backupFileURL,
                    durabilityError: .backupCommitDurabilityUnconfirmed
                )
            }

            try installDurably(
                data,
                at: stateFileURL,
                durabilityError: .primaryCommitDurabilityUnconfirmed
            )
            removeBackupAfterPrimaryCommit()
        }
    }

    private enum Candidate {
        case loaded(EluPersistedState)
        case recoverable(EluRecoverablePersistedState)
        case unreadable
    }

    private func recoverFromBackupWhenPrimaryIsMissing() throws -> EluPersistedStateLoadResult {
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

    private func inspectBackupCompatibilityIfPresent() throws {
        guard fileManager.fileExists(atPath: backupFileURL.path) else { return }
        // The result is deliberately ignored. A supported backup may only be
        // used when no primary path exists; this inspection solely protects
        // unknown future records from being overwritten by an older SDK.
        _ = try readCandidate(from: backupFileURL)
    }

    private func failClosedPrimaryCorruption() -> EluPersistedStateLoadResult {
        .recoverable(
            EluRecoverablePersistedState(
                identity: nil,
                streamMetadata: nil,
                flagContext: nil,
                forceOptOut: true
            )
        )
    }

    private func readCandidate(from url: URL) throws -> Candidate {
        guard let data = try readBoundedDataIfPresent(from: url) else {
            return .unreadable
        }
        return try decodeCandidate(data)
    }

    private func readBoundedDataIfPresent(from url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_RDONLY)
        }
        guard descriptor >= 0 else {
            throw Self.posixError(errno)
        }
        defer { _ = Darwin.close(descriptor) }

        let maximumReadBytes = Self.maximumAggregateBytes + 1
        var data = Data()
        data.reserveCapacity(maximumReadBytes)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count < maximumReadBytes {
            let requestedCount = min(buffer.count, maximumReadBytes - data.count)
            let bytesRead = buffer.withUnsafeMutableBufferPointer { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requestedCount)
            }
            if bytesRead > 0 {
                data.append(contentsOf: buffer.prefix(bytesRead))
            } else if bytesRead == 0 {
                break
            } else {
                let errorNumber = errno
                if errorNumber == EINTR {
                    continue
                }
                throw Self.posixError(errorNumber)
            }
        }
        guard !data.isEmpty else { return nil }
        guard data.count <= Self.maximumAggregateBytes else {
            throw EluIdentityStateStoreError.recordTooLarge(.aggregate)
        }
        return data
    }

    private func validDataIfPresent(at url: URL) throws -> Data? {
        guard let data = try readBoundedDataIfPresent(from: url) else { return nil }
        guard case .loaded = try decodeCandidate(data) else { return nil }
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

    private func installDurably(
        _ data: Data,
        at targetURL: URL,
        durabilityError: EluIdentityStateStoreError
    ) throws {
        try replaceWithoutDirectorySync(data, at: targetURL)
        do {
            try directorySynchronizer.synchronize(directoryURL: directoryURL)
        } catch {
            // The replacement is the visibility commit point. Never roll it
            // back to older bytes after that point; the caller distinguishes
            // an installed primary from an auxiliary backup failure.
            throw durabilityError
        }

        // Tightening after the durable commit is best-effort so no post-commit
        // error can make the caller believe an unpublished write occurred.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
    }

    private func removeBackupAfterPrimaryCommit() {
        guard fileManager.fileExists(atPath: backupFileURL.path) else { return }
        do {
            try fileManager.removeItem(at: backupFileURL)
            try directorySynchronizer.synchronize(directoryURL: directoryURL)
        } catch {
            // Any existing primary remains authoritative. Cleanup is retried
            // by the next successful primary commit and never authorizes
            // loading the backup while that primary path exists.
        }
    }

    private func replaceWithoutDirectorySync(_ data: Data, at targetURL: URL) throws {
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

        try writeAndSynchronize(data, to: stagedURL)

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
    }

    private func writeAndSynchronize(_ data: Data, to url: URL) throws {
        var descriptor = url.path.withCString { path in
            Darwin.open(path, O_WRONLY)
        }
        guard descriptor >= 0 else {
            throw Self.posixError(errno)
        }
        defer {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
        }

        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let bytesWritten = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if bytesWritten > 0 {
                    offset += bytesWritten
                } else if bytesWritten == 0 {
                    throw Self.posixError(EIO)
                } else {
                    let errorNumber = errno
                    if errorNumber == EINTR {
                        continue
                    }
                    throw Self.posixError(errorNumber)
                }
            }
        }

        guard Darwin.fsync(descriptor) == 0 else {
            throw Self.posixError(errno)
        }
        let descriptorToClose = descriptor
        descriptor = -1
        guard Darwin.close(descriptorToClose) == 0 else {
            throw Self.posixError(errno)
        }
    }

    private static func posixError(_ errorNumber: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
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
