import Darwin
import Foundation

/// The stream id event batches carry on the wire.
///
/// The queue's stream id names the installation and never changes. The server
/// keeps a stream's next sequence until a record with that sequence arrives, so
/// a record that leaves the queue without a stored server outcome would hold
/// back every later record of its stream. When that happens, delivery moves the
/// rest of the queue to a new wire stream; the server starts a stream at the
/// first sequence it receives. Records keep their sequences and record ids.
struct EluV1EventDeliveryStream: Equatable, Sendable {
    /// Stream-gap answers seen for one head record on this wire stream.
    struct Gap: Equatable, Sendable {
        var sequence: Int64
        var firstAnsweredAtMilliseconds: Int64
        var answers: Int64
    }

    /// Records already sent on this wire stream: every queued record up to
    /// `throughSequence`. The earliest of those sends began at
    /// `firstSentAtMilliseconds` by the device clock, so whatever the server
    /// stored for them, it stored no earlier than that.
    struct Sent: Equatable, Sendable {
        var throughSequence: Int64
        var firstSentAtMilliseconds: Int64
    }

    let installationStreamId: String
    let streamId: String
    var gap: Gap?
    var sent: Sent? = nil

    static func initial(installationStreamId: String) -> EluV1EventDeliveryStream {
        EluV1EventDeliveryStream(
            installationStreamId: installationStreamId,
            streamId: installationStreamId,
            gap: nil
        )
    }

    /// The same installation on a new wire stream, where nothing has been
    /// sent or answered yet.
    func moved(to streamId: String) -> EluV1EventDeliveryStream {
        EluV1EventDeliveryStream(
            installationStreamId: installationStreamId,
            streamId: streamId,
            gap: nil
        )
    }

    /// The state once the queue head `first` through `last` is sent at `now`.
    func recordingSend(
        first: Int64,
        last: Int64,
        atMilliseconds now: Int64
    ) -> EluV1EventDeliveryStream {
        var next = self
        if let sent, sent.throughSequence >= first {
            // Some of these records went out before, and the server may hold
            // what it stored for them since then: keep the earliest send.
            next.sent = Sent(
                throughSequence: max(sent.throughSequence, last),
                firstSentAtMilliseconds: min(sent.firstSentAtMilliseconds, now)
            )
        } else {
            // Every record sent before has left the queue.
            next.sent = Sent(throughSequence: last, firstSentAtMilliseconds: now)
        }
        return next
    }

    /// Whether the queue head through `sequence` can be removed without an
    /// answer from the server while later records stay on this wire stream.
    ///
    /// - A moved stream nothing has been sent or answered on yet is unknown
    ///   to the server, which starts a stream at the first sequence it
    ///   receives. The installation stream never counts as unknown: an
    ///   earlier version may have sent on it without noting it.
    /// - A stream that has already sent a record after `sequence` stays,
    ///   unless `serverStoredNone`. Every request that carried that record
    ///   carried the removed ones ahead of it, so the server either stored
    ///   them in order and has no gap, or stored none of them and answers
    ///   the later records `stream-gap` until it closes the gap or the head
    ///   moves. A new stream would carry later records the server may
    ///   already hold, and they would be counted twice.
    func keepsStream(removingThrough sequence: Int64, serverStoredNone: Bool) -> Bool {
        if streamId != installationStreamId, sent == nil, gap == nil {
            return true
        }
        if !serverStoredNone, let sent, sent.throughSequence > sequence {
            return true
        }
        return false
    }

    var isValid: Bool {
        EluV1EventDeliveryStreamStore.validStreamId(installationStreamId)
            && EluV1EventDeliveryStreamStore.validStreamId(streamId)
            && (gap.map { $0.sequence >= 0 && $0.answers >= 1 } ?? true)
            && (sent.map { $0.throughSequence >= 0 } ?? true)
    }
}

/// Keeps the wire stream beside the queue's store, so it survives restarts.
/// Only the queue reads or writes it, under its installation lease, and only
/// for persistent storage. A missing, unreadable or malformed file, or one
/// written for another installation stream, means the installation stream.
struct EluV1EventDeliveryStreamStore: Sendable {
    static let filename = "event-delivery-stream-v1.json"
    private static let temporaryFilename = ".event-delivery-stream-v1.tmp"
    private static let maximumBytes = 2_048
    let directoryURL: URL

