import Darwin
import CryptoKit
import Foundation
import SQLite3

enum EluRuntimeQueueError: Error, Equatable, Sendable {
    case invalidDirectory
    case ownershipConflict
    case databaseUnavailable
    case corruptStorage
    case unsupportedSchemaVersion(Int64)
    case invalidState
    case invalidRecord
    case queueCountLimitExceeded
    case queueByteLimitExceeded
    case counterExhausted
    case generationMismatch
    case acknowledgementMismatch
    case headRecordExceedsPeekLimit(Int64)
    case poisoned
    case ambiguousCommit
    case provenNotCommitted
    case captureAuthorityExpiredBeforeWrite
    case standaloneLegacyEntryPointUnavailable
    case flagAuthorityTerminal
    case faultInjected(EluRuntimeQueueFaultPoint)
}

enum EluRuntimeQueueFaultPoint: Equatable, Sendable {
    case open
    case beforeInitialInstall
    case afterInitialInstall
    case beforeBegin
    case afterBegin
    case afterStateRead
    case afterRecordInsert(Int)
    case beforeStateUpdate
    case beforeCommit
    case afterCommit
    case beforeRollback
    case checkpoint
    case vacuum
}

protocol EluRuntimeQueueFaultInjecting: Sendable {
    func hit(_ point: EluRuntimeQueueFaultPoint) throws
}

struct EluRuntimeQueueLimits: Equatable, Sendable {
    static let defaultMaximumCount = 10_000
    static let defaultMaximumBytes = 256 * 1_024 * 1_024

    var maximumCount: Int
    var maximumBytes: Int

    init(
        maximumCount: Int = Self.defaultMaximumCount,
        maximumBytes: Int = Self.defaultMaximumBytes
    ) throws {
        guard (1 ... Self.defaultMaximumCount).contains(maximumCount),
              (1 ... Self.defaultMaximumBytes).contains(maximumBytes)
        else {
            throw EluRuntimeQueueError.invalidState
        }
        self.maximumCount = maximumCount
        self.maximumBytes = maximumBytes
    }
}

struct EluRuntimeQueueSnapshot: Equatable, Sendable {
    var identity: EluIdentityState
    var flagContext: EluFlagContext
    var streamId: String
    var nextSequence: Int64
    var headSequence: Int64?
    var queuedCount: Int64
    var queuedBytes: Int64
    var generation: Int64
}

private struct EluStoredRuntimeState: Equatable, Sendable {
    var generation: Int64
    var identity: EluIdentityState
    var flagContext: EluPersistedFlagContext
    var streamId: String
    var nextSequence: Int64
    var headSequence: Int64?
    var liveCount: Int64
    var liveBytes: Int64

    var snapshot: EluRuntimeQueueSnapshot {
        EluRuntimeQueueSnapshot(
            identity: identity,
            flagContext: EluFlagContext(
                personProperties: flagContext.personProperties,
                groupProperties: flagContext.groupProperties
            ),
            streamId: streamId,
            nextSequence: nextSequence,
            headSequence: headSequence,
            queuedCount: liveCount,
            queuedBytes: liveBytes,
            generation: generation
        )
    }
}

private struct EluStoredQueueRecord: Sendable {
    var record: EluQueuedRecord
    var payload: Data
    var versionsPayload: Data
    var accountedBytes: Int64
}

private enum EluSQLiteRuntimeSchema {
    static let runtimeStateVersion: Int64 = 1
    static let initialDatabaseVersion: Int64 = 1
    static let flagDatabaseVersion: Int64 = 2
    static let databaseFilename = "runtime-state-v1.sqlite3"
    static let lockFilename = ".runtime-state-v1.lock"
    static let maximumPayloadBytes = 10 * 1_024 * 1_024
    static let maximumStateBytes = EluFileIdentityStateStore.maximumAggregateBytes

    static let createRuntimeState = """
    CREATE TABLE runtime_state (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        schema_version INTEGER NOT NULL CHECK (schema_version = 1),
        generation INTEGER NOT NULL CHECK (generation >= 0),
        identity_json BLOB NOT NULL,
        flag_context_json BLOB NOT NULL,
        stream_id TEXT NOT NULL,
        next_sequence INTEGER NOT NULL CHECK (next_sequence >= 0),
        head_sequence INTEGER,
        live_count INTEGER NOT NULL CHECK (live_count >= 0 AND live_count <= 10000),
        live_bytes INTEGER NOT NULL CHECK (
            live_bytes >= 0 AND live_bytes <= 268435456
        )
    )
    """

    static let createQueueRecords = """
    CREATE TABLE queue_records (
        sequence INTEGER PRIMARY KEY CHECK (sequence >= 0),
        kind TEXT NOT NULL CHECK (kind IN ('event', 'mutation')),
        record_id TEXT NOT NULL,
        occurred_at TEXT NOT NULL,
        payload BLOB NOT NULL,
        capture_versions BLOB NOT NULL,
        accounted_bytes INTEGER NOT NULL CHECK (accounted_bytes > 0),
        UNIQUE (kind, record_id)
    )
    """

    static let createFlagCacheRecords = """
    CREATE TABLE flag_cache_records (
        record_type TEXT NOT NULL CHECK (
            record_type IN ('authority', 'request', 'chunk')
        ),
        record_index INTEGER NOT NULL CHECK (record_index >= 0),
        storage_schema INTEGER NOT NULL CHECK (storage_schema >= 1),
        initialized INTEGER NOT NULL CHECK (initialized IN (0, 1)),
        declared_body_bytes INTEGER,
        body_sha256 TEXT,
        chunk_count INTEGER,
        body BLOB NOT NULL,
        PRIMARY KEY (record_type, record_index),
        CHECK (
            (record_type = 'authority' AND record_index = 0
                AND declared_body_bytes IS NULL AND body_sha256 IS NULL
                AND chunk_count IS NULL AND length(body) <= 1048576)
            OR
            (record_type = 'request' AND record_index = 0 AND initialized = 1
                AND declared_body_bytes IS NOT NULL AND declared_body_bytes >= 0
                AND body_sha256 IS NOT NULL AND chunk_count IS NOT NULL
                AND chunk_count >= 0 AND length(body) <= 1048576)
            OR
            (record_type = 'chunk' AND initialized = 1
                AND declared_body_bytes IS NULL AND body_sha256 IS NULL
                AND chunk_count IS NULL AND length(body) <= 1048576)
        )
    )
    """

    static let runtimeStateColumns = [
        "singleton": "INTEGER",
        "schema_version": "INTEGER",
        "generation": "INTEGER",
        "identity_json": "BLOB",
        "flag_context_json": "BLOB",
        "stream_id": "TEXT",
        "next_sequence": "INTEGER",
        "head_sequence": "INTEGER",
        "live_count": "INTEGER",
        "live_bytes": "INTEGER",
    ]

    static let queueRecordColumns = [
        "sequence": "INTEGER",
        "kind": "TEXT",
        "record_id": "TEXT",
        "occurred_at": "TEXT",
        "payload": "BLOB",
        "capture_versions": "BLOB",
        "accounted_bytes": "INTEGER",
    ]

    static let flagCacheRecordColumns = [
        "record_type": "TEXT",
        "record_index": "INTEGER",
        "storage_schema": "INTEGER",
        "initialized": "INTEGER",
        "declared_body_bytes": "INTEGER",
        "body_sha256": "TEXT",
        "chunk_count": "INTEGER",
        "body": "BLOB",
    ]
}

private enum EluRuntimeIdentifier {
    static func compactUUID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func recordId(
        kind: EluQueueRecordKind,
        streamId: String,
        sequence: Int64
    ) -> String {
        let material = Data("\(kind.rawValue)\u{0}\(streamId)\u{0}\(sequence)".utf8)
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return "\(kind.rawValue)_\(digest)"
    }
}

private enum EluRuntimeCanonical {
    static func value<Value: Codable>(_ value: Value) throws -> Value {
        let data = try EluStateCoding.encoder().encode(value)
        return try EluStateCoding.decoder().decode(Value.self, from: data)
    }
}

private final class EluRuntimeOwnershipRegistry: @unchecked Sendable {
    static let shared = EluRuntimeOwnershipRegistry()

    private let lock = NSLock()
    private var directories: Set<String> = []

    func acquire(_ canonicalDirectory: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return directories.insert(canonicalDirectory).inserted
    }

    func release(_ canonicalDirectory: String) {
        lock.lock()
        directories.remove(canonicalDirectory)
        lock.unlock()
    }
}

private final class EluRuntimeResources: @unchecked Sendable {
    let canonicalDirectory: String
    let connection: EluSQLiteConnection

    private let lock = NSLock()
    private var lockDescriptor: Int32
    private var isClosed = false

    init(
        canonicalDirectory: String,
        lockDescriptor: Int32,
        connection: EluSQLiteConnection
    ) {
        self.canonicalDirectory = canonicalDirectory
        self.lockDescriptor = lockDescriptor
        self.connection = connection
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let descriptor = lockDescriptor
        lockDescriptor = -1
        lock.unlock()

        connection.close()
        if descriptor >= 0 {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }
        EluRuntimeOwnershipRegistry.shared.release(canonicalDirectory)
    }

    deinit {
        close()
    }
}

private enum EluSQLiteFailure: Error {
    case result(Int32, String)
}

private final class EluSQLiteConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var database: OpaquePointer?

    init(path: String, create: Bool) throws {
        var opened: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if create {
            flags |= SQLITE_OPEN_CREATE
        }
        let result = sqlite3_open_v2(path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed"
            if let opened {
                sqlite3_close_v2(opened)
            }
            throw EluSQLiteFailure.result(result, message)
        }
        database = opened
        sqlite3_extended_result_codes(opened, 1)
        guard sqlite3_busy_timeout(opened, 1_000) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(opened))
            sqlite3_close_v2(opened)
            database = nil
            throw EluSQLiteFailure.result(SQLITE_BUSY, message)
        }
    }

    func close() {
        lock.lock()
        let opened = database
        database = nil
        lock.unlock()
        if let opened {
            sqlite3_close_v2(opened)
        }
    }

    func execute(_ sql: String) throws {
        let opened = try requireDatabase()
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(opened, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(opened))
            sqlite3_free(errorMessage)
            throw EluSQLiteFailure.result(result, message)
        }
    }

    func withStatement<Value>(
        _ sql: String,
        _ operation: (OpaquePointer) throws -> Value
    ) throws -> Value {
        let opened = try requireDatabase()
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(opened, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw EluSQLiteFailure.result(result, String(cString: sqlite3_errmsg(opened)))
        }
        defer { sqlite3_finalize(statement) }
        return try operation(statement)
    }

    func step(_ statement: OpaquePointer, expecting expected: Int32 = SQLITE_DONE) throws {
        let result = sqlite3_step(statement)
        guard result == expected else {
            let opened = try requireDatabase()
            throw EluSQLiteFailure.result(result, String(cString: sqlite3_errmsg(opened)))
        }
    }

    func changes() throws -> Int32 {
        sqlite3_changes(try requireDatabase())
    }

    func integerPragma(_ name: String) throws -> Int64 {
        try withStatement("PRAGMA \(name)") { statement in
            try step(statement, expecting: SQLITE_ROW)
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
                throw EluSQLiteFailure.result(SQLITE_CORRUPT, "Invalid integer pragma")
            }
            let value = sqlite3_column_int64(statement, 0)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw EluSQLiteFailure.result(SQLITE_CORRUPT, "Unexpected pragma row")
            }
            return value
        }
    }

    func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer) throws {
        try requireBind(sqlite3_bind_int64(statement, index, value))
    }

    func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.transientDestructor)
        }
        try requireBind(result)
    }

    func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                Self.transientDestructor
            )
        }
        try requireBind(result)
    }

    func bindNull(at index: Int32, to statement: OpaquePointer) throws {
        try requireBind(sqlite3_bind_null(statement, index))
    }

    func requiredInteger(_ statement: OpaquePointer, column: Int32) throws -> Int64 {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else {
            throw EluSQLiteFailure.result(SQLITE_CORRUPT, "Expected integer column")
        }
        return sqlite3_column_int64(statement, column)
    }

    func optionalInteger(_ statement: OpaquePointer, column: Int32) throws -> Int64? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL {
            return nil
        }
        return try requiredInteger(statement, column: column)
    }

    func requiredString(_ statement: OpaquePointer, column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let text = sqlite3_column_text(statement, column)
        else {
            throw EluSQLiteFailure.result(SQLITE_CORRUPT, "Expected text column")
        }
        return String(cString: text)
    }

    func requiredData(
        _ statement: OpaquePointer,
        column: Int32,
        maximumBytes: Int
    ) throws -> Data {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else {
            throw EluSQLiteFailure.result(SQLITE_CORRUPT, "Expected blob column")
        }
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount > 0, byteCount <= maximumBytes,
              let bytes = sqlite3_column_blob(statement, column)
        else {
            throw EluSQLiteFailure.result(SQLITE_CORRUPT, "Invalid blob column")
        }
        return Data(bytes: bytes, count: byteCount)
    }

    private func requireDatabase() throws -> OpaquePointer {
        lock.lock()
        defer { lock.unlock() }
        guard let database else {
            throw EluSQLiteFailure.result(SQLITE_MISUSE, "SQLite connection is closed")
        }
        return database
    }

    private func requireBind(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            let opened = try requireDatabase()
            throw EluSQLiteFailure.result(result, String(cString: sqlite3_errmsg(opened)))
        }
    }

    private static let transientDestructor = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )
}

private struct EluRuntimeBootstrapResult: @unchecked Sendable {
    var resources: EluRuntimeResources
    var state: EluStoredRuntimeState
    var databaseSchemaVersion: Int64
}

private struct EluRuntimeInspection: Sendable {
    var state: EluStoredRuntimeState
    var databaseSchemaVersion: Int64
}

