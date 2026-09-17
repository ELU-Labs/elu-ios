import Darwin
import Foundation

// Persistence contract: official ELU 0.1.0 (5825dfb4...) and the dated
// PostHog 3.69.0 source (1c9b3178...). See this overlay's source provenance.
// No upstream implementation is imported, initialized, or allowed to mutate state.
enum EluLegacyStartupError: Error, Equatable, Sendable {
    case unavailable
    case unsafePath
    case sourceChanged
    case sourceTooLarge
    case unsupportedMapping
    case unsupportedStorage
    case pendingLegacyQueue
    case invalidIdentity
    case invalidConsent
}

struct EluLegacyStartupSource: Sendable {
    let applicationSupportURL: URL
    let bundleIdentifier: String
    let siteKey: String
    private let permitsLegacyRead: Bool

    init(applicationSupportURL: URL, bundleIdentifier: String, siteKey: String,
         permitsLegacyRead: Bool = true) {
        self.applicationSupportURL = applicationSupportURL
        self.bundleIdentifier = bundleIdentifier
        self.siteKey = siteKey
        self.permitsLegacyRead = permitsLegacyRead
    }

    static func live(siteKey: String) throws -> Self {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else {
            throw EluLegacyStartupError.unavailable
        }
        let bundle = Bundle.main.bundleIdentifier ?? ""
        // Scope refusal is lazy: existing SQLite and owned JSON must still win.
        return Self(applicationSupportURL: base.standardizedFileURL.resolvingSymlinksInPath(),
                    bundleIdentifier: bundle, siteKey: siteKey,
                    permitsLegacyRead: !bundle.isEmpty && !Bundle.main.bundlePath.hasSuffix(".appex"))
    }

    struct Observation: Sendable {
        let state: EluPersistedState?
        let eventsImport: EluLegacyEventsImport?
        private let source: EluLegacyStartupSource
        private let snapshot: Snapshot

        fileprivate init(state: EluPersistedState?, source: EluLegacyStartupSource, snapshot: Snapshot,
                         eventsImport: EluLegacyEventsImport? = nil) {
            self.state = state; self.source = source; self.snapshot = snapshot; self.eventsImport = eventsImport
        }
        func recheck() throws {
            guard try source.snapshot() == snapshot else { throw EluLegacyStartupError.sourceChanged }
        }
    }

    func read(now: Date, streamIdGenerator: @Sendable () -> String) throws -> Observation {
        let observed = try snapshot()
        guard observed.token != nil else {
            return Observation(state: nil, source: self, snapshot: observed)
        }
        func scalar(_ key: String) throws -> EluV1StrictCanonicalJSON.Value? {
            guard let data = observed.files[key] else { return nil }
            let document = try EluV1StrictCanonicalJSON.parse(data)
            guard case let .object(members) = document.value, members.count == 1,
                  String(decoding: members[0].name, as: UTF16.self) == key else {
                throw EluLegacyStartupError.unsupportedStorage
            }
            return members[0].value
        }
        func string(_ key: String) throws -> String? {
            guard let value = try scalar(key) else { return nil }
            guard case let .string(units) = value else { throw EluLegacyStartupError.invalidIdentity }
            return String(decoding: units, as: UTF16.self)
        }
        func bool(_ key: String) throws -> Bool? {
            guard let value = try scalar(key) else { return nil }
            guard case let .bool(flag) = value else { throw EluLegacyStartupError.invalidConsent }
            return flag
        }
        func dictionary<T: Decodable>(_ key: String, as type: T.Type, empty: T) throws -> T {
            guard let data = observed.files[key] else { return empty }
            let parsed = try EluV1StrictCanonicalJSON.parse(data)
            guard case .object = parsed.value else { throw EluLegacyStartupError.unsupportedStorage }
            return try JSONDecoder().decode(type, from: parsed.canonicalData)
        }
        guard let anonymous = try string("posthog.anonymousId"),
              EluIdentityState.valid(anonymous, maximumLength: 256) else {
            throw EluLegacyStartupError.invalidIdentity
        }
        if let device = try string("posthog.deviceId"), device != anonymous {
            throw EluLegacyStartupError.unsupportedStorage
        }
        let distinct = try string("posthog.distinctId")
        if let distinct, !EluIdentityState.valid(distinct, maximumLength: 512) {
            throw EluLegacyStartupError.invalidIdentity
        }
        let identified = try bool("posthog.isIdentified") ?? (distinct != nil && distinct != anonymous)
        guard !identified || distinct != nil,
              identified || distinct == nil || distinct == anonymous else {
            throw EluLegacyStartupError.invalidIdentity
        }
        // Absence is not an opt-in witness. Preserve false exactly when explicit;
        // unknown consent and a cached disabled source remain restrictive.
        let optOut = try bool("posthog.optOut")
        let optedOut = observed.enabled != true || optOut != false
        let context = try EluMigrationContextSnapshot(
            superProperties: dictionary("posthog.registerProperties", as: [String: EluJSONValue].self, empty: [:]),
            groups: dictionary("posthog.groups", as: [String: String].self, empty: [:]),
            flagPersonProperties: dictionary("posthog.personPropertiesForFlags", as: [String: EluJSONValue].self, empty: [:]),
            flagGroupProperties: dictionary("posthog.groupPropertiesForFlags", as: [String: [String: EluJSONValue]].self, empty: [:]))
        // Existing identity_json stores this marker atomically with identity/context.
        // No separate "complete" row can bypass a failed state installation.
        let marker = try EluIdentityMigration(sourceSchema: "elu010-ph369-" + observed.digest,
                                              completedAt: now)
        let identity = try EluIdentityState(revision: 0, contextRevision: 0,
            anonymousId: anonymous, userId: identified ? distinct : nil,
            groups: context.groups, superProperties: context.superProperties,
            session: nil, optedOut: optedOut, updatedAt: now, migration: marker)
        let state = try EluPersistedState(identity: identity,
            streamMetadata: EluStreamMetadata(streamId: streamIdGenerator()),
            flagContext: EluPersistedFlagContext(personProperties: context.flagPersonProperties,
                                                groupProperties: context.flagGroupProperties))
        let eventsImport = observed.events.isEmpty ? nil : try EluLegacyEventsImport(state: state,
            entries: observed.events.sorted(by: EluLegacyEventsImport.precedes))
        let observation = Observation(state: state, source: self, snapshot: observed, eventsImport: eventsImport)
        try observation.recheck()
        return observation
    }

