import CoreFoundation
import Darwin
import Foundation

/// Why a stored checkpoint document could not be used. Each case maps to a
/// quarantine reason; the coordinator never repairs or discards such bytes.
enum EluMigrationCheckpointDefect: Equatable, Sendable {
    case oversized
    case malformed
    case unsupportedSchemaVersion
    case unknownRecordExtension
    case invalid
}

enum EluMigrationCheckpointLoadResult: Equatable, Sendable {
    case missing
    case loaded(EluMigrationCheckpoint)
    case unreadable(EluMigrationCheckpointDefect)
}

enum EluMigrationCheckpointStoreError: Error, Equatable, Sendable {
    case documentTooLarge
    case durabilityUnconfirmed
}

/// Durable home of the migration checkpoint. `save` replaces the whole
/// document atomically; `quarantine` moves the current document aside with
/// its bytes intact so a later inspection can still read it.
protocol EluMigrationCheckpointStore: Sendable {
    func load() throws -> EluMigrationCheckpointLoadResult
    func save(_ checkpoint: EluMigrationCheckpoint) throws
    func quarantine() throws
    func hasQuarantinedDocument() throws -> Bool
}

final class EluFileMigrationCheckpointStore: EluMigrationCheckpointStore, @unchecked Sendable {
    static let checkpointFilename = "migration-checkpoint-v1.json"
    static let quarantineFilename = "migration-checkpoint-v1.quarantined.json"
    static let maximumDocumentBytes = 1_024 * 1_024

    let directoryURL: URL
    let checkpointFileURL: URL
    let quarantineFileURL: URL

    private let fileManager: FileManager
    private let directorySynchronizer: any EluDirectorySynchronizing
    private let lock = NSLock()

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        directorySynchronizer: any EluDirectorySynchronizing = EluDarwinDirectorySynchronizer()
    ) throws {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.directorySynchronizer = directorySynchronizer
        checkpointFileURL = directoryURL.appendingPathComponent(
            Self.checkpointFilename,
            isDirectory: false
        )
        quarantineFileURL = directoryURL.appendingPathComponent(
            Self.quarantineFilename,
            isDirectory: false
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    func load() throws -> EluMigrationCheckpointLoadResult {
        try withLock {
            guard fileManager.fileExists(atPath: checkpointFileURL.path) else {
                return .missing
            }
            let data: Data
            do {
                guard let bounded = try readBoundedData(from: checkpointFileURL) else {
                    return .unreadable(.malformed)
                }
                data = bounded
            } catch EluMigrationCheckpointStoreError.documentTooLarge {
                return .unreadable(.oversized)
            }
            return Self.decode(data)
        }
    }

    func save(_ checkpoint: EluMigrationCheckpoint) throws {
        try withLock {
            try checkpoint.validate()
            let data = try EluStateCoding.encoder().encode(checkpoint)
            guard data.count <= Self.maximumDocumentBytes else {
                throw EluMigrationCheckpointStoreError.documentTooLarge
            }
            try replaceWithoutDirectorySync(data, at: checkpointFileURL)
            do {
                try directorySynchronizer.synchronize(directoryURL: directoryURL)
            } catch {
                // The replacement is already the visible document. Report
                // that its directory entry may not be durable yet instead of
                // rolling back to older bytes.
                throw EluMigrationCheckpointStoreError.durabilityUnconfirmed
            }
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: checkpointFileURL.path
            )
        }
    }

    func quarantine() throws {
        try withLock {
            guard fileManager.fileExists(atPath: checkpointFileURL.path) else { return }
            // An earlier quarantined document is never overwritten. The
            // current document then stays where it is; either file blocks
            // migration until someone inspects it.
            guard !fileManager.fileExists(atPath: quarantineFileURL.path) else { return }
            try fileManager.moveItem(at: checkpointFileURL, to: quarantineFileURL)
            try directorySynchronizer.synchronize(directoryURL: directoryURL)
        }
    }

    func hasQuarantinedDocument() throws -> Bool {
        withLock {
            fileManager.fileExists(atPath: quarantineFileURL.path)
        }
    }

    static func decode(_ data: Data) -> EluMigrationCheckpointLoadResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable(.malformed)
        }
        if let value = root["schemaVersion"] {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded(.towardZero) == number.doubleValue,
                  number.doubleValue >= Double(Int.min),
                  number.doubleValue <= Double(Int.max),
                  number.intValue == EluMigrationCheckpoint.schemaVersion
            else {
                return .unreadable(.unsupportedSchemaVersion)
            }
        }
        guard root.keys.allSatisfy(EluMigrationCheckpoint.persistedKeys.contains) else {
            return .unreadable(.unknownRecordExtension)
        }
        guard let checkpoint = try? EluStateCoding.decoder().decode(
            EluMigrationCheckpoint.self,
            from: data
        ) else {
            return .unreadable(.invalid)
        }
        return .loaded(checkpoint)
    }

    private func readBoundedData(from url: URL) throws -> Data? {
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_RDONLY)
        }
        guard descriptor >= 0 else {
            throw Self.posixError(errno)
        }
        defer { _ = Darwin.close(descriptor) }

        let maximumReadBytes = Self.maximumDocumentBytes + 1
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
        guard data.count <= Self.maximumDocumentBytes else {
            throw EluMigrationCheckpointStoreError.documentTooLarge
        }
        return data
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
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