private enum EluRuntimeQueueBootstrap {
    static func open(
        directoryURL: URL,
        clock: @Sendable () -> Date,
        anonymousIdGenerator: @Sendable () -> String,
        streamIdGenerator: @Sendable () -> String,
        faultInjector: (any EluRuntimeQueueFaultInjecting)?
    ) throws -> EluRuntimeBootstrapResult {
        try faultInjector?.hit(.open)

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: directoryURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw EluRuntimeQueueError.invalidDirectory
            }
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        } catch let error as EluRuntimeQueueError {
            throw error
        } catch {
            throw EluRuntimeQueueError.invalidDirectory
        }

        let canonicalURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalDirectory = canonicalURL.path
        guard EluRuntimeOwnershipRegistry.shared.acquire(canonicalDirectory) else {
            throw EluRuntimeQueueError.ownershipConflict
        }

        var lockDescriptor: Int32 = -1
        var connection: EluSQLiteConnection?
        do {
            let lockURL = canonicalURL.appendingPathComponent(
                EluSQLiteRuntimeSchema.lockFilename,
                isDirectory: false
            )
            lockDescriptor = lockURL.path.withCString { path in
                Darwin.open(path, O_CREAT | O_RDWR, mode_t(0o600))
            }
            guard lockDescriptor >= 0 else {
                throw EluRuntimeQueueError.databaseUnavailable
            }
            guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    throw EluRuntimeQueueError.ownershipConflict
                }
                throw EluRuntimeQueueError.databaseUnavailable
            }
            _ = Darwin.fchmod(lockDescriptor, mode_t(0o600))

            let databaseURL = canonicalURL.appendingPathComponent(
                EluSQLiteRuntimeSchema.databaseFilename,
                isDirectory: false
            )
            let databaseExists = fileManager.fileExists(atPath: databaseURL.path)
            if !databaseExists {
                let importedState = normalizeLegacyOptedOutSession(
                    try loadLegacyOrFreshState(
                        directoryURL: canonicalURL,
                        clock: clock,
                        anonymousIdGenerator: anonymousIdGenerator,
                        streamIdGenerator: streamIdGenerator
                    )
                )
                try installFreshDatabase(
                    at: databaseURL,
                    state: importedState,
                    faultInjector: faultInjector
                )
            }

            let inspected = try inspectExisting(databaseURL: databaseURL)
            let openedConnection = try EluSQLiteConnection(path: databaseURL.path, create: false)
            connection = openedConnection
            let liveInspection = try inspectExisting(connection: openedConnection)
            var state = liveInspection.state
            guard state == inspected.state,
                  liveInspection.databaseSchemaVersion == inspected.databaseSchemaVersion
            else {
                throw EluRuntimeQueueError.corruptStorage
            }
            try configureDurability(openedConnection, initializing: false)
            state = try normalizeLegacyOptedOutSession(
                connection: openedConnection,
                state: state
            )

            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: databaseURL.path
            )
            let resources = EluRuntimeResources(
                canonicalDirectory: canonicalDirectory,
                lockDescriptor: lockDescriptor,
                connection: openedConnection
            )
            connection = nil
            lockDescriptor = -1
            return EluRuntimeBootstrapResult(
                resources: resources,
                state: state,
                databaseSchemaVersion: liveInspection.databaseSchemaVersion
            )
        } catch {
            connection?.close()
            if lockDescriptor >= 0 {
                _ = flock(lockDescriptor, LOCK_UN)
                _ = Darwin.close(lockDescriptor)
            }
            EluRuntimeOwnershipRegistry.shared.release(canonicalDirectory)
            throw mapOpenError(error)
        }
    }

    private static func inspectExisting(
        databaseURL: URL
    ) throws -> EluRuntimeInspection {
        let fileManager = FileManager.default
        let inspectionDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "elu-runtime-inspection-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: inspectionDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: inspectionDirectory) }

        let inspectionDatabase = inspectionDirectory.appendingPathComponent(
            EluSQLiteRuntimeSchema.databaseFilename,
            isDirectory: false
        )
        try fileManager.copyItem(at: databaseURL, to: inspectionDatabase)
        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: inspectionDatabase.path + suffix)
            try fileManager.copyItem(at: source, to: destination)
        }

        let connection = try EluSQLiteConnection(path: inspectionDatabase.path, create: false)
        defer { connection.close() }
        return try inspectExisting(connection: connection)
    }

    private static func inspectExisting(
        connection: EluSQLiteConnection
    ) throws -> EluRuntimeInspection {
        let userVersion = try connection.integerPragma("user_version")
        guard userVersion == EluSQLiteRuntimeSchema.initialDatabaseVersion
            || userVersion == EluSQLiteRuntimeSchema.flagDatabaseVersion
        else {
            if userVersion == 0 {
                _ = try EluRuntimeDatabase.schemaObjects(connection)
                throw EluRuntimeQueueError.corruptStorage
            }
            throw EluRuntimeQueueError.unsupportedSchemaVersion(userVersion)
        }

        try EluRuntimeDatabase.verifySchema(connection, databaseVersion: userVersion)
        return EluRuntimeInspection(
            state: try EluRuntimeDatabase.loadState(connection, validateQueue: true),
            databaseSchemaVersion: userVersion
        )
    }

    private static func installFreshDatabase(
        at databaseURL: URL,
        state: EluStoredRuntimeState,
        faultInjector: (any EluRuntimeQueueFaultInjecting)?
    ) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: databaseURL.path) else {
            throw EluRuntimeQueueError.ownershipConflict
        }
        let stagedURL = databaseURL.deletingLastPathComponent().appendingPathComponent(
            ".\(databaseURL.lastPathComponent).\(UUID().uuidString).staged",
            isDirectory: false
        )
        var installed = false
        defer {
            if !installed {
                removeDatabaseFamily(at: stagedURL)
            }
        }

        let connection = try EluSQLiteConnection(path: stagedURL.path, create: true)
        do {
            try configureDurability(connection, initializing: true)
            try connection.execute("BEGIN IMMEDIATE")
            try connection.execute(EluSQLiteRuntimeSchema.createRuntimeState)
            try connection.execute(EluSQLiteRuntimeSchema.createQueueRecords)
            try EluRuntimeDatabase.insertInitialState(connection, state: state)
            try connection.execute(
                "PRAGMA user_version = \(EluSQLiteRuntimeSchema.initialDatabaseVersion)"
            )
            try connection.execute("COMMIT")
            try connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try connection.withStatement("PRAGMA journal_mode=DELETE") { statement in
                try connection.step(statement, expecting: SQLITE_ROW)
                guard try connection.requiredString(statement, column: 0).lowercased() == "delete",
                      sqlite3_step(statement) == SQLITE_DONE
                else {
                    throw EluSQLiteFailure.result(SQLITE_IOERR, "Unable to seal staged database")
                }
            }
        } catch {
            try? connection.execute("ROLLBACK")
            connection.close()
            throw error
        }
        connection.close()
        try synchronizeFile(stagedURL)
        try faultInjector?.hit(.beforeInitialInstall)
        try fileManager.moveItem(at: stagedURL, to: databaseURL)
        installed = true
        try EluDarwinDirectorySynchronizer().synchronize(
            directoryURL: databaseURL.deletingLastPathComponent()
        )
        try faultInjector?.hit(.afterInitialInstall)
    }

    private static func synchronizeFile(_ url: URL) throws {
        let descriptor = url.path.withCString { path in Darwin.open(path, O_RDONLY) }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func removeDatabaseFamily(at databaseURL: URL) {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fileManager.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
    }

    private static func configureDurability(
        _ connection: EluSQLiteConnection,
        initializing: Bool
    ) throws {
        if initializing {
            try connection.execute("PRAGMA auto_vacuum=INCREMENTAL")
        }
        try connection.withStatement("PRAGMA journal_mode=WAL") { statement in
            try connection.step(statement, expecting: SQLITE_ROW)
            guard try connection.requiredString(statement, column: 0).lowercased() == "wal",
                  sqlite3_step(statement) == SQLITE_DONE
            else {
                throw EluSQLiteFailure.result(SQLITE_CANTOPEN, "WAL mode unavailable")
            }
        }
        try connection.execute("PRAGMA synchronous=FULL")
        guard try connection.integerPragma("synchronous") == 2 else {
            throw EluSQLiteFailure.result(SQLITE_IOERR, "FULL synchronization unavailable")
        }
        try connection.execute("PRAGMA foreign_keys=ON")
    }

    private static func loadLegacyOrFreshState(
        directoryURL: URL,
        clock: @Sendable () -> Date,
        anonymousIdGenerator: @Sendable () -> String,
        streamIdGenerator: @Sendable () -> String
    ) throws -> EluStoredRuntimeState {
        let legacyStore = try EluFileIdentityStateStore(directoryURL: directoryURL)
        switch try legacyStore.load() {
        case let .loaded(state):
            return try storedState(from: state)
        case .missing:
            return try freshState(
                now: clock(),
                anonymousId: anonymousIdGenerator(),
                streamId: streamIdGenerator(),
                forceOptOut: false
            )
        case let .recoverable(recoverable):
            var identity: EluIdentityState
            if let recoveredIdentity = recoverable.identity {
                identity = recoveredIdentity
            } else {
                identity = try freshIdentity(
                    now: clock(),
                    anonymousId: anonymousIdGenerator(),
                    forceOptOut: recoverable.forceOptOut
                )
            }
            let optChanged = recoverable.forceOptOut && !identity.optedOut
            let flagContextWasCleared = recoverable.flagContext == nil
            if recoverable.forceOptOut {
                identity.optedOut = true
                identity.session = nil
            }
            if optChanged || flagContextWasCleared {
                guard identity.contextRevision < Int64.max else {
                    throw EluRuntimeQueueError.counterExhausted
                }
                identity.contextRevision += 1
            }
            let stream: EluStreamMetadata
            if let recoveredStream = recoverable.streamMetadata {
                stream = recoveredStream
            } else {
                stream = try EluStreamMetadata(streamId: streamIdGenerator())
            }
            let flagContext: EluPersistedFlagContext
            if let recoveredFlagContext = recoverable.flagContext {
                flagContext = recoveredFlagContext
            } else {
                flagContext = try EluPersistedFlagContext()
            }
            return try storedState(
                from: EluPersistedState(
                    identity: identity,
                    streamMetadata: stream,
                    flagContext: flagContext
                )
            )
        }
    }

    private static func normalizeLegacyOptedOutSession(
        _ state: EluStoredRuntimeState
    ) -> EluStoredRuntimeState {
        guard state.identity.optedOut, state.identity.session != nil else { return state }
        var normalized = state
        normalized.identity.session = nil
        return normalized
    }

    private static func normalizeLegacyOptedOutSession(
        connection: EluSQLiteConnection,
        state: EluStoredRuntimeState
    ) throws -> EluStoredRuntimeState {
        guard state.identity.optedOut, state.identity.session != nil else { return state }
        guard state.generation < Int64.max else {
            throw EluRuntimeQueueError.counterExhausted
        }
        try connection.execute("BEGIN IMMEDIATE")
        do {
            let diskState = try EluRuntimeDatabase.loadState(connection, validateQueue: false)
            guard diskState == state else {
                throw EluRuntimeQueueError.generationMismatch
            }
            var identity = diskState.identity
            identity.session = nil
            let normalized = EluStoredRuntimeState(
                generation: diskState.generation + 1,
                identity: identity,
                flagContext: diskState.flagContext,
                streamId: diskState.streamId,
                nextSequence: diskState.nextSequence,
                headSequence: diskState.headSequence,
                liveCount: diskState.liveCount,
                liveBytes: diskState.liveBytes
            )
            try EluRuntimeDatabase.updateState(
                connection,
                from: diskState.generation,
                to: normalized
            )
            try connection.execute("COMMIT")
            return normalized
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private static func freshState(
        now: Date,
        anonymousId: String,
        streamId: String,
        forceOptOut: Bool
    ) throws -> EluStoredRuntimeState {
        try storedState(
            from: EluPersistedState(
                identity: freshIdentity(
                    now: now,
                    anonymousId: anonymousId,
                    forceOptOut: forceOptOut
                ),
                streamMetadata: EluStreamMetadata(streamId: streamId),
                flagContext: EluPersistedFlagContext()
            )
        )
    }

    private static func freshIdentity(
        now: Date,
        anonymousId: String,
        forceOptOut: Bool
    ) throws -> EluIdentityState {
        try EluIdentityState(
            revision: 0,
            contextRevision: 0,
            anonymousId: anonymousId,
            userId: nil,
            groups: [:],
            superProperties: [:],
            session: nil,
            optedOut: forceOptOut,
            updatedAt: now
        )
    }

    private static func storedState(from state: EluPersistedState) throws
        -> EluStoredRuntimeState
    {
        let canonicalState = try EluRuntimeCanonical.value(state)
        try canonicalState.validate()
        guard canonicalState.identity.contextRevision >= canonicalState.identity.revision else {
            throw EluRuntimeQueueError.invalidState
        }
        return EluStoredRuntimeState(
            generation: 0,
            identity: canonicalState.identity,
            flagContext: canonicalState.flagContext,
            streamId: canonicalState.streamMetadata.streamId,
            nextSequence: canonicalState.streamMetadata.nextSequence,
            headSequence: nil,
            liveCount: 0,
            liveBytes: 0
        )
    }

    private static func mapOpenError(_ error: Error) -> EluRuntimeQueueError {
        if let error = error as? EluRuntimeQueueError {
            return error
        }
        if let identityError = error as? EluIdentityStateError,
           identityError == .unsupportedSchemaVersion
        {
            return .unsupportedSchemaVersion(-1)
        }
        if error is EluIdentityStateStoreError {
            return .corruptStorage
        }
        if error is EluQueueRecordValidationError || error is DecodingError {
            return .corruptStorage
        }
        if let sqliteError = error as? EluSQLiteFailure {
            if case let .result(code, _) = sqliteError {
                switch code & 0xFF {
                case SQLITE_BUSY, SQLITE_LOCKED, SQLITE_CANTOPEN, SQLITE_PERM,
                     SQLITE_READONLY, SQLITE_IOERR, SQLITE_FULL:
                    return .databaseUnavailable
                default:
                    return .corruptStorage
                }
            }
        }
        return .databaseUnavailable
    }
}

private struct EluStoredFlagAuthorityRow: Sendable {
    let storageSchema: Int64
    let initialized: Bool
    let body: Data
}

private struct EluStoredFlagRequestRow: Sendable {
    let storageSchema: Int64
    let declaredBodyBytes: Int64
    let bodySha256: String
    let chunkCount: Int64
    let metadataBody: Data
}

private enum EluRuntimeDatabase {
    static func insertUninitializedFlagAuthority(
        _ connection: EluSQLiteConnection,
        exactConstructorSiteKey: String,
        siteNamespaceDigest: String
    ) throws {
        let body = try EluV1FlagStorageCodec.encodeAuthority(
            .uninitialized(
                exactConstructorSiteKey: exactConstructorSiteKey,
                siteNamespaceDigest: siteNamespaceDigest
            )
        )
        try connection.withStatement(
            """
            INSERT INTO flag_cache_records (
                record_type, record_index, storage_schema, initialized,
                declared_body_bytes, body_sha256, chunk_count, body
            ) VALUES ('authority', 0, 1, 0, NULL, NULL, NULL, ?)
            """
        ) { statement in
            try connection.bind(body, at: 1, to: statement)
            try connection.step(statement)
        }
    }

    static func readFlagAuthority(
        _ connection: EluSQLiteConnection
    ) throws -> EluStoredFlagAuthorityRow {
        try connection.withStatement(
            """
            SELECT storage_schema, initialized, body
            FROM flag_cache_records
            WHERE record_type = 'authority' AND record_index = 0
            """
        ) { statement in
            let first = sqlite3_step(statement)
            if first == SQLITE_DONE {
                throw EluRuntimeQueueError.flagAuthorityTerminal
            }
            guard first == SQLITE_ROW else {
                throw EluSQLiteFailure.result(first, "Unable to read flag authority")
            }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
                throw EluRuntimeQueueError.flagAuthorityTerminal
            }
            let storageSchema = sqlite3_column_int64(statement, 0)
            if storageSchema != 1 {
                let trailing = sqlite3_step(statement)
                guard trailing == SQLITE_DONE else {
                    if trailing == SQLITE_ROW {
                        throw EluRuntimeQueueError.flagAuthorityTerminal
                    }
                    throw EluSQLiteFailure.result(
                        trailing,
                        "Unable to finish reading future flag authority"
                    )
                }
                return EluStoredFlagAuthorityRow(
                    storageSchema: storageSchema,
                    initialized: false,
                    body: Data()
                )
            }
            guard sqlite3_column_type(statement, 1) == SQLITE_INTEGER else {
                throw EluRuntimeQueueError.flagAuthorityTerminal
            }
            let initializedRaw = sqlite3_column_int64(statement, 1)
            guard initializedRaw == 0 || initializedRaw == 1 else {
                throw EluRuntimeQueueError.flagAuthorityTerminal
            }
            guard sqlite3_column_type(statement, 2) == SQLITE_BLOB else {
                throw EluRuntimeQueueError.flagAuthorityTerminal
            }
            let bodyBytes = Int(sqlite3_column_bytes(statement, 2))
            guard bodyBytes > 0,
                  bodyBytes <= EluV1FlagStorageCodec.maximumMetadataBytes,
                  let bytes = sqlite3_column_blob(statement, 2)
            else {
                throw EluRuntimeQueueError.flagAuthorityTerminal
            }
            let body = Data(bytes: bytes, count: bodyBytes)
            let trailing = sqlite3_step(statement)
            if trailing == SQLITE_ROW {
                throw EluRuntimeQueueError.flagAuthorityTerminal
            }
            guard trailing == SQLITE_DONE else {
                throw EluSQLiteFailure.result(
                    trailing,
                    "Unable to finish reading flag authority"
                )
            }
            return EluStoredFlagAuthorityRow(
                storageSchema: storageSchema,
                initialized: initializedRaw == 1,
                body: body
            )
        }
    }

    static func updateFlagAuthority(
        _ connection: EluSQLiteConnection,
        value: EluV1FlagDurableAuthority
    ) throws {
        let body = try EluV1FlagStorageCodec.encodeAuthority(value)
        try connection.withStatement(
            """
            UPDATE flag_cache_records
            SET storage_schema = 1, initialized = ?, body = ?
            WHERE record_type = 'authority' AND record_index = 0
            """
        ) { statement in
            try connection.bind(value.initialized ? 1 : 0, at: 1, to: statement)
            try connection.bind(body, at: 2, to: statement)
            try connection.step(statement)
        }
        guard try connection.changes() == 1 else {
            throw EluRuntimeQueueError.corruptStorage
        }
    }

    static func readFlagRequest(
        _ connection: EluSQLiteConnection
    ) throws -> EluStoredFlagRequestRow? {
        try connection.withStatement(
            """
            SELECT storage_schema, declared_body_bytes, length(body_sha256),
                   body_sha256, chunk_count, body
            FROM flag_cache_records
            WHERE record_type = 'request' AND record_index = 0
            """
        ) { statement in
            let first = sqlite3_step(statement)
            if first == SQLITE_DONE { return nil }
            guard first == SQLITE_ROW else {
                throw EluSQLiteFailure.result(first, "Unable to read flag request state")
            }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
                throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
            }
            let storageSchema = sqlite3_column_int64(statement, 0)
            if storageSchema != 1 {
                let trailing = sqlite3_step(statement)
                if trailing == SQLITE_ROW {
                    throw EluRuntimeQueueError.unsupportedSchemaVersion(storageSchema)
                }
                guard trailing == SQLITE_DONE else {
                    throw EluSQLiteFailure.result(
                        trailing,
                        "Unable to finish reading future flag request state"
                    )
                }
                // Future metadata is classified from its fixed header without
                // materializing its body or unbounded text fields.
                return EluStoredFlagRequestRow(
                    storageSchema: storageSchema,
                    declaredBodyBytes: 0,
                    bodySha256: "",
                    chunkCount: 0,
                    metadataBody: Data()
                )
            }
            guard sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 3) == SQLITE_TEXT,
                  sqlite3_column_type(statement, 4) == SQLITE_INTEGER
            else {
                // The physical-v1 header is not sufficiently typed to prove
                // ownership of any referenced inner body.
                throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
            }
            let declaredBodyBytes = sqlite3_column_int64(statement, 1)
            let hashLength = sqlite3_column_int64(statement, 2)
            guard hashLength >= 0,
                  hashLength <= 1_024,
                  let hashText = sqlite3_column_text(statement, 3)
            else {
                // Inner future envelopes own their digest representation. A
                // resource-heavy or non-text header is opaque, not v1-corrupt.
                throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
            }
            let chunkCount = sqlite3_column_int64(statement, 4)
            guard sqlite3_column_type(statement, 5) == SQLITE_BLOB else {
                throw EluRuntimeQueueError.corruptStorage
            }
            let metadataBytes = Int(sqlite3_column_bytes(statement, 5))
            guard metadataBytes >= 0,
                  metadataBytes <= EluV1FlagStorageCodec.maximumMetadataBytes
            else {
                throw EluRuntimeQueueError.corruptStorage
            }
            let metadataBody: Data
            if metadataBytes == 0 {
                metadataBody = Data()
            } else {
                guard let metadata = sqlite3_column_blob(statement, 5) else {
                    throw EluRuntimeQueueError.corruptStorage
                }
                metadataBody = Data(bytes: metadata, count: metadataBytes)
            }
            let row = EluStoredFlagRequestRow(
                storageSchema: storageSchema,
                declaredBodyBytes: declaredBodyBytes,
                bodySha256: String(cString: hashText),
                chunkCount: chunkCount,
                metadataBody: metadataBody
            )
            let trailing = sqlite3_step(statement)
            if trailing == SQLITE_ROW {
                throw EluRuntimeQueueError.corruptStorage
            }
            guard trailing == SQLITE_DONE else {
                throw EluSQLiteFailure.result(
                    trailing,
                    "Unable to finish reading flag request state"
                )
            }
            return row
        }
    }

    static func replaceFlagRequest(
        _ connection: EluSQLiteConnection,
        state: EluV1FlagRequestCacheState,
        cacheBody: Data?
    ) throws {
        let metadata = try EluV1FlagStorageCodec.encodeRequestState(state)
        let body = cacheBody ?? Data()
        guard body.count <= EluV1FlagJSON.maximumCacheBytes else {
            throw EluV1FlagContractError.cacheTooLarge
        }
        let chunks = body.isEmpty ? [] : stride(
            from: 0,
            to: body.count,
            by: EluV1FlagJSON.maximumWireBytes
        ).map { offset in
            body.subdata(
                in: offset ..< min(offset + EluV1FlagJSON.maximumWireBytes, body.count)
            )
        }
        let digest = body.isEmpty ? "" : EluV1FlagJSON.hash(body)
        try connection.execute("DELETE FROM flag_cache_records WHERE record_type = 'chunk'")
        try connection.execute("DELETE FROM flag_cache_records WHERE record_type = 'request'")
        try connection.withStatement(
            """
            INSERT INTO flag_cache_records (
                record_type, record_index, storage_schema, initialized,
                declared_body_bytes, body_sha256, chunk_count, body
            ) VALUES ('request', 0, 1, 1, ?, ?, ?, ?)
            """
        ) { statement in
            try connection.bind(Int64(body.count), at: 1, to: statement)
            try connection.bind(digest, at: 2, to: statement)
            try connection.bind(Int64(chunks.count), at: 3, to: statement)
            try connection.bind(metadata, at: 4, to: statement)
            try connection.step(statement)
        }
        for (index, chunk) in chunks.enumerated() {
            try connection.withStatement(
                """
                INSERT INTO flag_cache_records (
                    record_type, record_index, storage_schema, initialized,
                    declared_body_bytes, body_sha256, chunk_count, body
                ) VALUES ('chunk', ?, 1, 1, NULL, NULL, NULL, ?)
                """
            ) { statement in
                try connection.bind(Int64(index), at: 1, to: statement)
                try connection.bind(chunk, at: 2, to: statement)
                try connection.step(statement)
            }
        }
    }

    /// Constant-memory lexical preclassifier for an oversized chunked cache.
    /// It recognizes only an unambiguous top-level integer schemaVersion and
    /// never applies the v1 AST/string/node limits to unknown future content.
    private struct FlagFutureSchemaScanner {
        enum Classification: Equatable {
            case current
            case future
            case opaque
        }

        private enum Phase {
            case root
            case key
            case colon
            case value
            case primitive
            case nested
            case afterValue
            case done
            case invalid
        }

        private static let maximumNesting = 4_096
        private static let maximumCapturedKeyBytes = 1_024
        private static let maximumSchemaTokenBytes = 32

        private var phase: Phase = .root
        private var stack: [UInt8] = []
        private var inString = false
        private var escaped = false
        private var unicodeDigitsRemaining = 0
        private var capturingKey = false
        private var capturedKey = Data()
        private var currentKeyIsSchema = false
        private var schemaToken = Data()
        private var sawSchema = false
        private var resourceExhausted = false
        private var schemaVersion: Int64?

        mutating func update(_ data: Data) {
            for byte in data where phase != .invalid {
                consume(byte)
            }
        }

        mutating func finish() -> Classification {
            if phase == .primitive { finishPrimitive(delimiter: nil) }
            guard !resourceExhausted,
                  phase == .done,
                  !inString,
                  unicodeDigitsRemaining == 0,
                  let schemaVersion
            else {
                return .opaque
            }
            return schemaVersion == Int64(EluV1FlagRequestCacheState.storageSchema)
                ? .current
                : .future
        }

        private mutating func consume(_ byte: UInt8) {
            if phase == .done {
                if !Self.isWhitespace(byte) { phase = .invalid }
                return
            }
            if inString {
                consumeStringByte(byte)
                return
            }

            switch phase {
            case .root:
                guard Self.isWhitespace(byte) || byte == 0x7B else {
                    phase = .invalid
                    return
                }
                if byte == 0x7B {
                    stack = [0x7D]
                    phase = .key
                }

            case .key:
                if Self.isWhitespace(byte) { return }
                if byte == 0x7D {
                    guard stack == [0x7D] else { phase = .invalid; return }
                    stack.removeAll(keepingCapacity: false)
                    phase = .done
                } else if byte == 0x22 {
                    beginString(capturingKey: true)
                } else {
                    phase = .invalid
                }

            case .colon:
                if Self.isWhitespace(byte) { return }
                phase = byte == 0x3A ? .value : .invalid

            case .value:
                if Self.isWhitespace(byte) { return }
                if byte == 0x22 {
                    guard !currentKeyIsSchema else { phase = .invalid; return }
                    beginString(capturingKey: false)
                } else if byte == 0x7B || byte == 0x5B {
                    guard !currentKeyIsSchema else { phase = .invalid; return }
                    push(byte == 0x7B ? 0x7D : 0x5D)
                    if phase != .invalid { phase = .nested }
                } else {
                    phase = .primitive
                    consumePrimitiveByte(byte)
                }

            case .primitive:
                consumePrimitiveByte(byte)

            case .nested:
                if byte == 0x22 {
                    beginString(capturingKey: false)
                } else if byte == 0x7B || byte == 0x5B {
                    push(byte == 0x7B ? 0x7D : 0x5D)
                } else if byte == 0x7D || byte == 0x5D {
                    guard stack.last == byte else { phase = .invalid; return }
                    stack.removeLast()
                    if stack.count == 1 { phase = .afterValue }
                }

            case .afterValue:
                if Self.isWhitespace(byte) { return }
                if byte == 0x2C {
                    currentKeyIsSchema = false
                    phase = .key
                } else if byte == 0x7D, stack == [0x7D] {
                    stack.removeAll(keepingCapacity: false)
                    phase = .done
                } else {
                    phase = .invalid
                }

            case .done, .invalid:
                break
            }
        }

        private mutating func beginString(capturingKey: Bool) {
            inString = true
            escaped = false
            unicodeDigitsRemaining = 0
            self.capturingKey = capturingKey
            if capturingKey {
                capturedKey = Data([0x22])
            }
        }

        private mutating func consumeStringByte(_ byte: UInt8) {
            if capturingKey,
               capturedKey.count < Self.maximumCapturedKeyBytes
            {
                capturedKey.append(byte)
            } else if capturingKey {
                resourceExhausted = true
            }
            if unicodeDigitsRemaining > 0 {
                guard Self.isHex(byte) else { phase = .invalid; return }
                unicodeDigitsRemaining -= 1
                return
            }
            if escaped {
                escaped = false
                if byte == 0x75 {
                    unicodeDigitsRemaining = 4
                } else if ![0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(byte) {
                    phase = .invalid
                }
                return
            }
            if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                inString = false
                if capturingKey {
                    currentKeyIsSchema = (try? JSONDecoder().decode(
                        String.self,
                        from: capturedKey
                    )) == "schemaVersion"
                    phase = .colon
                } else if stack.count == 1 {
                    phase = .afterValue
                }
                capturingKey = false
            } else if byte < 0x20 {
                phase = .invalid
            }
        }

        private mutating func consumePrimitiveByte(_ byte: UInt8) {
            if Self.isWhitespace(byte) || byte == 0x2C || byte == 0x7D {
                finishPrimitive(delimiter: byte)
                return
            }
            if currentKeyIsSchema {
                guard schemaToken.count < Self.maximumSchemaTokenBytes else {
                    resourceExhausted = true
                    phase = .invalid
                    return
                }
                schemaToken.append(byte)
            }
        }

        private mutating func finishPrimitive(delimiter: UInt8?) {
            if currentKeyIsSchema {
                guard !sawSchema,
                      let token = String(data: schemaToken, encoding: .utf8),
                      let value = Double(token),
                      value.isFinite,
                      value.rounded(.towardZero) == value,
                      abs(value) <= EluV1FlagJSON.maximumSafeInteger,
                      let version = Int64(exactly: value),
                      (1 ... 9_007_199_254_740_991).contains(version)
                else {
                    phase = .invalid
                    return
                }
                sawSchema = true
                schemaVersion = version
                schemaToken.removeAll(keepingCapacity: false)
            }
            phase = .afterValue
            guard let delimiter else { return }
            if Self.isWhitespace(delimiter) { return }
            consume(delimiter)
        }

        private mutating func push(_ closing: UInt8) {
            guard stack.count < Self.maximumNesting else {
                resourceExhausted = true
                phase = .invalid
                return
            }
            stack.append(closing)
        }

        private static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        private static func isHex(_ byte: UInt8) -> Bool {
            (0x30 ... 0x39).contains(byte)
                || (0x41 ... 0x46).contains(byte)
                || (0x61 ... 0x66).contains(byte)
        }
    }

    static func readFlagCacheBody(
        _ connection: EluSQLiteConnection,
        row: EluStoredFlagRequestRow
    ) throws -> Data? {
        guard row.storageSchema == 1 else { throw EluRuntimeQueueError.unsupportedSchemaVersion(row.storageSchema) }
        let maximumFutureProbeBytes = Int64(EluRuntimeQueueLimits.defaultMaximumBytes)
        let maximumFutureChunks = maximumFutureProbeBytes
            / Int64(EluV1FlagJSON.maximumWireBytes)
        guard row.declaredBodyBytes >= 0,
              row.declaredBodyBytes <= maximumFutureProbeBytes,
              row.chunkCount >= 0,
              row.chunkCount <= maximumFutureChunks
        else {
            // A header outside the bounded probe cannot be proven to be a
            // current-v1 body. Preserve it as opaque/future instead of using
            // the current-schema corruption rotation path.
            throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
        }
        if row.declaredBodyBytes == 0 {
            guard row.chunkCount == 0, row.bodySha256.isEmpty else {
                // A lying zero-length header cannot prove that referenced
                // chunks are current-v1. Preserve the opaque record.
                throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
            }
            let physicalChunks = try flagCacheChunkInventory(
                connection,
                maximumRows: maximumFutureChunks
            )
            guard physicalChunks == 0 else {
                throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
            }
            return nil
        }
        guard row.chunkCount > 0 else {
            throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
        }
        // Every physical chunk row participates in storage ownership, even
        // when a stale current-v1 header does not reference it. Prove all
        // fixed headers are current before any count mismatch can enter the
        // v1 corruption/rotation path. A table too large to inspect within
        // the bounded future probe remains opaque and byte-preserved.
        let chunkRows = try flagCacheChunkInventory(
            connection,
            maximumRows: maximumFutureChunks
        )
        let isCurrentV1Envelope = row.declaredBodyBytes <= Int64(EluV1FlagJSON.maximumCacheBytes)
            && row.chunkCount <= 4
        var result = Data()
        if isCurrentV1Envelope {
            result.reserveCapacity(Int(row.declaredBodyBytes))
        }
        var scanner = FlagFutureSchemaScanner()
        var hasher = SHA256()
        var observedBytes: Int64 = 0
        for index in 0 ..< row.chunkCount {
            let chunk = try connection.withStatement(
                """
                SELECT storage_schema, body FROM flag_cache_records
                WHERE record_type = 'chunk' AND record_index = ?
                """
            ) { statement -> Data in
                try connection.bind(index, at: 1, to: statement)
                let first = sqlite3_step(statement)
                if first == SQLITE_DONE {
                    throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
                }
                guard first == SQLITE_ROW else {
                    throw EluSQLiteFailure.result(first, "Unable to read flag cache chunk")
                }
                guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
                    throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
                }
                let chunkSchema = sqlite3_column_int64(statement, 0)
                guard chunkSchema == 1 else {
                    throw EluRuntimeQueueError.unsupportedSchemaVersion(chunkSchema)
                }
                guard sqlite3_column_type(statement, 1) == SQLITE_BLOB else {
                    throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
                }
                let byteCount = Int(sqlite3_column_bytes(statement, 1))
                guard byteCount > 0,
                      byteCount <= EluV1FlagJSON.maximumWireBytes,
                      let bytes = sqlite3_column_blob(statement, 1)
                else {
                    throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
                }
                let body = Data(bytes: bytes, count: byteCount)
                let trailing = sqlite3_step(statement)
                if trailing == SQLITE_ROW {
                    throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
                }
                guard trailing == SQLITE_DONE else {
                    throw EluSQLiteFailure.result(
                        trailing,
                        "Unable to finish reading flag cache chunk"
                    )
                }
                return body
            }
            guard observedBytes <= maximumFutureProbeBytes - Int64(chunk.count) else {
                throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
            }
            observedBytes += Int64(chunk.count)
            scanner.update(chunk)
            hasher.update(data: chunk)
            if isCurrentV1Envelope {
                result.append(chunk)
            }
        }
        let observedHash = "sha256:"
            + hasher.finalize().map { String(format: "%02x", $0) }.joined()

        var classification = scanner.finish()
        if classification == .opaque, isCurrentV1Envelope {
            if let parsedVersion = flagCacheSchemaVersion(result) {
                classification = parsedVersion
                    == Int64(EluV1FlagRequestCacheState.storageSchema)
                    ? .current
                    : .future
            }
        }
        // A complete lexical future discriminator owns its integrity rules;
        // a stale v1 digest cannot turn future bytes into current corruption.
        if classification == .future {
            throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
        }
        guard classification == .current else {
            // Scanner ambiguity or resource exhaustion on an oversized body
            // is fail-closed and byte-preserving.
            throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
        }
        guard isCurrentV1Envelope else {
            // An explicitly current body is now owned by v1; exceeding its
            // frozen size/chunk budget is quarantinable current corruption.
            throw EluRuntimeQueueError.corruptStorage
        }
        guard chunkRows == row.chunkCount,
              observedBytes == row.declaredBodyBytes,
              observedHash == row.bodySha256
        else {
            throw EluRuntimeQueueError.corruptStorage
        }
        return result
    }

    private static func flagCacheChunkInventory(
        _ connection: EluSQLiteConnection,
        maximumRows: Int64
    ) throws -> Int64 {
        guard maximumRows >= 0 else {
            throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
        }
        return try connection.withStatement(
            "SELECT storage_schema FROM flag_cache_records "
                + "WHERE record_type = 'chunk' ORDER BY record_index"
        ) { statement -> Int64 in
            var count: Int64 = 0
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return count }
                guard step == SQLITE_ROW else {
                    throw EluSQLiteFailure.result(
                        step,
                        "Unable to inventory flag cache chunks"
                    )
                }
                guard count < maximumRows,
                      sqlite3_column_type(statement, 0) == SQLITE_INTEGER
                else {
                    throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
                }
                let storageSchema = sqlite3_column_int64(statement, 0)
                guard storageSchema == 1 else {
                    throw EluRuntimeQueueError.unsupportedSchemaVersion(storageSchema)
                }
                count += 1
            }
        }
    }

    private static func flagCacheSchemaVersion(_ body: Data) -> Int64? {
        do {
            let document = try EluV1StrictCanonicalJSON.parse(body)
            guard case let .number(token)? = try document.objectProperty("schemaVersion")
            else {
                return nil
            }
            guard let value = Double(token),
                  value.isFinite,
                  value.rounded(.towardZero) == value,
                  abs(value) <= EluV1FlagJSON.maximumSafeInteger
            else {
                return nil
            }
            return Int64(exactly: value)
        } catch {
            return nil
        }
    }
    static func schemaObjects(_ connection: EluSQLiteConnection) throws -> [String: String] {
        try connection.withStatement(
            "SELECT name, type FROM sqlite_master "
                + "WHERE name NOT LIKE 'sqlite_%' ORDER BY name"
        ) { statement in
            var objects: [String: String] = [:]
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    return objects
                }
                guard result == SQLITE_ROW else {
                    throw EluSQLiteFailure.result(result, "Unable to inspect SQLite schema")
                }
                let name = try connection.requiredString(statement, column: 0)
                let type = try connection.requiredString(statement, column: 1)
                guard objects[name] == nil else {
                    throw EluRuntimeQueueError.corruptStorage
                }
                objects[name] = type
            }
        }
    }

    static func verifySchema(
        _ connection: EluSQLiteConnection,
        databaseVersion: Int64
    ) throws {
        var expectedObjects = [
            "queue_records": "table",
            "runtime_state": "table",
        ]
        if databaseVersion == EluSQLiteRuntimeSchema.flagDatabaseVersion {
            expectedObjects["flag_cache_records"] = "table"
        }
        guard try schemaObjects(connection) == expectedObjects else {
            throw EluRuntimeQueueError.corruptStorage
        }
        try verifyColumns(
            connection,
            table: "runtime_state",
            expected: EluSQLiteRuntimeSchema.runtimeStateColumns
        )
        try verifyColumns(
            connection,
            table: "queue_records",
            expected: EluSQLiteRuntimeSchema.queueRecordColumns
        )
        try verifyCreateSQL(
            connection,
            table: "runtime_state",
            expected: EluSQLiteRuntimeSchema.createRuntimeState
        )
        try verifyCreateSQL(
            connection,
            table: "queue_records",
            expected: EluSQLiteRuntimeSchema.createQueueRecords
        )
        if databaseVersion == EluSQLiteRuntimeSchema.flagDatabaseVersion {
            try verifyColumns(
                connection,
                table: "flag_cache_records",
                expected: EluSQLiteRuntimeSchema.flagCacheRecordColumns
            )
            try verifyCreateSQL(
                connection,
                table: "flag_cache_records",
                expected: EluSQLiteRuntimeSchema.createFlagCacheRecords
            )
        }
    }

    static func insertInitialState(
        _ connection: EluSQLiteConnection,
        state: EluStoredRuntimeState
    ) throws {
        let identityData = try encodeStateValue(state.identity)
        let flagContextData = try encodeStateValue(state.flagContext)
        try connection.withStatement(
            """
            INSERT INTO runtime_state (
                singleton, schema_version, generation, identity_json,
                flag_context_json, stream_id, next_sequence, head_sequence,
                live_count, live_bytes
            ) VALUES (1, 1, ?, ?, ?, ?, ?, NULL, 0, 0)
            """
        ) { statement in
            try connection.bind(state.generation, at: 1, to: statement)
            try connection.bind(identityData, at: 2, to: statement)
            try connection.bind(flagContextData, at: 3, to: statement)
            try connection.bind(state.streamId, at: 4, to: statement)
            try connection.bind(state.nextSequence, at: 5, to: statement)
            try connection.step(statement)
        }
    }

    static func loadState(
        _ connection: EluSQLiteConnection,
        validateQueue: Bool
    ) throws -> EluStoredRuntimeState {
        let state = try connection.withStatement(
            """
            SELECT singleton, schema_version, generation, identity_json, flag_context_json,
                   stream_id, next_sequence, head_sequence, live_count, live_bytes
            FROM runtime_state
            """
        ) { statement in
            try connection.step(statement, expecting: SQLITE_ROW)
            guard try connection.requiredInteger(statement, column: 0) == 1 else {
                throw EluRuntimeQueueError.corruptStorage
            }
            let schemaVersion = try connection.requiredInteger(statement, column: 1)
            guard schemaVersion == EluSQLiteRuntimeSchema.runtimeStateVersion else {
                throw EluRuntimeQueueError.unsupportedSchemaVersion(schemaVersion)
            }
            let generation = try connection.requiredInteger(statement, column: 2)
            let identityData = try connection.requiredData(
                statement,
                column: 3,
                maximumBytes: EluSQLiteRuntimeSchema.maximumStateBytes
            )
            let flagContextData = try connection.requiredData(
                statement,
                column: 4,
                maximumBytes: EluSQLiteRuntimeSchema.maximumStateBytes
            )
            let streamId = try connection.requiredString(statement, column: 5)
            let nextSequence = try connection.requiredInteger(statement, column: 6)
            let headSequence = try connection.optionalInteger(statement, column: 7)
            let liveCount = try connection.requiredInteger(statement, column: 8)
            let liveBytes = try connection.requiredInteger(statement, column: 9)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw EluRuntimeQueueError.corruptStorage
            }

            let identity: EluIdentityState = try decodeStateValue(
                EluIdentityState.self,
                data: identityData
            )
            let flagContext: EluPersistedFlagContext = try decodeStateValue(
                EluPersistedFlagContext.self,
                data: flagContextData
            )
            let state = EluStoredRuntimeState(
                generation: generation,
                identity: identity,
                flagContext: flagContext,
                streamId: streamId,
                nextSequence: nextSequence,
                headSequence: headSequence,
                liveCount: liveCount,
                liveBytes: liveBytes
            )
            try validateStateShape(state)
            return state
        }

        if validateQueue {
            try validateQueueRows(connection, state: state)
        }
        return state
    }

    static func readPrefix(
        _ connection: EluSQLiteConnection,
        maximumCount: Int,
        streamId: String
    ) throws -> [EluStoredQueueRecord] {
        try connection.withStatement(
            """
            SELECT sequence, kind, record_id, occurred_at, payload,
                   capture_versions, accounted_bytes
            FROM queue_records ORDER BY sequence ASC LIMIT ?
            """
        ) { statement in
            try connection.bind(Int64(maximumCount), at: 1, to: statement)
            var records: [EluStoredQueueRecord] = []
            records.reserveCapacity(maximumCount)
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    return records
                }
                guard result == SQLITE_ROW else {
                    throw EluSQLiteFailure.result(result, "Unable to read queue prefix")
                }
                records.append(
                    try decodeQueueRow(
                        connection,
                        statement: statement,
                        streamId: streamId
                    )
                )
            }
        }
    }

    static func insert(
        _ connection: EluSQLiteConnection,
        storedRecord: EluStoredQueueRecord
    ) throws {
        try connection.withStatement(
            """
            INSERT INTO queue_records (
                sequence, kind, record_id, occurred_at, payload,
                capture_versions, accounted_bytes
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        ) { statement in
            try connection.bind(storedRecord.record.sequence, at: 1, to: statement)
            try connection.bind(storedRecord.record.kind.rawValue, at: 2, to: statement)
            try connection.bind(storedRecord.record.recordId, at: 3, to: statement)
            try connection.bind(
                EluRFC3339.string(from: storedRecord.record.occurredAt),
                at: 4,
                to: statement
            )
            try connection.bind(storedRecord.payload, at: 5, to: statement)
            try connection.bind(storedRecord.versionsPayload, at: 6, to: statement)
            try connection.bind(storedRecord.accountedBytes, at: 7, to: statement)
            try connection.step(statement)
        }
    }

    static func updateState(
        _ connection: EluSQLiteConnection,
        from expectedGeneration: Int64,
        to state: EluStoredRuntimeState
    ) throws {
        let identityData = try encodeStateValue(state.identity)
        let flagContextData = try encodeStateValue(state.flagContext)
        try connection.withStatement(
            """
            UPDATE runtime_state
            SET generation = ?, identity_json = ?, flag_context_json = ?,
                stream_id = ?, next_sequence = ?, head_sequence = ?,
                live_count = ?, live_bytes = ?
            WHERE singleton = 1 AND generation = ?
            """
        ) { statement in
            try connection.bind(state.generation, at: 1, to: statement)
            try connection.bind(identityData, at: 2, to: statement)
            try connection.bind(flagContextData, at: 3, to: statement)
            try connection.bind(state.streamId, at: 4, to: statement)
            try connection.bind(state.nextSequence, at: 5, to: statement)
            if let headSequence = state.headSequence {
                try connection.bind(headSequence, at: 6, to: statement)
            } else {
                try connection.bindNull(at: 6, to: statement)
            }
            try connection.bind(state.liveCount, at: 7, to: statement)
            try connection.bind(state.liveBytes, at: 8, to: statement)
            try connection.bind(expectedGeneration, at: 9, to: statement)
            try connection.step(statement)
        }
        guard try connection.changes() == 1 else {
            throw EluRuntimeQueueError.generationMismatch
        }
    }

    static func deletePrefix(
        _ connection: EluSQLiteConnection,
        firstSequence: Int64,
        lastSequence: Int64,
        expectedCount: Int
    ) throws {
        try connection.withStatement(
            "DELETE FROM queue_records WHERE sequence >= ? AND sequence <= ?"
        ) { statement in
            try connection.bind(firstSequence, at: 1, to: statement)
            try connection.bind(lastSequence, at: 2, to: statement)
            try connection.step(statement)
        }
        guard try connection.changes() == Int32(expectedCount) else {
            throw EluRuntimeQueueError.acknowledgementMismatch
        }
    }

    private static func verifyColumns(
        _ connection: EluSQLiteConnection,
        table: String,
        expected: [String: String]
    ) throws {
        try connection.withStatement("PRAGMA table_info(\(table))") { statement in
            var actual: [String: String] = [:]
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    break
                }
                guard result == SQLITE_ROW else {
                    throw EluSQLiteFailure.result(result, "Unable to inspect table")
                }
                let name = try connection.requiredString(statement, column: 1)
                let type = try connection.requiredString(statement, column: 2).uppercased()
                guard actual[name] == nil else {
                    throw EluRuntimeQueueError.corruptStorage
                }
                actual[name] = type
            }
            guard actual == expected else {
                throw EluRuntimeQueueError.corruptStorage
            }
        }
    }

    private static func verifyCreateSQL(
        _ connection: EluSQLiteConnection,
        table: String,
        expected: String
    ) throws {
        try connection.withStatement(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?"
        ) { statement in
            try connection.bind(table, at: 1, to: statement)
            try connection.step(statement, expecting: SQLITE_ROW)
            let actual = try connection.requiredString(statement, column: 0)
            guard normalizedSQL(actual) == normalizedSQL(expected),
                  sqlite3_step(statement) == SQLITE_DONE
            else {
                throw EluRuntimeQueueError.corruptStorage
            }
        }
    }

    private static func normalizedSQL(_ sql: String) -> String {
        sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func validateStateShape(_ state: EluStoredRuntimeState) throws {
        do {
            try state.identity.validate()
            try state.flagContext.validate()
        } catch let error as EluIdentityStateError {
            if error == .unsupportedSchemaVersion {
                throw EluRuntimeQueueError.unsupportedSchemaVersion(-1)
            }
            throw EluRuntimeQueueError.corruptStorage
        }
        guard state.generation >= 0,
              state.identity.contextRevision >= state.identity.revision,
              EluIdentityState.valid(state.streamId, maximumLength: 256),
              state.nextSequence >= 0,
              state.liveCount >= 0,
              state.liveCount <= Int64(EluRuntimeQueueLimits.defaultMaximumCount),
              state.liveBytes >= 0,
              state.liveBytes <= Int64(EluRuntimeQueueLimits.defaultMaximumBytes),
              (state.liveCount == 0) == (state.headSequence == nil),
              state.headSequence.map({ $0 >= 0 && $0 < state.nextSequence }) ?? true
        else {
            throw EluRuntimeQueueError.corruptStorage
        }
    }

    private static func validateQueueRows(
        _ connection: EluSQLiteConnection,
        state: EluStoredRuntimeState
    ) throws {
        try connection.withStatement(
            """
            SELECT sequence, kind, record_id, occurred_at, payload,
                   capture_versions, accounted_bytes
            FROM queue_records ORDER BY sequence ASC
            """
        ) { statement in
            var expectedSequence = state.headSequence
            var totalCount: Int64 = 0
            var totalBytes: Int64 = 0
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let sequence = expectedSequence,
                      totalCount < state.liveCount
                else {
                    throw EluRuntimeQueueError.corruptStorage
                }
                let storedRecord = try decodeQueueRow(
                    connection,
                    statement: statement,
                    streamId: state.streamId
                )
                guard storedRecord.record.sequence == sequence else {
                    throw EluRuntimeQueueError.corruptStorage
                }
                totalBytes = try adding(totalBytes, storedRecord.accountedBytes)
                totalCount += 1
                guard sequence < Int64.max else {
                    throw EluRuntimeQueueError.corruptStorage
                }
                expectedSequence = sequence + 1
            }
            guard totalCount == state.liveCount,
                  totalBytes == state.liveBytes,
                  expectedSequence == (state.liveCount == 0 ? nil : state.nextSequence)
            else {
                throw EluRuntimeQueueError.corruptStorage
            }
        }
    }

    private static func decodeQueueRow(
        _ connection: EluSQLiteConnection,
        statement: OpaquePointer,
        streamId: String
    ) throws -> EluStoredQueueRecord {
        let sequence = try connection.requiredInteger(statement, column: 0)
        let kindValue = try connection.requiredString(statement, column: 1)
        let recordId = try connection.requiredString(statement, column: 2)
        let occurredAt = try connection.requiredString(statement, column: 3)
        let payload = try connection.requiredData(
            statement,
            column: 4,
            maximumBytes: EluSQLiteRuntimeSchema.maximumPayloadBytes
        )
        let versionsPayload = try connection.requiredData(
            statement,
            column: 5,
            maximumBytes: EluSQLiteRuntimeSchema.maximumStateBytes
        )
        let accountedBytes = try connection.requiredInteger(statement, column: 6)
        guard let kind = EluQueueRecordKind(rawValue: kindValue),
              accountedBytes > 0
        else {
            throw EluRuntimeQueueError.corruptStorage
        }
        let versions: EluVersionContext = try decodeStateValue(
            EluVersionContext.self,
            data: versionsPayload
        )
        let record: EluQueuedRecord
        do {
            record = try EluQueueRecordCodec.decode(
                kind: kind,
                data: payload,
                versions: versions
            )
        } catch {
            throw EluRuntimeQueueError.corruptStorage
        }
        guard record.sequence == sequence,
              record.recordId == recordId,
              recordId == EluRuntimeIdentifier.recordId(
                  kind: kind,
                  streamId: streamId,
                  sequence: sequence
              ),
              EluRFC3339.string(from: record.occurredAt) == occurredAt,
              try EluQueueRecordCodec.encode(record) == payload,
              try encodeStateValue(record.versions) == versionsPayload,
              Int64(try EluQueueBatchCodec.encodeRecord(record).count) == accountedBytes,
              recordBelongsToStream(record, streamId: streamId)
        else {
            throw EluRuntimeQueueError.corruptStorage
        }
        return EluStoredQueueRecord(
            record: record,
            payload: payload,
            versionsPayload: versionsPayload,
            accountedBytes: accountedBytes
        )
    }

    private static func encodeStateValue<Value: Encodable>(_ value: Value) throws -> Data {
        let data = try EluStateCoding.encoder().encode(value)
        guard !data.isEmpty, data.count <= EluSQLiteRuntimeSchema.maximumStateBytes else {
            throw EluRuntimeQueueError.invalidState
        }
        return data
    }

    private static func decodeStateValue<Value: Codable>(
        _ type: Value.Type,
        data: Data
    ) throws -> Value {
        let value: Value
        do {
            value = try EluStateCoding.decoder().decode(type, from: data)
        } catch {
            throw EluRuntimeQueueError.corruptStorage
        }
        guard try encodeStateValue(value) == data else {
            throw EluRuntimeQueueError.corruptStorage
        }
        return value
    }

    private static func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        guard rhs >= 0, lhs <= Int64.max - rhs else {
            throw EluRuntimeQueueError.corruptStorage
        }
        return lhs + rhs
    }

    private static func recordBelongsToStream(
        _ record: EluQueuedRecord,
        streamId: String
    ) -> Bool {
        if case let .event(event) = record {
            return event.streamId == streamId
        }
        return true
    }

    private static func unwrap<Value>(_ value: Value?) throws -> Value {
        guard let value else {
            throw EluRuntimeQueueError.corruptStorage
        }
        return value
    }
}

private enum EluPreparedRecordDraft: Sendable {
    case event(EluEventDraft)
    case mutation(
        change: EluMutationChange,
        identity: EluIdentityState,
        occurredAt: Date,
        versions: EluVersionContext
    )
}

struct EluV1FlagConfigDeadlineIdentity: Equatable, Sendable {
    let exactConstructorSiteKey: String
    let siteNamespaceDigest: String
    let siteId: String
    let configRevision: String
    let ordering: EluV1StoredTimestamp
    let semanticHash: String
    let endpoint: String
    let configExpiresAt: EluV1StoredTimestamp
    let barrierGeneration: Int64
    /// Diagnostic/index aid only; excluded from semantic equality.
    let indexHash: String?

    static func == (
        lhs: EluV1FlagConfigDeadlineIdentity,
        rhs: EluV1FlagConfigDeadlineIdentity
    ) -> Bool {
        lhs.exactConstructorSiteKey == rhs.exactConstructorSiteKey
            && lhs.siteNamespaceDigest == rhs.siteNamespaceDigest
            && lhs.siteId == rhs.siteId
            && lhs.configRevision == rhs.configRevision
            && lhs.ordering == rhs.ordering
            && lhs.semanticHash == rhs.semanticHash
            && lhs.endpoint == rhs.endpoint
            && lhs.configExpiresAt == rhs.configExpiresAt
            && lhs.barrierGeneration == rhs.barrierGeneration
    }
}

struct EluV1FlagCacheDeadlineIdentity: Equatable, Sendable {
    let storeEpoch: String
    let cacheRecordId: String
    let cachedWitnessHash: String
    let flagsRevision: String
    let evaluatedAt: EluV1StoredTimestamp
    let responseExpiresAt: EluV1StoredTimestamp
    let effectiveExpiresAt: EluV1StoredTimestamp
    let barrierGeneration: Int64
    let declaredBodyBytes: Int64
    let bodySha256: String
    /// Diagnostic/index aid only; never the lease authority.
    let indexHash: String?

    static func == (
        lhs: EluV1FlagCacheDeadlineIdentity,
        rhs: EluV1FlagCacheDeadlineIdentity
    ) -> Bool {
        lhs.storeEpoch == rhs.storeEpoch
            && lhs.cacheRecordId == rhs.cacheRecordId
            && lhs.cachedWitnessHash == rhs.cachedWitnessHash
            && lhs.flagsRevision == rhs.flagsRevision
            && lhs.evaluatedAt == rhs.evaluatedAt
            && lhs.responseExpiresAt == rhs.responseExpiresAt
            && lhs.effectiveExpiresAt == rhs.effectiveExpiresAt
            && lhs.barrierGeneration == rhs.barrierGeneration
            && lhs.declaredBodyBytes == rhs.declaredBodyBytes
            && lhs.bodySha256 == rhs.bodySha256
    }
}

actor EluSQLiteRuntimeQueue {
    private struct FlagClockSample {
        let wallDate: Date
        let wall: EluV1Timestamp
        let continuous: UInt64
    }

    private struct FlagDeadline<Key: Equatable> {
        let key: Key
        let startedAt: UInt64
        let budget: UInt64

        func isExpired(at now: UInt64) -> Bool {
            now &- startedAt >= budget
        }
    }

    private static let reservedVersionProperties: Set<String> = [
        "$elu_contract_version",
        "$elu_sdk_version",
        "$elu_facade_version",
    ]
    private var resources: EluRuntimeResources?
    private var state: EluStoredRuntimeState
    private let limits: EluRuntimeQueueLimits
    private let clock: @Sendable () -> Date
    private let anonymousIdGenerator: @Sendable () -> String
    private let sessionIdGenerator: @Sendable () -> String
    private let faultInjector: (any EluRuntimeQueueFaultInjecting)?
    private let captureConfigManager: EluV1ConfigManager?
    private let flagConfigManager: EluV1ConfigManager?
    private let exactConstructorSiteKey: String?
    private let ownerNamespaceHash: String?
    private let continuousClock: @Sendable () -> UInt64
    private let continuousBudgetConverter: @Sendable (UInt64) -> UInt64?
    private let flagStoreEpochGenerator: @Sendable () -> String
    private var pinnedConfigSiteId: String?
    private var captureAuthority: EluV1CaptureAuthorityState = .absent
    private var authorityEpoch: UInt64 = 0
    private var databaseSchemaVersion: Int64
    private var flagWallLatch: EluV1Timestamp?
    private var flagContinuousLatch: UInt64?
    private var flagClockPoisoned = false
    private var flagConfigDeadline: FlagDeadline<EluV1FlagConfigDeadlineIdentity>?
    private var flagCacheDeadline: FlagDeadline<EluV1FlagCacheDeadlineIdentity>?
    private var isPoisoned = false

    static func open(
        directoryURL: URL,
        limits: EluRuntimeQueueLimits,
        clock: @escaping @Sendable () -> Date = { Date() },
        anonymousIdGenerator: @escaping @Sendable () -> String = {
            "anon_\(EluRuntimeIdentifier.compactUUID())"
        },
        streamIdGenerator: @escaping @Sendable () -> String = {
            "stream_\(EluRuntimeIdentifier.compactUUID())"
        },
        sessionIdGenerator: @escaping @Sendable () -> String = {
            "session_\(EluRuntimeIdentifier.compactUUID())"
        },
        faultInjector: (any EluRuntimeQueueFaultInjecting)? = nil
    ) async throws -> EluSQLiteRuntimeQueue {
        let opened = try await Task.detached(priority: .utility) {
            try EluRuntimeQueueBootstrap.open(
                directoryURL: directoryURL,
                clock: clock,
                anonymousIdGenerator: anonymousIdGenerator,
                streamIdGenerator: streamIdGenerator,
                faultInjector: faultInjector
            )
        }.value
        return EluSQLiteRuntimeQueue(
            resources: opened.resources,
            state: opened.state,
            limits: limits,
            clock: clock,
            anonymousIdGenerator: anonymousIdGenerator,
            sessionIdGenerator: sessionIdGenerator,
            faultInjector: faultInjector,
            databaseSchemaVersion: opened.databaseSchemaVersion,
            exactConstructorSiteKey: nil,
            ownerNamespaceHash: nil,
            continuousClock: EluMachContinuousClock.now,
            continuousBudgetConverter: EluMachContinuousClock.floorTicks
        )
    }

    /// Opens the internal standalone runtime in a constructor-site-key scoped
    /// directory. The site key never enters raw candidate submission or the
    /// event wire shape. This runtime remains unreferenced by the public facade.
    static func openCaptureRuntime(
        rootDirectoryURL: URL,
        exactConstructorSiteKey: String,
        limits: EluRuntimeQueueLimits,
        clock: @escaping @Sendable () -> Date = { Date() },
        continuousClock: @escaping @Sendable () -> UInt64 = EluMachContinuousClock.now,
        continuousBudgetConverter: @escaping @Sendable (UInt64) -> UInt64? =
            EluMachContinuousClock.floorTicks,
        anonymousIdGenerator: @escaping @Sendable () -> String = {
            "anon_\(EluRuntimeIdentifier.compactUUID())"
        },
        streamIdGenerator: @escaping @Sendable () -> String = {
            "stream_\(EluRuntimeIdentifier.compactUUID())"
        },
        sessionIdGenerator: @escaping @Sendable () -> String = {
            "session_\(EluRuntimeIdentifier.compactUUID())"
        },
        flagStoreEpochGenerator: @escaping @Sendable () -> String = {
            "flag_store_\(EluRuntimeIdentifier.compactUUID())"
        },
        faultInjector: (any EluRuntimeQueueFaultInjecting)? = nil
    ) async throws -> EluSQLiteRuntimeQueue {
        let namespaceHash = try EluV1SiteNamespace.digest(
            exactConstructorSiteKey: exactConstructorSiteKey
        )
        let directoryURL = rootDirectoryURL.appendingPathComponent(
            "site-\(namespaceHash)",
            isDirectory: true
        )
        let opened = try await Task.detached(priority: .utility) {
            try EluRuntimeQueueBootstrap.open(
                directoryURL: directoryURL,
                clock: clock,
                anonymousIdGenerator: anonymousIdGenerator,
                streamIdGenerator: streamIdGenerator,
                faultInjector: faultInjector
            )
        }.value
        return EluSQLiteRuntimeQueue(
            resources: opened.resources,
            state: opened.state,
            limits: limits,
            clock: clock,
            anonymousIdGenerator: anonymousIdGenerator,
            sessionIdGenerator: sessionIdGenerator,
            faultInjector: faultInjector,
            databaseSchemaVersion: opened.databaseSchemaVersion,
            exactConstructorSiteKey: exactConstructorSiteKey,
            ownerNamespaceHash: namespaceHash,
            continuousClock: continuousClock,
            continuousBudgetConverter: continuousBudgetConverter,
            flagStoreEpochGenerator: flagStoreEpochGenerator
        )
    }

    static func openCaptureRuntime(
        rootDirectoryURL: URL,
        exactConstructorSiteKey: String,
        clock: @escaping @Sendable () -> Date = { Date() },
        continuousClock: @escaping @Sendable () -> UInt64 = EluMachContinuousClock.now,
        continuousBudgetConverter: @escaping @Sendable (UInt64) -> UInt64? =
            EluMachContinuousClock.floorTicks,
        anonymousIdGenerator: @escaping @Sendable () -> String = {
            "anon_\(EluRuntimeIdentifier.compactUUID())"
        },
        streamIdGenerator: @escaping @Sendable () -> String = {
            "stream_\(EluRuntimeIdentifier.compactUUID())"
        },
        sessionIdGenerator: @escaping @Sendable () -> String = {
            "session_\(EluRuntimeIdentifier.compactUUID())"
        },
        flagStoreEpochGenerator: @escaping @Sendable () -> String = {
            "flag_store_\(EluRuntimeIdentifier.compactUUID())"
        },
        faultInjector: (any EluRuntimeQueueFaultInjecting)? = nil
    ) async throws -> EluSQLiteRuntimeQueue {
        try await openCaptureRuntime(
            rootDirectoryURL: rootDirectoryURL,
            exactConstructorSiteKey: exactConstructorSiteKey,
            limits: EluRuntimeQueueLimits(),
            clock: clock,
            continuousClock: continuousClock,
            continuousBudgetConverter: continuousBudgetConverter,
            anonymousIdGenerator: anonymousIdGenerator,
            streamIdGenerator: streamIdGenerator,
            sessionIdGenerator: sessionIdGenerator,
            flagStoreEpochGenerator: flagStoreEpochGenerator,
            faultInjector: faultInjector
        )
    }

    static func open(
        directoryURL: URL,
        clock: @escaping @Sendable () -> Date = { Date() },
        anonymousIdGenerator: @escaping @Sendable () -> String = {
            "anon_\(EluRuntimeIdentifier.compactUUID())"
        },
        streamIdGenerator: @escaping @Sendable () -> String = {
            "stream_\(EluRuntimeIdentifier.compactUUID())"
        },
        sessionIdGenerator: @escaping @Sendable () -> String = {
            "session_\(EluRuntimeIdentifier.compactUUID())"
        },
        faultInjector: (any EluRuntimeQueueFaultInjecting)? = nil
    ) async throws -> EluSQLiteRuntimeQueue {
        try await open(
            directoryURL: directoryURL,
            limits: EluRuntimeQueueLimits(),
            clock: clock,
            anonymousIdGenerator: anonymousIdGenerator,
            streamIdGenerator: streamIdGenerator,
            sessionIdGenerator: sessionIdGenerator,
            faultInjector: faultInjector
        )
    }

    private init(
        resources: EluRuntimeResources,
        state: EluStoredRuntimeState,
        limits: EluRuntimeQueueLimits,
        clock: @escaping @Sendable () -> Date,
        anonymousIdGenerator: @escaping @Sendable () -> String,
        sessionIdGenerator: @escaping @Sendable () -> String,
        faultInjector: (any EluRuntimeQueueFaultInjecting)?,
        databaseSchemaVersion: Int64,
        exactConstructorSiteKey: String?,
        ownerNamespaceHash: String?,
        continuousClock: @escaping @Sendable () -> UInt64,
        continuousBudgetConverter: @escaping @Sendable (UInt64) -> UInt64?,
        flagStoreEpochGenerator: @escaping @Sendable () -> String = {
            "flag_store_\(EluRuntimeIdentifier.compactUUID())"
        }
    ) {
        self.resources = resources
        self.state = state
        self.limits = limits
        self.clock = clock
        self.anonymousIdGenerator = anonymousIdGenerator
        self.sessionIdGenerator = sessionIdGenerator
        self.faultInjector = faultInjector
        self.databaseSchemaVersion = databaseSchemaVersion
        flagWallLatch = nil
        flagContinuousLatch = nil
        flagClockPoisoned = false
        flagConfigDeadline = nil
        flagCacheDeadline = nil
        self.exactConstructorSiteKey = exactConstructorSiteKey
        self.ownerNamespaceHash = ownerNamespaceHash
        captureConfigManager = ownerNamespaceHash == nil ? nil : EluV1ConfigManager()
        flagConfigManager = exactConstructorSiteKey.flatMap {
            try? EluV1ConfigManager(exactConstructorSiteKey: $0)
        }
        self.continuousClock = continuousClock
        self.continuousBudgetConverter = continuousBudgetConverter
        self.flagStoreEpochGenerator = flagStoreEpochGenerator
    }

    func snapshot() throws -> EluRuntimeQueueSnapshot {
        guard !isPoisoned, resources != nil else {
            throw EluRuntimeQueueError.poisoned
        }
        return state.snapshot
    }

    /// Explicitly reached only by the unwired internal flag client. Ordinary
    /// runtime open accepts v1/v2 and never calls this migration.
    func ensureFlagSchema() throws {
        guard flagConfigManager != nil,
              let exactConstructorSiteKey,
              let ownerNamespaceHash
        else {
            throw EluRuntimeQueueError.invalidState
        }
        let resources = try requireResources()
        let connection = resources.connection
        if databaseSchemaVersion == EluSQLiteRuntimeSchema.flagDatabaseVersion {
            let row = try EluRuntimeDatabase.readFlagAuthority(connection)
            guard row.storageSchema == 1 else {
                throw EluRuntimeQueueError.unsupportedSchemaVersion(row.storageSchema)
            }
            let authority = try EluV1FlagStorageCodec.decodeAuthority(row.body)
            guard row.initialized == authority.initialized,
                  authority.exactConstructorSiteKey == exactConstructorSiteKey,
                  authority.siteNamespaceDigest == ownerNamespaceHash
            else {
                throw EluRuntimeQueueError.corruptStorage
            }
            return
        }
        guard databaseSchemaVersion == EluSQLiteRuntimeSchema.initialDatabaseVersion else {
            throw EluRuntimeQueueError.unsupportedSchemaVersion(databaseSchemaVersion)
        }
        do {
            try connection.execute("BEGIN IMMEDIATE")
            guard try connection.integerPragma("user_version")
                == EluSQLiteRuntimeSchema.initialDatabaseVersion
            else {
                throw EluRuntimeQueueError.corruptStorage
            }
            try EluRuntimeDatabase.verifySchema(
                connection,
                databaseVersion: EluSQLiteRuntimeSchema.initialDatabaseVersion
            )
            try connection.execute(EluSQLiteRuntimeSchema.createFlagCacheRecords)
            try EluRuntimeDatabase.insertUninitializedFlagAuthority(
                connection,
                exactConstructorSiteKey: exactConstructorSiteKey,
                siteNamespaceDigest: ownerNamespaceHash
            )
            try connection.execute(
                "PRAGMA user_version = \(EluSQLiteRuntimeSchema.flagDatabaseVersion)"
            )
            try connection.execute("COMMIT")
            databaseSchemaVersion = EluSQLiteRuntimeSchema.flagDatabaseVersion
        } catch {
            try? connection.execute("ROLLBACK")
            throw mapOperationError(error)
        }
    }

    private func sampleFlagClock() -> FlagClockSample? {
        guard !flagClockPoisoned else { return nil }
        let wallDate = clock()
        let wall: EluV1Timestamp
        do {
            guard wallDate.timeIntervalSinceReferenceDate.isFinite else {
                throw EluRuntimeQueueError.generationMismatch
            }
            wall = try EluV1Timestamp.exactClock(wallDate)
        } catch {
            poisonFlagClock()
            return nil
        }
        let continuous = continuousClock()
        if let flagWallLatch, wall < flagWallLatch {
            poisonFlagClock()
            return nil
        }
        if let flagContinuousLatch, continuous < flagContinuousLatch {
            poisonFlagClock()
            return nil
        }
        if flagWallLatch.map({ $0 < wall }) ?? true { flagWallLatch = wall }
        flagContinuousLatch = continuous
        return FlagClockSample(
            wallDate: wallDate,
            wall: wall,
            continuous: continuous
        )
    }

    private func poisonFlagClock() {
        flagClockPoisoned = true
        flagConfigDeadline = nil
        flagCacheDeadline = nil
        flagConfigManager?.rejectPendingFlagConfig(nil)
    }

    private func installFlagConfigDeadline(
        authority: EluV1FlagDurableAuthority,
        sample: FlagClockSample
    ) throws {
        guard authority.isAllowed,
              let key = flagConfigDeadlineKey(authority),
              let expiry = try authority.configExpiresAt?.validated(),
              let ordering = try authority.ordering?.validated(),
              let durableWall = try authority.lastObservedWall?.validated()
        else {
            flagConfigDeadline = nil
            return
        }
        if flagConfigDeadline?.key == key { return }
        guard let wallRemaining = expiry.floorNanoseconds(after: sample.wallDate),
              let declaredRemaining = expiry.floorNanoseconds(since: ordering),
              let durableRemaining = expiry.floorNanoseconds(since: durableWall)
        else {
            flagConfigDeadline = FlagDeadline(key: key, startedAt: sample.continuous, budget: 0)
            return
        }
        let remaining = min(min(wallRemaining, declaredRemaining), durableRemaining)
        if remaining == 0 {
            flagConfigDeadline = FlagDeadline(key: key, startedAt: sample.continuous, budget: 0)
            return
        }
        guard let budget = continuousBudgetConverter(remaining), budget > 0 else {
            poisonFlagClock()
            throw EluRuntimeQueueError.generationMismatch
        }
        flagConfigDeadline = FlagDeadline(
            key: key,
            startedAt: sample.continuous,
            budget: budget
        )
    }

    private func installFlagCacheDeadline(
        request: EluV1FlagRequestCacheState,
        declaredBodyBytes: Int64,
        bodySha256: String,
        sample: FlagClockSample,
        force: Bool = false
    ) throws {
        guard let key = flagCacheDeadlineKey(
            request,
            declaredBodyBytes: declaredBodyBytes,
            bodySha256: bodySha256
        ),
              let expiry = try request.effectiveExpiresAt?.validated(),
              let evaluated = try request.evaluatedAt?.validated()
        else {
            flagCacheDeadline = nil
            return
        }
        if !force, flagCacheDeadline?.key == key { return }
        guard let wallRemaining = expiry.floorNanoseconds(after: sample.wallDate),
              let declaredRemaining = expiry.floorNanoseconds(since: evaluated)
        else {
            flagCacheDeadline = FlagDeadline(key: key, startedAt: sample.continuous, budget: 0)
            return
        }
        let remaining = min(wallRemaining, declaredRemaining)
        if remaining == 0 {
            flagCacheDeadline = FlagDeadline(key: key, startedAt: sample.continuous, budget: 0)
            return
        }
        guard let budget = continuousBudgetConverter(remaining), budget > 0 else {
            poisonFlagClock()
            throw EluRuntimeQueueError.generationMismatch
        }
        flagCacheDeadline = FlagDeadline(
            key: key,
            startedAt: sample.continuous,
            budget: budget
        )
    }

    private func flagConfigDeadlineKey(
        _ authority: EluV1FlagDurableAuthority
    ) -> EluV1FlagConfigDeadlineIdentity? {
        guard authority.isAllowed,
              let ordering = authority.ordering,
              let semanticHash = authority.semanticHash,
              let exactConstructorSiteKey = authority.exactConstructorSiteKey,
              let siteNamespaceDigest = authority.siteNamespaceDigest,
              let siteId = authority.siteId,
              let configRevision = authority.configRevision,
              let endpoint = authority.endpoint,
              let configExpiresAt = authority.configExpiresAt
        else {
            return nil
        }
        let components = [
            exactConstructorSiteKey, siteNamespaceDigest, siteId, configRevision,
            ordering.source, semanticHash, endpoint, configExpiresAt.source,
            String(authority.barrierGeneration),
        ]
        return EluV1FlagConfigDeadlineIdentity(
            exactConstructorSiteKey: exactConstructorSiteKey,
            siteNamespaceDigest: siteNamespaceDigest,
            siteId: siteId,
            configRevision: configRevision,
            ordering: ordering,
            semanticHash: semanticHash,
            endpoint: endpoint,
            configExpiresAt: configExpiresAt,
            barrierGeneration: authority.barrierGeneration,
            indexHash: EluV1FlagJSON.hash(
                Data(components.joined(separator: "\u{0}").utf8)
            )
        )
    }

    private func flagCacheDeadlineKey(
        _ request: EluV1FlagRequestCacheState,
        declaredBodyBytes: Int64,
        bodySha256: String
    ) -> EluV1FlagCacheDeadlineIdentity? {
        guard let cacheRecordId = request.cacheRecordId,
              let cachedWitnessHash = request.cachedWitnessHash,
              let flagsRevision = request.flagsRevision,
              let evaluatedAt = request.evaluatedAt,
              let responseExpiresAt = request.responseExpiresAt,
              let effectiveExpiresAt = request.effectiveExpiresAt
        else {
            return nil
        }
        let components = [
            request.storeEpoch, cacheRecordId, cachedWitnessHash, flagsRevision,
            evaluatedAt.source, responseExpiresAt.source, effectiveExpiresAt.source,
            String(request.barrierGeneration), String(declaredBodyBytes), bodySha256,
        ]
        return EluV1FlagCacheDeadlineIdentity(
            storeEpoch: request.storeEpoch,
            cacheRecordId: cacheRecordId,
            cachedWitnessHash: cachedWitnessHash,
            flagsRevision: flagsRevision,
            evaluatedAt: evaluatedAt,
            responseExpiresAt: responseExpiresAt,
            effectiveExpiresAt: effectiveExpiresAt,
            barrierGeneration: request.barrierGeneration,
            declaredBodyBytes: declaredBodyBytes,
            bodySha256: bodySha256,
            indexHash: EluV1FlagJSON.hash(
                Data(components.joined(separator: "\u{0}").utf8)
            )
        )
    }

    private func flagConfigDeadlineExpired(
        _ authority: EluV1FlagDurableAuthority,
        at sample: FlagClockSample
    ) throws -> Bool {
        try installFlagConfigDeadline(authority: authority, sample: sample)
        guard let key = flagConfigDeadlineKey(authority),
              let deadline = flagConfigDeadline,
              deadline.key == key
        else {
            return false
        }
        return deadline.isExpired(at: sample.continuous)
    }

    private func flagCacheDeadlineExpired(
        _ request: EluV1FlagRequestCacheState,
        declaredBodyBytes: Int64,
        bodySha256: String,
        at sample: FlagClockSample
    ) throws -> Bool {
        try installFlagCacheDeadline(
            request: request,
            declaredBodyBytes: declaredBodyBytes,
            bodySha256: bodySha256,
            sample: sample
        )
        guard let key = flagCacheDeadlineKey(
            request,
            declaredBodyBytes: declaredBodyBytes,
            bodySha256: bodySha256
        ),
              let deadline = flagCacheDeadline,
              deadline.key == key
        else {
            return false
        }
        return deadline.isExpired(at: sample.continuous)
    }

    func submitFlagConfig(_ configData: Data) -> EluV1FlagAuthorization {
        guard let manager = flagConfigManager,
              databaseSchemaVersion == EluSQLiteRuntimeSchema.flagDatabaseVersion,
              resources != nil
        else {
            return .restricted(flagClockPoisoned ? .wallRollback : .storageUnavailable)
        }
        // Storage ownership and durable authority must be classified before
        // sampling a rollback-sensitive clock or advancing the owner-local
        // activation generation. Future/opaque records and terminal authority
        // therefore cannot poison or invalidate the last valid activation.
        do {
            try preflightFlagSubmissionStorage()
        } catch EluRuntimeQueueError.unsupportedSchemaVersion(_) {
            return .restricted(.terminal)
        } catch EluRuntimeQueueError.flagAuthorityTerminal {
            return .restricted(.terminal)
        } catch {
            return .restricted(.storageUnavailable)
        }
        guard !isPoisoned, let sample = sampleFlagClock() else {
            return .restricted(flagClockPoisoned ? .wallRollback : .storageUnavailable)
        }
        let candidate: EluV1PreparedFlagConfig
        do {
            candidate = try manager.prepareFlagConfig(configData: configData, now: sample.wallDate)
        } catch EluV1ConfigResolutionError.flagActivationGenerationExhausted {
            manager.rejectPendingFlagConfig(nil)
            do {
                let durableRestriction = try applyUnversionedFlagRestriction(
                    .terminal,
                    sample: sample
                )
                return .restricted(durableRestriction)
            } catch EluRuntimeQueueError.unsupportedSchemaVersion(_) {
                return .restricted(.terminal)
            } catch EluRuntimeQueueError.flagAuthorityTerminal {
                return .restricted(.terminal)
            } catch {
                return .restricted(flagClockPoisoned ? .wallRollback : .storageUnavailable)
            }
        } catch {
            manager.rejectPendingFlagConfig(nil)
            do {
                let durableRestriction = try applyUnversionedFlagRestriction(
                    .malformed,
                    sample: sample
                )
                return .restricted(durableRestriction)
            } catch EluRuntimeQueueError.unsupportedSchemaVersion(_) {
                return .restricted(.terminal)
            } catch EluRuntimeQueueError.flagAuthorityTerminal {
                return .restricted(.terminal)
            } catch {
                return .restricted(flagClockPoisoned ? .wallRollback : .storageUnavailable)
            }
        }

        do {
            let transition = try applyFlagBarrier(candidate, sample: sample)
            guard transition.isCandidateAllowed else {
                manager.rejectPendingFlagConfig(candidate)
                return .restricted(transition.restriction ?? .missing)
            }
            let authorization = manager.commitFlagConfig(
                candidate,
                barrierGeneration: transition.barrierGeneration
            )
            guard case let .allowed(snapshot) = authorization else { return authorization }
            let authority = try loadFlagAuthority(try requireResources().connection)
            guard flagAuthorization(snapshot, matches: authority) else {
                manager.rejectPendingFlagConfig(nil)
                return .restricted(.storageUnavailable)
            }
            try installFlagConfigDeadline(authority: authority, sample: sample)
            return authorization
        } catch EluRuntimeQueueError.generationMismatch {
            manager.rejectPendingFlagConfig(candidate)
            return .restricted(.wallRollback)
        } catch EluRuntimeQueueError.unsupportedSchemaVersion(_) {
            manager.rejectPendingFlagConfig(candidate)
            return .restricted(.terminal)
        } catch EluRuntimeQueueError.flagAuthorityTerminal {
            manager.rejectPendingFlagConfig(candidate)
            return .restricted(.terminal)
        } catch {
            manager.rejectPendingFlagConfig(candidate)
            return .restricted(.storageUnavailable)
        }
    }

    private struct FlagBarrierTransition {
        let barrierGeneration: Int64
        let isCandidateAllowed: Bool
        let restriction: EluV1FlagRestriction?
    }

    private func applyFlagBarrier(
        _ candidate: EluV1PreparedFlagConfig,
        sample: FlagClockSample
    ) throws -> FlagBarrierTransition {
        guard candidate.exactConstructorSiteKey == exactConstructorSiteKey,
              candidate.siteNamespaceDigest == ownerNamespaceHash
        else {
            throw EluRuntimeQueueError.invalidState
        }
        let resources = try requireResources()
        let connection = resources.connection
        do {
            try connection.execute("BEGIN IMMEDIATE")
            try preflightOpaqueFlagRequest(connection)
            var authority = try loadFlagAuthority(connection)
            try advanceFlagWall(&authority, to: sample.wall)
            if authority.restriction == .terminal {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return FlagBarrierTransition(
                    barrierGeneration: authority.barrierGeneration,
                    isCandidateAllowed: false,
                    restriction: .terminal
                )
            }
            let preservedAuthority = authority

            let previousBarrier = authority.barrierGeneration
            var transitionRequiresIncrement = false
            var useCandidate = false
            var isCandidateAllowed = false
            var effectiveRestriction = authority.restriction

            let hasSiteOwnershipConflict: Bool
            if let candidateSiteId = candidate.siteId,
               let boundSiteId = authority.siteId
            {
                hasSiteOwnershipConflict = candidateSiteId != boundSiteId
            } else {
                hasSiteOwnershipConflict = false
            }
            if hasSiteOwnershipConflict {
                effectiveRestriction = .conflict
                isCandidateAllowed = false
                if authority.restriction != .conflict {
                    authority.restriction = .conflict
                    transitionRequiresIncrement = true
                }
            } else if let currentOrdering = authority.ordering {
                if candidate.issuedAt < (try currentOrdering.validated()) {
                    // A stale candidate never changes the durable barrier.
                } else if candidate.issuedAt == (try currentOrdering.validated()) {
                    if !flagAuthorityProjection(authority, matches: candidate) {
                        authority.restriction = .conflict
                        effectiveRestriction = .conflict
                        transitionRequiresIncrement = true
                    } else if authority.restriction != nil {
                        // Equal authority can never weaken a prior restriction.
                        effectiveRestriction = authority.restriction
                    } else if let restriction = candidate.restriction {
                        authority.restriction = restriction
                        effectiveRestriction = restriction
                        transitionRequiresIncrement = true
                    } else {
                        useCandidate = true
                        isCandidateAllowed = true
                        effectiveRestriction = nil
                    }
                } else {
                    useCandidate = true
                    transitionRequiresIncrement = true
                }
            } else {
                useCandidate = true
                transitionRequiresIncrement = true
            }

            if useCandidate {
                authority.initialized = true
                authority.ordering = EluV1StoredTimestamp(candidate.issuedAt)
                authority.semanticHash = candidate.semanticHash
                authority.restriction = candidate.restriction
                if authority.siteId == nil {
                    authority.siteId = candidate.siteId
                }
                authority.configRevision = candidate.configRevision
                authority.endpoint = candidate.endpoint?.absoluteString
                authority.configExpiresAt = EluV1StoredTimestamp(candidate.expiresAt)
                effectiveRestriction = candidate.restriction
                isCandidateAllowed = candidate.restriction == nil
            }

            if transitionRequiresIncrement {
                if previousBarrier >= 9_007_199_254_740_991 {
                    authority = preservedAuthority
                    authority.restriction = .terminal
                    effectiveRestriction = .terminal
                    isCandidateAllowed = false
                } else {
                    authority.barrierGeneration = previousBarrier + 1
                }
                try invalidateFlagRequest(
                    connection,
                    barrierGeneration: authority.barrierGeneration
                )
                flagCacheDeadline = nil
                if flagConfigDeadlineKey(authority) != flagConfigDeadline?.key {
                    flagConfigDeadline = nil
                }
            }
            try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
            try connection.execute("COMMIT")
            return FlagBarrierTransition(
                barrierGeneration: authority.barrierGeneration,
                isCandidateAllowed: isCandidateAllowed && authority.isAllowed,
                restriction: effectiveRestriction
            )
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private func applyUnversionedFlagRestriction(
        _ restriction: EluV1FlagRestriction,
        sample: FlagClockSample
    ) throws -> EluV1FlagRestriction {
        let resources = try requireResources()
        let connection = resources.connection
        do {
            try connection.execute("BEGIN IMMEDIATE")
            try preflightOpaqueFlagRequest(connection)
            var authority = try loadFlagAuthority(connection)
            try advanceFlagWall(&authority, to: sample.wall)
            if authority.restriction == .terminal
                || authority.barrierGeneration >= 9_007_199_254_740_991
            {
                authority.initialized = true
                authority.restriction = .terminal
                try invalidateFlagRequest(
                    connection,
                    barrierGeneration: authority.barrierGeneration
                )
                flagConfigDeadline = nil
                flagCacheDeadline = nil
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .terminal
            }
            authority.initialized = true
            authority.restriction = restriction
            authority.barrierGeneration += 1
            try invalidateFlagRequest(
                connection,
                barrierGeneration: authority.barrierGeneration
            )
            flagConfigDeadline = nil
            flagCacheDeadline = nil
            try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
            try connection.execute("COMMIT")
            return restriction
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private func loadFlagAuthority(
        _ connection: EluSQLiteConnection
    ) throws -> EluV1FlagDurableAuthority {
        do {
            let row = try EluRuntimeDatabase.readFlagAuthority(connection)
            guard row.storageSchema == 1 else {
                throw EluRuntimeQueueError.flagAuthorityTerminal
            }
            let authority = try EluV1FlagStorageCodec.decodeAuthority(row.body)
            guard authority.initialized == row.initialized,
                  authority.exactConstructorSiteKey == exactConstructorSiteKey,
                  authority.siteNamespaceDigest == ownerNamespaceHash
            else {
                throw EluRuntimeQueueError.flagAuthorityTerminal
            }
            return authority
        } catch let error as EluSQLiteFailure {
            throw error
        } catch EluRuntimeQueueError.databaseUnavailable {
            throw EluRuntimeQueueError.databaseUnavailable
        } catch {
            throw EluRuntimeQueueError.flagAuthorityTerminal
        }
    }

    private func advanceFlagWall(
        _ authority: inout EluV1FlagDurableAuthority,
        to wall: EluV1Timestamp
    ) throws {
        if let durable = authority.lastObservedWall {
            let durableTimestamp = try durable.validated()
            guard !(wall < durableTimestamp) else {
                poisonFlagClock()
                throw EluRuntimeQueueError.generationMismatch
            }
        }
        authority.lastObservedWall = EluV1StoredTimestamp(wall)
    }

    private func invalidateFlagRequest(
        _ connection: EluSQLiteConnection,
        barrierGeneration: Int64
    ) throws {
        guard let row = try EluRuntimeDatabase.readFlagRequest(connection),
              row.storageSchema == 1,
              let request = try? EluV1FlagStorageCodec.decodeRequestState(row.metadataBody)
        else {
            // Missing/current-corrupt metadata may only be initialized by begin;
            // future metadata is byte-preserved. The changed barrier is enough
            // to make any old cache or completion ineligible.
            return
        }
        do {
            let body = try EluRuntimeDatabase.readFlagCacheBody(connection, row: row)
            if let body {
                let cached = try EluV1FlagCodec.decodeCache(body)
                guard request.cacheRecordId != nil,
                      request.cachedWitnessHash
                        == (try EluV1FlagCodec.witnessHash(cached.witness)),
                      request.flagsRevision == cached.response.flagsRevision,
                      request.evaluatedAt == cached.response.evaluatedAt,
                      request.responseExpiresAt == cached.response.expiresAt
                else {
                    return
                }
            } else if request.cacheRecordId != nil {
                return
            }
        } catch let error as EluSQLiteFailure {
            throw error
        } catch EluRuntimeQueueError.databaseUnavailable {
            throw EluRuntimeQueueError.databaseUnavailable
        } catch let EluRuntimeQueueError.unsupportedSchemaVersion(version) {
            throw EluRuntimeQueueError.unsupportedSchemaVersion(version)
        } catch EluV1FlagContractError.unsupportedSchemaVersion {
            throw EluRuntimeQueueError.unsupportedSchemaVersion(2)
        } catch {
            // A corrupt body/chunk is byte-preserved. Only begin may rotate
            // known-current corruption; no invalidation path deletes it.
            return
        }
        var invalidated = request
        if invalidated.requestGeneration < 9_007_199_254_740_991 {
            invalidated.requestGeneration += 1
        }
        invalidated.activeRequestId = nil
        invalidated.activeWitnessHash = nil
        invalidated.barrierGeneration = barrierGeneration
        invalidated.cacheRecordId = nil
        invalidated.cachedWitnessHash = nil
        invalidated.flagsRevision = nil
        invalidated.evaluatedAt = nil
        invalidated.responseExpiresAt = nil
        invalidated.effectiveExpiresAt = nil
        try EluRuntimeDatabase.replaceFlagRequest(
            connection,
            state: invalidated,
            cacheBody: nil
        )
        flagCacheDeadline = nil
    }

    /// Future/opaque request storage owns precedence over every current-v1
    /// authority transition, including expiry. Known-current corruption is
    /// left for the operation-specific rotate/miss path; storage ambiguity is
    /// terminal and byte-preserving.
    private func preflightOpaqueFlagRequest(
        _ connection: EluSQLiteConnection
    ) throws {
        guard let row = try EluRuntimeDatabase.readFlagRequest(connection) else {
            return
        }
        guard row.storageSchema == 1 else {
            throw EluRuntimeQueueError.unsupportedSchemaVersion(row.storageSchema)
        }
        do {
            _ = try EluRuntimeDatabase.readFlagCacheBody(connection, row: row)
        } catch let error as EluSQLiteFailure {
            throw error
        } catch EluRuntimeQueueError.databaseUnavailable {
            throw EluRuntimeQueueError.databaseUnavailable
        } catch let EluRuntimeQueueError.unsupportedSchemaVersion(version) {
            throw EluRuntimeQueueError.unsupportedSchemaVersion(version)
        } catch {
            // A fully identified current-v1 body may be handled as corrupt by
            // begin/read after authority precedence has been established.
        }
    }

    private func preflightFlagSubmissionStorage() throws {
        let connection = try requireResources().connection
        var transactionBegan = false

        func rollbackOrPoison() throws {
            guard transactionBegan else { return }
            do {
                try faultInjector?.hit(.beforeRollback)
                try connection.execute("ROLLBACK")
                transactionBegan = false
            } catch {
                // No write or COMMIT was attempted. Closing the connection
                // rolls back the read-only transaction and, critically,
                // releases both SQLite and process ownership so this actor
                // cannot retain a wedged transaction.
                poisonAndRelease()
                throw EluRuntimeQueueError.databaseUnavailable
            }
        }

        do {
            try connection.execute("BEGIN IMMEDIATE")
            transactionBegan = true
            try preflightOpaqueFlagRequest(connection)
            let authority = try loadFlagAuthority(connection)
            guard authority.restriction != .terminal else {
                throw EluRuntimeQueueError.flagAuthorityTerminal
            }
        } catch {
            let classificationError = error
            try rollbackOrPoison()
            throw classificationError
        }
        do {
            try rollbackOrPoison()
        } catch {
            throw error
        }
    }

    func beginFlagReload(
        requestId: String,
        versions: EluVersionContext
    ) -> EluV1FlagBeginResult {
        guard databaseSchemaVersion == EluSQLiteRuntimeSchema.flagDatabaseVersion,
              EluV1FlagEvaluationWitness.validIdentifier(requestId, maximum: 256),
              let manager = flagConfigManager
        else {
            return .restricted(flagClockPoisoned ? .wallRollback : .storageUnavailable)
        }
        let connection: EluSQLiteConnection
        do {
            connection = try requireResources().connection
        } catch {
            return .restricted(.storageUnavailable)
        }

        do {
            try connection.execute("BEGIN IMMEDIATE")
            try preflightOpaqueFlagRequest(connection)
            var authority = try loadFlagAuthority(connection)
            guard let sample = sampleFlagClock() else {
                try connection.execute("ROLLBACK")
                return .restricted(flagClockPoisoned ? .wallRollback : .storageUnavailable)
            }
            let managerAuthorization = manager.currentFlagAuthorization(now: sample.wallDate)
            guard authority.initialized else {
                try connection.execute("ROLLBACK")
                return .restricted(.missing)
            }
            try advanceFlagWall(&authority, to: sample.wall)
            if authority.restriction == .terminal {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .terminal
            }
            if try flagConfigIsExpired(authority, at: sample) {
                let terminal = try persistFlagConfigExpiry(
                    connection,
                    authority: &authority
                )
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return terminal ? .terminal : .restricted(.expired)
            }
            guard case let .allowed(authorization) = managerAuthorization,
                  flagAuthorization(authorization, matches: authority)
            else {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .restricted(authority.restriction ?? .missing)
            }
            let diskState = try EluRuntimeDatabase.loadState(connection, validateQueue: false)
            guard diskState == state else {
                throw EluRuntimeQueueError.generationMismatch
            }
            let witness = try EluV1FlagEvaluationWitness(
                authorization: authorization,
                runtime: diskState.snapshot,
                versions: versions
            )
            let witnessHash = try EluV1FlagCodec.witnessHash(witness)
            let request = try EluV1FlagCodec.makeRequest(
                requestId: requestId,
                witness: witness
            )

            var requestState: EluV1FlagRequestCacheState
            var preservedBody: Data?
            var rotateEpoch = false
            if let row = try EluRuntimeDatabase.readFlagRequest(connection) {
                guard row.storageSchema == 1 else {
                    try connection.execute("ROLLBACK")
                    return .terminal
                }
                do {
                    requestState = try EluV1FlagStorageCodec.decodeRequestState(row.metadataBody)
                    preservedBody = try EluRuntimeDatabase.readFlagCacheBody(
                        connection,
                        row: row
                    )
                    if let body = preservedBody {
                        let cached = try EluV1FlagCodec.decodeCache(body)
                        guard requestState.cacheRecordId != nil,
                              requestState.cachedWitnessHash
                                == (try EluV1FlagCodec.witnessHash(cached.witness)),
                              requestState.flagsRevision == cached.response.flagsRevision,
                              requestState.barrierGeneration == authority.barrierGeneration
                        else {
                            throw EluRuntimeQueueError.corruptStorage
                        }
                        if let expiry = requestState.effectiveExpiresAt,
                           ((try expiry.validated()).isAtOrBefore(sample.wallDate)
                               || (try flagCacheDeadlineExpired(
                                   requestState,
                                   declaredBodyBytes: row.declaredBodyBytes,
                                   bodySha256: row.bodySha256,
                                   at: sample
                               )))
                        {
                            try expireFlagCacheState(&requestState)
                            preservedBody = nil
                            flagCacheDeadline = nil
                        }
                    } else if requestState.cacheRecordId != nil {
                        throw EluRuntimeQueueError.corruptStorage
                    }
                } catch let error as EluSQLiteFailure {
                    throw error
                } catch EluRuntimeQueueError.databaseUnavailable {
                    throw EluRuntimeQueueError.databaseUnavailable
                } catch EluRuntimeQueueError.unsupportedSchemaVersion(_) {
                    try connection.execute("ROLLBACK")
                    return .terminal
                } catch EluV1FlagContractError.unsupportedSchemaVersion {
                    try connection.execute("ROLLBACK")
                    return .terminal
                } catch {
                    rotateEpoch = true
                    requestState = freshFlagRequestState(
                        barrierGeneration: authority.barrierGeneration
                    )
                    preservedBody = nil
                    flagCacheDeadline = nil
                }
            } else {
                rotateEpoch = true
                requestState = freshFlagRequestState(
                    barrierGeneration: authority.barrierGeneration
                )
            }

            if rotateEpoch || requestState.requestGeneration >= 9_007_199_254_740_991 {
                requestState = freshFlagRequestState(
                    barrierGeneration: authority.barrierGeneration
                )
                preservedBody = nil
                flagCacheDeadline = nil
            } else {
                requestState.requestGeneration += 1
            }
            requestState.activeRequestId = requestId
            requestState.activeWitnessHash = witnessHash
            requestState.barrierGeneration = authority.barrierGeneration
            try EluRuntimeDatabase.replaceFlagRequest(
                connection,
                state: requestState,
                cacheBody: preservedBody
            )
            try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
            try connection.execute("COMMIT")

            let token = EluV1FlagBeginToken(
                storeEpoch: requestState.storeEpoch,
                requestGeneration: requestState.requestGeneration,
                barrierGeneration: requestState.barrierGeneration,
                requestId: requestId,
                witnessHash: witnessHash,
                activationGeneration: authorization.activationGeneration,
                witness: witness,
                versions: versions
            )
            return .begun(
                EluV1FlagBegunRequest(
                    token: token,
                    endpoint: authorization.endpoint,
                    request: request
                )
            )
        } catch EluRuntimeQueueError.generationMismatch {
            try? connection.execute("ROLLBACK")
            return .restricted(.wallRollback)
        } catch EluRuntimeQueueError.flagAuthorityTerminal {
            try? connection.execute("ROLLBACK")
            return .terminal
        } catch EluRuntimeQueueError.unsupportedSchemaVersion(_) {
            try? connection.execute("ROLLBACK")
            return .terminal
        } catch {
            try? connection.execute("ROLLBACK")
            return .restricted(.storageUnavailable)
        }
    }

    /// Revalidates the exact durable request immediately before the injected
    /// transport is allowed to observe it. This is intentionally a separate
    /// store transaction from begin: suspension between begin and send must
    /// not let config expiry, identity/context changes, or a newer begin slip
    /// past the durable barrier.
    func authorizeFlagSend(
        token: EluV1FlagBeginToken
    ) -> EluV1FlagSendResult {
        guard databaseSchemaVersion == EluSQLiteRuntimeSchema.flagDatabaseVersion,
              let manager = flagConfigManager
        else {
            return .restricted(flagClockPoisoned ? .wallRollback : .storageUnavailable)
        }

        let connection: EluSQLiteConnection
        do {
            connection = try requireResources().connection
        } catch {
            return .restricted(.storageUnavailable)
        }

        do {
            try connection.execute("BEGIN IMMEDIATE")
            try preflightOpaqueFlagRequest(connection)
            var authority = try loadFlagAuthority(connection)
            guard let sample = sampleFlagClock() else {
                try connection.execute("ROLLBACK")
                return .restricted(flagClockPoisoned ? .wallRollback : .storageUnavailable)
            }
            // The manager may restrict its process-local snapshot at equality,
            // but only after future storage has won precedence.
            let managerAuthorization = manager.currentFlagAuthorization(now: sample.wallDate)
            guard authority.initialized else {
                try connection.execute("ROLLBACK")
                return .restricted(.missing)
            }
            try advanceFlagWall(&authority, to: sample.wall)
            if authority.restriction == .terminal {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .terminal
            }
            if try flagConfigIsExpired(authority, at: sample) {
                let terminal = try persistFlagConfigExpiry(
                    connection,
                    authority: &authority
                )
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return terminal ? .terminal : .restricted(.expired)
            }
            guard case let .allowed(authorization) = managerAuthorization,
                  flagAuthorization(authorization, matches: authority),
                  token.activationGeneration == authorization.activationGeneration,
                  token.barrierGeneration == authority.barrierGeneration
            else {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .stale
            }

            let diskState = try EluRuntimeDatabase.loadState(
                connection,
                validateQueue: false
            )
            guard diskState == state else {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .stale
            }
            let currentWitness = try EluV1FlagEvaluationWitness(
                authorization: authorization,
                runtime: diskState.snapshot,
                versions: token.versions
            )
            guard currentWitness == token.witness,
                  try EluV1FlagCodec.witnessHash(currentWitness) == token.witnessHash,
                  let row = try EluRuntimeDatabase.readFlagRequest(connection)
            else {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .stale
            }
            guard row.storageSchema == 1 else {
                try connection.execute("ROLLBACK")
                return .terminal
            }

            let requestState: EluV1FlagRequestCacheState
            do {
                requestState = try EluV1FlagStorageCodec.decodeRequestState(
                    row.metadataBody
                )
                let priorBody = try EluRuntimeDatabase.readFlagCacheBody(
                    connection,
                    row: row
                )
                if let priorBody {
                    let priorCache = try EluV1FlagCodec.decodeCache(priorBody)
                    guard requestState.cacheRecordId != nil,
                          requestState.cachedWitnessHash
                            == (try EluV1FlagCodec.witnessHash(priorCache.witness)),
                          requestState.flagsRevision == priorCache.response.flagsRevision,
                          requestState.evaluatedAt == priorCache.response.evaluatedAt,
                          requestState.responseExpiresAt == priorCache.response.expiresAt
                    else {
                        throw EluRuntimeQueueError.corruptStorage
                    }
                } else if requestState.cacheRecordId != nil {
                    throw EluRuntimeQueueError.corruptStorage
                }
            } catch let error as EluSQLiteFailure {
                throw error
            } catch EluRuntimeQueueError.databaseUnavailable {
                throw EluRuntimeQueueError.databaseUnavailable
            } catch EluRuntimeQueueError.unsupportedSchemaVersion(_) {
                try connection.execute("ROLLBACK")
                return .terminal
            } catch EluV1FlagContractError.unsupportedSchemaVersion {
                try connection.execute("ROLLBACK")
                return .terminal
            } catch {
                try connection.execute("ROLLBACK")
                return .stale
            }

            guard requestState.storeEpoch == token.storeEpoch,
                  requestState.requestGeneration == token.requestGeneration,
                  requestState.barrierGeneration == token.barrierGeneration,
                  requestState.activeRequestId == token.requestId,
                  requestState.activeWitnessHash == token.witnessHash
            else {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .stale
            }
            try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
            try connection.execute("COMMIT")
            return .allowed
        } catch EluRuntimeQueueError.generationMismatch {
            try? connection.execute("ROLLBACK")
            return .restricted(.wallRollback)
        } catch EluRuntimeQueueError.flagAuthorityTerminal {
            try? connection.execute("ROLLBACK")
            return .terminal
        } catch EluRuntimeQueueError.unsupportedSchemaVersion(_) {
            try? connection.execute("ROLLBACK")
            return .terminal
        } catch {
            try? connection.execute("ROLLBACK")
            return .restricted(.storageUnavailable)
        }
    }

    func commitFlagReload(
        token: EluV1FlagBeginToken,
        response: EluV1FlagResponse
    ) -> EluV1FlagCommitResult {
        guard databaseSchemaVersion == EluSQLiteRuntimeSchema.flagDatabaseVersion,
              let manager = flagConfigManager
        else {
            return .restricted(flagClockPoisoned ? .wallRollback : .storageUnavailable)
        }
        let connection: EluSQLiteConnection
        do {
            connection = try requireResources().connection
        } catch {
            return .restricted(.storageUnavailable)
        }
        do {
            try connection.execute("BEGIN IMMEDIATE")
            try preflightOpaqueFlagRequest(connection)
            var authority = try loadFlagAuthority(connection)
            guard let sample = sampleFlagClock() else {
                try connection.execute("ROLLBACK")
                return .restricted(flagClockPoisoned ? .wallRollback : .storageUnavailable)
            }
            let managerAuthorization = manager.currentFlagAuthorization(now: sample.wallDate)
            try advanceFlagWall(&authority, to: sample.wall)
            if authority.restriction == .terminal {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .terminal
            }
            if try flagConfigIsExpired(authority, at: sample) {
                let terminal = try persistFlagConfigExpiry(
                    connection,
                    authority: &authority
                )
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return terminal ? .terminal : .restricted(.expired)
            }
            guard case let .allowed(authorization) = managerAuthorization,
                  flagAuthorization(authorization, matches: authority),
                  token.activationGeneration == authorization.activationGeneration,
                  token.barrierGeneration == authority.barrierGeneration
            else {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .stale
            }
            let diskState = try EluRuntimeDatabase.loadState(connection, validateQueue: false)
            guard diskState == state else { throw EluRuntimeQueueError.generationMismatch }
            let currentWitness = try EluV1FlagEvaluationWitness(
                authorization: authorization,
                runtime: diskState.snapshot,
                versions: token.versions
            )
            guard currentWitness == token.witness,
                  try EluV1FlagCodec.witnessHash(currentWitness) == token.witnessHash,
                  let row = try EluRuntimeDatabase.readFlagRequest(connection)
            else {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .stale
            }
            guard row.storageSchema == 1 else {
                try connection.execute("ROLLBACK")
                return .terminal
            }
            let requestState: EluV1FlagRequestCacheState
            do {
                requestState = try EluV1FlagStorageCodec.decodeRequestState(row.metadataBody)
                let priorBody = try EluRuntimeDatabase.readFlagCacheBody(
                    connection,
                    row: row
                )
                if let priorBody {
                    let priorCache = try EluV1FlagCodec.decodeCache(priorBody)
                    guard requestState.cacheRecordId != nil,
                          requestState.cachedWitnessHash
                            == (try EluV1FlagCodec.witnessHash(priorCache.witness)),
                          requestState.flagsRevision == priorCache.response.flagsRevision,
                          requestState.evaluatedAt == priorCache.response.evaluatedAt,
                          requestState.responseExpiresAt == priorCache.response.expiresAt
                    else {
                        throw EluRuntimeQueueError.corruptStorage
                    }
                } else if requestState.cacheRecordId != nil {
                    throw EluRuntimeQueueError.corruptStorage
                }
            } catch let error as EluSQLiteFailure {
                throw error
            } catch EluRuntimeQueueError.databaseUnavailable {
                throw EluRuntimeQueueError.databaseUnavailable
            } catch EluRuntimeQueueError.unsupportedSchemaVersion(_) {
                try connection.execute("ROLLBACK")
                return .terminal
            } catch EluV1FlagContractError.unsupportedSchemaVersion {
                try connection.execute("ROLLBACK")
                return .terminal
            } catch {
                try connection.execute("ROLLBACK")
                return .stale
            }
            guard requestState.storeEpoch == token.storeEpoch,
                  requestState.requestGeneration == token.requestGeneration,
                  requestState.barrierGeneration == token.barrierGeneration,
                  requestState.activeRequestId == token.requestId,
                  requestState.activeWitnessHash == token.witnessHash,
                  response.requestId == token.requestId,
                  response.contextRevision == token.witness.contextRevision,
                  response.identityRevision == token.witness.identityRevision
            else {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .stale
            }
            let responseExpiry = try response.expiresAt.validated()
            let configExpiry = try token.witness.configExpiresAt.validated()
            guard !responseExpiry.isAtOrBefore(sample.wallDate),
                  !configExpiry.isAtOrBefore(sample.wallDate)
            else {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .restricted(.expired)
            }
            let effectiveExpiry = min(responseExpiry, configExpiry)
            let body = try EluV1FlagCodec.encodeCache(
                witness: token.witness,
                response: response
            )
            var committed = requestState
            committed.activeRequestId = nil
            committed.activeWitnessHash = nil
            committed.cacheRecordId = "flag_cache_\(EluRuntimeIdentifier.compactUUID())"
            committed.cachedWitnessHash = token.witnessHash
            committed.flagsRevision = response.flagsRevision
            committed.evaluatedAt = response.evaluatedAt
            committed.responseExpiresAt = response.expiresAt
            committed.effectiveExpiresAt = EluV1StoredTimestamp(effectiveExpiry)
            try installFlagCacheDeadline(
                request: committed,
                declaredBodyBytes: Int64(body.count),
                bodySha256: EluV1FlagJSON.hash(body),
                sample: sample,
                force: true
            )
            try EluRuntimeDatabase.replaceFlagRequest(
                connection,
                state: committed,
                cacheBody: body
            )
            try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
            try connection.execute("COMMIT")
            return .updated
        } catch EluRuntimeQueueError.generationMismatch {
            try? connection.execute("ROLLBACK")
            return flagClockPoisoned ? .restricted(.wallRollback) : .stale
        } catch EluRuntimeQueueError.flagAuthorityTerminal {
            try? connection.execute("ROLLBACK")
            return .terminal
        } catch EluRuntimeQueueError.unsupportedSchemaVersion(_) {
            try? connection.execute("ROLLBACK")
            return .terminal
        } catch {
            try? connection.execute("ROLLBACK")
            return .restricted(.storageUnavailable)
        }
    }

    func readFlagCache(versions: EluVersionContext) -> EluV1FlagCacheReadResult {
        readFlagCache(versions: versions, cleanupToken: nil)
    }

    func finalizeFlagReload(
        token: EluV1FlagBeginToken,
        versions: EluVersionContext
    ) -> EluV1FlagCacheReadResult {
        readFlagCache(versions: versions, cleanupToken: token)
    }

    private func readFlagCache(
        versions: EluVersionContext,
        cleanupToken: EluV1FlagBeginToken?
    ) -> EluV1FlagCacheReadResult {
        guard databaseSchemaVersion == EluSQLiteRuntimeSchema.flagDatabaseVersion,
              let manager = flagConfigManager
        else {
            return .restricted(flagClockPoisoned ? .wallRollback : .storageUnavailable)
        }
        let connection: EluSQLiteConnection
        do {
            connection = try requireResources().connection
        } catch {
            return .restricted(.storageUnavailable)
        }
        do {
            try connection.execute("BEGIN IMMEDIATE")
            try preflightOpaqueFlagRequest(connection)
            var authority = try loadFlagAuthority(connection)
            guard let sample = sampleFlagClock() else {
                try connection.execute("ROLLBACK")
                return .restricted(flagClockPoisoned ? .wallRollback : .storageUnavailable)
            }
            let managerAuthorization = manager.currentFlagAuthorization(now: sample.wallDate)
            guard authority.initialized else {
                try connection.execute("ROLLBACK")
                return .miss
            }
            try advanceFlagWall(&authority, to: sample.wall)
            if authority.restriction == .terminal {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .terminal
            }
            if try flagConfigIsExpired(authority, at: sample) {
                let terminal = try persistFlagConfigExpiry(
                    connection,
                    authority: &authority
                )
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return terminal ? .terminal : .restricted(.expired)
            }
            let diskState = try EluRuntimeDatabase.loadState(connection, validateQueue: false)
            guard diskState == state else { throw EluRuntimeQueueError.generationMismatch }
            guard case let .allowed(authorization) = managerAuthorization,
                  flagAuthorization(authorization, matches: authority)
            else {
                try deleteFlagCacheIfMatches(
                    connection,
                    token: cleanupToken
                )
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .restricted(authority.restriction ?? .missing)
            }
            let currentWitness = try EluV1FlagEvaluationWitness(
                authorization: authorization,
                runtime: diskState.snapshot,
                versions: versions
            )
            let currentWitnessHash = try EluV1FlagCodec.witnessHash(currentWitness)
            guard let row = try EluRuntimeDatabase.readFlagRequest(connection) else {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .miss
            }
            guard row.storageSchema == 1 else {
                try connection.execute("ROLLBACK")
                return .terminal
            }
            let requestState: EluV1FlagRequestCacheState
            let body: Data?
            do {
                requestState = try EluV1FlagStorageCodec.decodeRequestState(row.metadataBody)
                body = try EluRuntimeDatabase.readFlagCacheBody(connection, row: row)
            } catch let error as EluSQLiteFailure {
                throw error
            } catch EluRuntimeQueueError.databaseUnavailable {
                throw EluRuntimeQueueError.databaseUnavailable
            } catch EluRuntimeQueueError.unsupportedSchemaVersion(_) {
                try connection.execute("ROLLBACK")
                return .terminal
            } catch {
                // Reads never quarantine or recreate request/cache metadata.
                // Only begin may rotate a current-corrupt request epoch.
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .miss
            }
            guard let body,
                  requestState.cacheRecordId != nil,
                  requestState.cachedWitnessHash == currentWitnessHash,
                  requestState.barrierGeneration == authority.barrierGeneration,
                  let effectiveExpiry = requestState.effectiveExpiresAt
            else {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .miss
            }
            if (try effectiveExpiry.validated()).isAtOrBefore(sample.wallDate)
                || (try flagCacheDeadlineExpired(
                    requestState,
                    declaredBodyBytes: row.declaredBodyBytes,
                    bodySha256: row.bodySha256,
                    at: sample
                ))
            {
                var expired = requestState
                try expireFlagCacheState(&expired)
                flagCacheDeadline = nil
                try EluRuntimeDatabase.replaceFlagRequest(
                    connection,
                    state: expired,
                    cacheBody: nil
                )
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .miss
            }
            let cached: (witness: EluV1FlagEvaluationWitness, response: EluV1FlagResponse)
            do {
                cached = try EluV1FlagCodec.decodeCache(body)
            } catch EluV1FlagContractError.unsupportedSchemaVersion {
                try connection.execute("ROLLBACK")
                return .terminal
            } catch {
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .miss
            }
            let finalTokenMatches = cleanupToken.map {
                requestState.storeEpoch == $0.storeEpoch
                    && requestState.requestGeneration == $0.requestGeneration
                    && requestState.barrierGeneration == $0.barrierGeneration
                    && requestState.cachedWitnessHash == $0.witnessHash
                    && cached.response.requestId == $0.requestId
                    && cached.witness == $0.witness
            } ?? true
            guard finalTokenMatches,
                  cached.witness == currentWitness,
                  try EluV1FlagCodec.witnessHash(cached.witness) == currentWitnessHash,
                  cached.response.flagsRevision == requestState.flagsRevision,
                  cached.response.evaluatedAt == requestState.evaluatedAt,
                  cached.response.expiresAt == requestState.responseExpiresAt
            else {
                try deleteFlagCacheIfMatches(
                    connection,
                    token: cleanupToken
                )
                try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
                try connection.execute("COMMIT")
                return .miss
            }
            try EluRuntimeDatabase.updateFlagAuthority(connection, value: authority)
            try connection.execute("COMMIT")
            return .hit(
                EluV1FlagCacheSnapshot(
                    witness: cached.witness,
                    response: cached.response
                )
            )
        } catch EluRuntimeQueueError.generationMismatch {
            try? connection.execute("ROLLBACK")
            return .restricted(.wallRollback)
        } catch EluRuntimeQueueError.flagAuthorityTerminal {
            try? connection.execute("ROLLBACK")
            return .terminal
        } catch EluRuntimeQueueError.unsupportedSchemaVersion(_) {
            try? connection.execute("ROLLBACK")
            return .terminal
        } catch {
            try? connection.execute("ROLLBACK")
            return .restricted(.storageUnavailable)
        }
    }

    func flagWitnessFingerprint(versions: EluVersionContext) -> String? {
        guard let manager = flagConfigManager else {
            return nil
        }
        do {
            let connection = try requireResources().connection
            try preflightOpaqueFlagRequest(connection)
            var authority = try loadFlagAuthority(connection)
            guard let sample = sampleFlagClock() else {
                return nil
            }
            guard case let .allowed(authorization) = manager.currentFlagAuthorization(
                now: sample.wallDate
            ) else {
                return nil
            }
            try advanceFlagWall(&authority, to: sample.wall)
            guard flagAuthorization(authorization, matches: authority),
                  !(try flagConfigIsExpired(authority, at: sample))
            else {
                return nil
            }
            let witness = try EluV1FlagEvaluationWitness(
                authorization: authorization,
                runtime: state.snapshot,
                versions: versions
            )
            return "\(authorization.activationGeneration):"
                + (try EluV1FlagCodec.witnessHash(witness))
        } catch EluRuntimeQueueError.generationMismatch {
            poisonFlagClock()
            return nil
        } catch {
            return nil
        }
    }

    private func freshFlagRequestState(
        barrierGeneration: Int64
    ) -> EluV1FlagRequestCacheState {
        EluV1FlagRequestCacheState(
            storeEpoch: flagStoreEpochGenerator(),
            requestGeneration: 1,
            activeRequestId: nil,
            barrierGeneration: barrierGeneration,
            activeWitnessHash: nil,
            cacheRecordId: nil,
            cachedWitnessHash: nil,
            flagsRevision: nil,
            evaluatedAt: nil,
            responseExpiresAt: nil,
            effectiveExpiresAt: nil
        )
    }

    /// Final-recheck cleanup is deliberately token-scoped. A stale response
    /// can remove only the exact cache entry it just committed; a newer begin,
    /// cache, epoch, barrier, or witness turns this into a no-op.
    private func deleteFlagCacheIfMatches(
        _ connection: EluSQLiteConnection,
        token: EluV1FlagBeginToken?
    ) throws {
        guard let token,
              let row = try EluRuntimeDatabase.readFlagRequest(connection),
              row.storageSchema == 1,
              let request = try? EluV1FlagStorageCodec.decodeRequestState(row.metadataBody),
              request.storeEpoch == token.storeEpoch,
              request.requestGeneration == token.requestGeneration,
              request.barrierGeneration == token.barrierGeneration,
              request.cachedWitnessHash == token.witnessHash
        else {
            return
        }
        let cached: (witness: EluV1FlagEvaluationWitness, response: EluV1FlagResponse)
        do {
            guard let body = try EluRuntimeDatabase.readFlagCacheBody(
                connection,
                row: row
            ) else {
                return
            }
            cached = try EluV1FlagCodec.decodeCache(body)
        } catch {
            return
        }
        guard cached.witness == token.witness,
              cached.response.requestId == token.requestId,
              (try? EluV1FlagCodec.witnessHash(cached.witness)) == token.witnessHash
        else {
            return
        }
        var invalidated = request
        try expireFlagCacheState(&invalidated)
        try EluRuntimeDatabase.replaceFlagRequest(
            connection,
            state: invalidated,
            cacheBody: nil
        )
    }

    private func expireFlagCacheState(
        _ request: inout EluV1FlagRequestCacheState
    ) throws {
        flagCacheDeadline = nil
        guard request.requestGeneration < 9_007_199_254_740_991 else {
            // Begin is the sole operation allowed to rotate the store epoch.
            request.activeRequestId = nil
            request.activeWitnessHash = nil
            request.cacheRecordId = nil
            request.cachedWitnessHash = nil
            request.flagsRevision = nil
            request.evaluatedAt = nil
            request.responseExpiresAt = nil
            request.effectiveExpiresAt = nil
            return
        }
        request.requestGeneration += 1
        request.activeRequestId = nil
        request.activeWitnessHash = nil
        request.cacheRecordId = nil
        request.cachedWitnessHash = nil
        request.flagsRevision = nil
        request.evaluatedAt = nil
        request.responseExpiresAt = nil
        request.effectiveExpiresAt = nil
    }

    private func flagConfigIsExpired(
        _ authority: EluV1FlagDurableAuthority,
        at sample: FlagClockSample
    ) throws -> Bool {
        guard authority.isAllowed, let expiry = authority.configExpiresAt else { return false }
        return try expiry.validated() <= sample.wall
            || flagConfigDeadlineExpired(authority, at: sample)
    }

    private func persistFlagConfigExpiry(
        _ connection: EluSQLiteConnection,
        authority: inout EluV1FlagDurableAuthority
    ) throws -> Bool {
        guard authority.restriction != .terminal else { return true }
        guard authority.barrierGeneration < 9_007_199_254_740_991 else {
            authority.restriction = .terminal
            try invalidateFlagRequest(
                connection,
                barrierGeneration: authority.barrierGeneration
            )
            flagConfigManager?.rejectPendingFlagConfig(nil)
            flagConfigDeadline = nil
            flagCacheDeadline = nil
            return true
        }
        authority.restriction = .expired
        authority.barrierGeneration += 1
        try invalidateFlagRequest(
            connection,
            barrierGeneration: authority.barrierGeneration
        )
        flagConfigManager?.rejectPendingFlagConfig(nil)
        flagConfigDeadline = nil
        flagCacheDeadline = nil
        return false
    }

    private func flagAuthorization(
        _ authorization: EluV1FlagAuthorizationSnapshot,
        matches authority: EluV1FlagDurableAuthority
    ) -> Bool {
        guard authority.isAllowed,
              authority.barrierGeneration == authorization.barrierGeneration,
              authority.exactConstructorSiteKey == authorization.exactConstructorSiteKey,
              authority.siteNamespaceDigest == authorization.siteNamespaceDigest,
              authority.siteId == authorization.siteId,
              authority.configRevision == authorization.configRevision,
              authority.semanticHash == authorization.configSemanticHash,
              authority.endpoint == authorization.endpoint.absoluteString,
              authority.ordering == EluV1StoredTimestamp(authorization.configIssuedAt),
              authority.configExpiresAt == EluV1StoredTimestamp(authorization.configExpiresAt)
        else {
            return false
        }
        return true
    }

    private func flagAuthorityProjection(
        _ authority: EluV1FlagDurableAuthority,
        matches candidate: EluV1PreparedFlagConfig
    ) -> Bool {
        let siteOwnershipMatches = candidate.siteId.map { authority.siteId == $0 } ?? true
        return authority.ordering == EluV1StoredTimestamp(candidate.issuedAt)
            && authority.semanticHash == candidate.semanticHash
            && authority.exactConstructorSiteKey == candidate.exactConstructorSiteKey
            && authority.siteNamespaceDigest == candidate.siteNamespaceDigest
            && siteOwnershipMatches
            && authority.configRevision == candidate.configRevision
            && authority.endpoint == candidate.endpoint?.absoluteString
            && authority.configExpiresAt == EluV1StoredTimestamp(candidate.expiresAt)
    }

    /// Validates raw config and effective privacy on this actor and installs a
    /// non-transferable executable authority or terminal latch.
    func submitCaptureAuthority(
        configData: Data,
        effectivePrivacyStateData: Data?
    ) -> EluV1CaptureAuthorityUpdateResult {
        // Lease time starts before any wall-clock read, decoding, hashing, or
        // policy validation. Validation latency must consume the lease.
        let monotonicOrigin = continuousClock()
        guard let manager = captureConfigManager,
              let ownerNamespaceHash,
              !isPoisoned,
              resources != nil
        else {
            return terminateCaptureAuthority(reason: .malformed)
        }

        let update: EluV1ConfigUpdateResult
        do {
            update = try manager.update(configData: configData, now: clock())
        } catch let error as EluV1ConfigResolutionError {
            let reason: EluV1CaptureAuthorityTerminalReason = error == .conflictingConfigAtIssuedAt
                ? .conflict
                : .malformed
            let candidate = manager.validatedCandidateIdentity()
            let candidateBoundary = candidate.map(Self.captureBoundary)
            if let expired = expiredTerminalDominating(candidateBoundary) {
                return .terminated(expired)
            }
            if reason == .malformed,
               let restriction = restrictionTerminalDominating(
                   candidateBoundary,
                   candidateContextRevision: nil
               )
            {
                return .terminated(restriction)
            }
            return terminateCaptureAuthority(
                candidateBoundary: candidateBoundary,
                policySourceHash: candidate?.policySourceHash,
                reason: reason
            )
        } catch {
            if let expired = expiredTerminalDominating(nil) {
                return .terminated(expired)
            }
            if let restriction = restrictionTerminalDominating(
                nil,
                candidateContextRevision: nil
            ) {
                return .terminated(restriction)
            }
            return terminateCaptureAuthority(reason: .malformed)
        }

        let validatedCandidate = manager.validatedCandidateIdentity()
        let validatedBoundary = validatedCandidate.map(Self.captureBoundary)
        if let expired = expiredTerminalDominating(validatedBoundary) {
            return .terminated(expired)
        }

        switch update {
        case .disabled:
            return terminateCaptureAuthority(
                trustedBoundary: validatedBoundary,
                candidateBoundary: validatedBoundary,
                policySourceHash: validatedCandidate?.policySourceHash,
                reason: .disabled
            )
        case .revoked:
            return terminateCaptureAuthority(
                trustedBoundary: validatedBoundary,
                candidateBoundary: validatedBoundary,
                policySourceHash: validatedCandidate?.policySourceHash,
                reason: .revoked
            )
        case .expired:
            return terminateCaptureAuthority(
                trustedBoundary: validatedBoundary,
                candidateBoundary: validatedBoundary,
                policySourceHash: validatedCandidate?.policySourceHash,
                reason: .expired
            )
        case .stale:
            if let restriction = restrictionTerminalDominating(
                validatedBoundary,
                candidateContextRevision: nil
            ) {
                return .terminated(restriction)
            }
            return terminateCaptureAuthority(
                candidateBoundary: validatedBoundary,
                policySourceHash: validatedCandidate?.policySourceHash,
                reason: .stale
            )
        case .enabled:
            break
        }

        let resolution: EluV1ConfigResolution
        let authorizationNow = clock()
        do {
            resolution = try manager.authorize(
                effectivePrivacyStateData: effectivePrivacyStateData,
                identity: identitySnapshot,
                now: authorizationNow
            )
        } catch {
            if let expired = expiredTerminalDominating(validatedBoundary) {
                return .terminated(expired)
            }
            if let restriction = restrictionTerminalDominating(
                validatedBoundary,
                candidateContextRevision: nil
            ) {
                return .terminated(restriction)
            }
            return terminateCaptureAuthority(
                trustedBoundary: validatedBoundary,
                candidateBoundary: validatedBoundary,
                policySourceHash: validatedCandidate?.policySourceHash,
                reason: .malformed
            )
        }

        let boundary = EluV1CaptureConfigBoundary(
            issuedAt: resolution.exactIssuedAt,
            semanticHash: resolution.configSemanticHash
        )
        if let pinnedConfigSiteId {
            guard pinnedConfigSiteId == resolution.siteId else {
                return terminateCaptureAuthority(
                    trustedBoundary: boundary,
                    candidateBoundary: boundary,
                    policySourceHash: resolution.policySourceHash,
                    contextRevision: resolution.decisionContextRevision,
                    reason: .siteChanged
                )
            }
        } else {
            pinnedConfigSiteId = resolution.siteId
        }

        // Once this exact config boundary has expired under either wall or
        // monotonic time, mutable identity/context changes cannot revive it.
        if case let .terminal(current) = captureAuthority,
           current.reason == .expired,
           current.trustedConfigBoundary == boundary
        {
            return .terminated(current)
        }

        guard resolution.captureAuthorization == .authorized,
              let decisionHash = resolution.decisionHash,
              !state.identity.optedOut
        else {
            let reason: EluV1CaptureAuthorityTerminalReason
            switch resolution.captureAuthorization {
            case .restricted:
                reason = .privacyBlocked
            case let .invalid(invalidReason):
                if invalidReason == .contextRevisionMismatch,
                   let candidateContext = resolution.decisionContextRevision,
                   candidateContext < state.identity.contextRevision
                {
                    reason = .stale
                } else {
                    reason = .malformed
                }
            case .authorized:
                reason = .privacyBlocked
            }
            if reason == .stale || reason == .malformed,
               let restriction = restrictionTerminalDominating(
                   boundary,
                   candidateContextRevision: resolution.decisionContextRevision
               )
            {
                return .terminated(restriction)
            }
            return terminateCaptureAuthority(
                trustedBoundary: boundary,
                candidateBoundary: boundary,
                policySourceHash: resolution.policySourceHash,
                contextRevision: resolution.decisionContextRevision,
                reason: reason
            )
        }

        // Restriction dominates a same-config, same-context allow. A higher
        // context witness or newer config is required to loosen it.
        if case let .terminal(current) = captureAuthority,
           current.reason == .privacyBlocked,
           current.trustedConfigBoundary == boundary,
           current.contextRevision == state.identity.contextRevision
        {
            return .terminated(current)
        }

        guard !resolution.exactExpiresAt.isAtOrBefore(authorizationNow),
              let wallRemaining = resolution.exactExpiresAt.floorNanoseconds(
                  after: authorizationNow
              ),
              let declaredRemaining = resolution.exactExpiresAt.floorNanoseconds(
                  since: resolution.exactIssuedAt
              ),
              let durableRemaining = resolution.exactExpiresAt.floorNanoseconds(
                  after: durableWallFloor
              )
        else {
            return terminateCaptureAuthority(
                trustedBoundary: boundary,
                candidateBoundary: boundary,
                policySourceHash: resolution.policySourceHash,
                contextRevision: resolution.decisionContextRevision,
                reason: .expired
            )
        }
        let remainingNanoseconds = min(
            min(wallRemaining, declaredRemaining),
            durableRemaining
        )
        guard remainingNanoseconds > 0,
              let monotonicBudget = continuousBudgetConverter(remainingNanoseconds),
              monotonicBudget > 0
        else {
            return terminateCaptureAuthority(
                trustedBoundary: boundary,
                candidateBoundary: boundary,
                policySourceHash: resolution.policySourceHash,
                contextRevision: resolution.decisionContextRevision,
                reason: .expired
            )
        }
        let monotonicInstalledAt = continuousClock()
        guard monotonicInstalledAt &- monotonicOrigin < monotonicBudget else {
            return terminateCaptureAuthority(
                trustedBoundary: boundary,
                candidateBoundary: boundary,
                policySourceHash: resolution.policySourceHash,
                contextRevision: resolution.decisionContextRevision,
                reason: .expired
            )
        }

        let epoch = nextAuthorityEpoch()
        let authority = EluV1CaptureAuthoritySnapshot(
            ownerEpoch: epoch,
            configBoundary: boundary,
            expiresAt: resolution.exactExpiresAt,
            policySourceHash: resolution.policySourceHash,
            decisionHash: decisionHash,
            ownerNamespaceHash: ownerNamespaceHash,
            configSiteId: resolution.siteId,
            streamId: state.streamId,
            identityRevision: state.identity.revision,
            contextRevision: state.identity.contextRevision,
            identityOptedOut: state.identity.optedOut,
            monotonicStartedAt: monotonicOrigin,
            monotonicBudget: monotonicBudget,
            idleTimeoutSeconds: resolution.sessionIdleTimeoutSeconds,
            maximumDurationSeconds: resolution.sessionMaximumDurationSeconds
        )
        captureAuthority = .authorized(authority)
        return .activated(authority)
    }

    /// Creates and consumes admission entirely inside this actor operation.
    /// No authority token or detached resolution is returned to the caller.
    func capture(_ command: EluV1CaptureCommand) -> EluV1CaptureResult {
        let before = state.snapshot
        guard command.kind == .capture || command.kind == .screen,
              validCaptureName(command.name),
              validateCaptureProperties(command.properties),
              let occurredAt = canonicalDate(command.occurredAt),
              occurredAt >= state.identity.updatedAt
        else {
            return .rejected(.invalidEvent, snapshot: before)
        }

        let authority: EluV1CaptureAuthoritySnapshot
        switch captureAuthority {
        case .absent:
            return .rejected(.authorityAbsent, snapshot: before)
        case .terminal:
            return .rejected(.authorityTerminal, snapshot: before)
        case let .authorized(snapshot):
            authority = snapshot
        }

        guard authorityWitnessMatches(authority, diskState: state) else {
            return .rejected(
                state.identity.optedOut ? .optedOut : .authorityWitnessChanged,
                snapshot: before
            )
        }
        guard authorityIsLive(authority, wallNow: clock(), monotonicNow: continuousClock()) else {
            latchExpiredAuthority(authority)
            return .rejected(.authorityExpired, snapshot: before)
        }

        let prepared: (identity: EluIdentityState, draft: EluEventDraft)
        do {
            prepared = try prepareCapture(
                command: command,
                occurredAt: occurredAt,
                authority: authority
            )
        } catch {
            return .rejected(.invalidEvent, snapshot: before)
        }

        for attempt in 0 ... 1 {
            do {
                let result = try commitPrepared(
                    expectedGeneration: state.generation,
                    identity: prepared.identity,
                    flagContext: state.flagContext,
                    drafts: [.event(prepared.draft)],
                    surfaceProvenNotCommitted: true,
                    prewriteValidation: { diskState in
                        guard self.authorityWitnessMatches(authority, diskState: diskState) else {
                            throw EluRuntimeQueueError.generationMismatch
                        }
                        guard self.authorityIsLive(
                            authority,
                            wallNow: self.clock(),
                            monotonicNow: self.continuousClock()
                        ) else {
                            throw EluRuntimeQueueError.captureAuthorityExpiredBeforeWrite
                        }
                    }
                )
                guard let record = result.records.first else {
                    return .rejected(.invalidEvent, snapshot: before)
                }
                return .accepted(record, snapshot: result.snapshot)
            } catch EluRuntimeQueueError.provenNotCommitted where attempt == 0 {
                guard !isPoisoned, resources != nil else {
                    return .rejected(
                        .storageProvenNotCommitted,
                        snapshot: state.snapshot
                    )
                }
                guard authorityWitnessMatches(authority, diskState: state) else {
                    return .rejected(
                        state.identity.optedOut ? .optedOut : .authorityWitnessChanged,
                        snapshot: state.snapshot
                    )
                }
                guard authorityIsLive(
                    authority,
                    wallNow: clock(),
                    monotonicNow: continuousClock()
                ) else {
                    latchExpiredAuthority(authority)
                    return .rejected(.authorityExpired, snapshot: state.snapshot)
                }
                continue
            } catch EluRuntimeQueueError.provenNotCommitted {
                return .rejected(.storageProvenNotCommitted, snapshot: state.snapshot)
            } catch EluRuntimeQueueError.ambiguousCommit {
                return .rejected(.storageOutcomeUnknown, snapshot: before)
            } catch EluRuntimeQueueError.poisoned {
                // This capture could not acquire the already-poisoned owner,
                // so no transaction or write was attempted for this call.
                return .rejected(.storageProvenNotCommitted, snapshot: state.snapshot)
            } catch EluRuntimeQueueError.queueCountLimitExceeded,
                    EluRuntimeQueueError.queueByteLimitExceeded {
                return .rejected(.queueLimit, snapshot: state.snapshot)
            } catch EluRuntimeQueueError.generationMismatch {
                return .rejected(.authorityWitnessChanged, snapshot: state.snapshot)
            } catch EluRuntimeQueueError.captureAuthorityExpiredBeforeWrite {
                latchExpiredAuthority(authority)
                return .rejected(.authorityExpired, snapshot: state.snapshot)
            } catch EluRuntimeQueueError.invalidState {
                if !authorityIsLive(
                    authority,
                    wallNow: clock(),
                    monotonicNow: continuousClock()
                ) {
                    latchExpiredAuthority(authority)
                    return .rejected(.authorityExpired, snapshot: state.snapshot)
                }
                return .rejected(.authorityWitnessChanged, snapshot: state.snapshot)
            } catch {
                return .rejected(.invalidEvent, snapshot: state.snapshot)
            }
        }
        return .rejected(.storageProvenNotCommitted, snapshot: state.snapshot)
    }

    @discardableResult
    func registerStandaloneSuperProperties(
        _ properties: [String: EluJSONValue]
    ) throws -> EluRuntimeQueueSnapshot {
        guard !properties.isEmpty,
              validateCaptureProperties(properties),
              Set(properties.keys).isDisjoint(with: Self.reservedVersionProperties),
              state.identity.contextRevision < Int64.max,
              let now = canonicalDate(clock()),
              now >= state.identity.updatedAt
        else {
            throw EluRuntimeQueueError.invalidRecord
        }
        var identity = state.identity
        for (key, value) in properties { identity.superProperties[key] = value }
        guard identity.superProperties.count <= EluIdentityState.maximumSuperProperties else {
            throw EluRuntimeQueueError.invalidRecord
        }
        identity.contextRevision += 1
        identity.updatedAt = now
        return try commitPrepared(
            expectedGeneration: state.generation,
            identity: identity,
            flagContext: state.flagContext,
            drafts: []
        ).snapshot
    }

    @discardableResult
    func unregisterStandaloneSuperProperty(_ key: String) throws -> EluRuntimeQueueSnapshot {
        guard EluIdentityState.valid(key, maximumLength: 256),
              !Self.reservedVersionProperties.contains(key),
              state.identity.contextRevision < Int64.max,
              let now = canonicalDate(clock()),
              now >= state.identity.updatedAt
        else {
            throw EluRuntimeQueueError.invalidRecord
        }
        var identity = state.identity
        identity.superProperties.removeValue(forKey: key)
        identity.contextRevision += 1
        identity.updatedAt = now
        return try commitPrepared(
            expectedGeneration: state.generation,
            identity: identity,
            flagContext: state.flagContext,
            drafts: []
        ).snapshot
    }

    @discardableResult
    func markStandaloneBackgrounded(at rawDate: Date? = nil) throws -> EluV1BackgroundResult {
        let before = state.snapshot
        guard !state.identity.optedOut else { return .rejectedOptedOut(before) }
        guard var session = state.identity.session else { return .unchanged(before) }
        guard let occurredAt = canonicalDate(rawDate ?? clock()),
              occurredAt >= state.identity.updatedAt,
              occurredAt >= session.lastActivityAt
        else {
            throw EluRuntimeQueueError.invalidState
        }
        if session.lifecycle == .background {
            if session.backgroundedAt == occurredAt { return .unchanged(before) }
            throw EluRuntimeQueueError.invalidState
        }
        session.lifecycle = .background
        session.backgroundedAt = occurredAt
        var identity = state.identity
        identity.session = session
        identity.updatedAt = occurredAt
        let snapshot = try commitPrepared(
            expectedGeneration: state.generation,
            identity: identity,
            flagContext: state.flagContext,
            drafts: []
        ).snapshot
        return .changed(snapshot)
    }

    func captureAuthorityForTesting() -> EluV1CaptureAuthorityState {
        captureAuthority
    }

    func appendEvent(
        _ draft: EluEventDraft,
        sessionUpdate: EluRuntimeEventSessionUpdate
    ) throws -> EluQueuedRecord {
        guard ownerNamespaceHash == nil else {
            throw EluRuntimeQueueError.standaloneLegacyEntryPointUnavailable
        }
        guard draft.occurredAt.timeIntervalSinceReferenceDate.isFinite,
              let canonicalOccurredAt = EluRFC3339.date(
                  from: EluRFC3339.string(from: draft.occurredAt)
              )
        else {
            throw EluRuntimeQueueError.invalidRecord
        }
        var canonicalDraft = draft
        canonicalDraft.occurredAt = canonicalOccurredAt
        let identity: EluIdentityState
        do {
            identity = try prepareEventIdentity(
                sessionUpdate: sessionUpdate,
                draft: canonicalDraft
            )
        } catch {
            throw mapOperationError(error)
        }
        let result = try commitPrepared(
            expectedGeneration: state.generation,
            identity: identity,
            flagContext: state.flagContext,
            drafts: [.event(canonicalDraft)]
        )
        guard let record = result.records.first else {
            throw EluRuntimeQueueError.invalidRecord
        }
        return record
    }

    func applyMutation(
        _ transition: EluRuntimeMutationTransition,
        versions: EluVersionContext,
        expectedGeneration: Int64
    ) throws -> [EluQueuedRecord] {
        guard ownerNamespaceHash == nil else {
            throw EluRuntimeQueueError.standaloneLegacyEntryPointUnavailable
        }
        guard expectedGeneration == state.generation else {
            throw EluRuntimeQueueError.generationMismatch
        }
        let occurredAt = clock()
        let prepared: (
            identity: EluIdentityState,
            flagContext: EluPersistedFlagContext,
            drafts: [EluPreparedRecordDraft]
        )
        do {
            prepared = try prepareMutationTransition(
                transition,
                occurredAt: occurredAt,
                versions: versions
            )
        } catch {
            throw mapOperationError(error)
        }
        return try commitPrepared(
            expectedGeneration: expectedGeneration,
            identity: prepared.identity,
            flagContext: prepared.flagContext,
            drafts: prepared.drafts
        ).records
    }

    /// Applies flag evaluation context through the owner runtime so the
    /// durable request barrier and the in-memory witness advance atomically.
    /// This is separate from the legacy standalone mutation entrypoint above.
    @discardableResult
    func setFlagPersonProperties(
        _ properties: [String: EluJSONValue],
        versions: EluVersionContext,
        expectedGeneration: Int64
    ) throws -> EluRuntimeQueueSnapshot {
        guard ownerNamespaceHash != nil else {
            throw EluRuntimeQueueError.invalidState
        }
        guard expectedGeneration == state.generation else {
            throw EluRuntimeQueueError.generationMismatch
        }
        let prepared: (
            identity: EluIdentityState,
            flagContext: EluPersistedFlagContext,
            drafts: [EluPreparedRecordDraft]
        )
        do {
            prepared = try prepareMutationTransition(
                .setPersonProperties(set: properties, setOnce: [:], unset: []),
                occurredAt: clock(),
                versions: versions
            )
        } catch {
            throw mapOperationError(error)
        }
        return try commitPrepared(
            expectedGeneration: expectedGeneration,
            identity: prepared.identity,
            flagContext: prepared.flagContext,
            drafts: prepared.drafts
        ).snapshot
    }

    @discardableResult
    func recordEligibleActivity(
        expectedGeneration: Int64,
        timeoutSeconds requestedTimeoutSeconds: Int = 1_800
    ) throws -> EluRuntimeQueueSnapshot {
        guard ownerNamespaceHash == nil else {
            throw EluRuntimeQueueError.standaloneLegacyEntryPointUnavailable
        }
        guard expectedGeneration == state.generation else {
            throw EluRuntimeQueueError.generationMismatch
        }
        let timeoutSeconds = min(max(requestedTimeoutSeconds, 60), 36_000)
        let observedNow = clock()
        guard observedNow.timeIntervalSinceReferenceDate.isFinite,
              let now = EluRFC3339.date(from: EluRFC3339.string(from: observedNow)),
              now >= state.identity.updatedAt
        else {
            throw EluRuntimeQueueError.invalidState
        }
        let previousSession = state.identity.session
        let shouldRotate: Bool
        if let previousSession {
            try validateStoredSession(
                previousSession,
                identityUpdatedAt: state.identity.updatedAt
            )
            let idleSeconds = now.timeIntervalSince(previousSession.lastActivityAt)
            let durationSeconds = now.timeIntervalSince(previousSession.startedAt)
            shouldRotate = idleSeconds
                >= Double(min(previousSession.timeoutSeconds, timeoutSeconds))
                || durationSeconds >= Double(EluSessionState.requiredMaximumDurationSeconds)
        } else {
            shouldRotate = true
        }

        let session: EluSessionState
        if shouldRotate {
            let sessionId = sessionIdGenerator()
            guard sessionId != previousSession?.id else {
                throw EluRuntimeQueueError.invalidState
            }
            session = try EluSessionState(
                id: sessionId,
                startedAt: now,
                lastActivityAt: now,
                timeoutSeconds: timeoutSeconds
            )
        } else if var resumed = previousSession {
            resumed.lastActivityAt = now
            resumed.timeoutSeconds = timeoutSeconds
            resumed.lifecycle = .active
            resumed.backgroundedAt = nil
            try resumed.validate()
            session = resumed
        } else {
            throw EluRuntimeQueueError.invalidState
        }

        var identity = state.identity
        identity.session = session
        identity.updatedAt = now
        return try commitPrepared(
            expectedGeneration: expectedGeneration,
            identity: identity,
            flagContext: state.flagContext,
            drafts: []
        ).snapshot
    }

    @discardableResult
    func setOptedOut(
        _ optedOut: Bool,
        expectedGeneration: Int64
    ) throws -> EluRuntimeQueueSnapshot {
        guard expectedGeneration == state.generation else {
            throw EluRuntimeQueueError.generationMismatch
        }
        if state.identity.optedOut == optedOut {
            return state.snapshot
        }
        guard state.identity.contextRevision < Int64.max else {
            throw EluRuntimeQueueError.counterExhausted
        }
        var identity = state.identity
        identity.optedOut = optedOut
        if optedOut {
            identity.session = nil
        }
        identity.contextRevision += 1
        guard let now = canonicalDate(clock()), now >= identity.updatedAt else {
            throw EluRuntimeQueueError.invalidState
        }
        identity.updatedAt = now
        return try commitPrepared(
            expectedGeneration: expectedGeneration,
            identity: identity,
            flagContext: state.flagContext,
            drafts: []
        ).snapshot
    }

    @discardableResult
    func reset(expectedGeneration: Int64) throws -> EluRuntimeQueueSnapshot {
        guard expectedGeneration == state.generation else {
            throw EluRuntimeQueueError.generationMismatch
        }
        guard state.identity.revision < Int64.max,
              state.identity.contextRevision < Int64.max
        else {
            throw EluRuntimeQueueError.counterExhausted
        }
        let anonymousId = anonymousIdGenerator()
        guard EluIdentityState.valid(anonymousId, maximumLength: 256),
              anonymousId != state.identity.anonymousId
        else {
            throw EluRuntimeQueueError.invalidState
        }
        var identity = state.identity
        identity.anonymousId = anonymousId
        identity.userId = nil
        identity.groups = [:]
        identity.superProperties = [:]
        identity.session = nil
        identity.revision += 1
        identity.contextRevision += 1
        identity.updatedAt = clock()
        return try commitPrepared(
            expectedGeneration: expectedGeneration,
            identity: identity,
            flagContext: try EluPersistedFlagContext(),
            drafts: []
        ).snapshot
    }

    private func commitPrepared(
        expectedGeneration: Int64,
        identity: EluIdentityState,
        flagContext: EluPersistedFlagContext,
        drafts: [EluPreparedRecordDraft],
        surfaceProvenNotCommitted: Bool = false,
        prewriteValidation: ((EluStoredRuntimeState) throws -> Void)? = nil
    ) throws -> (records: [EluQueuedRecord], snapshot: EluRuntimeQueueSnapshot) {
        let resources = try requireResources()
        let canonicalIdentity: EluIdentityState
        let canonicalFlagContext: EluPersistedFlagContext
        do {
            try identity.validate()
            try flagContext.validate()
            canonicalIdentity = try EluRuntimeCanonical.value(identity)
            canonicalFlagContext = try EluRuntimeCanonical.value(flagContext)
        } catch {
            throw EluRuntimeQueueError.invalidState
        }
        guard expectedGeneration == state.generation,
              canonicalIdentity.contextRevision >= canonicalIdentity.revision,
              drafts.count <= 1_000
        else {
            throw EluRuntimeQueueError.invalidState
        }

        let connection = resources.connection
        var transactionBegan = false
        var commitAttempted = false
        do {
            try faultInjector?.hit(.beforeBegin)
            try connection.execute("BEGIN IMMEDIATE")
            transactionBegan = true
            try faultInjector?.hit(.afterBegin)
            let diskState = try EluRuntimeDatabase.loadState(
                connection,
                validateQueue: false
            )
            guard diskState == state,
                  diskState.generation == expectedGeneration
            else {
                throw EluRuntimeQueueError.generationMismatch
            }
            try faultInjector?.hit(.afterStateRead)

            let storedRecords = try makeRecords(
                drafts,
                identity: canonicalIdentity,
                streamId: diskState.streamId,
                startingAt: diskState.nextSequence
            )
            let addedBytes = try sumBytes(storedRecords)
            guard Int64(storedRecords.count) <= Int64.max - diskState.liveCount else {
                throw EluRuntimeQueueError.counterExhausted
            }
            let nextCount = diskState.liveCount + Int64(storedRecords.count)
            if !storedRecords.isEmpty,
               nextCount > Int64(limits.maximumCount)
            {
                throw EluRuntimeQueueError.queueCountLimitExceeded
            }
            guard addedBytes <= Int64.max - diskState.liveBytes else {
                throw EluRuntimeQueueError.counterExhausted
            }
            let nextBytes = diskState.liveBytes + addedBytes
            if !storedRecords.isEmpty,
               nextBytes > Int64(limits.maximumBytes)
            {
                throw EluRuntimeQueueError.queueByteLimitExceeded
            }
            guard Int64(storedRecords.count) <= Int64.max - diskState.nextSequence,
                  diskState.generation < Int64.max
            else {
                throw EluRuntimeQueueError.counterExhausted
            }

            try prewriteValidation?(diskState)

            for (index, storedRecord) in storedRecords.enumerated() {
                try EluRuntimeDatabase.insert(connection, storedRecord: storedRecord)
                try faultInjector?.hit(.afterRecordInsert(index))
            }

            let nextState = EluStoredRuntimeState(
                generation: diskState.generation + 1,
                identity: canonicalIdentity,
                flagContext: canonicalFlagContext,
                streamId: diskState.streamId,
                nextSequence: diskState.nextSequence + Int64(storedRecords.count),
                headSequence: diskState.headSequence
                    ?? storedRecords.first?.record.sequence,
                liveCount: nextCount,
                liveBytes: nextBytes
            )
            let flagWitnessChanged = diskState.identity.contextRevision
                != canonicalIdentity.contextRevision
                || diskState.identity.revision != canonicalIdentity.revision
                || diskState.identity.anonymousId != canonicalIdentity.anonymousId
                || diskState.identity.userId != canonicalIdentity.userId
                || diskState.identity.groups != canonicalIdentity.groups
                || diskState.identity.optedOut != canonicalIdentity.optedOut
                || diskState.flagContext != canonicalFlagContext
            if databaseSchemaVersion == EluSQLiteRuntimeSchema.flagDatabaseVersion,
               flagWitnessChanged
            {
                do {
                    let authority = try loadFlagAuthority(connection)
                    try invalidateFlagRequest(
                        connection,
                        barrierGeneration: authority.barrierGeneration
                    )
                } catch EluRuntimeQueueError.flagAuthorityTerminal {
                    // A corrupt/future/missing flag authority is already
                    // permanently unreadable. Preserve its bytes and keep the
                    // public identity/capture state machine independent.
                } catch EluRuntimeQueueError.corruptStorage {
                    // Known-current flag-only request/header corruption is
                    // unreadable but cannot roll back core identity/context.
                } catch EluRuntimeQueueError.unsupportedSchemaVersion(_) {
                    // Future flag rows remain byte-preserved and fail closed.
                } catch is EluV1FlagContractError {
                    // Known-current flag-only metadata/body corruption is
                    // isolated from the core state mutation transaction.
                }
            }
            try faultInjector?.hit(.beforeStateUpdate)
            try EluRuntimeDatabase.updateState(
                connection,
                from: diskState.generation,
                to: nextState
            )
            try faultInjector?.hit(.beforeCommit)
            commitAttempted = true
            do {
                try connection.execute("COMMIT")
            } catch {
                poisonAndRelease()
                throw EluRuntimeQueueError.ambiguousCommit
            }
            do {
                try faultInjector?.hit(.afterCommit)
            } catch {
                poisonAndRelease()
                throw EluRuntimeQueueError.ambiguousCommit
            }

            state = nextState
            runMaintenance(checkpoint: true, vacuum: false)
            return (storedRecords.map(\.record), nextState.snapshot)
        } catch {
            if !commitAttempted {
                if transactionBegan {
                    do {
                        try faultInjector?.hit(.beforeRollback)
                        try connection.execute("ROLLBACK")
                        transactionBegan = false
                    } catch {
                        // COMMIT was never attempted, so closing the poisoned
                        // connection cannot turn this into an ambiguous write.
                        // The capture owner receives the typed, fail-closed
                        // not-committed outcome and must not retry this owner.
                        poisonAndRelease()
                        if surfaceProvenNotCommitted {
                            throw EluRuntimeQueueError.provenNotCommitted
                        }
                        throw EluRuntimeQueueError.databaseUnavailable
                    }
                }
                if surfaceProvenNotCommitted,
                   shouldSurfaceProvenNotCommitted(error)
                {
                    throw EluRuntimeQueueError.provenNotCommitted
                }
            }
            throw mapOperationError(error)
        }
    }

    func peek(maximumCount: Int, maximumBytes: Int) throws -> [EluQueuedRecord] {
        guard (1 ... 1_000).contains(maximumCount), maximumBytes > 0 else {
            throw EluRuntimeQueueError.invalidState
        }
        let resources = try requireResources()
        let connection = resources.connection
        do {
            try connection.execute("BEGIN")
            let diskState = try EluRuntimeDatabase.loadState(
                connection,
                validateQueue: false
            )
            guard diskState == state else {
                throw EluRuntimeQueueError.generationMismatch
            }
            let requestedCount = min(maximumCount, Int(diskState.liveCount))
            let storedRecords = try EluRuntimeDatabase.readPrefix(
                connection,
                maximumCount: requestedCount,
                streamId: diskState.streamId
            )
            guard storedRecords.count == requestedCount else {
                throw EluRuntimeQueueError.corruptStorage
            }
            try connection.execute("COMMIT")

            var records: [EluQueuedRecord] = []
            records.reserveCapacity(storedRecords.count)
            var bytes = 0
            var expectedSequence = diskState.headSequence
            for (index, storedRecord) in storedRecords.enumerated() {
                guard let sequence = expectedSequence,
                      storedRecord.record.sequence == sequence,
                      recordBelongsToStream(storedRecord.record, streamId: diskState.streamId)
                else {
                    throw EluRuntimeQueueError.corruptStorage
                }
                if storedRecord.accountedBytes > Int64(maximumBytes - bytes) {
                    if index == 0 {
                        throw EluRuntimeQueueError.headRecordExceedsPeekLimit(
                            storedRecord.accountedBytes
                        )
                    }
                    break
                }
                bytes += Int(storedRecord.accountedBytes)
                records.append(storedRecord.record)
                guard sequence < Int64.max else {
                    throw EluRuntimeQueueError.corruptStorage
                }
                expectedSequence = sequence + 1
            }
            return records
        } catch {
            try? connection.execute("ROLLBACK")
            throw mapOperationError(error)
        }
    }

    @discardableResult
    func acknowledge(
        _ references: [EluQueueAcknowledgementReference]
    ) throws -> EluRuntimeQueueSnapshot {
        guard references.count <= 1_000 else {
            throw EluRuntimeQueueError.acknowledgementMismatch
        }
        if references.isEmpty {
            return try snapshot()
        }
        try validateAcknowledgementReferences(references, streamId: state.streamId)

        let resources = try requireResources()
        let connection = resources.connection
        var commitAttempted = false
        do {
            try connection.execute("BEGIN IMMEDIATE")
            try faultInjector?.hit(.afterBegin)
            let diskState = try EluRuntimeDatabase.loadState(
                connection,
                validateQueue: false
            )
            guard diskState == state else {
                throw EluRuntimeQueueError.generationMismatch
            }
            try faultInjector?.hit(.afterStateRead)

            if try acknowledgementIsIdempotent(references, state: diskState) {
                try connection.execute("COMMIT")
                return state.snapshot
            }
            guard let headSequence = diskState.headSequence,
                  references[0].sequence == headSequence
            else {
                throw EluRuntimeQueueError.acknowledgementMismatch
            }

            let storedRecords = try EluRuntimeDatabase.readPrefix(
                connection,
                maximumCount: references.count,
                streamId: diskState.streamId
            )
            guard storedRecords.count == references.count else {
                throw EluRuntimeQueueError.acknowledgementMismatch
            }
            var removedBytes: Int64 = 0
            for (reference, storedRecord) in zip(references, storedRecords) {
                guard reference.sequence == storedRecord.record.sequence,
                      reference.streamId == diskState.streamId,
                      reference.kind == storedRecord.record.kind,
                      reference.recordId == storedRecord.record.recordId
                else {
                    throw EluRuntimeQueueError.acknowledgementMismatch
                }
                guard removedBytes <= Int64.max - storedRecord.accountedBytes else {
                    throw EluRuntimeQueueError.corruptStorage
                }
                removedBytes += storedRecord.accountedBytes
            }
            guard Int64(references.count) <= diskState.liveCount,
                  removedBytes <= diskState.liveBytes,
                  diskState.generation < Int64.max
            else {
                throw EluRuntimeQueueError.corruptStorage
            }

            try EluRuntimeDatabase.deletePrefix(
                connection,
                firstSequence: references[0].sequence,
                lastSequence: references[references.count - 1].sequence,
                expectedCount: references.count
            )
            let nextCount = diskState.liveCount - Int64(references.count)
            let nextHead: Int64?
            if nextCount == 0 {
                nextHead = nil
            } else {
                let lastSequence = references[references.count - 1].sequence
                guard lastSequence < Int64.max else {
                    throw EluRuntimeQueueError.counterExhausted
                }
                nextHead = lastSequence + 1
            }
            let nextState = EluStoredRuntimeState(
                generation: diskState.generation + 1,
                identity: diskState.identity,
                flagContext: diskState.flagContext,
                streamId: diskState.streamId,
                nextSequence: diskState.nextSequence,
                headSequence: nextHead,
                liveCount: nextCount,
                liveBytes: diskState.liveBytes - removedBytes
            )
            try faultInjector?.hit(.beforeStateUpdate)
            try EluRuntimeDatabase.updateState(
                connection,
                from: diskState.generation,
                to: nextState
            )
            try faultInjector?.hit(.beforeCommit)
            commitAttempted = true
            do {
                try connection.execute("COMMIT")
            } catch {
                poisonAndRelease()
                throw EluRuntimeQueueError.ambiguousCommit
            }
            do {
                try faultInjector?.hit(.afterCommit)
            } catch {
                poisonAndRelease()
                throw EluRuntimeQueueError.ambiguousCommit
            }

            state = nextState
            runMaintenance(checkpoint: true, vacuum: true)
            return nextState.snapshot
        } catch {
            if !commitAttempted {
                do {
                    try connection.execute("ROLLBACK")
                } catch {
                    poisonAndRelease()
                    throw EluRuntimeQueueError.databaseUnavailable
                }
            }
            throw mapOperationError(error)
        }
    }

    func close() {
        isPoisoned = true
        captureAuthority = .absent
        resources?.close()
        resources = nil
    }

    private var identitySnapshot: EluIdentitySnapshot {
        EluIdentitySnapshot(
            identity: state.identity,
            streamId: state.streamId,
            nextSequence: state.nextSequence,
            flagContext: EluFlagContext(
                personProperties: state.flagContext.personProperties,
                groupProperties: state.flagContext.groupProperties
            )
        )
    }

    private var durableWallFloor: Date {
        var floor = state.identity.updatedAt
        if let session = state.identity.session {
            floor = max(max(floor, session.startedAt), session.lastActivityAt)
            if let backgroundedAt = session.backgroundedAt {
                floor = max(floor, backgroundedAt)
            }
        }
        return floor
    }

    private func nextAuthorityEpoch() -> UInt64 {
        if authorityEpoch < UInt64.max { authorityEpoch += 1 }
        return authorityEpoch
    }

    private static func captureBoundary(
        _ candidate: EluV1ConfigManager.ValidatedCandidateIdentity
    ) -> EluV1CaptureConfigBoundary {
        EluV1CaptureConfigBoundary(
            issuedAt: candidate.issuedAt,
            semanticHash: candidate.semanticHash
        )
    }

    private func terminateCaptureAuthority(
        trustedBoundary: EluV1CaptureConfigBoundary? = nil,
        candidateBoundary: EluV1CaptureConfigBoundary? = nil,
        policySourceHash: String? = nil,
        contextRevision: Int64? = nil,
        reason: EluV1CaptureAuthorityTerminalReason
    ) -> EluV1CaptureAuthorityUpdateResult {
        let retained: (
            boundary: EluV1CaptureConfigBoundary?,
            policySourceHash: String?
        )
        switch captureAuthority {
        case let .authorized(current):
            retained = (
                current.configBoundary,
                current.policySourceHash
            )
        case let .terminal(current):
            retained = (
                current.trustedConfigBoundary,
                current.policySourceHash
            )
        case .absent:
            retained = (nil, nil)
        }
        let terminal = EluV1CaptureAuthorityTerminal(
            ownerEpoch: nextAuthorityEpoch(),
            trustedConfigBoundary: trustedBoundary ?? retained.boundary,
            candidateConfigBoundary: candidateBoundary,
            policySourceHash: trustedBoundary == nil
                ? retained.policySourceHash
                : policySourceHash,
            contextRevision: contextRevision,
            reason: reason
        )
        captureAuthority = .terminal(terminal)
        return .terminated(terminal)
    }

    private func authorityWitnessMatches(
        _ authority: EluV1CaptureAuthoritySnapshot,
        diskState: EluStoredRuntimeState
    ) -> Bool {
        guard let ownerNamespaceHash else { return false }
        return authority.ownerNamespaceHash == ownerNamespaceHash
            && authority.configSiteId == pinnedConfigSiteId
            && authority.streamId == diskState.streamId
            && authority.identityRevision == diskState.identity.revision
            && authority.contextRevision == diskState.identity.contextRevision
            && authority.identityOptedOut == diskState.identity.optedOut
            && !diskState.identity.optedOut
    }

    private func expiredTerminalDominating(
        _ candidateBoundary: EluV1CaptureConfigBoundary?
    ) -> EluV1CaptureAuthorityTerminal? {
        guard case let .terminal(current) = captureAuthority,
              current.reason == .expired,
              let expiredBoundary = current.trustedConfigBoundary
        else {
            return nil
        }
        guard let candidateBoundary else { return current }
        if candidateBoundary.issuedAt < expiredBoundary.issuedAt {
            return current
        }
        if candidateBoundary.issuedAt == expiredBoundary.issuedAt,
           candidateBoundary.semanticHash == expiredBoundary.semanticHash
        {
            return current
        }
        return nil
    }

    private func authorityIsLive(
        _ authority: EluV1CaptureAuthoritySnapshot,
        wallNow: Date,
        monotonicNow: UInt64
    ) -> Bool {
        guard wallNow.timeIntervalSinceReferenceDate.isFinite,
              !authority.expiresAt.isAtOrBefore(wallNow),
              authority.monotonicBudget > 0
        else {
            return false
        }
        let elapsed = monotonicNow &- authority.monotonicStartedAt
        return elapsed < authority.monotonicBudget
    }

    private func restrictionTerminalDominating(
        _ candidateBoundary: EluV1CaptureConfigBoundary?,
        candidateContextRevision _: Int64?
    ) -> EluV1CaptureAuthorityTerminal? {
        guard case let .terminal(current) = captureAuthority,
              current.reason == .privacyBlocked,
              let restrictedBoundary = current.trustedConfigBoundary,
              current.contextRevision != nil
        else {
            return nil
        }
        guard let candidateBoundary else { return current }
        if candidateBoundary.issuedAt < restrictedBoundary.issuedAt {
            return current
        }
        guard candidateBoundary == restrictedBoundary else { return nil }
        return current
    }

    private func latchExpiredAuthority(_ authority: EluV1CaptureAuthoritySnapshot) {
        _ = terminateCaptureAuthority(
            trustedBoundary: authority.configBoundary,
            candidateBoundary: authority.configBoundary,
            policySourceHash: authority.policySourceHash,
            contextRevision: authority.contextRevision,
            reason: .expired
        )
    }

    private func prepareCapture(
        command: EluV1CaptureCommand,
        occurredAt: Date,
        authority: EluV1CaptureAuthoritySnapshot
    ) throws -> (identity: EluIdentityState, draft: EluEventDraft) {
        var properties = state.identity.superProperties
        for (key, value) in command.properties { properties[key] = value }
        properties["$elu_contract_version"] = .string(command.versions.contractVersion)
        properties["$elu_sdk_version"] = .string(command.versions.runtime.version)
        properties["$elu_facade_version"] = .string(command.versions.facade.version)
        guard validateCaptureProperties(properties) else {
            throw EluRuntimeQueueError.invalidRecord
        }

        let previous = state.identity.session
        let session: EluSessionState
        if let previous {
            try validateStoredSession(previous, identityUpdatedAt: state.identity.updatedAt)
            guard occurredAt >= previous.lastActivityAt,
                  occurredAt >= previous.startedAt
            else {
                throw EluRuntimeQueueError.invalidState
            }
            let effectiveTimeout = min(
                previous.timeoutSeconds,
                authority.idleTimeoutSeconds
            )
            let idleSeconds = occurredAt.timeIntervalSince(previous.lastActivityAt)
            let durationSeconds = occurredAt.timeIntervalSince(previous.startedAt)
            if idleSeconds >= Double(effectiveTimeout)
                || durationSeconds >= Double(authority.maximumDurationSeconds)
            {
                let identifier = sessionIdGenerator()
                guard identifier != previous.id else {
                    throw EluRuntimeQueueError.invalidState
                }
                session = try EluSessionState(
                    id: identifier,
                    startedAt: occurredAt,
                    lastActivityAt: occurredAt,
                    timeoutSeconds: authority.idleTimeoutSeconds
                )
            } else {
                var resumed = previous
                resumed.lastActivityAt = occurredAt
                resumed.timeoutSeconds = effectiveTimeout
                resumed.lifecycle = .active
                resumed.backgroundedAt = nil
                try resumed.validate()
                session = resumed
            }
        } else {
            session = try EluSessionState(
                id: sessionIdGenerator(),
                startedAt: occurredAt,
                lastActivityAt: occurredAt,
                timeoutSeconds: authority.idleTimeoutSeconds
            )
        }

        var identity = state.identity
        identity.session = session
        identity.updatedAt = occurredAt
        let draft = EluEventDraft(
            kind: command.kind,
            name: command.name,
            occurredAt: occurredAt,
            expectedSessionId: session.id,
            properties: properties,
            versions: command.versions
        )
        return (identity, draft)
    }

    private func canonicalDate(_ date: Date) -> Date? {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return EluRFC3339.date(from: EluRFC3339.string(from: date))
    }

    private func validCaptureName(_ name: String) -> Bool {
        EluIdentityState.valid(name, maximumLength: 512)
    }

    private func validateCaptureProperties(_ properties: [String: EluJSONValue]) -> Bool {
        guard properties.count <= 1_024 else { return false }
        do {
            for (key, value) in properties {
                guard EluIdentityState.valid(key, maximumLength: 256) else { return false }
                try value.validate()
            }
            return true
        } catch {
            return false
        }
    }

    private func shouldSurfaceProvenNotCommitted(_ error: Error) -> Bool {
        if let queueError = error as? EluRuntimeQueueError {
            if case .faultInjected = queueError { return true }
            return queueError == .databaseUnavailable
        }
        return error is EluSQLiteFailure
    }

    private func prepareMutationTransition(
        _ transition: EluRuntimeMutationTransition,
        occurredAt: Date,
        versions: EluVersionContext
    ) throws -> (
        identity: EluIdentityState,
        flagContext: EluPersistedFlagContext,
        drafts: [EluPreparedRecordDraft]
    ) {
        var identity = state.identity
        var personProperties = state.flagContext.personProperties
        var groupProperties = state.flagContext.groupProperties
        var drafts: [EluPreparedRecordDraft] = []

        switch transition {
        case let .identify(userId, set, setOnce):
            let change = EluMutationChange.identify(
                userId: userId,
                set: set,
                setOnce: setOnce
            )
            if identity.userId != userId {
                guard identity.revision < Int64.max else {
                    throw EluRuntimeQueueError.counterExhausted
                }
                identity.revision += 1
                identity.userId = userId
            }
            try applyProperties(
                set: set,
                setOnce: setOnce,
                unset: [],
                to: &personProperties
            )
            try advanceMutationContext(&identity, occurredAt: occurredAt)
            drafts.append(
                try prepareMutationDraft(
                    change: change,
                    identity: identity,
                    occurredAt: occurredAt,
                    versions: versions
                )
            )

        case let .linkAlias(aliasId):
            guard let canonicalId = identity.userId else {
                throw EluRuntimeQueueError.invalidState
            }
            try advanceMutationContext(&identity, occurredAt: occurredAt)
            drafts.append(
                try prepareMutationDraft(
                    change: .linkAlias(aliasId: aliasId, canonicalId: canonicalId),
                    identity: identity,
                    occurredAt: occurredAt,
                    versions: versions
                )
            )

        case let .setPersonProperties(set, setOnce, unset):
            try applyProperties(
                set: set,
                setOnce: setOnce,
                unset: unset,
                to: &personProperties
            )
            try advanceMutationContext(&identity, occurredAt: occurredAt)
            drafts.append(
                try prepareMutationDraft(
                    change: .setPersonProperties(
                        set: set,
                        setOnce: setOnce,
                        unset: unset
                    ),
                    identity: identity,
                    occurredAt: occurredAt,
                    versions: versions
                )
            )

        case let .associateGroup(groupType, groupKey):
            try associateGroup(
                type: groupType,
                key: groupKey,
                identity: &identity,
                groupProperties: &groupProperties
            )
            try advanceMutationContext(&identity, occurredAt: occurredAt)
            drafts.append(
                try prepareMutationDraft(
                    change: .associateGroup(groupType: groupType, groupKey: groupKey),
                    identity: identity,
                    occurredAt: occurredAt,
                    versions: versions
                )
            )

        case let .setGroupProperties(groupType, groupKey, set, setOnce, unset):
            guard identity.groups[groupType] == groupKey else {
                throw EluRuntimeQueueError.invalidState
            }
            var properties = groupProperties[groupType] ?? [:]
            try applyProperties(
                set: set,
                setOnce: setOnce,
                unset: unset,
                to: &properties
            )
            groupProperties[groupType] = properties
            try advanceMutationContext(&identity, occurredAt: occurredAt)
            drafts.append(
                try prepareMutationDraft(
                    change: .setGroupProperties(
                        groupType: groupType,
                        groupKey: groupKey,
                        set: set,
                        setOnce: setOnce,
                        unset: unset
                    ),
                    identity: identity,
                    occurredAt: occurredAt,
                    versions: versions
                )
            )

        case let .group(groupType, groupKey, set, setOnce, unset):
            try associateGroup(
                type: groupType,
                key: groupKey,
                identity: &identity,
                groupProperties: &groupProperties
            )
            try advanceMutationContext(&identity, occurredAt: occurredAt)
            drafts.append(
                try prepareMutationDraft(
                    change: .associateGroup(groupType: groupType, groupKey: groupKey),
                    identity: identity,
                    occurredAt: occurredAt,
                    versions: versions
                )
            )

            var properties = groupProperties[groupType] ?? [:]
            try applyProperties(
                set: set,
                setOnce: setOnce,
                unset: unset,
                to: &properties
            )
            groupProperties[groupType] = properties
            try advanceMutationContext(&identity, occurredAt: occurredAt)
            drafts.append(
                try prepareMutationDraft(
                    change: .setGroupProperties(
                        groupType: groupType,
                        groupKey: groupKey,
                        set: set,
                        setOnce: setOnce,
                        unset: unset
                    ),
                    identity: identity,
                    occurredAt: occurredAt,
                    versions: versions
                )
            )
        }

        let flagContext = try EluPersistedFlagContext(
            personProperties: personProperties,
            groupProperties: groupProperties
        )
        return (identity, flagContext, drafts)
    }

    private func prepareEventIdentity(
        sessionUpdate: EluRuntimeEventSessionUpdate,
        draft: EluEventDraft
    ) throws -> EluIdentityState {
        guard EluIdentityState.valid(draft.expectedSessionId, maximumLength: 256),
              draft.occurredAt.timeIntervalSinceReferenceDate.isFinite,
              draft.occurredAt >= state.identity.updatedAt
        else {
            throw EluRuntimeQueueError.invalidRecord
        }

        var identity = state.identity
        switch sessionUpdate {
        case .preserve:
            guard let session = identity.session else {
                throw EluRuntimeQueueError.invalidState
            }
            try validateEventSession(session, identityUpdatedAt: identity.updatedAt)

        case let .replace(expectedCurrentSessionId, proposedSession):
            if let expectedCurrentSessionId,
               !EluIdentityState.valid(expectedCurrentSessionId, maximumLength: 256)
            {
                throw EluRuntimeQueueError.invalidState
            }
            guard identity.session?.id == expectedCurrentSessionId else {
                throw EluRuntimeQueueError.generationMismatch
            }
            let session: EluSessionState
            do {
                session = try EluRuntimeCanonical.value(proposedSession)
            } catch {
                throw EluRuntimeQueueError.invalidState
            }
            try validateEventSessionTransition(
                from: identity,
                to: session
            )
            identity.session = session
            identity.updatedAt = session.lastActivityAt
        }

        let canonicalIdentity: EluIdentityState
        do {
            canonicalIdentity = try EluRuntimeCanonical.value(identity)
            try canonicalIdentity.validate()
        } catch {
            throw EluRuntimeQueueError.invalidState
        }
        guard let session = canonicalIdentity.session,
              session.id == draft.expectedSessionId,
              draft.occurredAt >= session.startedAt,
              draft.occurredAt <= session.lastActivityAt
        else {
            throw EluRuntimeQueueError.invalidRecord
        }
        return canonicalIdentity
    }

    private func validateEventSessionTransition(
        from identity: EluIdentityState,
        to session: EluSessionState
    ) throws {
        try validateEventSession(session, identityUpdatedAt: session.lastActivityAt)
        guard session.lastActivityAt >= identity.updatedAt else {
            throw EluRuntimeQueueError.invalidState
        }
        if let current = identity.session {
            try validateStoredSession(current, identityUpdatedAt: identity.updatedAt)
            if current.id == session.id {
                let effectiveTimeout = min(
                    current.timeoutSeconds,
                    session.timeoutSeconds
                )
                guard session.startedAt == current.startedAt,
                      session.lastActivityAt >= current.lastActivityAt,
                      session.lastActivityAt.timeIntervalSince(current.lastActivityAt)
                          < Double(effectiveTimeout)
                else {
                    throw EluRuntimeQueueError.invalidState
                }
            } else {
                let previousBoundary = current.backgroundedAt ?? current.lastActivityAt
                guard session.startedAt >= previousBoundary else {
                    throw EluRuntimeQueueError.invalidState
                }
            }
        }
    }

    private func validateEventSession(
        _ session: EluSessionState,
        identityUpdatedAt: Date
    ) throws {
        try validateStoredSession(session, identityUpdatedAt: identityUpdatedAt)
        guard session.lifecycle == .active,
              session.backgroundedAt == nil
        else {
            throw EluRuntimeQueueError.invalidState
        }
    }

    private func validateStoredSession(
        _ session: EluSessionState,
        identityUpdatedAt: Date
    ) throws {
        do {
            try session.validate()
        } catch {
            throw EluRuntimeQueueError.invalidState
        }
        guard session.lastActivityAt >= session.startedAt,
              session.lastActivityAt.timeIntervalSince(session.startedAt)
                  < Double(EluSessionState.requiredMaximumDurationSeconds),
              identityUpdatedAt >= session.lastActivityAt
        else {
            throw EluRuntimeQueueError.invalidState
        }
        switch session.lifecycle {
        case .active:
            guard session.backgroundedAt == nil else {
                throw EluRuntimeQueueError.invalidState
            }
        case .background:
            guard let backgroundedAt = session.backgroundedAt,
                  backgroundedAt >= session.lastActivityAt,
                  identityUpdatedAt >= backgroundedAt
            else {
                throw EluRuntimeQueueError.invalidState
            }
        }
    }

    private func advanceMutationContext(
        _ identity: inout EluIdentityState,
        occurredAt: Date
    ) throws {
        guard identity.contextRevision < Int64.max else {
            throw EluRuntimeQueueError.counterExhausted
        }
        identity.contextRevision += 1
        identity.updatedAt = occurredAt
    }

    private func prepareMutationDraft(
        change: EluMutationChange,
        identity: EluIdentityState,
        occurredAt: Date,
        versions: EluVersionContext
    ) throws -> EluPreparedRecordDraft {
        try change.validate()
        switch change {
        case let .identify(userId, _, _):
            guard identity.userId == userId else {
                throw EluRuntimeQueueError.invalidState
            }
        case let .linkAlias(_, canonicalId):
            guard identity.userId == canonicalId else {
                throw EluRuntimeQueueError.invalidState
            }
        case let .associateGroup(groupType, groupKey),
             let .setGroupProperties(groupType, groupKey, _, _, _):
            guard identity.groups[groupType] == groupKey else {
                throw EluRuntimeQueueError.invalidState
            }
        case .setPersonProperties:
            break
        }
        return .mutation(
            change: change,
            identity: identity,
            occurredAt: occurredAt,
            versions: versions
        )
    }

    private func associateGroup(
        type: String,
        key: String,
        identity: inout EluIdentityState,
        groupProperties: inout [String: [String: EluJSONValue]]
    ) throws {
        try EluMutationChange.associateGroup(groupType: type, groupKey: key).validate()
        if identity.groups[type] == nil,
           identity.groups.count >= EluIdentityState.maximumGroups
        {
            throw EluRuntimeQueueError.invalidState
        }
        if identity.groups[type] != key {
            groupProperties.removeValue(forKey: type)
        }
        identity.groups[type] = key
    }

    private func applyProperties(
        set: [String: EluJSONValue],
        setOnce: [String: EluJSONValue],
        unset: [String],
        to properties: inout [String: EluJSONValue]
    ) throws {
        let setKeys = Set(set.keys)
        let setOnceKeys = Set(setOnce.keys)
        let unsetKeys = Set(unset)
        guard setKeys.isDisjoint(with: setOnceKeys),
              setKeys.isDisjoint(with: unsetKeys),
              setOnceKeys.isDisjoint(with: unsetKeys)
        else {
            throw EluRuntimeQueueError.invalidRecord
        }
        for key in unset {
            properties.removeValue(forKey: key)
        }
        for (key, value) in setOnce where properties[key] == nil {
            properties[key] = value
        }
        for (key, value) in set {
            properties[key] = value
        }
    }

    private func makeRecords(
        _ drafts: [EluPreparedRecordDraft],
        identity: EluIdentityState,
        streamId: String,
        startingAt firstSequence: Int64
    ) throws -> [EluStoredQueueRecord] {
        var records: [EluStoredQueueRecord] = []
        records.reserveCapacity(drafts.count)

        for (index, draft) in drafts.enumerated() {
            guard Int64(index) <= Int64.max - firstSequence else {
                throw EluRuntimeQueueError.counterExhausted
            }
            let sequence = firstSequence + Int64(index)
            let rawRecord: EluQueuedRecord
            switch draft {
            case let .event(eventDraft):
                guard let session = identity.session,
                      session.lifecycle == .active,
                      session.backgroundedAt == nil,
                      eventDraft.expectedSessionId == session.id,
                      eventDraft.occurredAt >= session.startedAt,
                      eventDraft.occurredAt <= session.lastActivityAt
                else {
                    throw EluRuntimeQueueError.invalidRecord
                }
                let recordId = EluRuntimeIdentifier.recordId(
                    kind: .event,
                    streamId: streamId,
                    sequence: sequence
                )
                rawRecord = .event(
                    try EluQueuedEvent(
                        eventId: recordId,
                        streamId: streamId,
                        sequence: sequence,
                        contextRevision: identity.contextRevision,
                        kind: eventDraft.kind,
                        name: eventDraft.name,
                        occurredAt: eventDraft.occurredAt,
                        identity: EluEventIdentity(
                            anonymousId: identity.anonymousId,
                            userId: identity.userId,
                            revision: identity.revision
                        ),
                        sessionId: session.id,
                        properties: eventDraft.properties,
                        groups: identity.groups,
                        versions: eventDraft.versions
                    )
                )
            case let .mutation(change, mutationIdentity, occurredAt, versions):
                let recordId = EluRuntimeIdentifier.recordId(
                    kind: .mutation,
                    streamId: streamId,
                    sequence: sequence
                )
                rawRecord = .mutation(
                    try EluQueuedMutation(
                        mutationId: recordId,
                        sequence: sequence,
                        contextRevision: mutationIdentity.contextRevision,
                        occurredAt: occurredAt,
                        subject: EluMutationSubject(
                            anonymousId: mutationIdentity.anonymousId,
                            userId: mutationIdentity.userId,
                            identityRevision: mutationIdentity.revision
                        ),
                        change: change
                    ),
                    versions: versions
                )
            }
            let initialPayload = try EluQueueRecordCodec.encode(rawRecord)
            let record = try EluQueueRecordCodec.decode(
                kind: rawRecord.kind,
                data: initialPayload,
                versions: rawRecord.versions
            )
            let payload = try EluQueueRecordCodec.encode(record)
            let versionsPayload = try EluStateCoding.encoder().encode(record.versions)
            let outboundRecord = try EluQueueBatchCodec.encodeRecord(record)
            guard !payload.isEmpty,
                  payload.count <= EluSQLiteRuntimeSchema.maximumPayloadBytes,
                  outboundRecord.count <= EluSQLiteRuntimeSchema.maximumPayloadBytes
            else {
                throw EluRuntimeQueueError.queueByteLimitExceeded
            }
            records.append(
                EluStoredQueueRecord(
                    record: record,
                    payload: payload,
                    versionsPayload: versionsPayload,
                    accountedBytes: Int64(outboundRecord.count)
                )
            )
        }
        return records
    }

    private func sumBytes(_ records: [EluStoredQueueRecord]) throws -> Int64 {
        var result: Int64 = 0
        for record in records {
            guard result <= Int64.max - record.accountedBytes else {
                throw EluRuntimeQueueError.counterExhausted
            }
            result += record.accountedBytes
        }
        return result
    }

    private func validateAcknowledgementReferences(
        _ references: [EluQueueAcknowledgementReference],
        streamId: String
    ) throws {
        var previous: Int64?
        for reference in references {
            guard reference.sequence >= 0,
                  reference.streamId == streamId,
                  reference.recordId == EluRuntimeIdentifier.recordId(
                      kind: reference.kind,
                      streamId: streamId,
                      sequence: reference.sequence
                  )
            else {
                throw EluRuntimeQueueError.acknowledgementMismatch
            }
            if let previous {
                guard previous < Int64.max, reference.sequence == previous + 1 else {
                    throw EluRuntimeQueueError.acknowledgementMismatch
                }
            }
            previous = reference.sequence
        }
    }

    private func acknowledgementIsIdempotent(
        _ references: [EluQueueAcknowledgementReference],
        state: EluStoredRuntimeState
    ) throws -> Bool {
        let lastSequence = references[references.count - 1].sequence
        if let headSequence = state.headSequence {
            if lastSequence < headSequence {
                return true
            }
            if references[0].sequence < headSequence {
                throw EluRuntimeQueueError.acknowledgementMismatch
            }
            return false
        }
        if lastSequence < state.nextSequence {
            return true
        }
        throw EluRuntimeQueueError.acknowledgementMismatch
    }

    private func recordBelongsToStream(
        _ record: EluQueuedRecord,
        streamId: String
    ) -> Bool {
        switch record {
        case let .event(event):
            return event.streamId == streamId
        case .mutation:
            return true
        }
    }

    private func runMaintenance(checkpoint: Bool, vacuum: Bool) {
        guard let connection = resources?.connection else { return }
        if checkpoint {
            do {
                try faultInjector?.hit(.checkpoint)
                try connection.execute("PRAGMA wal_checkpoint(PASSIVE)")
            } catch {
                // Maintenance happens after the logical commit and cannot
                // retroactively turn a durable success into an enqueue error.
            }
        }
        if vacuum {
            do {
                try faultInjector?.hit(.vacuum)
                try connection.execute("PRAGMA incremental_vacuum")
            } catch {
                // Reclaimed pages are an optimization, not queue correctness.
            }
        }
    }

    private func requireResources() throws -> EluRuntimeResources {
        guard !isPoisoned, let resources else {
            throw EluRuntimeQueueError.poisoned
        }
        return resources
    }

    private func poisonAndRelease() {
        isPoisoned = true
        resources?.close()
        resources = nil
    }

    private func mapOperationError(_ error: Error) -> EluRuntimeQueueError {
        if let error = error as? EluRuntimeQueueError {
            return error
        }
        if error is EluIdentityStateError || error is EluQueueRecordValidationError {
            return .invalidRecord
        }
        if let sqliteError = error as? EluSQLiteFailure {
            if case let .result(code, _) = sqliteError,
               (code & 0xFF) == SQLITE_CONSTRAINT
            {
                return .invalidRecord
            }
            return .databaseUnavailable
        }
        return .databaseUnavailable
    }
}
