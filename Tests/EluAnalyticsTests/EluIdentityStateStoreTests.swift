import Foundation
import XCTest
@testable import EluAnalytics

final class EluIdentityStateStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_775_260_800)

    func testAggregateSerializationUsesThreeClosedRecordsAndExactIdentityKeys() throws {
        try withTemporaryDirectory { directory in
            let store = try EluFileIdentityStateStore(directoryURL: directory)
            try store.save(try self.makeState(session: self.makeSession()), mode: .recovery)

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

    func testFlagContextAndContextRevisionPersistTogetherAcrossReopen() throws {
        try withTemporaryDirectory { directory in
            var identity = try self.makeIdentity()
            identity.contextRevision = 2
            let state = try EluPersistedState(
                identity: identity,
                streamMetadata: EluStreamMetadata(streamId: "stream-initial"),
                flagContext: EluPersistedFlagContext(
                    personProperties: ["plan": .string("growth")],
                    groupProperties: ["organization": ["tier": .integer(2)]]
                )
            )
            try EluFileIdentityStateStore(directoryURL: directory).save(state, mode: .recovery)

            let reopened = try EluFileIdentityStateStore(directoryURL: directory)
            guard case let .loaded(persisted) = try reopened.load() else {
                return XCTFail("Expected a valid aggregate")
            }
            XCTAssertEqual(persisted, state)
            XCTAssertEqual(persisted.identity.contextRevision, 2)
            XCTAssertEqual(persisted.flagContext.personProperties["plan"], .string("growth"))
            XCTAssertEqual(
                persisted.flagContext.groupProperties["organization"]?["tier"],
                .integer(2)
            )
        }
    }

    func testParseableCorruptFlagContextPreservesValidIdentityAndStream() throws {
        try withTemporaryDirectory { directory in
            let store = try EluFileIdentityStateStore(directoryURL: directory)
            var identity = try self.makeIdentity()
            identity.userId = "user-current"
            let state = try EluPersistedState(
                identity: identity,
                streamMetadata: EluStreamMetadata(streamId: "stream-initial"),
                flagContext: EluPersistedFlagContext(personProperties: ["plan": .string("growth")])
            )
            try store.save(state, mode: .recovery)

            var aggregate = try self.jsonObject(at: store.stateFileURL)
            var context = try XCTUnwrap(aggregate["flagContext"] as? [String: Any])
            context["personProperties"] = ["": true]
            aggregate["flagContext"] = context
            try self.writeJSONObject(aggregate, to: store.stateFileURL)

            guard case let .recoverable(recovered) = try store.load() else {
                return XCTFail("Expected a component-level recovery")
            }
            XCTAssertEqual(recovered.identity, state.identity)
            XCTAssertEqual(recovered.streamMetadata, state.streamMetadata)
            XCTAssertNil(recovered.flagContext)
            XCTAssertFalse(recovered.forceOptOut)
        }
    }

    func testCorruptPrimaryNeverRestoresStaleBackupIdentity() throws {
        try withTemporaryDirectory { directory in
            let store = try EluFileIdentityStateStore(directoryURL: directory)
            var previous = try self.makeIdentity(anonymousId: "anon-before-reset")
            previous.userId = "user-before-reset"
            previous.groups = ["organization": "org-before-reset"]
            previous.superProperties = ["plan": .string("legacy")]
            try store.save(try EluPersistedState(
                identity: previous,
                streamMetadata: EluStreamMetadata(streamId: "stream-stable"),
                flagContext: EluPersistedFlagContext(personProperties: ["role": .string("admin")])
            ), mode: .recovery)
            let stalePreResetBytes = try Data(contentsOf: store.stateFileURL)

            let current = try EluPersistedState(
                identity: self.makeIdentity(anonymousId: "anon-after-reset"),
                streamMetadata: EluStreamMetadata(streamId: "stream-stable", nextSequence: 3),
                flagContext: EluPersistedFlagContext()
            )
            try store.save(current, mode: .normal)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupFileURL.path))

            // Simulate cleanup failure leaving a pre-reset backup. The current
            // primary exists and must remain the only recovery authority.
            try stalePreResetBytes.write(to: store.backupFileURL)
            var aggregate = try self.jsonObject(at: store.stateFileURL)
            var identity = try XCTUnwrap(aggregate["identity"] as? [String: Any])
            identity["anonymousId"] = ""
            aggregate["identity"] = identity
            try self.writeJSONObject(aggregate, to: store.stateFileURL)

            guard case let .recoverable(recovered) = try store.load() else {
                return XCTFail("Expected the corrupt primary to recover by component")
            }
            XCTAssertNil(recovered.identity)
            XCTAssertEqual(recovered.streamMetadata, current.streamMetadata)
            XCTAssertEqual(recovered.flagContext, current.flagContext)

            // The next successful primary commit removes the stale backup.
            let fresh = try EluPersistedState(
                identity: self.makeIdentity(anonymousId: "anon-after-corruption", optedOut: true),
                streamMetadata: XCTUnwrap(recovered.streamMetadata),
                flagContext: EluPersistedFlagContext()
            )
            try store.save(fresh, mode: .recovery)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupFileURL.path))
            guard case let .loaded(reloaded) = try store.load() else {
                return XCTFail("Expected the recovered primary")
            }
            XCTAssertEqual(reloaded, fresh)
            XCTAssertNil(reloaded.identity.userId)
            XCTAssertTrue(reloaded.identity.groups.isEmpty)
        }
    }

    func testMissingPrimaryRecoversSynchronizedBackupFailClosed() throws {
        try withTemporaryDirectory { directory in
            let store = try EluFileIdentityStateStore(directoryURL: directory)
            var identity = try self.makeIdentity()
            identity.userId = "user-in-backup"
            identity.superProperties = ["latest": .bool(true)]
            let state = try EluPersistedState(
                identity: identity,
                streamMetadata: EluStreamMetadata(streamId: "stream-initial"),
                flagContext: EluPersistedFlagContext()
            )
            try store.save(state, mode: .recovery)
            let backupBytes = try Data(contentsOf: store.stateFileURL)
            try backupBytes.write(to: store.backupFileURL)
            try FileManager.default.removeItem(at: store.stateFileURL)

            guard case let .recoverable(recovered) = try store.load() else {
                return XCTFail("Expected backup recovery")
            }
            XCTAssertEqual(recovered.identity?.userId, "user-in-backup")
            XCTAssertEqual(recovered.identity?.superProperties["latest"], .bool(true))
            XCTAssertEqual(recovered.streamMetadata, state.streamMetadata)
            XCTAssertTrue(recovered.forceOptOut)
        }
    }

    func testUnsupportedAggregateAndNestedVersionsLeavePrimaryBytesUntouched() throws {
        for versionPath in ["aggregate", "identity", "streamMetadata", "flagContext"] {
            try withTemporaryDirectory { directory in
                let store = try EluFileIdentityStateStore(directoryURL: directory)
                let state = try self.makeState()
                try store.save(state, mode: .recovery)

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

                XCTAssertThrowsError(try store.load(), versionPath) {
                    XCTAssertEqual($0 as? EluIdentityStateError, .unsupportedSchemaVersion)
                }
                XCTAssertThrowsError(try store.save(state, mode: .normal), versionPath) {
                    XCTAssertEqual($0 as? EluIdentityStateError, .unsupportedSchemaVersion)
                }
                XCTAssertEqual(try Data(contentsOf: store.stateFileURL), futureBytes)
            }
        }
    }

    func testUnknownClosedRecordExtensionsLeavePrimaryBytesUntouched() throws {
        let cases: [(path: String, record: EluStoredIdentityRecord)] = [
            ("aggregate", .aggregate),
            ("identity", .identity),
            ("streamMetadata", .streamMetadata),
            ("flagContext", .flagContext),
            ("session", .session),
            ("migration", .migration),
        ]

        for testCase in cases {
            try withTemporaryDirectory { directory in
                let store = try EluFileIdentityStateStore(directoryURL: directory)
                try store.save(try self.makeState(session: self.makeSession()), mode: .recovery)

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
                        "sourceSchema": "fixture-layout",
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

                XCTAssertThrowsError(try store.load(), testCase.path) {
                    XCTAssertEqual(
                        $0 as? EluIdentityStateStoreError,
                        .unsupportedRecordExtension(testCase.record)
                    )
                }
                XCTAssertEqual(try Data(contentsOf: store.stateFileURL), extendedBytes)
            }
        }
    }

    func testUnsupportedBackupBlocksLoadAndWritesWithoutChangingEitherRecord() throws {
        for unsupportedKind in ["version", "extension"] {
            try withTemporaryDirectory { directory in
                let store = try EluFileIdentityStateStore(directoryURL: directory)
                var identity = try self.makeIdentity()
                identity.userId = "user-current"
                let persisted = try EluPersistedState(
                    identity: identity,
                    streamMetadata: EluStreamMetadata(streamId: "stream-initial"),
                    flagContext: EluPersistedFlagContext(personProperties: ["plan": .string("growth")])
                )
                try store.save(persisted, mode: .recovery)
                let primaryBytes = try Data(contentsOf: store.stateFileURL)

                var backup = try self.jsonObject(at: store.stateFileURL)
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

                XCTAssertThrowsError(try store.load()) {
                    self.assertUnsupportedBackupError($0, kind: unsupportedKind)
                }
                for mode in [EluStateWriteMode.normal, .recovery] {
                    XCTAssertThrowsError(try store.save(persisted, mode: mode)) {
                        self.assertUnsupportedBackupError($0, kind: unsupportedKind)
                    }
                }
                XCTAssertEqual(try Data(contentsOf: store.stateFileURL), primaryBytes)
                XCTAssertEqual(try Data(contentsOf: store.backupFileURL), backupBytes)
            }
        }
    }

    func testOversizedBackupBlocksLoadAndWritesWithoutChangingEitherRecord() throws {
        try withTemporaryDirectory { directory in
            let store = try EluFileIdentityStateStore(directoryURL: directory)
            let persisted = try self.makeState()
            try store.save(persisted, mode: .recovery)
            let primaryBytes = try Data(contentsOf: store.stateFileURL)
            let backupBytes = Data(
                repeating: 0x41,
                count: EluFileIdentityStateStore.maximumAggregateBytes + 1
            )
            try backupBytes.write(to: store.backupFileURL)

            XCTAssertThrowsError(try store.load()) {
                XCTAssertEqual($0 as? EluIdentityStateStoreError, .recordTooLarge(.aggregate))
            }
            for mode in [EluStateWriteMode.normal, .recovery] {
                XCTAssertThrowsError(try store.save(persisted, mode: mode)) {
                    XCTAssertEqual($0 as? EluIdentityStateStoreError, .recordTooLarge(.aggregate))
                }
            }
            XCTAssertEqual(try Data(contentsOf: store.stateFileURL), primaryBytes)
            XCTAssertEqual(try Data(contentsOf: store.backupFileURL), backupBytes)
        }
    }

    func testDirectorySyncFailureAfterPrimaryCommitKeepsOptOutAcrossReopen() throws {
        try withTemporaryDirectory { directory in
            let synchronizer = ScriptedDirectorySynchronizer()
            let store = try EluFileIdentityStateStore(
                directoryURL: directory,
                directorySynchronizer: synchronizer
            )
            let initial = try self.makeState()
            try store.save(initial, mode: .recovery)
            XCTAssertEqual(synchronizer.callCount, 1)

            // A normal save durably installs the backup first and the primary
            // second. Fail only the directory sync after primary replacement.
            var optedOut = initial
            optedOut.identity.optedOut = true
            synchronizer.fail(onCall: synchronizer.callCount + 2)
            XCTAssertThrowsError(try store.save(optedOut, mode: .normal)) {
                XCTAssertEqual(
                    $0 as? EluIdentityStateStoreError,
                    .primaryCommitDurabilityUnconfirmed
                )
            }

            let reopened = try EluFileIdentityStateStore(
                directoryURL: directory,
                directorySynchronizer: synchronizer
            )
            guard case let .loaded(installedPrimary) = try reopened.load() else {
                return XCTFail("Expected the installed primary to remain authoritative")
            }
            XCTAssertTrue(installedPrimary.identity.optedOut)

            var next = installedPrimary
            next.identity.superProperties = ["afterFailure": .bool(true)]
            try reopened.save(next, mode: .normal)
            guard case let .loaded(afterSubsequentSave) = try reopened.load() else {
                return XCTFail("Expected the subsequent save to load")
            }
            XCTAssertTrue(afterSubsequentSave.identity.optedOut)
            XCTAssertEqual(afterSubsequentSave.identity.superProperties["afterFailure"], .bool(true))
            XCTAssertEqual(synchronizer.callCount, 6)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupFileURL.path))
        }
    }

    func testBackupSyncFailureDoesNotPublishUninstalledPrimaryState() throws {
        try withTemporaryDirectory { directory in
            let synchronizer = ScriptedDirectorySynchronizer()
            let store = try EluFileIdentityStateStore(
                directoryURL: directory,
                directorySynchronizer: synchronizer
            )
            let initial = try self.makeState()
            try store.save(initial, mode: .recovery)
            synchronizer.fail(onCall: synchronizer.callCount + 1)

            var identified = initial
            identified.identity.userId = "user-must-not-publish"
            XCTAssertThrowsError(try store.save(identified, mode: .normal)) {
                XCTAssertEqual(
                    $0 as? EluIdentityStateStoreError,
                    .backupCommitDurabilityUnconfirmed
                )
            }

            guard case let .loaded(primary) = try store.load() else {
                return XCTFail("Expected the existing primary to remain authoritative")
            }
            XCTAssertNil(primary.identity.userId)
            XCTAssertEqual(synchronizer.callCount, 2)
        }
    }

    func testAggregateBudgetRejectsBeforeInvokingEncoder() throws {
        try withTemporaryDirectory { directory in
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

    private func assertUnsupportedBackupError(_ error: Error, kind: String) {
        if kind == "version" {
            XCTAssertEqual(error as? EluIdentityStateError, .unsupportedSchemaVersion)
        } else {
            XCTAssertEqual(
                error as? EluIdentityStateStoreError,
                .unsupportedRecordExtension(.aggregate)
            )
        }
    }

    private func makeIdentity(
        anonymousId: String = "anon-initial",
        session: EluSessionState? = nil,
        optedOut: Bool = false
    ) throws -> EluIdentityState {
        try EluIdentityState(
            revision: 0,
            contextRevision: 0,
            anonymousId: anonymousId,
            userId: nil,
            groups: [:],
            superProperties: [:],
            session: session,
            optedOut: optedOut,
            updatedAt: now
        )
    }

    private func makeSession() throws -> EluSessionState {
        try EluSessionState(id: "session-initial", startedAt: now, lastActivityAt: now, timeoutSeconds: 1_800)
    }

    private func makeState(session: EluSessionState? = nil) throws -> EluPersistedState {
        try EluPersistedState(
            identity: makeIdentity(session: session),
            streamMetadata: EluStreamMetadata(streamId: "stream-initial"),
            flagContext: EluPersistedFlagContext()
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

    private func withTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }
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
