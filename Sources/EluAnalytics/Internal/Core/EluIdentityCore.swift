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

actor EluIdentityCore {
    private let store: any EluIdentityStateStore
    private let clock: @Sendable () -> Date
    private let anonymousIdGenerator: @Sendable () -> String
    private let sessionIdGenerator: @Sendable () -> String

    private var identity: EluIdentityState
    private var streamMetadata: EluStreamMetadata
    private var flagContext: EluFlagContext

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

        let state = try Self.loadOrCreateState(
            store: store,
            now: clock(),
            anonymousIdGenerator: anonymousIdGenerator,
            streamIdGenerator: streamIdGenerator
        )
        identity = state.identity
        streamMetadata = state.streamMetadata
        flagContext = Self.runtimeFlagContext(from: state.flagContext)
    }

    func snapshot() -> EluIdentitySnapshot {
        // Sequence allocation belongs to the future durable queue. That layer
        // must advance nextSequence atomically with enqueue; this core never
        // reserves or advances it independently.
        EluIdentitySnapshot(
            identity: identity,
            streamId: streamMetadata.streamId,
            nextSequence: streamMetadata.nextSequence,
            flagContext: flagContext
        )
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
        var nextIdentity = identity
        if let key {
            if nextIdentity.groups[type] == nil,
               nextIdentity.groups.count >= EluIdentityState.maximumGroups
            {
                throw EluIdentityStateError.tooManyGroups
            }
            nextIdentity.groups[type] = key
        } else {
            nextIdentity.groups.removeValue(forKey: type)
        }

        var nextFlagContext = flagContext
        if previousKey != key {
            nextFlagContext.groupProperties.removeValue(forKey: type)
        }
        nextIdentity.contextRevision = try increment(nextIdentity.contextRevision)
        nextIdentity.updatedAt = clock()
        try persist(nextIdentity, flagContext: nextFlagContext)
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
        var nextIdentity = identity
        nextIdentity.groups = [:]
        nextIdentity.contextRevision = try increment(nextIdentity.contextRevision)
        nextIdentity.updatedAt = clock()

        var nextFlagContext = flagContext
        nextFlagContext.groupProperties = [:]
        try persist(nextIdentity, flagContext: nextFlagContext)
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
        guard nextFlagContext.personProperties.count <= EluPersistedFlagContext.maximumProperties else {
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
        guard group.count <= EluPersistedFlagContext.maximumProperties else {
            throw EluIdentityStateError.tooManySuperProperties
        }
        if nextFlagContext.groupProperties[type] == nil,
           nextFlagContext.groupProperties.count >= EluPersistedFlagContext.maximumGroups
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
    func recordEligibleActivity(timeoutSeconds requestedTimeoutSeconds: Int = 1_800) throws
        -> EluSessionState
    {
        let timeoutSeconds = min(max(requestedTimeoutSeconds, 60), 36_000)
        let now = clock()
        let previousSession = identity.session

        let shouldRotate: Bool
        if let previousSession {
            let idleSeconds = now.timeIntervalSince(previousSession.lastActivityAt)
            let durationSeconds = now.timeIntervalSince(previousSession.startedAt)
            let effectiveExpiryTimeout = min(previousSession.timeoutSeconds, timeoutSeconds)
            let clockMovedBackward = now < previousSession.lastActivityAt
                || now < previousSession.startedAt
            shouldRotate = clockMovedBackward
                || idleSeconds >= Double(effectiveExpiryTimeout)
                || durationSeconds >= Double(EluSessionState.requiredMaximumDurationSeconds)
        } else {
            shouldRotate = true
        }

        let session: EluSessionState
        if shouldRotate {
            let nextId = sessionIdGenerator()
            if let previousSession, nextId == previousSession.id {
                throw EluIdentityStateError.invalidIdentifier("sessionId")
            }
            session = try EluSessionState(
                id: nextId,
                startedAt: now,
                lastActivityAt: now,
                timeoutSeconds: timeoutSeconds
            )
        } else if var resumed = previousSession {
            resumed.lastActivityAt = now
            resumed.timeoutSeconds = timeoutSeconds
            try resumed.validate()
            session = resumed
        } else {
            preconditionFailure("A missing session must take the rotation path")
        }

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
        try persist(next, flagContext: EluFlagContext())
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
        try persist(next, flagContext: nextFlagContext)
    }

    private func persist(
        _ nextIdentity: EluIdentityState,
        flagContext nextFlagContext: EluFlagContext? = nil
    ) throws {
        let resolvedFlagContext = nextFlagContext ?? flagContext
        let persistedFlagContext = try EluPersistedFlagContext(
            personProperties: resolvedFlagContext.personProperties,
            groupProperties: resolvedFlagContext.groupProperties
        )
        let state = try EluPersistedState(
            identity: nextIdentity,
            streamMetadata: streamMetadata,
            flagContext: persistedFlagContext
        )
        do {
            try store.save(state, mode: .normal)
        } catch {
            if error as? EluIdentityStateStoreError == .primaryCommitDurabilityUnconfirmed {
                // The primary replacement is already visible and startup will
                // prefer it. Publish the same state in memory before surfacing
                // that its directory durability could not be confirmed.
                identity = nextIdentity
                flagContext = resolvedFlagContext
            }
            throw error
        }
        identity = nextIdentity
        flagContext = resolvedFlagContext
    }

    private func increment(_ value: Int64) throws -> Int64 {
        guard value < Int64.max else {
            throw EluIdentityStateError.counterExhausted
        }
        return value + 1
    }

    private func validateProperties(_ properties: [String: EluJSONValue]) throws {
        guard properties.count <= EluPersistedFlagContext.maximumProperties else {
            throw EluIdentityStateError.tooManySuperProperties
        }
        for (key, value) in properties {
            guard EluIdentityState.valid(key, maximumLength: 256) else {
                throw EluIdentityStateError.invalidPropertyKey
            }
            try value.validate()
        }
    }

    private static func loadOrCreateState(
        store: any EluIdentityStateStore,
        now: Date,
        anonymousIdGenerator: @Sendable () -> String,
        streamIdGenerator: @Sendable () -> String
    ) throws -> EluPersistedState {
        switch try store.load() {
        case let .loaded(state):
            return state
        case .missing:
            let state = try makeState(
                identity: nil,
                streamMetadata: nil,
                flagContext: nil,
                failClosed: false,
                now: now,
                anonymousIdGenerator: anonymousIdGenerator,
                streamIdGenerator: streamIdGenerator
            )
            try store.save(state, mode: .recovery)
            return state
        case let .recoverable(components):
            let identityIsValid = components.identity != nil
            let state = try makeState(
                identity: components.identity,
                streamMetadata: components.streamMetadata,
                flagContext: identityIsValid ? components.flagContext : nil,
                failClosed: !identityIsValid,
                forceOptOut: components.forceOptOut,
                advanceContextForClearedFlagContext: identityIsValid
                    && components.flagContext == nil,
                now: now,
                anonymousIdGenerator: anonymousIdGenerator,
                streamIdGenerator: streamIdGenerator
            )
            try store.save(state, mode: .recovery)
            return state
        }
    }

    private static func makeState(
        identity existingIdentity: EluIdentityState?,
        streamMetadata existingStreamMetadata: EluStreamMetadata?,
        flagContext existingFlagContext: EluPersistedFlagContext?,
        failClosed: Bool,
        forceOptOut: Bool = false,
        advanceContextForClearedFlagContext: Bool = false,
        now: Date,
        anonymousIdGenerator: @Sendable () -> String,
        streamIdGenerator: @Sendable () -> String
    ) throws -> EluPersistedState {
        let identity: EluIdentityState
        if var existingIdentity {
            if forceOptOut, !existingIdentity.optedOut {
                existingIdentity.optedOut = true
                existingIdentity.updatedAt = now
            }
            if advanceContextForClearedFlagContext {
                guard existingIdentity.contextRevision < Int64.max else {
                    throw EluIdentityStateError.counterExhausted
                }
                existingIdentity.contextRevision += 1
                existingIdentity.updatedAt = now
            }
            identity = existingIdentity
        } else {
            identity = try EluIdentityState(
                revision: 0,
                contextRevision: 0,
                anonymousId: anonymousIdGenerator(),
                userId: nil,
                groups: [:],
                superProperties: [:],
                session: nil,
                optedOut: failClosed,
                updatedAt: now
            )
        }

        let streamMetadata: EluStreamMetadata
        if let existingStreamMetadata {
            streamMetadata = existingStreamMetadata
        } else {
            streamMetadata = try EluStreamMetadata(streamId: streamIdGenerator())
        }

        let flagContext: EluPersistedFlagContext
        if let existingFlagContext {
            flagContext = existingFlagContext
        } else {
            flagContext = try EluPersistedFlagContext()
        }
        return try EluPersistedState(
            identity: identity,
            streamMetadata: streamMetadata,
            flagContext: flagContext
        )
    }

    private static func runtimeFlagContext(from context: EluPersistedFlagContext) -> EluFlagContext {
        EluFlagContext(
            personProperties: context.personProperties,
            groupProperties: context.groupProperties
        )
    }
}
