import Foundation

enum EluStoredIdentityRecord: String, Sendable {
    case identity
    case streamMetadata
}

enum EluIdentityStateStoreError: Error, Equatable {
    case corrupted(EluStoredIdentityRecord)
    case recordTooLarge(EluStoredIdentityRecord)
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

protocol EluIdentityStateStore: Sendable {
    func loadIdentity() throws -> EluIdentityState?
    func loadStreamMetadata() throws -> EluStreamMetadata?
    func saveIdentity(_ identity: EluIdentityState) throws
    func saveStreamMetadata(_ metadata: EluStreamMetadata) throws
}

final class EluFileIdentityStateStore: EluIdentityStateStore, @unchecked Sendable {
    static let identityFilename = "identity-v1.json"
    static let streamMetadataFilename = "stream-v1.json"

    private static let maximumIdentityBytes = 1 * 1_024 * 1_024
    private static let maximumStreamMetadataBytes = 16 * 1_024

    let directoryURL: URL
    let identityFileURL: URL
    let streamMetadataFileURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()

    init(directoryURL: URL, fileManager: FileManager = .default) throws {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        identityFileURL = directoryURL.appendingPathComponent(Self.identityFilename, isDirectory: false)
        streamMetadataFileURL = directoryURL.appendingPathComponent(
            Self.streamMetadataFilename,
            isDirectory: false
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    func loadIdentity() throws -> EluIdentityState? {
        try withLock {
            try read(
                EluIdentityState.self,
                from: identityFileURL,
                maximumBytes: Self.maximumIdentityBytes,
                record: .identity
            )
        }
    }

    func loadStreamMetadata() throws -> EluStreamMetadata? {
        try withLock {
            try read(
                EluStreamMetadata.self,
                from: streamMetadataFileURL,
                maximumBytes: Self.maximumStreamMetadataBytes,
                record: .streamMetadata
            )
        }
    }

    func saveIdentity(_ identity: EluIdentityState) throws {
        try withLock {
            try write(
                identity,
                to: identityFileURL,
                maximumBytes: Self.maximumIdentityBytes,
                record: .identity
            )
        }
    }

    func saveStreamMetadata(_ metadata: EluStreamMetadata) throws {
        try withLock {
            try write(
                metadata,
                to: streamMetadataFileURL,
                maximumBytes: Self.maximumStreamMetadataBytes,
                record: .streamMetadata
            )
        }
    }

    private func read<Value: Decodable>(
        _ type: Value.Type,
        from url: URL,
        maximumBytes: Int,
        record: EluStoredIdentityRecord
    ) throws -> Value? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw EluIdentityStateStoreError.corrupted(record)
        }
        do {
            return try EluStateCoding.decoder().decode(type, from: data)
        } catch is DecodingError {
            throw EluIdentityStateStoreError.corrupted(record)
        } catch is EluIdentityStateError {
            throw EluIdentityStateStoreError.corrupted(record)
        }
    }

    private func write<Value: Encodable>(
        _ value: Value,
        to url: URL,
        maximumBytes: Int,
        record: EluStoredIdentityRecord
    ) throws {
        let data = try EluStateCoding.encoder().encode(value)
        guard data.count <= maximumBytes else {
            throw EluIdentityStateStoreError.recordTooLarge(record)
        }
        try data.write(to: url, options: .atomic)
        // The containing directory is 0700. Keep permission tightening best-effort
        // after the atomic replacement so a post-commit chmod failure cannot make
        // callers believe the durable state transition failed.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
