import Foundation

// A bounded migration format, not a historical capture-authority assertion.
// Raw source bytes survive adoption and retirement. No upstream queue is mutated.
struct EluLegacyEventsImport: Codable, Equatable, Sendable {
    static let maximumRecords = 128
    static let maximumSourceBytes = 2 * 1024 * 1024
    static let maximumEncodedBytes = 4 * 1024 * 1024
    static let maximumEventBytes = 256 * 1024

    struct Entry: Codable, Equatable, Sendable {
        let filename: String
        let creationSeconds: Int64
        let creationNanoseconds: Int64
        let bytes: Data
    }
    let schemaVersion: Int
    let state: EluPersistedState
    let entries: [Entry]

    init(state: EluPersistedState, entries: [Entry]) throws {
        schemaVersion = 1
        // Match the existing SQLite state codec before comparing atomic joins.
        self.state = try EluStateCoding.decoder().decode(EluPersistedState.self,
            from: EluStateCoding.encoder().encode(state))
        self.entries = entries
        _ = try records()
    }

    // This names the transformation and retains the actual original producer in
    // $lib/$lib_version. It does not claim a fresh capture or an upstream revision.
    static func versions() throws -> EluVersionContext {
        try EluVersionContext(runtime: EluVersionComponent(name: "elu-ios-legacy-import", version: "1.0.0"),
            facade: EluVersionComponent(name: "EluAnalytics", version: "0.1.0"),
            build: "posthog-ios-3.69.0")
    }

    func records() throws -> [EluQueuedRecord] {
        guard schemaVersion == 1, (1...Self.maximumRecords).contains(entries.count),
              state.identity.revision == 0, state.identity.contextRevision == 0,
              state.identity.userId == nil, !state.identity.optedOut, state.identity.session == nil,
              state.streamMetadata.nextSequence == 0,
              let marker = state.identity.migration,
              marker.sourceSchema.range(of: #"^elu010-ph369-[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw EluLegacyStartupError.pendingLegacyQueue
        }
        try state.validate()
        let versions = try Self.versions()
        var names = Set<String>(); var ids = Set<String>(); var total = 0
        var previous: Entry?
        return try entries.enumerated().map { index, entry in
            guard Self.uuid7(entry.filename), names.insert(entry.filename).inserted,
                  entry.creationSeconds > 0, (0..<1_000_000_000).contains(entry.creationNanoseconds),
                  !entry.bytes.isEmpty, entry.bytes.count <= Self.maximumEventBytes else {
                throw EluLegacyStartupError.pendingLegacyQueue
            }
            if let previous {
                guard Self.precedes(previous, entry) else { throw EluLegacyStartupError.pendingLegacyQueue }
            }
            previous = entry; total += entry.bytes.count
            guard total <= Self.maximumSourceBytes else { throw EluLegacyStartupError.sourceTooLarge }
            let json = try EluV1StrictCanonicalJSON.parse(entry.bytes)
            guard case let .object(members) = json.value,
                  Set(members.map { String(decoding: $0.name, as: UTF16.self) })
                    == Set(["uuid", "event", "distinct_id", "timestamp", "properties"]) else {
                throw EluLegacyStartupError.pendingLegacyQueue
            }
            let object = try JSONDecoder().decode([String: EluJSONValue].self, from: json.canonicalData)
            guard case let .string(id)? = object["uuid"], Self.uuid7(id), ids.insert(id).inserted,
                  case let .string(name)? = object["event"], !name.hasPrefix("$"),
                  case let .string(distinct)? = object["distinct_id"], distinct == state.identity.anonymousId,
                  case let .string(timestamp)? = object["timestamp"],
                  case let .object(properties)? = object["properties"],
                  properties["$is_identified"] == .bool(false),
                  properties["$lib"] == .string("posthog-ios"),
                  properties["$lib_version"] == .string("3.69.0"),
                  case let .string(session)? = properties["$session_id"], Self.uuid7(session),
                  !properties.keys.contains(where: { Self.mutationProperties.contains($0) }),
                  properties["distinct_id"] == nil, properties["$anon_distinct_id"] == nil,
                  properties["$device_id"] == nil || properties["$device_id"] == .string(distinct) else {
                throw EluLegacyStartupError.pendingLegacyQueue
            }
            let encodedProperties = try JSONEncoder().encode(properties)
            guard try EluV1StrictCanonicalJSON.parse(encodedProperties).canonicalData
                    == json.canonicalObjectProperty("properties") else { throw EluLegacyStartupError.pendingLegacyQueue }
            let occurredAt = try Self.timestamp(timestamp)
            // Older values are kept; current delivery's independently authorized
            // age/terminal policy still applies. Future timestamps never normalize.
            guard occurredAt <= marker.completedAt else { throw EluLegacyStartupError.pendingLegacyQueue }
            var groups: [String: String] = [:]
            if let value = properties["$groups"] {
                guard case let .object(values) = value else { throw EluLegacyStartupError.pendingLegacyQueue }
                for (key, value) in values {
                    guard case let .string(group) = value else { throw EluLegacyStartupError.pendingLegacyQueue }
                    groups[key] = group
                }
            }
            let event = try EluQueuedEvent(eventId: id, streamId: state.streamMetadata.streamId,
                sequence: Int64(index), contextRevision: 0, kind: .capture, name: name,
                occurredAt: occurredAt, identity: EluEventIdentity(anonymousId: distinct, userId: nil, revision: 0),
                sessionId: session, properties: properties, groups: groups, versions: versions)
            // The original milliseconds must survive the current wire serializer.
            guard EluRFC3339.string(from: event.occurredAt) == timestamp else {
                throw EluLegacyStartupError.pendingLegacyQueue
            }
            return .event(event)
        }
    }
    func encoded() throws -> Data {
        _ = try records()
        let bytes = try EluStateCoding.encoder().encode(self)
        guard bytes.count <= Self.maximumEncodedBytes else { throw EluLegacyStartupError.sourceTooLarge }
        return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= maximumEncodedBytes else { throw EluLegacyStartupError.sourceTooLarge }
        let value = try EluStateCoding.decoder().decode(Self.self, from: bytes)
        guard try value.encoded() == bytes else { throw EluLegacyStartupError.pendingLegacyQueue }
        return value
    }
    static func precedes(_ a: Entry, _ b: Entry) -> Bool {
        a.creationSeconds < b.creationSeconds ||
            (a.creationSeconds == b.creationSeconds && a.creationNanoseconds < b.creationNanoseconds)
    }
    private static func uuid7(_ string: String) -> Bool {
        string.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
                     options: .regularExpression) != nil && UUID(uuidString: string) != nil
    }
    private static let mutationProperties: Set<String> = [
        "$set", "$set_once", "$unset", "$add", "$append", "$remove", "$union", "$delete",
        "$group_set", "$group_set_once", "$group_key", "$group_type", "alias"
    ]
    private static func timestamp(_ value: String) throws -> Date {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$"#,
                          options: .regularExpression) != nil else { throw EluLegacyStartupError.pendingLegacyQueue }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw EluLegacyStartupError.pendingLegacyQueue
        }
        return date
    }
}
