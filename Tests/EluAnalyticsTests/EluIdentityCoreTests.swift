import Foundation
import XCTest
@testable import EluAnalytics

final class EluIdentityCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_775_260_800)

    func testAggregateSerializationUsesThreeClosedRecordsAndExactIdentityKeys() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileIdentityStateStore(directoryURL: directory)
            let core = try self.makeCore(store: store)
            _ = try await core.recordEligibleActivity()

            let data = try Data(contentsOf: store.stateFileURL)
            let aggregate = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(
                Set(aggregate.keys),
                Set(["schemaVersion", "identity", "streamMetadata", "flagContext"])
            )
            XCTAssertEqual(aggregate["schemaVersion"] as? Int, 1)

            let identity = try XCTUnwrap(aggregate["identity"] as? [String: Any])
            XCTAssertEqual(
                Set(identity.keys),
                Set([
                    "schemaVersion", "revision", "contextRevision", "anonymousId", "userId",
                    "groups", "superProperties", "session", "optedOut", "updatedAt",
                ])
            )
            XCTAssertNil(identity["streamId"])
            XCTAssertNil(identity["nextSequence"])
            XCTAssertTrue(identity["userId"] is NSNull)

            let stream = try XCTUnwrap(aggregate["streamMetadata"] as? [String: Any])
            XCTAssertEqual(Set(stream.keys), Set(["schemaVersion", "streamId", "nextSequence"]))
            XCTAssertEqual(stream["streamId"] as? String, "stream-initial")
            XCTAssertEqual(stream["nextSequence"] as? Int, 0)

            let flagContext = try XCTUnwrap(aggregate["flagContext"] as? [String: Any])
            XCTAssertEqual(
                Set(flagContext.keys),
                Set(["schemaVersion", "personProperties", "groupProperties"])
            )

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

            guard case let .loaded(roundTripped) = try store.load() else {
                return XCTFail("Expected the aggregate to round-trip")
            }
            XCTAssertEqual(roundTripped.identity.session?.id, "session-initial")
            XCTAssertEqual(roundTripped.streamMetadata.nextSequence, 0)
        }
    }

    func testFlagContextAndContextRevisionPersistTogetherAcrossReconstruction() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileIdentityStateStore(directoryURL: directory)
            let first = try self.makeCore(store: store)

            try await first.setFlagPersonProperties(["plan": .string("growth")])
            try await first.setFlagGroupProperties(
                type: "organization",
                properties: ["tier": .integer(2)]
            )
            let before = await first.snapshot()
            XCTAssertEqual(before.identity.contextRevision, 2)

            guard case let .loaded(persisted) = try store.load() else {
                return XCTFail("Expected a valid aggregate")
            }
            XCTAssertEqual(persisted.identity.contextRevision, 2)
            XCTAssertEqual(persisted.flagContext.personProperties["plan"], .string("growth"))
            XCTAssertEqual(
                persisted.flagContext.groupProperties["organization"]?["tier"],
                .integer(2)
            )

            let reconstructed = try self.makeCore(store: store)
            let after = await reconstructed.snapshot()
            XCTAssertEqual(after, before)
        }
    }

    func testResetGroupsGroupReplacementAndResetClearTheCorrectPersistedContext() async throws {
        let anonymousIds = LockedIdentifierSequence(["anon-initial", "anon-reset"])
        let sessionIds = LockedIdentifierSequence(["session-1"])
        let store = LockedMemoryIdentityStore()
        let core = try EluIdentityCore(
            store: store,
            clock: { self.now },
            anonymousIdGenerator: { anonymousIds.next() },
            streamIdGenerator: { "stream-stable" },
            sessionIdGenerator: { sessionIds.next() }
        )

        try await core.identify("user-123")
        try await core.setGroup(type: "organization", key: "org-1")
        try await core.setFlagPersonProperties(["beta": .bool(true)])
        try await core.setFlagGroupProperties(
            type: "organization",
            properties: ["tier": .string("growth")]
        )
        try await core.resetGroups()

        var snapshot = await core.snapshot()
        XCTAssertTrue(snapshot.identity.groups.isEmpty)
        XCTAssertTrue(snapshot.flagContext.groupProperties.isEmpty)
        XCTAssertEqual(snapshot.flagContext.personProperties["beta"], .bool(true))

        try await core.setGroup(type: "organization", key: "org-1")
        try await core.setFlagGroupProperties(
            type: "organization",
            properties: ["tier": .string("enterprise")]
        )
        try await core.setGroup(type: "organization", key: "org-1")
        snapshot = await core.snapshot()
        XCTAssertEqual(
            snapshot.flagContext.groupProperties["organization"]?["tier"],
            .string("enterprise")
        )

        try await core.setGroup(type: "organization", key: "org-2")
        snapshot = await core.snapshot()
        XCTAssertNil(snapshot.flagContext.groupProperties["organization"])

        try await core.registerSuperProperties(["plan": .string("paid")])
        try await core.setOptedOut(true)
        _ = try await core.recordEligibleActivity()
        let beforeReset = await core.snapshot()
        try await core.reset()
        let afterReset = await core.snapshot()

        XCTAssertEqual(afterReset.identity.anonymousId, "anon-reset")
        XCTAssertNil(afterReset.identity.userId)
        XCTAssertTrue(afterReset.identity.groups.isEmpty)
        XCTAssertTrue(afterReset.identity.superProperties.isEmpty)
        XCTAssertNil(afterReset.identity.session)
        XCTAssertTrue(afterReset.identity.optedOut)
        XCTAssertTrue(afterReset.flagContext.personProperties.isEmpty)
        XCTAssertTrue(afterReset.flagContext.groupProperties.isEmpty)
        XCTAssertEqual(afterReset.streamId, beforeReset.streamId)
        XCTAssertEqual(afterReset.nextSequence, 0)

        let reconstructed = try EluIdentityCore(
            store: store,
            clock: { self.now },
            anonymousIdGenerator: { "unused-anon" },
            streamIdGenerator: { "unused-stream" },
            sessionIdGenerator: { "unused-session" }
        )
        let reconstructedSnapshot = await reconstructed.snapshot()
        XCTAssertEqual(reconstructedSnapshot, afterReset)
    }

    func testParseableCorruptFlagContextPreservesValidIdentityAndStream() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileIdentityStateStore(directoryURL: directory)
            let first = try self.makeCore(store: store)
            try await first.identify("user-current")
            try await first.setFlagPersonProperties(["plan": .string("growth")])
            try await first.setFlagGroupProperties(
                type: "organization",
                properties: ["tier": .integer(2)]
            )
            let before = await first.snapshot()

            var aggregate = try self.jsonObject(at: store.stateFileURL)
            var context = try XCTUnwrap(aggregate["flagContext"] as? [String: Any])
            context["personProperties"] = ["": true]
            aggregate["flagContext"] = context
            try self.writeJSONObject(aggregate, to: store.stateFileURL)

            let recovered = try EluIdentityCore(
                store: store,
                clock: { self.now },
                anonymousIdGenerator: { "unused-anon" },
                streamIdGenerator: { "unused-stream" },
                sessionIdGenerator: { "unused-session" }
            )
            let after = await recovered.snapshot()
            var expectedIdentity = before.identity
            expectedIdentity.contextRevision += 1
            expectedIdentity.updatedAt = self.now
            XCTAssertEqual(after.identity, expectedIdentity)
            XCTAssertEqual(after.streamId, before.streamId)
            XCTAssertEqual(after.nextSequence, 0)
            XCTAssertTrue(after.flagContext.personProperties.isEmpty)
            XCTAssertTrue(after.flagContext.groupProperties.isEmpty)

            guard case let .loaded(rewritten) = try store.load() else {
                return XCTFail("Expected corruption recovery to rewrite a valid aggregate")
            }
            XCTAssertEqual(rewritten.identity, expectedIdentity)
            XCTAssertTrue(rewritten.flagContext.personProperties.isEmpty)
        }
    }

    func testCorruptIdentityUsesBackupIdentityFailClosedAndPreservesPrimaryStream() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileIdentityStateStore(directoryURL: directory)
            let first = try self.makeCore(store: store)
            try await first.identify("user-before-corruption")
            try await first.setFlagPersonProperties(["beta": .bool(true)])
            let before = await first.snapshot()

            var aggregate = try self.jsonObject(at: store.stateFileURL)
            var identity = try XCTUnwrap(aggregate["identity"] as? [String: Any])
            identity["anonymousId"] = ""
            aggregate["identity"] = identity
            var stream = try XCTUnwrap(aggregate["streamMetadata"] as? [String: Any])
            stream["streamId"] = "stream-primary-newer"
            stream["nextSequence"] = 42
            aggregate["streamMetadata"] = stream
            try self.writeJSONObject(aggregate, to: store.stateFileURL)

            let recovered = try EluIdentityCore(
                store: store,
                clock: { self.now },
                anonymousIdGenerator: { "anon-must-not-replace-backup" },
                streamIdGenerator: { "stream-must-not-replace-primary" },
                sessionIdGenerator: { "session-recovered" }
            )
            let after = await recovered.snapshot()
            XCTAssertEqual(after.identity.anonymousId, "anon-initial")
            XCTAssertEqual(after.identity.userId, "user-before-corruption")
            XCTAssertEqual(after.identity.identityRevision, 1)
            XCTAssertEqual(after.identity.contextRevision, 1)
            XCTAssertTrue(after.identity.optedOut)
            XCTAssertTrue(after.flagContext.personProperties.isEmpty)
            XCTAssertTrue(after.flagContext.groupProperties.isEmpty)
            XCTAssertNotEqual(after.streamId, before.streamId)
            XCTAssertEqual(after.streamId, "stream-primary-newer")
            XCTAssertEqual(after.nextSequence, 42)
        }
    }

    func testUnreadablePrimaryRecoversFromSynchronizedBackupWithoutRelaxingOptOut() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileIdentityStateStore(directoryURL: directory)
            let first = try self.makeCore(store: store)
            try await first.identify("user-in-backup")
            try await first.registerSuperProperties(["latest": .bool(true)])
            try await first.setOptedOut(true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.backupFileURL.path))

            try Data("not-json".utf8).write(to: store.stateFileURL)
            let recovered = try EluIdentityCore(
                store: store,
                clock: { self.now },
                anonymousIdGenerator: { "unused-anon" },
                streamIdGenerator: { "unused-stream" },
                sessionIdGenerator: { "unused-session" }
            )
            let snapshot = await recovered.snapshot()
            XCTAssertEqual(snapshot.identity.userId, "user-in-backup")
            XCTAssertEqual(snapshot.identity.superProperties["latest"], .bool(true))
            XCTAssertTrue(snapshot.identity.optedOut)

            guard case .loaded = try store.load() else {
                return XCTFail("Expected backup recovery to restore the primary aggregate")
            }
        }
    }

    func testUnsupportedAggregateAndNestedVersionsLeavePrimaryBytesUntouched() async throws {
        for versionPath in ["aggregate", "identity", "streamMetadata", "flagContext"] {
            try await withTemporaryDirectory { directory in
                let store = try EluFileIdentityStateStore(directoryURL: directory)
                _ = try self.makeCore(store: store)

                var aggregate = try self.jsonObject(at: store.stateFileURL)
                if versionPath == "aggregate" {
                    aggregate["schemaVersion"] = 99
                } else {
                    var nested = try XCTUnwrap(aggregate[versionPath] as? [String: Any])
                    nested["schemaVersion"] = 99
                    aggregate[versionPath] = nested
                }
                let futureBytes = try JSONSerialization.data(
                    withJSONObject: aggregate,
                    options: [.sortedKeys]
                )
                try futureBytes.write(to: store.stateFileURL)

                do {
                    _ = try EluIdentityCore(
                        store: store,
                        clock: { self.now },
                        anonymousIdGenerator: { "must-not-run" },
                        streamIdGenerator: { "must-not-run" },
                        sessionIdGenerator: { "must-not-run" }
                    )
                    XCTFail("Expected unsupported \(versionPath) schema")
                } catch {
                    XCTAssertEqual(error as? EluIdentityStateError, .unsupportedSchemaVersion)
                }
                XCTAssertEqual(try Data(contentsOf: store.stateFileURL), futureBytes)
            }
        }
    }

    func testUnknownClosedRecordExtensionsLeavePrimaryBytesUntouched() async throws {
        let cases: [(path: String, record: EluStoredIdentityRecord)] = [
            ("aggregate", .aggregate),
            ("identity", .identity),
            ("streamMetadata", .streamMetadata),
            ("flagContext", .flagContext),
            ("session", .session),
            ("migration", .migration),
        ]

        for testCase in cases {
            try await withTemporaryDirectory { directory in
                let store = try EluFileIdentityStateStore(directoryURL: directory)
                let core = try self.makeCore(store: store)
                _ = try await core.recordEligibleActivity()

                var aggregate = try self.jsonObject(at: store.stateFileURL)
                switch testCase.path {
                case "aggregate":
                    aggregate["futureField"] = true
                case "identity", "streamMetadata", "flagContext":
                    var nested = try XCTUnwrap(aggregate[testCase.path] as? [String: Any])
                    nested["futureField"] = true
                    aggregate[testCase.path] = nested
                case "session":
                    var identity = try XCTUnwrap(aggregate["identity"] as? [String: Any])
                    var session = try XCTUnwrap(identity["session"] as? [String: Any])
                    session["futureField"] = true
                    identity["session"] = session
                    aggregate["identity"] = identity
                case "migration":
                    var identity = try XCTUnwrap(aggregate["identity"] as? [String: Any])
                    let migration: [String: Any] = [
                        "sourceSchema": "legacy-v0",
                        "completedAt": EluRFC3339.string(from: self.now),
                        "futureField": true,
                    ]
                    identity["migration"] = migration
                    aggregate["identity"] = identity
                default:
                    XCTFail("Unhandled test path")
                }

                let extendedBytes = try JSONSerialization.data(
                    withJSONObject: aggregate,
                    options: [.sortedKeys]
                )
                try extendedBytes.write(to: store.stateFileURL)

                do {
                    _ = try EluIdentityCore(
                        store: store,
                        clock: { self.now },
                        anonymousIdGenerator: { "must-not-run" },
                        streamIdGenerator: { "must-not-run" },
                        sessionIdGenerator: { "must-not-run" }
                    )
                    XCTFail("Expected unsupported \(testCase.path) extension")
                } catch {
                    XCTAssertEqual(
                        error as? EluIdentityStateStoreError,
                        .unsupportedRecordExtension(testCase.record)
                    )
                }
                XCTAssertEqual(try Data(contentsOf: store.stateFileURL), extendedBytes)
            }
        }
    }

    func testBackupReconciliationPreservesUnsupportedBackupBytes() async throws {
        for unsupportedKind in ["version", "extension"] {
            try await withTemporaryDirectory { directory in
                let store = try EluFileIdentityStateStore(directoryURL: directory)
                let core = try self.makeCore(store: store)
                try await core.identify("user-current")
                try await core.setFlagPersonProperties(["plan": .string("growth")])

                var primary = try self.jsonObject(at: store.stateFileURL)
                var identity = try XCTUnwrap(primary["identity"] as? [String: Any])
                identity["anonymousId"] = ""
                primary["identity"] = identity
                let primaryBytes = try JSONSerialization.data(
                    withJSONObject: primary,
                    options: [.sortedKeys]
                )
                try primaryBytes.write(to: store.stateFileURL)

                var backup = try self.jsonObject(at: store.backupFileURL)
                if unsupportedKind == "version" {
                    backup["schemaVersion"] = 99
                } else {
                    backup["futureField"] = true
                }
                let backupBytes = try JSONSerialization.data(
                    withJSONObject: backup,
                    options: [.sortedKeys]
                )
                try backupBytes.write(to: store.backupFileURL)

                do {
                    _ = try EluIdentityCore(
                        store: store,
                        clock: { self.now },
                        anonymousIdGenerator: { "must-not-run" },
                        streamIdGenerator: { "must-not-run" },
                        sessionIdGenerator: { "must-not-run" }
                    )
                    XCTFail("Expected unsupported backup \(unsupportedKind)")
                } catch {
                    if unsupportedKind == "version" {
                        XCTAssertEqual(
                            error as? EluIdentityStateError,
                            .unsupportedSchemaVersion
                        )
                    } else {
                        XCTAssertEqual(
                            error as? EluIdentityStateStoreError,
                            .unsupportedRecordExtension(.aggregate)
                        )
                    }
                }
                XCTAssertEqual(try Data(contentsOf: store.stateFileURL), primaryBytes)
                XCTAssertEqual(try Data(contentsOf: store.backupFileURL), backupBytes)
            }
        }
    }

    func testResetPreservesAnExistingDurableStreamCursorWithoutAllocatingFromIt() async throws {
        let initialState = try EluPersistedState(
            identity: makeIdentity(),
            streamMetadata: EluStreamMetadata(streamId: "stream-from-queue", nextSequence: 42),
            flagContext: EluPersistedFlagContext()
        )
        let store = LockedMemoryIdentityStore(state: initialState)
        let core = try EluIdentityCore(
            store: store,
            clock: { self.now },
            anonymousIdGenerator: { "anon-reset" },
            streamIdGenerator: { "must-not-run" },
            sessionIdGenerator: { "session-initial" }
        )

        let before = await core.snapshot()
        XCTAssertEqual(before.streamId, "stream-from-queue")
        XCTAssertEqual(before.nextSequence, 42)
        try await core.reset()
        let after = await core.snapshot()
        XCTAssertEqual(after.streamId, before.streamId)
        XCTAssertEqual(after.nextSequence, 42)
        XCTAssertEqual(store.persistedState?.streamMetadata.nextSequence, 42)
    }

    func testFailedAggregateWriteDoesNotAdvanceAnyVisibleState() async throws {
        let store = LockedMemoryIdentityStore()
        let core = try makeCore(store: store)
        try await core.setGroup(type: "organization", key: "org-1")
        try await core.setFlagGroupProperties(
            type: "organization",
            properties: ["tier": .string("growth")]
        )
        let before = await core.snapshot()
        let persistedBefore = store.persistedState

        store.shouldFailWrites = true
        do {
            try await core.setGroup(type: "organization", key: "org-2")
            XCTFail("Expected the aggregate write to fail")
        } catch {
            XCTAssertTrue(error is TestStoreError)
        }

        let after = await core.snapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(store.persistedState, persistedBefore)
        XCTAssertEqual(
            after.flagContext.groupProperties["organization"]?["tier"],
            .string("growth")
        )
    }

    func testDirectorySyncFailureAfterPrimaryCommitKeepsOptOutAcrossRestart() async throws {
        try await withTemporaryDirectory { directory in
            let synchronizer = ScriptedDirectorySynchronizer()
            let store = try EluFileIdentityStateStore(
                directoryURL: directory,
                directorySynchronizer: synchronizer
            )
            let core = try self.makeCore(store: store)
            XCTAssertEqual(synchronizer.callCount, 1)

            // A normal save durably installs the backup first and the primary
            // second. Fail only the directory sync after primary replacement.
            synchronizer.fail(onCall: synchronizer.callCount + 2)
            do {
                try await core.setOptedOut(true)
                XCTFail("Expected primary durability to remain unconfirmed")
            } catch {
                XCTAssertEqual(
                    error as? EluIdentityStateStoreError,
                    .primaryCommitDurabilityUnconfirmed
                )
            }

            let afterFailure = await core.snapshot()
            XCTAssertTrue(afterFailure.identity.optedOut)
            guard case let .loaded(installedPrimary) = try store.load() else {
                return XCTFail("Expected the installed primary to remain authoritative")
            }
            XCTAssertTrue(installedPrimary.identity.optedOut)

            let restarted = try self.makeCore(store: store)
            let afterRestart = await restarted.snapshot()
            XCTAssertTrue(afterRestart.identity.optedOut)
            try await restarted.registerSuperProperties(["afterFailure": .bool(true)])
            let afterSubsequentMutation = await restarted.snapshot()
            XCTAssertTrue(afterSubsequentMutation.identity.optedOut)
            XCTAssertEqual(
                afterSubsequentMutation.identity.superProperties["afterFailure"],
                .bool(true)
            )
            XCTAssertEqual(synchronizer.callCount, 5)
        }
    }

    func testBackupSyncFailureDoesNotPublishUninstalledPrimaryState() async throws {
        try await withTemporaryDirectory { directory in
            let synchronizer = ScriptedDirectorySynchronizer()
            let store = try EluFileIdentityStateStore(
                directoryURL: directory,
                directorySynchronizer: synchronizer
            )
            let core = try self.makeCore(store: store)
            synchronizer.fail(onCall: synchronizer.callCount + 1)

            do {
                try await core.identify("user-must-not-publish")
                XCTFail("Expected backup durability to remain unconfirmed")
            } catch {
                XCTAssertEqual(
                    error as? EluIdentityStateStoreError,
                    .backupCommitDurabilityUnconfirmed
                )
            }

            let afterFailure = await core.snapshot()
            XCTAssertNil(afterFailure.identity.userId)
            guard case let .loaded(primary) = try store.load() else {
                return XCTFail("Expected the existing primary to remain authoritative")
            }
            XCTAssertNil(primary.identity.userId)
            XCTAssertEqual(synchronizer.callCount, 2)
        }
    }

    func testAggregateBudgetRejectsBeforeInvokingEncoder() async throws {
        try await withTemporaryDirectory { directory in
            let encoder = RecordingStateEncoder()
            let store = try EluFileIdentityStateStore(
                directoryURL: directory,
                stateEncoder: encoder
            )
            let individuallyValidValue = EluJSONValue.string(
                String(repeating: "x", count: 65_536)
            )
            XCTAssertNoThrow(try individuallyValidValue.validate())
            let properties = Dictionary(
                uniqueKeysWithValues: (0 ..< 17).map { ("property-\($0)", individuallyValidValue) }
            )
            let state = try EluPersistedState(
                identity: self.makeIdentity(),
                streamMetadata: EluStreamMetadata(streamId: "stream-budget"),
                flagContext: EluPersistedFlagContext(personProperties: properties)
            )

            XCTAssertThrowsError(try store.save(state, mode: .recovery)) { error in
                XCTAssertEqual(
                    error as? EluIdentityStateStoreError,
                    .recordTooLarge(.aggregate)
                )
            }
            XCTAssertEqual(encoder.callCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.stateFileURL.path))

            let child = EluJSONValue.array([.null, .null, .null])
            let individuallyNodeValidValue = EluJSONValue.array(
                Array(repeating: child, count: 1_023)
            )
            XCTAssertNoThrow(try individuallyNodeValidValue.validate())
            let nodeDenseProperties = Dictionary(
                uniqueKeysWithValues: (0 ..< 17).map {
                    ("node-property-\($0)", individuallyNodeValidValue)
                }
            )
            let nodeDenseState = try EluPersistedState(
                identity: self.makeIdentity(),
                streamMetadata: EluStreamMetadata(streamId: "stream-node-budget"),
                flagContext: EluPersistedFlagContext(personProperties: nodeDenseProperties)
            )
            XCTAssertThrowsError(try store.save(nodeDenseState, mode: .recovery)) { error in
                XCTAssertEqual(
                    error as? EluIdentityStateStoreError,
                    .recordTooLarge(.aggregate)
                )
            }
            XCTAssertEqual(encoder.callCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.stateFileURL.path))
        }
    }

    func testStringLimitsUseUnicodeScalarCounts() throws {
        let twoScalarGrapheme = "e\u{301}"
        let exactly256Scalars = String(repeating: twoScalarGrapheme, count: 128)
        let over256Scalars = String(repeating: twoScalarGrapheme, count: 129)
        XCTAssertEqual(exactly256Scalars.count, 128)
        XCTAssertEqual(exactly256Scalars.unicodeScalars.count, 256)
        XCTAssertTrue(EluIdentityState.valid(exactly256Scalars, maximumLength: 256))
        XCTAssertFalse(EluIdentityState.valid(over256Scalars, maximumLength: 256))

        XCTAssertNoThrow(try EluJSONValue.object([exactly256Scalars: .bool(true)]).validate())
        XCTAssertThrowsError(try EluJSONValue.object([over256Scalars: .bool(true)]).validate()) {
            XCTAssertEqual($0 as? EluIdentityStateError, .invalidPropertyKey)
        }
    }

    func testMigrationNullIsRejectedWhileAbsentMigrationIsAccepted() throws {
        let identity = try makeIdentity()
        let data = try EluStateCoding.encoder().encode(identity)
        XCTAssertNoThrow(try EluStateCoding.decoder().decode(EluIdentityState.self, from: data))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["migration"] = NSNull()
        let nullMigration = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(
            try EluStateCoding.decoder().decode(EluIdentityState.self, from: nullMigration)
        )
    }

    func testPersistenceTimestampsAcceptOnlyCanonicalUTCZ() throws {
        XCTAssertNotNil(EluRFC3339.date(from: "2026-08-04T12:34:56Z"))
        XCTAssertNotNil(EluRFC3339.date(from: "2026-08-04T12:34:56.123456Z"))
        XCTAssertNil(EluRFC3339.date(from: "2026-08-04T12:34:56+00:00"))
        XCTAssertNil(EluRFC3339.date(from: "2026-08-04T05:34:56-07:00"))

        let identity = try makeIdentity()
        let data = try EluStateCoding.encoder().encode(identity)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        for accepted in ["2026-08-04T12:34:56Z", "2026-08-04T12:34:56.123Z"] {
            object["updatedAt"] = accepted
            let candidate = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            XCTAssertNoThrow(
                try EluStateCoding.decoder().decode(EluIdentityState.self, from: candidate)
            )
        }

        for rejected in ["2026-08-04T12:34:56+00:00", "2026-08-04T05:34:56-07:00"] {
            object["updatedAt"] = rejected
            let candidate = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            XCTAssertThrowsError(
                try EluStateCoding.decoder().decode(EluIdentityState.self, from: candidate)
            )
        }
    }

    func testEligibleActivityUsesPriorTimeoutWhenRequestedTimeoutIncreases() async throws {
        let clock = LockedClock(now)
        let sessionIds = LockedIdentifierSequence(["session-1", "session-2"])
        let core = try EluIdentityCore(
            store: LockedMemoryIdentityStore(),
            clock: { clock.now() },
            anonymousIdGenerator: { "anon-initial" },
            streamIdGenerator: { "stream-initial" },
            sessionIdGenerator: { sessionIds.next() }
        )

        let started = try await core.recordEligibleActivity(timeoutSeconds: 0)
        XCTAssertEqual(started.id, "session-1")
        XCTAssertEqual(started.timeoutSeconds, 60)

        clock.set(now.addingTimeInterval(59))
        let resumed = try await core.recordEligibleActivity(timeoutSeconds: 60)
        XCTAssertEqual(resumed.id, started.id)
        XCTAssertEqual(resumed.startedAt, started.startedAt)
        XCTAssertEqual(resumed.lastActivityAt, clock.now())

        clock.set(now.addingTimeInterval(119))
        let rotated = try await core.recordEligibleActivity(timeoutSeconds: 99_999)
        XCTAssertEqual(rotated.id, "session-2")
        XCTAssertEqual(rotated.startedAt, clock.now())
        XCTAssertEqual(rotated.lastActivityAt, clock.now())
        XCTAssertEqual(rotated.timeoutSeconds, 36_000)
    }

    func testEligibleActivityUsesNewTimeoutWhenRequestedTimeoutDecreases() async throws {
        let clock = LockedClock(now)
        let sessionIds = LockedIdentifierSequence(["session-1", "session-2"])
        let core = try EluIdentityCore(
            store: LockedMemoryIdentityStore(),
            clock: { clock.now() },
            anonymousIdGenerator: { "anon-initial" },
            streamIdGenerator: { "stream-initial" },
            sessionIdGenerator: { sessionIds.next() }
        )

        let started = try await core.recordEligibleActivity(timeoutSeconds: 3_600)
        clock.set(now.addingTimeInterval(60))
        let rotated = try await core.recordEligibleActivity(timeoutSeconds: 60)
        XCTAssertNotEqual(rotated.id, started.id)
        XCTAssertEqual(rotated.id, "session-2")
        XCTAssertEqual(rotated.timeoutSeconds, 60)
        XCTAssertEqual(rotated.startedAt, clock.now())
    }

    func testEligibleActivityRotatesAtExactMaximumDurationBoundary() async throws {
        let clock = LockedClock(now)
        let sessionIds = LockedIdentifierSequence(["session-1", "session-2"])
        let core = try EluIdentityCore(
            store: LockedMemoryIdentityStore(),
            clock: { clock.now() },
            anonymousIdGenerator: { "anon-initial" },
            streamIdGenerator: { "stream-initial" },
            sessionIdGenerator: { sessionIds.next() }
        )

        let started = try await core.recordEligibleActivity(timeoutSeconds: 36_000)
        for offset in [35_999, 71_998, 86_399] {
            clock.set(now.addingTimeInterval(TimeInterval(offset)))
            let resumed = try await core.recordEligibleActivity(timeoutSeconds: 36_000)
            XCTAssertEqual(resumed.id, started.id)
        }

        clock.set(now.addingTimeInterval(86_400))
        let rotated = try await core.recordEligibleActivity(timeoutSeconds: 36_000)
        XCTAssertEqual(rotated.id, "session-2")
        XCTAssertEqual(rotated.startedAt, clock.now())
    }

    func testLifecycleTransitionsAreNotEligibleActivity() async throws {
        let clock = LockedClock(now)
        let sessionIds = LockedIdentifierSequence(["session-1", "session-2"])
        let core = try EluIdentityCore(
            store: LockedMemoryIdentityStore(),
            clock: { clock.now() },
            anonymousIdGenerator: { "anon-initial" },
            streamIdGenerator: { "stream-initial" },
            sessionIdGenerator: { sessionIds.next() }
        )
        let started = try await core.recordEligibleActivity(timeoutSeconds: 60)

        clock.set(now.addingTimeInterval(30))
        let backgroundedValue = try await core.setSessionLifecycle(.background)
        let backgrounded = try XCTUnwrap(backgroundedValue)
        XCTAssertEqual(backgrounded.lastActivityAt, started.lastActivityAt)
        XCTAssertEqual(backgrounded.backgroundedAt, clock.now())

        clock.set(now.addingTimeInterval(59))
        let foregroundedValue = try await core.setSessionLifecycle(.active)
        let foregrounded = try XCTUnwrap(foregroundedValue)
        XCTAssertEqual(foregrounded.lastActivityAt, started.lastActivityAt)
        XCTAssertNil(foregrounded.backgroundedAt)

        clock.set(now.addingTimeInterval(60))
        let rotated = try await core.recordEligibleActivity(timeoutSeconds: 60)
        XCTAssertEqual(rotated.id, "session-2")
    }

    func testEligibleActivityRotatesInsteadOfMovingActivityBackwardOnClockRollback() async throws {
        let clock = LockedClock(now)
        let sessionIds = LockedIdentifierSequence(["session-1", "session-2"])
        let core = try EluIdentityCore(
            store: LockedMemoryIdentityStore(),
            clock: { clock.now() },
            anonymousIdGenerator: { "anon-initial" },
            streamIdGenerator: { "stream-initial" },
            sessionIdGenerator: { sessionIds.next() }
        )
        let started = try await core.recordEligibleActivity(timeoutSeconds: 1_800)

        clock.set(now.addingTimeInterval(-120))
        let rotated = try await core.recordEligibleActivity(timeoutSeconds: 1_800)
        XCTAssertNotEqual(rotated.id, started.id)
        XCTAssertEqual(rotated.id, "session-2")
        XCTAssertEqual(rotated.startedAt, clock.now())
        XCTAssertEqual(rotated.lastActivityAt, rotated.startedAt)
    }

    func testConcurrentContextMutationsRemainActorSerialized() async throws {
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
        XCTAssertEqual(store.saveCount, 101)
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

    private func makeIdentity() throws -> EluIdentityState {
        try EluIdentityState(
            revision: 0,
            contextRevision: 0,
            anonymousId: "anon-initial",
            userId: nil,
            groups: [:],
            superProperties: [:],
            session: nil,
            optedOut: false,
            updatedAt: now
        )
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
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

private enum TestStoreError: Error {
    case forcedFailure
}

private enum TestDirectorySyncError: Error, Equatable {
    case forcedFailure
}

private final class ScriptedDirectorySynchronizer: EluDirectorySynchronizing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var failingCalls: Set<Int> = []

    var callCount: Int {
        withLock { calls }
    }

    func fail(onCall call: Int) {
        _ = withLock { failingCalls.insert(call) }
    }

    func synchronize(directoryURL _: URL) throws {
        try withLock {
            calls += 1
            if failingCalls.remove(calls) != nil {
                throw TestDirectorySyncError.forcedFailure
            }
        }
    }

    private func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private final class RecordingStateEncoder: EluPersistedStateEncoding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func encode(_ state: EluPersistedState) throws -> Data {
        lock.lock()
        calls += 1
        lock.unlock()
        return try EluStateCoding.encoder().encode(state)
    }
}

private final class LockedMemoryIdentityStore: EluIdentityStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: EluPersistedState?
    private var _saveCount = 0
    private var _shouldFailWrites = false

    init(state: EluPersistedState? = nil) {
        self.state = state
    }

    var persistedState: EluPersistedState? {
        withLock { state }
    }

    var saveCount: Int {
        withLock { _saveCount }
    }

    var shouldFailWrites: Bool {
        get { withLock { _shouldFailWrites } }
        set { withLock { _shouldFailWrites = newValue } }
    }

    func load() -> EluPersistedStateLoadResult {
        withLock {
            if let state {
                return .loaded(state)
            }
            return .missing
        }
    }

    func save(_ state: EluPersistedState, mode: EluStateWriteMode) throws {
        try withLock {
            if _shouldFailWrites {
                throw TestStoreError.forcedFailure
            }
            self.state = state
            _saveCount += 1
        }
    }

    private func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
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