    fileprivate struct Snapshot: Equatable, Sendable {
        var token: String?
        var enabled: Bool?
        var files: [String: Data] = [:]
        var events: [EluLegacyEventsImport.Entry] = []
        var witnesses: [String: Witness] = [:]
        var digest: String {
            let rows = witnesses.keys.sorted().map { key in
                key + ":" + witnesses[key]!.digest
            }.joined(separator: "\n")
            return String(EluV1StrictCanonicalJSON.hash(Data(rows.utf8)).dropFirst(7))
        }
    }
    fileprivate enum Witness: Equatable, Sendable {
        case missing
        case unrelatedRegularFile(String)
        case file(String, Data)
        case directory(String, [String])
        var digest: String {
            switch self {
            case .missing: return "missing"
            case let .unrelatedRegularFile(stamp): return "unrelated:" + stamp
            case let .file(stamp, data): return stamp + ":" + EluV1StrictCanonicalJSON.hash(data)
            case let .directory(stamp, names): return stamp + ":" + names.joined(separator: "\n")
            }
        }
    }
    private static let queues: Set<String> = [
        "posthog.queueFolder.uuid", "posthog.queueFolder", "posthog.queue.plist",
        "posthog.replayFolder.uuid", "posthog.replayFolder", "posthog.replayBufferFolder",
        "posthog.logsFolder"
    ]
    private static let scalars: Set<String> = [
        "posthog.distinctId", "posthog.anonymousId", "posthog.isIdentified", "posthog.optOut", "posthog.deviceId"
    ]
    private static let knownFiles: Set<String> = [
        "posthog.distinctId", "posthog.anonymousId", "posthog.enabledFeatureFlags",
        "posthog.enabledFeatureFlagPayloads", "posthog.flags", "posthog.groups",
        "posthog.registerProperties", "posthog.optOut", "posthog.sessionReplay",
        "posthog.isIdentified", "posthog.enabledPersonProcessing", "posthog.remoteConfig",
        "posthog.surveySeen", "posthog.lastSeenSurveyDate", "posthog.requestId",
        "posthog.evaluatedAt", "posthog.minimalFlagCalledEvents", "posthog.personPropertiesForFlags",
        "posthog.groupPropertiesForFlags", "posthog.errorTracking", "posthog.capturePerformance",
        "posthog.deviceId", "posthog.pushSubscription", "posthog.pushPendingUnregister"
    ]

