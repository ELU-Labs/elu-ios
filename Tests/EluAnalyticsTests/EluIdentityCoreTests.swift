import Foundation
import XCTest
@testable import EluAnalytics

final class EluIdentityCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_775_260_800)

    func testFreshIdentitySerializationMatchesClosedSchemaAndSeparatesStreamMetadata() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileIdentityStateStore(directoryURL: directory)
            let core = try self.makeCore(store: store)
            _ = try await core.startSession()

            let identityData = try Data(contentsOf: store.identityFileURL)
            let identity = try XCTUnwrap(
                JSONSerialization.jsonObject(with: identityData) as? [String: Any]
            )
            XCTAssertEqual(
                Set(identity.keys),
                Set([
                    "schemaVersion", "revision", "contextRevision", "anonymousId", "userId",
                    "groups", "superProperties", "session", "optedOut", "updatedAt",
                ])
            )
            XCTAssertNil(identity["streamId"])
            XCTAssertNil(identity["sequence"])
            XCTAssertTrue(identity["userId"] is NSNull)
            XCTAssertEqual(identity["schemaVersion"] as? Int, 1)

            let session = try XCTUnwrap(identity["session"] as? [String: Any])
            XCTAssertEqual(
                Set(session.keys),
                Set([
                    "id", "startedAt", "lastActivityAt", "timeoutSeconds",
                    "maximumDurationSeconds", "lifecycle", "backgroundedAt",
                ])
            )
            XCTAssertTrue(session["backgroundedAt"] is NSNull)
            XCTAssertEqual(session["maximumDurationSeconds"] as? Int, 86_400)
            XCTAssertNotNil(EluRFC3339.date(from: try XCTUnwrap(session["startedAt"] as? String)))
            let roundTrippedIdentity = try XCTUnwrap(store.loadIdentity())
            XCTAssertEqual(roundTrippedIdentity.session?.id, "session-initial")

            let streamData = try Data(contentsOf: store.streamMetadataFileURL)
            let stream = try XCTUnwrap(
                JSONSerialization.jsonObject(with: streamData) as? [String: Any]
            )
            XCTAssertEqual(Set(stream.keys), Set(["schemaVersion", "streamId", "nextSequence"]))
            XCTAssertEqual(stream["nextSequence"] as? Int, 0)
        }
    }

    func testIdentifyPreservesAnonymousIdAndUsesIndependentRevisions() async throws {
        let store = LockedMemoryIdentityStore()
        let core = try makeCore(store: store)
        let original = await core.snapshot()

        try await core.identify("user-123")
        let identified = await core.snapshot()
        XCTAssertEqual(identified.identity.anonymousId, original.identity.anonymousId)
        XCTAssertEqual(identified.identity.userId, "user-123")
        XCTAssertEqual(identified.identity.identityRevision, 1)
        XCTAssertEqual(identified.identity.contextRevision, 1)

        try await core.identify("user-123")
        try await core.alias("legacy-user-123")
        let repeated = await core.snapshot()
        XCTAssertEqual(repeated.identity.identityRevision, 1)
        XCTAssertEqual(repeated.identity.contextRevision, 3)
    }

    func testResetClearsContextAndSessionWhilePreservingOptStreamAndSequence() async throws {
        let identifiers = LockedIdentifierSequence(["anon-initial", "anon-reset"])
        let store = LockedMemoryIdentityStore()
        let core = try EluIdentityCore(
            store: store,
            clock: { self.now },
            anonymousIdGenerator: { identifiers.next() },
            streamIdGenerator: { "stream-stable" },
            sessionIdGenerator: { "session-1" }
        )

        try await core.identify("user-123")
        try await core.setGroup(type: "organization", key: "org-456")
        try await core.registerSuperProperties(["plan": .string("growth")])
        try await core.setFlagPersonProperties(["beta": .bool(true)])
        try await core.setFlagGroupProperties(
            type: "organization",
            properties: ["tier": .integer(2)]
        )
        try await core.setOptedOut(true)
        _ = try await core.startSession()
        let firstSequence = try await core.nextSequence()
        let secondSequence = try await core.nextSequence()
        XCTAssertEqual(firstSequence.sequence, 0)
        XCTAssertEqual(secondSequence.sequence, 1)

        let before = await core.snapshot()
        try await core.reset()
        let after = await core.snapshot()

        XCTAssertEqual(after.identity.anonymousId, "anon-reset")
        XCTAssertNotEqual(after.identity.anonymousId, before.identity.anonymousId)
        XCTAssertNil(after.identity.userId)
        XCTAssertTrue(after.identity.groups.isEmpty)
        XCTAssertTrue(after.identity.superProperties.isEmpty)
        XCTAssertNil(after.identity.session)
        XCTAssertTrue(after.identity.optedOut)
        XCTAssertTrue(after.flagContext.personProperties.isEmpty)
        XCTAssertTrue(after.flagContext.groupProperties.isEmpty)
        XCTAssertEqual(after.streamId, before.streamId)
        XCTAssertEqual(after.identity.identityRevision, before.identity.identityRevision + 1)
        XCTAssertEqual(after.identity.contextRevision, before.identity.contextRevision + 1)
        let sequenceAfterReset = try await core.nextSequence()
        XCTAssertEqual(sequenceAfterReset.sequence, 2)
    }

    func testEveryContextMutationAdvancesContextRevisionEvenWhenValueIsUnchanged() async throws {
        let store = LockedMemoryIdentityStore()
        let core = try makeCore(store: store)

        try await core.identify("user-123")
        try await core.identify("user-123")
        try await core.alias("legacy-user")
        try await core.setGroup(type: "organization", key: "org-1")
        try await core.setGroup(type: "organization", key: "org-1")
        try await core.setGroup(type: "missing", key: nil)
        try await core.registerSuperProperties(["plan": .string("growth")])
        try await core.registerSuperProperties(["plan": .string("growth")])
        try await core.unregisterSuperProperty("missing")
        try await core.setFlagPersonProperties(["plan": .string("growth")])
        try await core.setFlagGroupProperties(
            type: "organization",
            properties: ["plan": .string("growth")]
        )
        try await core.resetGroups()

        let snapshot = await core.snapshot()
        XCTAssertEqual(snapshot.identity.identityRevision, 1)
        XCTAssertEqual(snapshot.identity.contextRevision, 12)
        XCTAssertTrue(snapshot.identity.groups.isEmpty)
        XCTAssertTrue(snapshot.flagContext.groupProperties.isEmpty)
    }

    func testChangingOrRemovingGroupAssociationClearsItsFlagContext() async throws {
        let core = try makeCore(store: LockedMemoryIdentityStore())
        try await core.setGroup(type: "organization", key: "org-1")
        try await core.setFlagGroupProperties(
            type: "organization",
            properties: ["plan": .string("growth")]
        )

        try await core.setGroup(type: "organization", key: "org-1")
        var snapshot = await core.snapshot()
        XCTAssertEqual(snapshot.flagContext.groupProperties["organization"]?["plan"], .string("growth"))

        try await core.setGroup(type: "organization", key: "org-2")
        snapshot = await core.snapshot()
        XCTAssertNil(snapshot.flagContext.groupProperties["organization"])

        try await core.setFlagGroupProperties(
            type: "organization",
            properties: ["plan": .string("enterprise")]
        )
        try await core.setGroup(type: "organization", key: nil)
        snapshot = await core.snapshot()
        XCTAssertNil(snapshot.flagContext.groupProperties["organization"])
    }

    func testGroupBoundRejectsTheSixtyFifthDistinctTypeWithoutMutatingState() async throws {
        let store = LockedMemoryIdentityStore()
        let core = try makeCore(store: store)
        for index in 0 ..< EluIdentityState.maximumGroups {
            try await core.setGroup(type: "type-\(index)", key: "group-\(index)")
        }
        let before = await core.snapshot()

        do {
            try await core.setGroup(type: "overflow", key: "group-overflow")
            XCTFail("Expected the group bound to reject a new type")
        } catch {
            XCTAssertEqual(error as? EluIdentityStateError, .tooManyGroups)
        }

        let after = await core.snapshot()
        XCTAssertEqual(after, before)
    }

    func testLifecycleTransitionsDoNotCountAsSessionActivity() async throws {
        let clock = LockedClock(now)
        let core = try EluIdentityCore(
            store: LockedMemoryIdentityStore(),
            clock: { clock.now() },
            anonymousIdGenerator: { "anon-initial" },
            streamIdGenerator: { "stream-initial" },
            sessionIdGenerator: { "session-initial" }
        )
        let started = try await core.startSession()

        clock.set(Date(timeIntervalSince1970: now.timeIntervalSince1970 + 120))
        let backgroundedValue = try await core.setSessionLifecycle(.background)
        let backgrounded = try XCTUnwrap(backgroundedValue)
        XCTAssertEqual(backgrounded.lastActivityAt, started.lastActivityAt)
        XCTAssertEqual(backgrounded.backgroundedAt, clock.now())

        clock.set(Date(timeIntervalSince1970: now.timeIntervalSince1970 + 240))
        let foregroundedValue = try await core.setSessionLifecycle(.active)
        let foregrounded = try XCTUnwrap(foregroundedValue)
        XCTAssertEqual(foregrounded.lastActivityAt, started.lastActivityAt)
        XCTAssertNil(foregrounded.backgroundedAt)
    }

    func testCorruptIdentityRecoversFreshStateWithoutResettingValidStreamOrdering() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileIdentityStateStore(directoryURL: directory)
            let first = try self.makeCore(store: store)
            let firstPosition = try await first.nextSequence()
            let secondPosition = try await first.nextSequence()
            XCTAssertEqual(firstPosition.sequence, 0)
            XCTAssertEqual(secondPosition.sequence, 1)
            let originalSnapshot = await first.snapshot()
            let originalStreamId = originalSnapshot.streamId

            var corruptIdentity = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: store.identityFileURL))
                    as? [String: Any]
            )
            corruptIdentity["streamId"] = "forbidden"
            try JSONSerialization.data(withJSONObject: corruptIdentity, options: [.sortedKeys])
                .write(to: store.identityFileURL, options: .atomic)

            let recovered = try EluIdentityCore(
                store: store,
                clock: { self.now },
                anonymousIdGenerator: { "anon-recovered" },
                streamIdGenerator: { "stream-must-not-replace-valid-state" },
                sessionIdGenerator: { "session-1" }
            )
            let snapshot = await recovered.snapshot()
            XCTAssertEqual(snapshot.identity.anonymousId, "anon-recovered")
            XCTAssertEqual(snapshot.identity.identityRevision, 0)
            XCTAssertTrue(snapshot.identity.optedOut)
            XCTAssertEqual(snapshot.streamId, originalStreamId)
            let recoveredPosition = try await recovered.nextSequence()
            XCTAssertEqual(recoveredPosition.sequence, 2)

            let recoveredData = try Data(contentsOf: store.identityFileURL)
            let recoveredObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: recoveredData) as? [String: Any]
            )
            XCTAssertNil(recoveredObject["streamId"])
        }
    }

    func testConcurrentSequenceAllocationIsUniqueOrderedAndDurable() async throws {
        let store = LockedMemoryIdentityStore()
        let core = try makeCore(store: store)
        let positions = try await withThrowingTaskGroup(
            of: EluStreamPosition.self,
            returning: [EluStreamPosition].self
        ) { group in
            for _ in 0 ..< 250 {
                group.addTask { try await core.nextSequence() }
            }
            var positions: [EluStreamPosition] = []
            for try await position in group {
                positions.append(position)
            }
            return positions
        }

        XCTAssertEqual(Set(positions.map(\.streamId)), Set(["stream-initial"]))
        XCTAssertEqual(positions.map(\.sequence).sorted(), Array(0 ..< 250).map(Int64.init))

        let reloaded = try makeCore(store: store)
        let reloadedPosition = try await reloaded.nextSequence()
        XCTAssertEqual(reloadedPosition.sequence, 250)
    }

    func testConcurrentPropertyMutationsAreSerializedWithoutLostRevisions() async throws {
        let store = LockedMemoryIdentityStore()
        let core = try makeCore(store: store)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 100 {
                group.addTask {
                    try await core.registerSuperProperties(["key-\(index)": .integer(Int64(index))])
                }
            }
            try await group.waitForAll()
        }

        let snapshot = await core.snapshot()
        XCTAssertEqual(snapshot.identity.contextRevision, 100)
        XCTAssertEqual(snapshot.identity.superProperties.count, 100)
        XCTAssertEqual(store.identitySaveCount, 101)
    }

    private func makeCore(store: any EluIdentityStateStore) throws -> EluIdentityCore {
        try EluIdentityCore(
            store: store,
            clock: { self.now },
            anonymousIdGenerator: { "anon-initial" },
            streamIdGenerator: { "stream-initial" },
            sessionIdGenerator: { "session-initial" }
        )
    }

    private func withTemporaryDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await operation(directory)
    }
}

private final class LockedMemoryIdentityStore: EluIdentityStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: EluIdentityState?
    private var streamMetadata: EluStreamMetadata?
    private var _identitySaveCount = 0

    var identitySaveCount: Int {
        withLock { _identitySaveCount }
    }

    func loadIdentity() -> EluIdentityState? {
        withLock { identity }
    }

    func loadStreamMetadata() -> EluStreamMetadata? {
        withLock { streamMetadata }
    }

    func saveIdentity(_ identity: EluIdentityState) {
        withLock {
            self.identity = identity
            _identitySaveCount += 1
        }
    }

    func saveStreamMetadata(_ metadata: EluStreamMetadata) {
        withLock { streamMetadata = metadata }
    }

    private func withLock<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class LockedIdentifierSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        precondition(!values.isEmpty)
        return values.removeFirst()
    }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}
