import Darwin
import Foundation

/// Consent only: never identity, sessions, events, flags, or timestamps. All access
/// requires the queue's original canonical installation lease, across both modes.
struct EluExplicitConsentStore: Sendable {
    static let filename = "explicit-consent-v1.json"
    private static let temporaryFilename = ".explicit-consent-v1.tmp"
    private static let maximumBytes = 128
    let directoryURL: URL

    struct Choice: Equatable, Sendable {
        let optedOut: Bool
        let settled: Bool
        var persistentReconciled = false
        var effectiveOptedOut: Bool { !settled || optedOut }
        var bytes: Data {
            Data("{\"schemaVersion\":1,\"optedOut\":\(optedOut),\"settled\":\(settled),\"persistentReconciled\":\(persistentReconciled)}\n".utf8)
        }
    }

    func load() throws -> Choice? {
        try withDirectory { directory in
            // Even a partial write before the first rename proves unfinished
            // consent work. Absence of the primary must never become a grant.
            if try read(Self.temporaryFilename, in: directory) != nil {
                return Choice(optedOut: true, settled: false)
            }
            guard let bytes = try read(Self.filename, in: directory) else { return nil }
            return try decode(bytes)
        }
    }

    func save(_ choice: Choice, ifCurrent: () -> Bool = { true }) throws {
        try withDirectory { directory in
            guard ifCurrent() else { throw EluRuntimeQueueError.sourceAuthorityUnavailable }
            // A process may die before rename. Keep an existing pending inode
            // present while replacing its bytes: unlink/recreate would briefly
            // expose the previous settled grant if this process died in between.
            let pendingExists = try read(Self.temporaryFilename, in: directory) != nil
            // Refuse replacing a malformed/link target instead of following it.
            if let primary = try read(Self.filename, in: directory) { _ = try decode(primary) }
            let flags = O_WRONLY | O_NOFOLLOW | O_NONBLOCK | (pendingExists ? 0 : O_CREAT | O_EXCL)
            let output = openat(directory, Self.temporaryFilename, flags, mode_t(0o600))
            guard output >= 0 else { throw failure() }
            var closed = false
            defer { if !closed { _ = Darwin.close(output) } }
            var metadata = stat()
            guard fstat(output, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == geteuid(), metadata.st_nlink == 1,
                  metadata.st_size >= 0, metadata.st_size <= Self.maximumBytes,
                  ftruncate(output, 0) == 0 else { throw failure() }
            try choice.bytes.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw failure() }
                    offset += count
                }
            }
            guard fsync(output) == 0 else { throw failure() }
            let closeResult = Darwin.close(output); closed = true
            guard closeResult == 0 else { throw failure() }
            guard ifCurrent() else { throw EluRuntimeQueueError.sourceAuthorityUnavailable }
            guard renameat(directory, Self.temporaryFilename, directory, Self.filename) == 0,
                  fsync(directory) == 0 else { throw failure() }
            guard try read(Self.filename, in: directory) == choice.bytes else {
                throw EluRuntimeQueueError.corruptStorage
            }
        }
    }

    private func decode(_ bytes: Data) throws -> Choice {
        // Exact bounded encoding rejects extra fields, coercions and extensions.
        for optedOut in [false, true] {
            for settled in [false, true] {
                for reconciled in [false, true] {
                    let value = Choice(optedOut: optedOut, settled: settled, persistentReconciled: reconciled)
                    if bytes == value.bytes { return value }
                }
            }
        }
        throw EluRuntimeQueueError.corruptStorage
    }

    /// Presence only: memory startup must not open any old analytics member.
    func hasPriorAnalyticsStore() throws -> Bool {
        try withDirectory { directory in
            for name in ["runtime-state-v1.sqlite3", "runtime-state-v1.sqlite3-wal",
                         "runtime-state-v1.sqlite3-shm", "runtime-state-v1.sqlite3-journal",
                         ".runtime-state-v1.scratch",
                         EluFileIdentityStateStore.stateFilename, EluFileIdentityStateStore.backupFilename] {
                var metadata = stat()
                if fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 { return true }
                guard errno == ENOENT else { throw failure() }
            }
            return false
        }
    }

    private func withDirectory<T>(_ operation: (Int32) throws -> T) throws -> T {
        let descriptor = directoryURL.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw failure() }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() else { throw EluRuntimeQueueError.invalidDirectory }
        return try operation(descriptor)
    }

    private func read(_ name: String, in directory: Int32) throws -> Data? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw failure()
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              metadata.st_size >= 0, metadata.st_size <= Self.maximumBytes else {
            throw EluRuntimeQueueError.corruptStorage
        }
        var bytes = [UInt8](repeating: 0, count: Self.maximumBytes + 1)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw failure() }
            if count == 0 { break }
            offset += count
        }
        guard offset == metadata.st_size, offset <= Self.maximumBytes else {
            throw EluRuntimeQueueError.corruptStorage
        }
        return Data(bytes.prefix(offset))
    }

    private func failure() -> EluRuntimeQueueError { .databaseUnavailable }
}
