import Foundation

enum EluNativeReplaySessionError: Error, Equatable, Sendable {
    case invalidMetadata
    case invalidClock
    case counterExhausted
}

/// Durable accounting only. Decoding this value never grants recorder or source permission.
struct EluNativeReplaySessionState: Codable, Equatable, Sendable {
    static let maximumBytes = 16_384
    static let maximumMicroseconds: Int64 = 86_400_000_000
    static let maximumOrdinal: Int64 = 9_007_199_254_740_991

    let schemaVersion: Int
    let namespaceHash: String
    let streamId: String
    var nextReplayOrdinal: Int64
    var session: Session?

    struct Key: Equatable, Sendable {
        let siteId: String
        let sessionId: String
        let sessionStartedAt: String
        static func == (a: Self, b: Self) -> Bool {
            same(a.siteId, b.siteId) && same(a.sessionId, b.sessionId)
                && same(a.sessionStartedAt, b.sessionStartedAt)
        }
    }

    struct Session: Codable, Equatable, Sendable {
        let siteId: String
        let sessionId: String
        let sessionStartedAt: String
        let samplingHash: String
        let originalSampleRate: Double
        let originalSelected: Bool
        var firstStartAt: String?
        var maximumDurationSeconds: Int
        var elapsedFloorMicroseconds: Int64
        var observedWallAt: String
        var clockDenied: Bool
        var interrupted: Bool
        var activeEpoch: String?

        var key: Key { Key(siteId: siteId, sessionId: sessionId, sessionStartedAt: sessionStartedAt) }
        var remainingMicroseconds: Int64 {
            max(0, Int64(maximumDurationSeconds) * 1_000_000 - elapsedFloorMicroseconds)
        }
        var remainingWholeSeconds: Int { Int(remainingMicroseconds / 1_000_000) }
        func selected(currentRate: Double) -> Bool {
            originalSelected && Self.validRate(currentRate)
                && EluNativeReplaySessionState.selected(hash: samplingHash, rate: currentRate)
        }
        private static func validRate(_ rate: Double) -> Bool { rate.isFinite && (0 ... 1).contains(rate) }
    }

    init(namespaceHash: String, streamId: String) throws {
        schemaVersion = 1; self.namespaceHash = namespaceHash; self.streamId = streamId
        nextReplayOrdinal = 0; session = nil
        try validate()
    }

    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    func matches(namespace: String, stream: String) -> Bool {
        Self.same(namespaceHash, namespace) && Self.same(streamId, stream)
    }

    private static let rootKeys: Set<String> = ["schemaVersion", "namespaceHash", "streamId", "nextReplayOrdinal", "session"]
    private static let sessionKeys: Set<String> = ["siteId", "sessionId", "sessionStartedAt", "samplingHash", "originalSampleRate", "originalSelected", "firstStartAt", "maximumDurationSeconds", "elapsedFloorMicroseconds", "observedWallAt", "clockDenied", "interrupted", "activeEpoch"]

    static func decode(_ data: Data) throws -> Self {
        guard (1 ... maximumBytes).contains(data.count) else { throw EluNativeReplaySessionError.invalidMetadata }
        let parsed = try EluV1StrictCanonicalJSON.parse(data)
        guard parsed.canonicalData == data, case let .object(root) = parsed.value,
              Set(root.map { String(decoding: $0.name, as: UTF16.self) }) == rootKeys,
              let value = root.first(where: { String(decoding: $0.name, as: UTF16.self) == "session" })?.value
        else { throw EluNativeReplaySessionError.invalidMetadata }
        switch value {
        case .null: break
        case let .object(members):
            guard Set(members.map { String(decoding: $0.name, as: UTF16.self) }) == sessionKeys
            else { throw EluNativeReplaySessionError.invalidMetadata }
        default: throw EluNativeReplaySessionError.invalidMetadata
        }
        let state = try JSONDecoder().decode(Self.self, from: data)
        try state.validate()
        return state
    }

    func encoded() throws -> Data {
        try validate()
        // Synthesized Codable omits nil optionals; retain explicit required null keys.
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
        if let session {
            var value = object["session"] as! [String: Any]
            if session.firstStartAt == nil { value["firstStartAt"] = NSNull() }
            if session.activeEpoch == nil { value["activeEpoch"] = NSNull() }
            object["session"] = value
        } else { object["session"] = NSNull() }
        let data = try EluV1StrictCanonicalJSON.parse(JSONSerialization.data(withJSONObject: object)).canonicalData
        guard data.count <= Self.maximumBytes else { throw EluNativeReplaySessionError.invalidMetadata }
        return data
    }

