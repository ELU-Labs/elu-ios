import Foundation

struct EluFlagContext: Equatable, Sendable {
    var personProperties: [String: EluJSONValue] = [:]
    var groupProperties: [String: [String: EluJSONValue]] = [:]
}

struct EluIdentitySnapshot: Equatable, Sendable {
    var identity: EluIdentityState
    var streamId: String
    var nextSequence: Int64
    var flagContext: EluFlagContext
}

struct EluStreamPosition: Equatable, Sendable {
    var streamId: String
    var sequence: Int64
}

actor EluIdentityCore {
    private static let maximumFlagGroups = 64
    private static let maximumFlagProperties = 256

    private let store: any EluIdentityStateStore
    private let clock: @Sendable () -> Date
    private let anonymousIdGenerator: @Sendable () -> String
    private let sessionIdGenerator: @Sendable () -> String

    private var identity: EluIdentityState
    private var streamMetadata: EluStreamMetadata
    private var flagContext = EluFlagContext()

    init(
        store: any EluIdentityStateStore,
        clock: @escaping @Sendable () -> Date = { Date() },
        anonymousIdGenerator: @escaping @Sendable () -> String = {
            "anon_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        },
        streamIdGenerator: @escaping @Sendable () -> String = {
            "stream_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        },
        sessionIdGenerator: @escaping @Sendable () -> String = {
            "session_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        }
    ) throws {
        self.store = store
        self.clock = clock
        self.anonymousIdGenerator = anonymousIdGenerator
        self.sessionIdGenerator = sessionIdGenerator

        identity = try Self.loadOrCreateIdentity(
            store: store,
            now: clock(),
            anonymousIdGenerator: anonymousIdGenerator
        )
        streamMetadata = try Self.loadOrCreateStreamMetadata(
            store: store,
            streamIdGenerator: streamIdGenerator
        )
    }

    func snapshot() -> EluIdentitySnapshot {
        EluIdentitySnapshot(
            identity: identity,
            streamId: streamMetadata.streamId,
            nextSequence: streamMetadata.nextSequence,
            flagContext: flagContext
        )
    }

    func nextSequence() throws -> EluStreamPosition {
        guard streamMetadata.nextSequence < Int64.max else {
            throw EluIdentityStateError.counterExhausted
        }
        let position = EluStreamPosition(
            streamId: streamMetadata.streamId,
            sequence: streamMetadata.nextSequence
        )
        var next = streamMetadata
        next.nextSequence += 1
        try next.validate()
        try store.saveStreamMetadata(next)
        streamMetadata = next
        return position
    }

    func identify(_ userId: String) throws {
        guard EluIdentityState.valid(userId, maximumLength: 512) else {
            throw EluIdentityStateError.invalidIdentifier("userId")
        }
        var next = identity
        if next.userId != userId {
            next.revision = try increment(next.revision)
            next.userId = userId
        }
        next.contextRevision = try increment(next.contextRevision)
        next.updatedAt = clock()
        try persist(next)
    }

    func alias(_ aliasId: String) throws {
        guard EluIdentityState.valid(aliasId, maximumLength: 512) else {
            throw EluIdentityStateError.invalidIdentifier("alias")
        }
        try advanceContextRevision()
    }

    func setGroup(type: String, key: String?) throws {
        guard EluIdentityState.valid(type, maximumLength: 256) else {
            throw EluIdentityStateError.invalidIdentifier("groupType")
        }
        if let key, !EluIdentityState.valid(key, maximumLength: 512) {
            throw EluIdentityStateError.invalidIdentifier("groupKey")
        }

        let previousKey = identity.groups[type]
        var next = identity
        if let key {
            if next.groups[type] == nil, next.groups.count >= EluIdentityState.maximumGroups {
                throw EluIdentityStateError.tooManyGroups
            }
            next.groups[type] = key
        } else {
            next.groups.removeValue(forKey: type)
        }
        next.contextRevision = try increment(next.contextRevision)
        next.updatedAt = clock()
        try persist(next)
        if previousKey != key {
            flagContext.groupProperties.removeValue(forKey: type)
        }
    }

    func registerSuperProperties(_ properties: [String: EluJSONValue]) throws {
        try validateProperties(properties)
        var next = identity
        for (key, value) in properties {
            next.superProperties[key] = value
        }
        guard next.superProperties.count <= EluIdentityState.maximumSuperProperties else {
            throw EluIdentityStateError.tooManySuperProperties
        }
        next.contextRevision = try increment(next.contextRevision)
        next.updatedAt = clock()
        try persist(next)
    }

    func resetGroups() throws {
        var next = identity
        next.groups = [:]
        next.contextRevision = try increment(next.contextRevision)
        next.updatedAt = clock()
        try persist(next)
        flagContext.groupProperties = [:]
    }

    func unregisterSuperProperty(_ key: String) throws {
        guard EluIdentityState.valid(key, maximumLength: 256) else {
            throw EluIdentityStateError.invalidPropertyKey
        }
        var next = identity
        next.superProperties.removeValue(forKey: key)
        next.contextRevision = try increment(next.contextRevision)
        next.updatedAt = clock()
        try persist(next)
    }

    func setFlagPersonProperties(_ properties: [String: EluJSONValue]) throws {
        try validateProperties(properties)
        var nextFlagContext = flagContext
        for (key, value) in properties {
            nextFlagContext.personProperties[key] = value
        }
        guard nextFlagContext.personProperties.count <= Self.maximumFlagProperties else {
            throw EluIdentityStateError.tooManySuperProperties
        }
        try persistContextMutation(flagContext: nextFlagContext)
    }

    func setFlagGroupProperties(type: String, properties: [String: EluJSONValue]) throws {
        guard EluIdentityState.valid(type, maximumLength: 256) else {
            throw EluIdentityStateError.invalidIdentifier("flagGroupType")
        }
        try validateProperties(properties)
        var nextFlagContext = flagContext
        var group = nextFlagContext.groupProperties[type] ?? [:]
        for (key, value) in properties {
            group[key] = value
        }
        guard group.count <= Self.maximumFlagProperties else {
            throw EluIdentityStateError.tooManySuperProperties
        }
        if nextFlagContext.groupProperties[type] == nil,
           nextFlagContext.groupProperties.count >= Self.maximumFlagGroups
        {
            throw EluIdentityStateError.tooManyGroups
        }
        nextFlagContext.groupProperties[type] = group
        try persistContextMutation(flagContext: nextFlagContext)
    }

    func setOptedOut(_ optedOut: Bool) throws {
        var next = identity
        next.optedOut = optedOut
        next.updatedAt = clock()
        try persist(next)
    }

    @discardableResult
    func startSession(timeoutSeconds: Int = 1_800) throws -> EluSessionState {
        let now = clock()
        let session = try EluSessionState(
            id: sessionIdGenerator(),
            startedAt: now,
            lastActivityAt: now,
            timeoutSeconds: timeoutSeconds
        )
        var next = identity
        next.session = session
        next.updatedAt = now
        try persist(next)
        return session
    }

    @discardableResult
    func touchSession() throws -> EluSessionState? {
        guard var session = identity.session else { return nil }
        let now = clock()
        session.lastActivityAt = now
        try session.validate()
        var next = identity
        next.session = session
        next.updatedAt = now
        try persist(next)
        return session
    }

    @discardableResult
    func setSessionLifecycle(_ lifecycle: EluSessionLifecycle) throws -> EluSessionState? {
        guard var session = identity.session else { return nil }
        let now = clock()
        session.lifecycle = lifecycle
        session.backgroundedAt = lifecycle == .background ? now : nil
        try session.validate()
        var next = identity
        next.session = session
        next.updatedAt = now
        try persist(next)
        return session
    }

    func clearSession() throws {
        var next = identity
        next.session = nil
        next.updatedAt = clock()
        try persist(next)
    }

    func reset() throws {
        let anonymousId = anonymousIdGenerator()
        guard EluIdentityState.valid(anonymousId, maximumLength: 256),
              anonymousId != identity.anonymousId
        else {
            throw EluIdentityStateError.invalidIdentifier("anonymousId")
        }
        var next = identity
        next.anonymousId = anonymousId
        next.userId = nil
        next.groups = [:]
        next.superProperties = [:]
        next.session = nil
        next.revision = try increment(next.revision)
        next.contextRevision = try increment(next.contextRevision)
        next.updatedAt = clock()
        try persist(next)
        flagContext = EluFlagContext()
    }

    private func advanceContextRevision() throws {
        var next = identity
        next.contextRevision = try increment(next.contextRevision)
        next.updatedAt = clock()
        try persist(next)
    }

    private func persistContextMutation(flagContext nextFlagContext: EluFlagContext) throws {
        var next = identity
        next.contextRevision = try increment(next.contextRevision)
        next.updatedAt = clock()
        try persist(next)
        flagContext = nextFlagContext
    }

    private func persist(_ next: EluIdentityState) throws {
        try next.validate()
        try store.saveIdentity(next)
        identity = next
    }

    private func increment(_ value: Int64) throws -> Int64 {
        guard value < Int64.max else {
            throw EluIdentityStateError.counterExhausted
        }
        return value + 1
    }

    private func validateProperties(_ properties: [String: EluJSONValue]) throws {
        guard properties.count <= Self.maximumFlagProperties else {
            throw EluIdentityStateError.tooManySuperProperties
        }
        for (key, value) in properties {
            guard EluIdentityState.valid(key, maximumLength: 256) else {
                throw EluIdentityStateError.invalidPropertyKey
            }
            try value.validate()
        }
    }

    private static func loadOrCreateIdentity(
        store: any EluIdentityStateStore,
        now: Date,
        anonymousIdGenerator: @Sendable () -> String
    ) throws -> EluIdentityState {
        var recoveringCorruption = false
        var identityWasMissing = false
        do {
            if let identity = try store.loadIdentity() {
                try identity.validate()
                return identity
            }
            identityWasMissing = true
        } catch let error as EluIdentityStateStoreError {
            guard error == .corrupted(.identity) else { throw error }
            recoveringCorruption = true
        } catch is EluIdentityStateError {
            // A decodable but invalid record is recoverable corruption.
            recoveringCorruption = true
        }

        if identityWasMissing {
            do {
                recoveringCorruption = try store.loadStreamMetadata() != nil
            } catch let error as EluIdentityStateStoreError {
                guard error == .corrupted(.streamMetadata) else { throw error }
                recoveringCorruption = true
            }
        }

        let identity = try EluIdentityState(
            revision: 0,
            contextRevision: 0,
            anonymousId: anonymousIdGenerator(),
            userId: nil,
            groups: [:],
            superProperties: [:],
            session: nil,
            optedOut: recoveringCorruption,
            updatedAt: now
        )
        try store.saveIdentity(identity)
        return identity
    }

    private static func loadOrCreateStreamMetadata(
        store: any EluIdentityStateStore,
        streamIdGenerator: @Sendable () -> String
    ) throws -> EluStreamMetadata {
        do {
            if let metadata = try store.loadStreamMetadata() {
                try metadata.validate()
                return metadata
            }
        } catch let error as EluIdentityStateStoreError {
            guard error == .corrupted(.streamMetadata) else { throw error }
        } catch is EluIdentityStateError {
            // A decodable but invalid record is recoverable corruption.
        }

        let metadata = try EluStreamMetadata(streamId: streamIdGenerator())
        try store.saveStreamMetadata(metadata)
        return metadata
    }
}