    private func snapshot() throws -> Snapshot {
        guard permitsLegacyRead else { throw EluLegacyStartupError.unsupportedStorage }
        try Self.requireComponent(bundleIdentifier)
        guard !siteKey.isEmpty, siteKey.utf8.count <= 512 else { throw EluLegacyStartupError.unsupportedMapping }
        let safeKey = String(siteKey.map { c -> Character in
            c.isLetter || c.isNumber || c == "-" || c == "_" ? c : "_"
        })
        let support = applicationSupportURL.standardizedFileURL
        guard support.isFileURL, support.path.hasPrefix("/") else { throw EluLegacyStartupError.unsafePath }
        let cache = support.appendingPathComponent("EluAnalytics/config-\(safeKey).json")
        let base = support.appendingPathComponent(bundleIdentifier)
        var result = Snapshot()
        var consumed = 0
        func file(_ url: URL, maximum: Int) throws -> Data? {
            let witness = try Self.readFile(url, within: support, maximum: maximum)
            result.witnesses[url.path] = witness
            if case let .file(_, data) = witness {
                consumed += data.count
                guard consumed <= 2 * 1024 * 1024 else { throw EluLegacyStartupError.sourceTooLarge }
                return data
            }
            return nil
        }
        func directory(_ url: URL) throws -> [String]? {
            let witness = try Self.readDirectory(url, within: support)
            result.witnesses[url.path] = witness
            if case let .directory(_, names) = witness { return names }
            return nil
        }
        let cached = try file(cache, maximum: 64 * 1024)
        let baseNames = try directory(base) ?? []
        guard let cached else {
            // A true first install may share this bundle directory with unrelated
            // app files. Inspect the exact known layout, not arbitrary descendants:
            // original pre-token keys or one token-directory level containing a
            // posthog.* key are recognizable unmapped state and must refuse.
            var inspectedNames = baseNames.count
            for name in baseNames {
                guard !name.hasPrefix("posthog.") else { throw EluLegacyStartupError.unsupportedMapping }
                let candidate = base.appendingPathComponent(name)
                if let witness = try Self.unrelatedRegularFile(candidate, within: support) {
                    result.witnesses[candidate.path] = witness
                } else {
                    guard let children = try directory(candidate) else { throw EluLegacyStartupError.sourceChanged }
                    inspectedNames += children.count
                    guard inspectedNames <= 256 else { throw EluLegacyStartupError.sourceTooLarge }
                    guard !children.contains(where: { $0.hasPrefix("posthog.") }) else {
                        throw EluLegacyStartupError.unsupportedMapping
                    }
                }
            }
            return result
        }
        guard safeKey == siteKey else { throw EluLegacyStartupError.unsupportedMapping }
        let config = try EluV1StrictCanonicalJSON.parse(cached)
        guard case let .bool(enabled)? = try config.objectProperty("enabled"),
              case let .string(units)? = try config.objectProperty("publicToken") else {
            throw EluLegacyStartupError.unsupportedMapping
        }
        if let version = try config.objectProperty("v") {
            guard case let .number(value) = version, value == "1" else { throw EluLegacyStartupError.unsupportedMapping }
        }
        let token = String(decoding: units, as: UTF16.self)
        try Self.requireComponent(token)
        guard token.trimmingCharacters(in: .whitespacesAndNewlines) == token else {
            throw EluLegacyStartupError.unsupportedMapping
        }
        // Pre-token layouts and concurrent root-level leftovers need a distinct
        // migration policy. The dated source migrates them destructively; we do not.
        guard !baseNames.contains(where: { Self.knownFiles.contains($0) || Self.queues.contains($0) }) else {
            throw EluLegacyStartupError.unsupportedStorage
        }
        let selected = base.appendingPathComponent(token)
        let names = try directory(selected) ?? []
        guard !names.isEmpty else {
            // A mapping without identity is not evidence of a new install.
            throw EluLegacyStartupError.invalidIdentity
        }
        guard Set(names).isSubset(of: Self.knownFiles.union(Self.queues)) else {
            throw EluLegacyStartupError.unsupportedStorage
        }
        guard !names.contains("posthog.pushPendingUnregister"), !names.contains("posthog.pushSubscription") else {
            throw EluLegacyStartupError.unsupportedStorage
        }
        result.token = token; result.enabled = enabled
        for name in names.sorted() {
            let url = selected.appendingPathComponent(name)
            if name == "posthog.queueFolder.uuid" {
                guard let names = try directory(url) else { throw EluLegacyStartupError.sourceChanged }
                for filename in names {
                    let entryURL = url.appendingPathComponent(filename)
                    guard let bytes = try file(entryURL, maximum: EluLegacyEventsImport.maximumEventBytes) else {
                        throw EluLegacyStartupError.sourceChanged
                    }
                    var info = stat()
                    guard entryURL.path.withCString({ Darwin.lstat($0, &info) }) == 0,
                          result.witnesses[entryURL.path] == .file(Self.stamp(info), bytes) else {
                        throw EluLegacyStartupError.sourceChanged
                    }
                    result.events.append(.init(filename: filename,
                        creationSeconds: Int64(info.st_birthtimespec.tv_sec),
                        creationNanoseconds: Int64(info.st_birthtimespec.tv_nsec), bytes: bytes))
                }
            } else if Self.queues.contains(name) {
                // Older Events formats and Replay/logs require a separate adapter.
                guard name != "posthog.queue.plist", let entries = try directory(url), entries.isEmpty else {
                    throw EluLegacyStartupError.pendingLegacyQueue
                }
            } else if let bytes = try file(url, maximum: Self.scalars.contains(name) ? 2048 : 256 * 1024) {
                result.files[name] = bytes
            } else {
                throw EluLegacyStartupError.sourceChanged
            }
        }
        return result
    }