    func validate() throws {
        guard schemaVersion == 1, namespaceHash.utf8.count == 64,
              namespaceHash.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }),
              EluIdentityState.valid(streamId, maximumLength: 256),
              (0 ... Self.maximumOrdinal).contains(nextReplayOrdinal)
        else { throw EluNativeReplaySessionError.invalidMetadata }
        guard let s = session else { return }
        guard EluIdentityState.valid(s.siteId, maximumLength: 256),
              EluIdentityState.valid(s.sessionId, maximumLength: 256),
              s.originalSampleRate.isFinite, (0 ... 1).contains(s.originalSampleRate),
              (0 ... 86_400).contains(s.maximumDurationSeconds),
              (0 ... Self.maximumMicroseconds).contains(s.elapsedFloorMicroseconds),
              s.samplingHash == Self.samplingHash(s.key),
              s.originalSelected == Self.selected(hash: s.samplingHash, rate: s.originalSampleRate)
        else { throw EluNativeReplaySessionError.invalidMetadata }
        let start = try EluV1Timestamp(s.sessionStartedAt)
        let observed = try EluV1Timestamp(s.observedWallAt)
        guard !start.storageIsLeapSecond, !observed.storageIsLeapSecond, observed >= start,
              s.activeEpoch.map({ UUID(uuidString: $0) != nil }) ?? true,
              s.activeEpoch == nil || (s.originalSelected && s.firstStartAt != nil),
              s.firstStartAt != nil || s.elapsedFloorMicroseconds == 0
        else { throw EluNativeReplaySessionError.invalidMetadata }
        if let first = s.firstStartAt {
            let first = try EluV1Timestamp(first)
            guard s.originalSelected, !first.storageIsLeapSecond, first >= start, observed >= first
            else { throw EluNativeReplaySessionError.invalidMetadata }
        }
    }

    static func samplingHash(_ key: Key) -> String {
        hashArray([.string(Array("elu-native-session-replay-sampling-v1".utf16)),
            .string(Array(key.siteId.utf16)), .string(Array(key.sessionId.utf16)),
            .string(Array(key.sessionStartedAt.utf16))])
    }

    static func selected(hash: String, rate: Double) -> Bool {
        guard rate.isFinite, (0 ... 1).contains(rate), hash.hasPrefix("sha256:"), hash.utf8.count == 71,
              let numerator = UInt64(hash.dropFirst(7).prefix(13), radix: 16)
        else { return false }
        return Double(numerator) / 4_503_599_627_370_496 < rate
    }

    private static func hashArray(_ values: [EluV1StrictCanonicalJSON.Value]) -> String {
        // All callers provide bounded already validated scalar values.
        let bytes = try! EluV1StrictCanonicalJSON.canonicalData(for: .array(values))
        return EluV1StrictCanonicalJSON.hash(bytes)
    }

    mutating func allocateReplayID() throws -> String {
        try validate()
        guard nextReplayOrdinal < Self.maximumOrdinal else { throw EluNativeReplaySessionError.counterExhausted }
        let hash = Self.hashArray([.string(Array("elu-native-replay-id-v1".utf16)),
            .string(Array(namespaceHash.utf16)), .string(Array(streamId.utf16)), .number(String(nextReplayOrdinal))])
        nextReplayOrdinal += 1
        return "replay_" + hash.dropFirst(7)
    }

    /// Current configuration can restrict the original draw/cap, never renew it.
    mutating func observe(key: Key, sampleRate: Double, maximumDurationSeconds: Int,
                          wall: EluV1Timestamp, ownedEpoch: String?, continuousElapsed: Int64?) throws {
        guard sampleRate.isFinite, (0 ... 1).contains(sampleRate), (0 ... 86_400).contains(maximumDurationSeconds),
              !wall.storageIsLeapSecond, wall >= (try EluV1Timestamp(key.sessionStartedAt))
        else { throw EluNativeReplaySessionError.invalidMetadata }
        if session?.key != key {
            let hash = Self.samplingHash(key)
            session = Session(siteId: key.siteId, sessionId: key.sessionId, sessionStartedAt: key.sessionStartedAt,
                samplingHash: hash, originalSampleRate: sampleRate == 0 ? 0 : sampleRate,
                originalSelected: Self.selected(hash: hash, rate: sampleRate), firstStartAt: nil,
                maximumDurationSeconds: maximumDurationSeconds, elapsedFloorMicroseconds: 0,
                observedWallAt: wall.source, clockDenied: false, interrupted: false, activeEpoch: nil)
        }
        guard var s = session else { throw EluNativeReplaySessionError.invalidMetadata }
        s.maximumDurationSeconds = min(s.maximumDurationSeconds, maximumDurationSeconds)
        if let epoch = s.activeEpoch, ownedEpoch.map({ Self.same(epoch, $0) }) != true { s.interrupted = true }
        if wall < (try EluV1Timestamp(s.observedWallAt)) { s.clockDenied = true }
        else {
            s.observedWallAt = wall.source
            if let first = s.firstStartAt {
                guard let elapsed = Self.elapsedCeilMicroseconds(from: try EluV1Timestamp(first), to: wall) else {
                    s.clockDenied = true; session = s; return
                }
                s.elapsedFloorMicroseconds = max(s.elapsedFloorMicroseconds, elapsed)
            }
        }
        if let elapsed = continuousElapsed {
            guard (0 ... Self.maximumMicroseconds).contains(elapsed) else { throw EluNativeReplaySessionError.invalidClock }
            if s.firstStartAt != nil { s.elapsedFloorMicroseconds = max(s.elapsedFloorMicroseconds, elapsed) }
        }
        session = s
        try validate()
    }

    mutating func begin(epoch: String, wall: EluV1Timestamp, currentRate: Double) throws -> Bool {
        guard var s = session, s.selected(currentRate: currentRate), !s.clockDenied, !s.interrupted,
              s.activeEpoch == nil, s.remainingMicroseconds > 0, UUID(uuidString: epoch) != nil,
              wall >= (try EluV1Timestamp(s.observedWallAt)) else { return false }
        if let first = s.firstStartAt {
            guard let elapsed = Self.elapsedCeilMicroseconds(from: try EluV1Timestamp(first), to: wall) else { return false }
            s.elapsedFloorMicroseconds = max(s.elapsedFloorMicroseconds, elapsed)
            if s.remainingMicroseconds == 0 { s.observedWallAt = wall.source; session = s; return false }
        } else { s.firstStartAt = wall.source }
        s.observedWallAt = wall.source; s.activeEpoch = epoch; session = s
        try validate(); return true
    }

    /// Restrictive exact-scope receipt. The owner checks installation scope before calling.
    mutating func stop(key: Key, firstStartAt: String, epoch: String,
                       wall: EluV1Timestamp?, elapsedMicroseconds: Int64?) throws -> Bool {
        guard var s = session, s.key == key, s.firstStartAt.map({ Self.same($0, firstStartAt) }) == true,
              s.activeEpoch.map({ Self.same($0, epoch) }) == true else { return false }
        if let wall, let elapsed = Self.elapsedCeilMicroseconds(from: try EluV1Timestamp(firstStartAt), to: wall),
           wall >= (try EluV1Timestamp(s.observedWallAt)) {
            s.observedWallAt = wall.source; s.elapsedFloorMicroseconds = max(s.elapsedFloorMicroseconds, elapsed)
        } else { s.clockDenied = true }
        if let elapsedMicroseconds, (0 ... Self.maximumMicroseconds).contains(elapsedMicroseconds) {
            s.elapsedFloorMicroseconds = max(s.elapsedFloorMicroseconds, elapsedMicroseconds)
        } else { s.clockDenied = true }
        s.activeEpoch = nil; session = s; try validate(); return true
    }

    /// Ceil the single exact original-window delta, never separately rounded refresh deltas.
    static func elapsedCeilMicroseconds(from start: EluV1Timestamp, to end: EluV1Timestamp) -> Int64? {
        guard !start.storageIsLeapSecond, !end.storageIsLeapSecond, end >= start else { return nil }
        let days = end.storageDay - start.storageDay
        if days > 2 { return maximumMicroseconds }
        let seconds = days * 86_400 + end.storageSecondOfDay - start.storageSecondOfDay
        if seconds > 86_401 { return maximumMicroseconds }
        func parts(_ text: String) -> (Int64, [UInt8]) {
            let digits = text.utf8.map { $0 - 48 }
            var micro: Int64 = 0
            for index in 0 ..< 6 { micro = micro * 10 + Int64(index < digits.count ? digits[index] : 0) }
            return (micro, Array(digits.dropFirst(6)))
        }
        let a = parts(start.storageFractionDigits), b = parts(end.storageFractionDigits)
        var tailGreater = false
        for index in 0 ..< max(a.1.count, b.1.count) {
            let x = index < a.1.count ? a.1[index] : 0, y = index < b.1.count ? b.1[index] : 0
            if x != y { tailGreater = y > x; break }
        }
        let result = seconds * 1_000_000 + b.0 - a.0 + (tailGreater ? 1 : 0)
        return result < 0 ? nil : min(maximumMicroseconds, result)
    }
}