    static func validStreamId(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.count <= 256
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    func load() throws -> EluV1EventDeliveryStream? {
        try withDirectory { directory in
            guard let bytes = try read(Self.filename, in: directory) else { return nil }
            return try Self.decode(bytes)
        }
    }

    func save(_ value: EluV1EventDeliveryStream) throws {
        let bytes = try Self.encode(value)
        guard bytes.count <= Self.maximumBytes else { throw EluRuntimeQueueError.invalidState }
        try withDirectory { directory in
            // Opened without truncating: a temporary file left as a link to
            // another file is refused below before any of its bytes change.
            let output = openat(
                directory,
                Self.temporaryFilename,
                O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK,
                mode_t(0o600)
            )
            guard output >= 0 else { throw EluRuntimeQueueError.databaseUnavailable }
            var closed = false
            defer { if !closed { _ = Darwin.close(output) } }
            var metadata = stat()
            guard fstat(output, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == geteuid(), metadata.st_nlink == 1,
                  ftruncate(output, 0) == 0
            else {
                throw EluRuntimeQueueError.databaseUnavailable
            }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(
                        output,
                        buffer.baseAddress!.advanced(by: offset),
                        buffer.count - offset
                    )
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw EluRuntimeQueueError.databaseUnavailable }
                    offset += count
                }
            }
            guard fsync(output) == 0 else { throw EluRuntimeQueueError.databaseUnavailable }
            let closeResult = Darwin.close(output)
            closed = true
            guard closeResult == 0,
                  renameat(directory, Self.temporaryFilename, directory, Self.filename) == 0,
                  fsync(directory) == 0
            else {
                throw EluRuntimeQueueError.databaseUnavailable
            }
        }
    }

    private struct Document: Codable, Equatable {
        struct Gap: Codable, Equatable {
            var sequence: Int64
            var firstAnsweredAtMilliseconds: Int64
            var answers: Int64
        }

        struct Sent: Codable, Equatable {
            var throughSequence: Int64
            var firstSentAtMilliseconds: Int64
        }

        var schemaVersion: Int
        var installationStreamId: String
        var streamId: String
        var gap: Gap?
        var sent: Sent?

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case installationStreamId
            case streamId
            case gap
            case sent
        }

        init(
            schemaVersion: Int,
            installationStreamId: String,
            streamId: String,
            gap: Gap?,
            sent: Sent?
        ) {
            self.schemaVersion = schemaVersion
            self.installationStreamId = installationStreamId
            self.streamId = streamId
            self.gap = gap
            self.sent = sent
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            installationStreamId = try container.decode(String.self, forKey: .installationStreamId)
            streamId = try container.decode(String.self, forKey: .streamId)
            gap = try container.decode(Gap?.self, forKey: .gap)
            sent = try container.decode(Sent?.self, forKey: .sent)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(installationStreamId, forKey: .installationStreamId)
            try container.encode(streamId, forKey: .streamId)
            // Written as null so the canonical bytes always carry every key.
            try container.encode(gap, forKey: .gap)
            try container.encode(sent, forKey: .sent)
        }
    }

    static func encode(_ value: EluV1EventDeliveryStream) throws -> Data {
        guard value.isValid else { throw EluRuntimeQueueError.invalidState }
        let document = Document(
            schemaVersion: 1,
            installationStreamId: value.installationStreamId,
            streamId: value.streamId,
            gap: value.gap.map {
                Document.Gap(
                    sequence: $0.sequence,
                    firstAnsweredAtMilliseconds: $0.firstAnsweredAtMilliseconds,
                    answers: $0.answers
                )
            },
            sent: value.sent.map {
                Document.Sent(
                    throughSequence: $0.throughSequence,
                    firstSentAtMilliseconds: $0.firstSentAtMilliseconds
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    static func decode(_ bytes: Data) throws -> EluV1EventDeliveryStream {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: bytes)
        } catch {
            throw EluRuntimeQueueError.corruptStorage
        }
        guard document.schemaVersion == 1 else { throw EluRuntimeQueueError.corruptStorage }
        let value = EluV1EventDeliveryStream(
            installationStreamId: document.installationStreamId,
            streamId: document.streamId,
            gap: document.gap.map {
                EluV1EventDeliveryStream.Gap(
                    sequence: $0.sequence,
                    firstAnsweredAtMilliseconds: $0.firstAnsweredAtMilliseconds,
                    answers: $0.answers
                )
            },
            sent: document.sent.map {
                EluV1EventDeliveryStream.Sent(
                    throughSequence: $0.throughSequence,
                    firstSentAtMilliseconds: $0.firstSentAtMilliseconds
                )
            }
        )
        // Only the exact bytes this type writes are accepted: no extra keys,
        // no other spellings of the same values.
        guard value.isValid, try encode(value) == bytes else {
            throw EluRuntimeQueueError.corruptStorage
        }
        return value
    }

    private func withDirectory<T>(_ operation: (Int32) throws -> T) throws -> T {
        let descriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw EluRuntimeQueueError.databaseUnavailable }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid()
        else {
            throw EluRuntimeQueueError.invalidDirectory
        }
        return try operation(descriptor)
    }

    private func read(_ name: String, in directory: Int32) throws -> Data? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw EluRuntimeQueueError.databaseUnavailable
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              metadata.st_size >= 0, metadata.st_size <= Self.maximumBytes
        else {
            throw EluRuntimeQueueError.corruptStorage
        }
        var bytes = [UInt8](repeating: 0, count: Self.maximumBytes + 1)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw EluRuntimeQueueError.databaseUnavailable }
            if count == 0 { break }
            offset += count
        }
        guard offset == metadata.st_size else { throw EluRuntimeQueueError.corruptStorage }
        return Data(bytes.prefix(offset))
    }
}