    // No unrelated file contents are read. A changed kind/inode is witnessed on
    // the final source check; symlinks/special files remain ambiguous and refuse.
    private static func unrelatedRegularFile(_ url: URL, within root: URL) throws -> Witness? {
        try checkParents(url, within: root)
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else {
            throw EluLegacyStartupError.sourceChanged
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .unrelatedRegularFile(stamp(info))
        case S_IFDIR: return nil
        default: throw EluLegacyStartupError.unsafePath
        }
    }

    private static func requireComponent(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 512,
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw EluLegacyStartupError.unsafePath
        }
    }
    private static func stamp(_ s: stat) -> String {
        "\(s.st_dev):\(s.st_ino):\(s.st_mode):\(s.st_size):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec):\(s.st_birthtimespec.tv_sec):\(s.st_birthtimespec.tv_nsec)"
    }
    private static func checkParents(_ url: URL, within root: URL) throws {
        guard url.path.hasPrefix(root.path + "/") else { throw EluLegacyStartupError.unsafePath }
        var current = url.deletingLastPathComponent()
        while current.path.count >= root.path.count {
            var info = stat()
            if current.path.withCString({ Darwin.lstat($0, &info) }) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw EluLegacyStartupError.unsafePath }
            } else if errno != ENOENT { throw EluLegacyStartupError.unavailable }
            if current == root { break }
            current.deleteLastPathComponent()
        }
    }
    private static func readFile(_ url: URL, within root: URL, maximum: Int) throws -> Witness {
        try checkParents(url, within: root)
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else {
            if errno == ENOENT { return .missing }
            throw EluLegacyStartupError.unavailable
        }
        defer { _ = Darwin.close(fd) }
        var before = stat(); var after = stat(); var pathState = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= maximum else { throw EluLegacyStartupError.sourceTooLarge }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: min(maximum + 1, 16 * 1024))
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            if count < 0 { if errno == EINTR { continue }; throw EluLegacyStartupError.unavailable }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximum else { throw EluLegacyStartupError.sourceTooLarge }
        }
        guard fstat(fd, &after) == 0, url.path.withCString({ Darwin.lstat($0, &pathState) }) == 0,
              stamp(before) == stamp(after), stamp(after) == stamp(pathState), data.count == before.st_size else {
            throw EluLegacyStartupError.sourceChanged
        }
        return .file(stamp(after), data)
    }
    private static func readDirectory(_ url: URL, within root: URL) throws -> Witness {
        try checkParents(url, within: root)
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard fd >= 0 else {
            if errno == ENOENT { return .missing }
            throw EluLegacyStartupError.unavailable
        }
        var before = stat(); var after = stat(); var pathState = stat()
        guard fstat(fd, &before) == 0, let directory = fdopendir(fd) else {
            _ = Darwin.close(fd); throw EluLegacyStartupError.unavailable
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw EluLegacyStartupError.unavailable }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw EluLegacyStartupError.unsafePath }
            if name == "." || name == ".." { continue }
            try requireComponent(name); names.append(name)
            guard names.count <= 128 else { throw EluLegacyStartupError.sourceTooLarge }
        }
        guard fstat(fd, &after) == 0, url.path.withCString({ Darwin.lstat($0, &pathState) }) == 0,
              stamp(before) == stamp(after), stamp(after) == stamp(pathState) else { throw EluLegacyStartupError.sourceChanged }
        return .directory(stamp(after), names.sorted())
    }
}
