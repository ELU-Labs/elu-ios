import Darwin
import Foundation
import SQLite3
import XCTest
@testable import EluAnalytics

final class EluSQLiteRuntimeQueueTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_147_200.000_987)

    func testQueueCountConfigurationCannotExceedCrossRuntimeBound() throws {
        XCTAssertNoThrow(
            try EluRuntimeQueueLimits(
                maximumCount: EluRuntimeQueueLimits.defaultMaximumCount
            )
        )
        XCTAssertThrowsError(
            try EluRuntimeQueueLimits(
                maximumCount: EluRuntimeQueueLimits.defaultMaximumCount + 1
            )
        ) { error in
            XCTAssertEqual(error as? EluRuntimeQueueError, .invalidState)
        }
    }

    func testSubmillisecondDatesAreCanonicalAcrossCommitsAndRestart() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(directory: directory)
            let initial = try await queue.snapshot()
            let canonicalNow = try XCTUnwrap(
                EluRFC3339.date(from: EluRFC3339.string(from: now))
            )
            XCTAssertEqual(initial.identity.updatedAt, canonicalNow)

            let withSession = try await queue.recordEligibleActivity(
                expectedGeneration: initial.generation
            )
            let records = try await queue.applyMutation(
                .setPersonProperties(
                    set: ["plan": .string("growth")],
                    setOnce: [:],
                    unset: []
                ),
                versions: testVersions(),
                expectedGeneration: withSession.generation
            )
            XCTAssertEqual(records.map(\.sequence), [0])
            let committed = try await queue.snapshot()
            XCTAssertEqual(committed.identity.updatedAt, canonicalNow)
            XCTAssertEqual(committed.identity.session?.startedAt, canonicalNow)
            await queue.close()

            let reopened = try await makeQueue(directory: directory)
            let reopenedSnapshot = try await reopened.snapshot()
            XCTAssertEqual(reopenedSnapshot, committed)
            let next = try await reopened.applyMutation(
                .setPersonProperties(
                    set: ["role": .string("owner")],
                    setOnce: [:],
                    unset: []
                ),
                versions: testVersions(),
                expectedGeneration: committed.generation
            )
            XCTAssertEqual(next.map(\.sequence), [1])
            XCTAssertNotEqual(next[0].recordId, records[0].recordId)
            await reopened.close()
        }
    }

    func testConcurrentEventsProduceOneContiguousStreamWithDerivedIds() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(
                directory: directory,
                limits: EluRuntimeQueueLimits(maximumCount: 1_000, maximumBytes: 20_000_000)
            )
            let initial = try await queue.snapshot()
            _ = try await queue.recordEligibleActivity(expectedGeneration: initial.generation)
            let versions = try testVersions()
            let fixedNow = now

            let records = try await withThrowingTaskGroup(
                of: EluQueuedRecord.self,
                returning: [EluQueuedRecord].self
            ) { group in
                for index in 0 ..< 100 {
                    group.addTask {
                        try await queue.appendEvent(
                            EluEventDraft(
                                kind: .capture,
                                name: "event_\(index)",
                                occurredAt: fixedNow,
                                expectedSessionId: "session_test",
                                properties: ["index": .integer(Int64(index))],
                                versions: versions
                            ),
                            sessionUpdate: .preserve
                        )
                    }
                }
                var result: [EluQueuedRecord] = []
                for try await record in group {
                    result.append(record)
                }
                return result
            }

            XCTAssertEqual(records.count, 100)
            XCTAssertEqual(Set(records.map(\.recordId)).count, 100)
            XCTAssertEqual(records.map(\.sequence).sorted(), Array(0 ..< 100).map(Int64.init))
            let peeked = try await queue.peek(maximumCount: 100, maximumBytes: 20_000_000)
            XCTAssertEqual(peeked.map(\.sequence), Array(0 ..< 100).map(Int64.init))
            await queue.close()
        }
    }

    func testEventSessionReplacementAndRowCommitAtomically() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(directory: directory)
            let replacement = try testSession(
                id: "session_atomic",
                startedAt: now,
                lastActivityAt: now
            )
            let record = try await queue.appendEvent(
                eventDraft(
                    index: 0,
                    versions: testVersions(),
                    expectedSessionId: replacement.id
                ),
                sessionUpdate: .replace(
                    expectedCurrentSessionId: nil,
                    session: replacement
                )
            )

            let snapshot = try await queue.snapshot()
            XCTAssertEqual(snapshot.identity.session, replacement)
            XCTAssertEqual(snapshot.identity.updatedAt, replacement.lastActivityAt)
            XCTAssertEqual(snapshot.queuedCount, 1)
            XCTAssertEqual(snapshot.nextSequence, 1)
            guard case let .event(event) = record else {
                return XCTFail("Expected an event record")
            }
            XCTAssertEqual(event.sessionId, replacement.id)
            XCTAssertEqual(event.sequence, 0)
            let persisted = try await queue.peek(maximumCount: 1, maximumBytes: 1_000_000)
            XCTAssertEqual(persisted, [record])
            await queue.close()

            let reopened = try await makeQueue(directory: directory)
            let reopenedSnapshot = try await reopened.snapshot()
            let reopenedRecords = try await reopened.peek(
                maximumCount: 1,
                maximumBytes: 1_000_000
            )
            XCTAssertEqual(reopenedSnapshot, snapshot)
            XCTAssertEqual(reopenedRecords, [record])
            await reopened.close()
        }
    }

    func testEventSessionReplacementRollsBackWithInsertedRow() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(
                directory: directory,
                faultInjector: TestFaultInjector(point: .afterRecordInsert(0))
            )
            let initial = try await queue.snapshot()
            let replacement = try testSession(
                id: "session_rollback",
                startedAt: now,
                lastActivityAt: now
            )
            do {
                _ = try await queue.appendEvent(
                    eventDraft(
                        index: 0,
                        versions: testVersions(),
                        expectedSessionId: replacement.id
                    ),
                    sessionUpdate: .replace(
                        expectedCurrentSessionId: nil,
                        session: replacement
                    )
                )
                XCTFail("Expected injected rollback")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .faultInjected(.afterRecordInsert(0)))
            }

            let rolledBack = try await queue.snapshot()
            let records = try await queue.peek(maximumCount: 1, maximumBytes: 1_000_000)
            XCTAssertEqual(rolledBack, initial)
            XCTAssertTrue(records.isEmpty)
            await queue.close()
        }
    }

    func testQueueFullRejectsEventAndSessionReplacementTogether() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(
                directory: directory,
                limits: EluRuntimeQueueLimits(maximumCount: 1, maximumBytes: 1_000_000)
            )
            let firstSession = try testSession(
                id: "session_first",
                startedAt: now,
                lastActivityAt: now
            )
            let first = try await queue.appendEvent(
                eventDraft(
                    index: 0,
                    versions: testVersions(),
                    expectedSessionId: firstSession.id
                ),
                sessionUpdate: .replace(
                    expectedCurrentSessionId: nil,
                    session: firstSession
                )
            )
            let beforeRejected = try await queue.snapshot()
            let later = now.addingTimeInterval(1)
            let replacement = try testSession(
                id: "session_replacement",
                startedAt: later,
                lastActivityAt: later
            )
            do {
                _ = try await queue.appendEvent(
                    eventDraft(
                        index: 1,
                        versions: testVersions(),
                        occurredAt: later,
                        expectedSessionId: replacement.id
                    ),
                    sessionUpdate: .replace(
                        expectedCurrentSessionId: firstSession.id,
                        session: replacement
                    )
                )
                XCTFail("Expected count-limit rejection")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .queueCountLimitExceeded)
            }

            let rejected = try await queue.snapshot()
            let records = try await queue.peek(maximumCount: 1, maximumBytes: 1_000_000)
            XCTAssertEqual(rejected, beforeRejected)
            XCTAssertEqual(records, [first])
            await queue.close()
        }
    }

    func testEventsRejectStaleSessionBackdatedTimeAndOverlappingReplacement() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(directory: directory)
            let currentSession = try testSession(
                id: "session_current",
                startedAt: now,
                lastActivityAt: now
            )
            _ = try await queue.appendEvent(
                eventDraft(
                    index: 0,
                    versions: testVersions(),
                    expectedSessionId: currentSession.id
                ),
                sessionUpdate: .replace(
                    expectedCurrentSessionId: nil,
                    session: currentSession
                )
            )
            let committed = try await queue.snapshot()

            let later = now.addingTimeInterval(1)
            let nextSession = try testSession(
                id: "session_next",
                startedAt: later,
                lastActivityAt: later
            )
            do {
                _ = try await queue.appendEvent(
                    eventDraft(
                        index: 1,
                        versions: testVersions(),
                        occurredAt: later,
                        expectedSessionId: currentSession.id
                    ),
                    sessionUpdate: .replace(
                        expectedCurrentSessionId: currentSession.id,
                        session: nextSession
                    )
                )
                XCTFail("Expected stale expected-session rejection")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .invalidRecord)
            }

            do {
                _ = try await queue.appendEvent(
                    eventDraft(
                        index: 2,
                        versions: testVersions(),
                        occurredAt: now.addingTimeInterval(-1),
                        expectedSessionId: currentSession.id
                    ),
                    sessionUpdate: .preserve
                )
                XCTFail("Expected backdated-event rejection")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .invalidRecord)
            }

            let overlapping = try testSession(
                id: "session_overlap",
                startedAt: now.addingTimeInterval(-1),
                lastActivityAt: later
            )
            do {
                _ = try await queue.appendEvent(
                    eventDraft(
                        index: 3,
                        versions: testVersions(),
                        occurredAt: later,
                        expectedSessionId: overlapping.id
                    ),
                    sessionUpdate: .replace(
                        expectedCurrentSessionId: currentSession.id,
                        session: overlapping
                    )
                )
                XCTFail("Expected overlapping-session rejection")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .invalidState)
            }

            let afterRejected = try await queue.snapshot()
            let records = try await queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
            XCTAssertEqual(afterRejected, committed)
            XCTAssertEqual(records.count, 1)
            await queue.close()
        }
    }

    func testEventSequenceCannotBackdateWithinAnExistingSession() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(directory: directory)
            let later = now.addingTimeInterval(10)
            let session = try testSession(
                id: "session_causal",
                startedAt: now,
                lastActivityAt: later
            )
            _ = try await queue.appendEvent(
                eventDraft(
                    index: 0,
                    versions: testVersions(),
                    occurredAt: later,
                    expectedSessionId: session.id
                ),
                sessionUpdate: .replace(
                    expectedCurrentSessionId: nil,
                    session: session
                )
            )
            let committed = try await queue.snapshot()

            do {
                _ = try await queue.appendEvent(
                    eventDraft(
                        index: 1,
                        versions: testVersions(),
                        occurredAt: now.addingTimeInterval(5),
                        expectedSessionId: session.id
                    ),
                    sessionUpdate: .preserve
                )
                XCTFail("Expected cross-transaction event causality rejection")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .invalidRecord)
            }

            let afterRejected = try await queue.snapshot()
            let records = try await queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
            XCTAssertEqual(afterRejected, committed)
            XCTAssertEqual(records.count, 1)
            await queue.close()
        }
    }

    func testSuccessfulEventSessionReplacementStampsPostTransitionSession() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(directory: directory)
            let firstSession = try testSession(
                id: "session_before",
                startedAt: now,
                lastActivityAt: now
            )
            _ = try await queue.appendEvent(
                eventDraft(
                    index: 0,
                    versions: testVersions(),
                    expectedSessionId: firstSession.id
                ),
                sessionUpdate: .replace(
                    expectedCurrentSessionId: nil,
                    session: firstSession
                )
            )

            let later = now.addingTimeInterval(1)
            let replacement = try testSession(
                id: "session_after",
                startedAt: later,
                lastActivityAt: later
            )
            let record = try await queue.appendEvent(
                eventDraft(
                    index: 1,
                    versions: testVersions(),
                    occurredAt: later,
                    expectedSessionId: replacement.id
                ),
                sessionUpdate: .replace(
                    expectedCurrentSessionId: firstSession.id,
                    session: replacement
                )
            )
            let snapshot = try await queue.snapshot()
            XCTAssertEqual(snapshot.identity.session, replacement)
            guard case let .event(event) = record else {
                return XCTFail("Expected replacement event")
            }
            XCTAssertEqual(event.sessionId, replacement.id)
            XCTAssertEqual(event.occurredAt, replacement.lastActivityAt)
            XCTAssertEqual(event.sequence, 1)
            await queue.close()
        }
    }

    func testSessionReplacementCASRejectsAStaleRotation() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(directory: directory)
            let base = try testSession(
                id: "session_base",
                startedAt: now,
                lastActivityAt: now
            )
            _ = try await queue.appendEvent(
                eventDraft(
                    index: 0,
                    versions: testVersions(),
                    expectedSessionId: base.id
                ),
                sessionUpdate: .replace(
                    expectedCurrentSessionId: nil,
                    session: base
                )
            )

            let firstRotationAt = now.addingTimeInterval(1)
            let firstRotation = try testSession(
                id: "session_rotation_a",
                startedAt: firstRotationAt,
                lastActivityAt: firstRotationAt
            )
            _ = try await queue.appendEvent(
                eventDraft(
                    index: 1,
                    versions: testVersions(),
                    occurredAt: firstRotationAt,
                    expectedSessionId: firstRotation.id
                ),
                sessionUpdate: .replace(
                    expectedCurrentSessionId: base.id,
                    session: firstRotation
                )
            )
            let committed = try await queue.snapshot()

            let staleRotationAt = now.addingTimeInterval(2)
            let staleRotation = try testSession(
                id: "session_rotation_b",
                startedAt: staleRotationAt,
                lastActivityAt: staleRotationAt
            )
            for expectedCurrentSessionId in [Optional(base.id), nil] {
                do {
                    _ = try await queue.appendEvent(
                        eventDraft(
                            index: 2,
                            versions: testVersions(),
                            occurredAt: staleRotationAt,
                            expectedSessionId: staleRotation.id
                        ),
                        sessionUpdate: .replace(
                            expectedCurrentSessionId: expectedCurrentSessionId,
                            session: staleRotation
                        )
                    )
                    XCTFail("Expected stale current-session CAS rejection")
                } catch let error as EluRuntimeQueueError {
                    XCTAssertEqual(error, .generationMismatch)
                }
            }

            let afterRejected = try await queue.snapshot()
            let records = try await queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
            XCTAssertEqual(afterRejected, committed)
            XCTAssertEqual(afterRejected.identity.session, firstRotation)
            XCTAssertEqual(records.count, 2)
            await queue.close()
        }
    }

    func testRetainedSessionUsesTheStricterIdleTimeout() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(directory: directory)
            let current = try testSession(
                id: "session_timeout",
                startedAt: now,
                lastActivityAt: now,
                timeoutSeconds: 60
            )
            _ = try await queue.appendEvent(
                eventDraft(
                    index: 0,
                    versions: testVersions(),
                    expectedSessionId: current.id
                ),
                sessionUpdate: .replace(
                    expectedCurrentSessionId: nil,
                    session: current
                )
            )
            let committed = try await queue.snapshot()

            let tooLate = now.addingTimeInterval(100)
            let proposed = try testSession(
                id: current.id,
                startedAt: current.startedAt,
                lastActivityAt: tooLate,
                timeoutSeconds: 1_800
            )
            do {
                _ = try await queue.appendEvent(
                    eventDraft(
                        index: 1,
                        versions: testVersions(),
                        occurredAt: tooLate,
                        expectedSessionId: proposed.id
                    ),
                    sessionUpdate: .replace(
                        expectedCurrentSessionId: current.id,
                        session: proposed
                    )
                )
                XCTFail("Expected retained-session idle expiry rejection")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .invalidState)
            }

            let afterRejected = try await queue.snapshot()
            let records = try await queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
            XCTAssertEqual(afterRejected, committed)
            XCTAssertEqual(records.count, 1)
            await queue.close()
        }
    }

    func testEligibleActivityForegroundsAndPersistsABackgroundSession() async throws {
        try await withTemporaryDirectory { directory in
            let backgroundedAt = now.addingTimeInterval(-5)
            let backgroundSession = try testSession(
                id: "session_background",
                startedAt: now.addingTimeInterval(-30),
                lastActivityAt: now.addingTimeInterval(-10),
                lifecycle: .background,
                backgroundedAt: backgroundedAt
            )
            let legacyStore = try EluFileIdentityStateStore(directoryURL: directory)
            let identity = try EluIdentityState(
                revision: 0,
                contextRevision: 0,
                anonymousId: "anon_background",
                userId: nil,
                groups: [:],
                superProperties: [:],
                session: backgroundSession,
                optedOut: false,
                updatedAt: try XCTUnwrap(backgroundSession.backgroundedAt)
            )
            try legacyStore.save(
                EluPersistedState(
                    identity: identity,
                    streamMetadata: EluStreamMetadata(streamId: "stream_background"),
                    flagContext: EluPersistedFlagContext()
                ),
                mode: .normal
            )

            let queue = try await makeQueue(directory: directory)
            let imported = try await queue.snapshot()
            XCTAssertEqual(imported.identity.session?.lifecycle, .background)
            let foregrounded = try await queue.recordEligibleActivity(
                expectedGeneration: imported.generation
            )
            XCTAssertEqual(foregrounded.identity.session?.lifecycle, .active)
            XCTAssertNil(foregrounded.identity.session?.backgroundedAt)
            XCTAssertEqual(foregrounded.identity.session?.lastActivityAt, foregrounded.identity.updatedAt)
            await queue.close()

            let reopened = try await makeQueue(directory: directory)
            let persisted = try await reopened.snapshot()
            XCTAssertEqual(persisted, foregrounded)
            XCTAssertEqual(persisted.identity.session?.lifecycle, .active)
            XCTAssertNil(persisted.identity.session?.backgroundedAt)
            await reopened.close()
        }
    }

    func testTypedMutationTransitionsDeriveStateSubjectsAndContextAtomically() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(directory: directory)
            let versions = try testVersions()
            let initial = try await queue.snapshot()

            let identifyRecords = try await queue.applyMutation(
                .identify(
                    userId: "user_123",
                    set: ["plan": .string("growth")],
                    setOnce: ["firstPlan": .string("growth")]
                ),
                versions: versions,
                expectedGeneration: initial.generation
            )
            let identified = try await queue.snapshot()
            XCTAssertEqual(identified.identity.userId, "user_123")
            XCTAssertEqual(identified.identity.revision, 1)
            XCTAssertEqual(identified.identity.contextRevision, 1)
            XCTAssertEqual(identified.flagContext.personProperties["plan"], .string("growth"))
            assertMutation(
                identifyRecords[0],
                contextRevision: 1,
                userId: "user_123",
                identityRevision: 1,
                versions: versions
            )

            let groupRecords = try await queue.applyMutation(
                .group(
                    groupType: "organization",
                    groupKey: "org_456",
                    set: ["tier": .string("design-partner")],
                    setOnce: [:],
                    unset: []
                ),
                versions: versions,
                expectedGeneration: identified.generation
            )
            let grouped = try await queue.snapshot()
            XCTAssertEqual(groupRecords.map(\.sequence), [1, 2])
            XCTAssertEqual(grouped.identity.groups["organization"], "org_456")
            XCTAssertEqual(grouped.identity.contextRevision, 3)
            XCTAssertEqual(
                grouped.flagContext.groupProperties["organization"]?["tier"],
                .string("design-partner")
            )
            assertMutation(
                groupRecords[0],
                contextRevision: 2,
                userId: "user_123",
                identityRevision: 1,
                versions: versions
            )
            assertMutation(
                groupRecords[1],
                contextRevision: 3,
                userId: "user_123",
                identityRevision: 1,
                versions: versions
            )
            guard case let .mutation(associated, _) = groupRecords[0],
                  case .associateGroup = associated.change,
                  case let .mutation(properties, _) = groupRecords[1],
                  case .setGroupProperties = properties.change
            else {
                return XCTFail("Expected sequential group association and property mutations")
            }

            let aliasRecords = try await queue.applyMutation(
                .linkAlias(aliasId: "legacy_123"),
                versions: versions,
                expectedGeneration: grouped.generation
            )
            guard case let .mutation(alias, _) = aliasRecords[0],
                  case let .linkAlias(aliasId, canonicalId) = alias.change
            else {
                return XCTFail("Expected a derived linkAlias mutation")
            }
            XCTAssertEqual(aliasId, "legacy_123")
            XCTAssertEqual(canonicalId, "user_123")
            XCTAssertEqual(alias.contextRevision, 4)

            let afterAlias = try await queue.snapshot()
            let personRecords = try await queue.applyMutation(
                .setPersonProperties(
                    set: ["plan": .string("enterprise")],
                    setOnce: ["firstSeen": .string("today")],
                    unset: ["firstPlan"]
                ),
                versions: versions,
                expectedGeneration: afterAlias.generation
            )
            XCTAssertEqual(personRecords.count, 1)
            let final = try await queue.snapshot()
            XCTAssertEqual(final.identity.contextRevision, 5)
            XCTAssertEqual(final.flagContext.personProperties["plan"], .string("enterprise"))
            XCTAssertEqual(final.flagContext.personProperties["firstSeen"], .string("today"))
            XCTAssertNil(final.flagContext.personProperties["firstPlan"])
            await queue.close()
        }
    }

    func testStaleExpectedGenerationCannotOverwriteNewerState() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(directory: directory)
            let stale = try await queue.snapshot()
            _ = try await queue.applyMutation(
                .identify(userId: "new_user", set: [:], setOnce: [:]),
                versions: testVersions(),
                expectedGeneration: stale.generation
            )
            do {
                _ = try await queue.applyMutation(
                    .setPersonProperties(
                        set: ["stale": .bool(true)],
                        setOnce: [:],
                        unset: []
                    ),
                    versions: testVersions(),
                    expectedGeneration: stale.generation
                )
                XCTFail("Expected a stale generation rejection")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .generationMismatch)
            }
            let current = try await queue.snapshot()
            XCTAssertEqual(current.identity.userId, "new_user")
            XCTAssertNil(current.flagContext.personProperties["stale"])
            await queue.close()
        }
    }

    func testTwoRecordGroupTransitionRollsBackStateRowsAndSequenceTogether() async throws {
        try await withTemporaryDirectory { directory in
            let fault = TestFaultInjector(point: .afterRecordInsert(0))
            let queue = try await makeQueue(directory: directory, faultInjector: fault)
            let initial = try await queue.snapshot()
            do {
                _ = try await queue.applyMutation(
                    .group(
                        groupType: "organization",
                        groupKey: "org_rollback",
                        set: ["tier": .string("trial")],
                        setOnce: [:],
                        unset: []
                    ),
                    versions: testVersions(),
                    expectedGeneration: initial.generation
                )
                XCTFail("Expected injected rollback")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .faultInjected(.afterRecordInsert(0)))
            }
            let rolledBack = try await queue.snapshot()
            let rolledBackRecords = try await queue.peek(
                maximumCount: 10,
                maximumBytes: 1_000_000
            )
            XCTAssertEqual(rolledBack, initial)
            XCTAssertTrue(rolledBackRecords.isEmpty)
            await queue.close()
        }

        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(
                directory: directory,
                limits: EluRuntimeQueueLimits(maximumCount: 1, maximumBytes: 1_000_000)
            )
            let initial = try await queue.snapshot()
            do {
                _ = try await queue.applyMutation(
                    .group(
                        groupType: "organization",
                        groupKey: "org_full",
                        set: ["tier": .string("trial")],
                        setOnce: [:],
                        unset: []
                    ),
                    versions: testVersions(),
                    expectedGeneration: initial.generation
                )
                XCTFail("Expected atomic count-limit rejection")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .queueCountLimitExceeded)
            }
            let rejected = try await queue.snapshot()
            XCTAssertEqual(rejected, initial)
            await queue.close()
        }
    }

    func testExactOutboundRecordBytesVersionsAndBatchEnvelopeAccounting() async throws {
        let versions = try testVersions(build: "capture-build")
        var expectedRecordBytes = 0
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(directory: directory)
            let initial = try await queue.snapshot()
            let records = try await queue.applyMutation(
                .setPersonProperties(
                    set: ["emoji": .string("💡")],
                    setOnce: [:],
                    unset: []
                ),
                versions: versions,
                expectedGeneration: initial.generation
            )
            expectedRecordBytes = try EluQueueBatchCodec.encodeRecord(records[0]).count
            let snapshot = try await queue.snapshot()
            XCTAssertEqual(snapshot.queuedBytes, Int64(expectedRecordBytes))
            XCTAssertEqual(records[0].versions, versions)

            let batch = try EluQueueBatchCodec.encodeBatch(
                requestId: "request_test",
                streamId: snapshot.streamId,
                sentAt: now,
                versions: versions,
                records: records
            )
            XCTAssertGreaterThan(batch.count, expectedRecordBytes)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: batch))
            await queue.close()
        }

        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(
                directory: directory,
                limits: EluRuntimeQueueLimits(
                    maximumCount: 1,
                    maximumBytes: expectedRecordBytes
                )
            )
            let initial = try await queue.snapshot()
            _ = try await queue.applyMutation(
                .setPersonProperties(
                    set: ["emoji": .string("💡")],
                    setOnce: [:],
                    unset: []
                ),
                versions: versions,
                expectedGeneration: initial.generation
            )
            let exactSnapshot = try await queue.snapshot()
            XCTAssertEqual(exactSnapshot.queuedBytes, Int64(expectedRecordBytes))
            await queue.close()
        }

        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(
                directory: directory,
                limits: EluRuntimeQueueLimits(
                    maximumCount: 10,
                    maximumBytes: expectedRecordBytes - 1
                )
            )
            let initial = try await queue.snapshot()
            do {
                _ = try await queue.applyMutation(
                    .setPersonProperties(
                        set: ["emoji": .string("💡")],
                        setOnce: [:],
                        unset: []
                    ),
                    versions: versions,
                    expectedGeneration: initial.generation
                )
                XCTFail("Expected one-byte-over rejection")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .queueByteLimitExceeded)
            }
            let rejected = try await queue.snapshot()
            XCTAssertEqual(rejected, initial)
            await queue.close()
        }
    }

    func testPeekRejectsAnOversizeHeadExplicitly() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(directory: directory)
            let initial = try await queue.snapshot()
            let records = try await queue.applyMutation(
                .setPersonProperties(set: ["x": .string("value")], setOnce: [:], unset: []),
                versions: testVersions(),
                expectedGeneration: initial.generation
            )
            let requiredBytes = try EluQueueBatchCodec.encodeRecord(records[0]).count
            do {
                _ = try await queue.peek(maximumCount: 10, maximumBytes: requiredBytes - 1)
                XCTFail("Expected an explicit oversize-head failure")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .headRecordExceedsPeekLimit(Int64(requiredBytes)))
            }
            await queue.close()
        }
    }

    func testAcknowledgementIsStreamScopedExactAndProvesStaleIds() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(directory: directory)
            var generation = (try await queue.snapshot()).generation
            var records: [EluQueuedRecord] = []
            for index in 0 ..< 3 {
                let appended = try await queue.applyMutation(
                    .setPersonProperties(
                        set: ["index": .integer(Int64(index))],
                        setOnce: [:],
                        unset: []
                    ),
                    versions: testVersions(),
                    expectedGeneration: generation
                )
                records.append(contentsOf: appended)
                generation = (try await queue.snapshot()).generation
            }
            let streamId = (try await queue.snapshot()).streamId
            let references = records.map { reference(for: $0, streamId: streamId) }

            var wrongStream = references[0]
            wrongStream.streamId = "stream_wrong"
            await assertAckMismatch(queue, [wrongStream])

            var wrongId = references[0]
            wrongId.recordId = "mutation_wrong"
            await assertAckMismatch(queue, [wrongId])

            let afterTwo = try await queue.acknowledge(Array(references.prefix(2)))
            XCTAssertEqual(afterTwo.headSequence, 2)
            let stale = try await queue.acknowledge(Array(references.prefix(2)))
            XCTAssertEqual(stale, afterTwo)

            var forgedStale = references[0]
            forgedStale.recordId = "mutation_forged"
            await assertAckMismatch(queue, [forgedStale])
            await assertAckMismatch(queue, [references[1], references[2]])

            let empty = try await queue.acknowledge([references[2]])
            XCTAssertEqual(empty.queuedCount, 0)
            let next = try await queue.applyMutation(
                .setPersonProperties(set: ["next": .bool(true)], setOnce: [:], unset: []),
                versions: testVersions(),
                expectedGeneration: empty.generation
            )
            XCTAssertEqual(next[0].sequence, 3)
            XCTAssertFalse(records.map(\.recordId).contains(next[0].recordId))
            await queue.close()
        }
    }

    func testAmbiguousCommitPoisonsOwnerAndReopenReconcilesDerivedRecord() async throws {
        try await withTemporaryDirectory { directory in
            let fault = TestFaultInjector(point: .afterCommit)
            let queue = try await makeQueue(directory: directory, faultInjector: fault)
            let initial = try await queue.snapshot()
            do {
                _ = try await queue.applyMutation(
                    .setPersonProperties(set: ["x": .integer(1)], setOnce: [:], unset: []),
                    versions: testVersions(),
                    expectedGeneration: initial.generation
                )
                XCTFail("Expected an ambiguous commit")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .ambiguousCommit)
            }
            do {
                _ = try await queue.snapshot()
                XCTFail("Expected poisoned owner")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .poisoned)
            }

            let reopened = try await makeQueue(directory: directory)
            let records = try await reopened.peek(maximumCount: 10, maximumBytes: 1_000_000)
            XCTAssertEqual(records.map(\.sequence), [0])
            XCTAssertEqual(Set(records.map(\.recordId)).count, 1)
            await reopened.close()
        }
    }

    func testFreshInitializationStagesBeforeAtomicInstall() async throws {
        try await withTemporaryDirectory { directory in
            do {
                _ = try await makeQueue(
                    directory: directory,
                    faultInjector: TestFaultInjector(point: .beforeInitialInstall)
                )
                XCTFail("Expected pre-install failure")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .faultInjected(.beforeInitialInstall))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL(directory).path))
            XCTAssertFalse(try directoryNames(directory).contains(where: { $0.contains(".staged") }))

            let queue = try await makeQueue(directory: directory)
            await queue.close()
        }

        try await withTemporaryDirectory { directory in
            do {
                _ = try await makeQueue(
                    directory: directory,
                    faultInjector: TestFaultInjector(point: .afterInitialInstall)
                )
                XCTFail("Expected post-install failure")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .faultInjected(.afterInitialInstall))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL(directory).path))
            let reopened = try await makeQueue(directory: directory)
            let snapshot = try await reopened.snapshot()
            XCTAssertEqual(snapshot.nextSequence, 0)
            await reopened.close()
        }
    }

    func testUnsupportedWALStatePreservesDatabaseWalAndShmBytes() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(directory: directory)
            await queue.close()

            let database = databaseURL(directory)
            let external = try openFutureWALDatabase(database)
            defer { _ = sqlite3_close_v2(external) }
            let wal = URL(fileURLWithPath: database.path + "-wal")
            let shm = URL(fileURLWithPath: database.path + "-shm")
            XCTAssertTrue(FileManager.default.fileExists(atPath: wal.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: shm.path))
            let before = try [database, wal, shm].map { try Data(contentsOf: $0) }

            do {
                _ = try await makeQueue(directory: directory)
                XCTFail("Expected future schema rejection")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .unsupportedSchemaVersion(2))
            }
            let after = try [database, wal, shm].map { try Data(contentsOf: $0) }
            XCTAssertEqual(after, before)
        }
    }

    func testCorruptWALStatePreservesDatabaseWalAndShmBytes() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(directory: directory)
            await queue.close()

            let database = databaseURL(directory)
            let external = try openWALDatabase(
                database,
                mutationSQL: "UPDATE runtime_state SET stream_id='' WHERE singleton=1"
            )
            defer { _ = sqlite3_close_v2(external) }
            let wal = URL(fileURLWithPath: database.path + "-wal")
            let shm = URL(fileURLWithPath: database.path + "-shm")
            XCTAssertTrue(FileManager.default.fileExists(atPath: wal.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: shm.path))
            let before = try [database, wal, shm].map { try Data(contentsOf: $0) }

            do {
                _ = try await makeQueue(directory: directory)
                XCTFail("Expected corrupt storage rejection")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .corruptStorage)
            }
            let after = try [database, wal, shm].map { try Data(contentsOf: $0) }
            XCTAssertEqual(after, before)
        }
    }

    func testRestartValidationHandlesALargeQueueWithoutMaterializingItAsOneArray() async throws {
        try await withTemporaryDirectory { directory in
            let queue = try await makeQueue(
                directory: directory,
                limits: EluRuntimeQueueLimits(maximumCount: 512, maximumBytes: 100_000_000)
            )
            let initial = try await queue.snapshot()
            _ = try await queue.recordEligibleActivity(expectedGeneration: initial.generation)
            let versions = try testVersions()
            for index in 0 ..< 256 {
                let draft = eventDraft(index: index, versions: versions)
                _ = try await queue.appendEvent(
                    draft,
                    sessionUpdate: .replace(
                        expectedCurrentSessionId: "session_test",
                        session: testSession(
                            startedAt: now,
                            lastActivityAt: draft.occurredAt
                        )
                    )
                )
            }
            let before = try await queue.snapshot()
            await queue.close()

            let reopened = try await makeQueue(
                directory: directory,
                limits: EluRuntimeQueueLimits(maximumCount: 512, maximumBytes: 100_000_000)
            )
            let reopenedSnapshot = try await reopened.snapshot()
            let records = try await reopened.peek(
                maximumCount: 256,
                maximumBytes: 100_000_000
            )
            XCTAssertEqual(reopenedSnapshot, before)
            XCTAssertEqual(records.count, 256)
            await reopened.close()
        }
    }

    func testDuplicateOwnerOffMainOpenAndMaintenanceFailureBehavior() async throws {
        try await withTemporaryDirectory { directory in
            let recorder = OpenThreadRecorder()
            let first = try await makeQueue(directory: directory, faultInjector: recorder)
            XCTAssertEqual(recorder.openWasMainThread, false)
            do {
                _ = try await makeQueue(directory: directory.appendingPathComponent("."))
                XCTFail("Expected duplicate owner rejection")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .ownershipConflict)
            }
            await first.close()

            let maintenance = MaintenanceFaultInjector()
            let second = try await makeQueue(directory: directory, faultInjector: maintenance)
            let initial = try await second.snapshot()
            let records = try await second.applyMutation(
                .setPersonProperties(set: ["x": .integer(1)], setOnce: [:], unset: []),
                versions: testVersions(),
                expectedGeneration: initial.generation
            )
            let streamId = (try await second.snapshot()).streamId
            _ = try await second.acknowledge([reference(for: records[0], streamId: streamId)])
            XCTAssertGreaterThanOrEqual(maintenance.checkpointHits, 2)
            XCTAssertEqual(maintenance.vacuumHits, 1)
            await second.close()
        }
    }

    func testExternalFileLockBlocksQueueOpenUntilReleased() async throws {
        try await withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent(".runtime-state-v1.lock")
            var descriptor = lockURL.path.withCString { path in
                Darwin.open(path, O_CREAT | O_RDWR, mode_t(0o600))
            }
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            defer {
                if descriptor >= 0 {
                    _ = flock(descriptor, LOCK_UN)
                    _ = Darwin.close(descriptor)
                }
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                XCTFail("Expected the external lock to be acquired")
                return
            }

            do {
                _ = try await makeQueue(directory: directory)
                XCTFail("Expected an external lock ownership conflict")
            } catch let error as EluRuntimeQueueError {
                XCTAssertEqual(error, .ownershipConflict)
            }

            XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
            XCTAssertEqual(Darwin.close(descriptor), 0)
            descriptor = -1

            let queue = try await makeQueue(directory: directory)
            await queue.close()
        }
    }

    func testLegacyImportIsCanonicalAndNeverDualWritten() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileIdentityStateStore(directoryURL: directory)
            let identity = try EluIdentityState(
                revision: 1,
                contextRevision: 2,
                anonymousId: "anon_legacy",
                userId: "user_legacy",
                groups: [:],
                superProperties: [:],
                session: nil,
                optedOut: false,
                updatedAt: now
            )
            let legacy = try EluPersistedState(
                identity: identity,
                streamMetadata: EluStreamMetadata(streamId: "stream_legacy"),
                flagContext: EluPersistedFlagContext()
            )
            try store.save(legacy, mode: .normal)
            let legacyBytes = try Data(contentsOf: store.stateFileURL)

            let queue = try await makeQueue(directory: directory)
            let imported = try await queue.snapshot()
            XCTAssertEqual(imported.identity.anonymousId, "anon_legacy")
            XCTAssertEqual(imported.streamId, "stream_legacy")
            let optedOut = try await queue.setOptedOut(
                true,
                expectedGeneration: imported.generation
            )
            XCTAssertTrue(optedOut.identity.optedOut)
            XCTAssertEqual(
                optedOut.identity.contextRevision,
                imported.identity.contextRevision + 1
            )
            await queue.close()
            XCTAssertEqual(try Data(contentsOf: store.stateFileURL), legacyBytes)
        }
    }

    private func makeQueue(
        directory: URL,
        limits: EluRuntimeQueueLimits? = nil,
        faultInjector: (any EluRuntimeQueueFaultInjecting)? = nil
    ) async throws -> EluSQLiteRuntimeQueue {
        let fixedNow = now
        let resolvedLimits: EluRuntimeQueueLimits
        if let limits {
            resolvedLimits = limits
        } else {
            resolvedLimits = try EluRuntimeQueueLimits()
        }
        return try await EluSQLiteRuntimeQueue.open(
            directoryURL: directory,
            limits: resolvedLimits,
            clock: { fixedNow },
            anonymousIdGenerator: { "anon_test" },
            streamIdGenerator: { "stream_test" },
            sessionIdGenerator: { "session_test" },
            faultInjector: faultInjector
        )
    }

    private func eventDraft(
        index: Int,
        versions: EluVersionContext,
        occurredAt: Date? = nil,
        expectedSessionId: String = "session_test"
    ) -> EluEventDraft {
        EluEventDraft(
            kind: .capture,
            name: "event_\(index)",
            occurredAt: occurredAt ?? now.addingTimeInterval(Double(index)),
            expectedSessionId: expectedSessionId,
            properties: ["index": .integer(Int64(index))],
            versions: versions
        )
    }

    private func testSession(
        id: String = "session_test",
        startedAt: Date,
        lastActivityAt: Date,
        timeoutSeconds: Int = 1_800,
        lifecycle: EluSessionLifecycle = .active,
        backgroundedAt: Date? = nil
    ) throws -> EluSessionState {
        let canonicalStartedAt = try XCTUnwrap(
            EluRFC3339.date(from: EluRFC3339.string(from: startedAt))
        )
        let canonicalLastActivityAt = try XCTUnwrap(
            EluRFC3339.date(from: EluRFC3339.string(from: lastActivityAt))
        )
        let canonicalBackgroundedAt = try backgroundedAt.map { value in
            try XCTUnwrap(EluRFC3339.date(from: EluRFC3339.string(from: value)))
        }
        return try EluSessionState(
            id: id,
            startedAt: canonicalStartedAt,
            lastActivityAt: canonicalLastActivityAt,
            timeoutSeconds: timeoutSeconds,
            lifecycle: lifecycle,
            backgroundedAt: canonicalBackgroundedAt
        )
    }

    private func testVersions(build: String = "test") throws -> EluVersionContext {
        try EluVersionContext(
            runtime: EluVersionComponent(name: "elu-ios", version: "0.1.0"),
            facade: EluVersionComponent(name: "Elu", version: "1.0.0"),
            build: build
        )
    }

    private func reference(
        for record: EluQueuedRecord,
        streamId: String
    ) -> EluQueueAcknowledgementReference {
        EluQueueAcknowledgementReference(
            streamId: streamId,
            sequence: record.sequence,
            kind: record.kind,
            recordId: record.recordId
        )
    }

    private func assertMutation(
        _ record: EluQueuedRecord,
        contextRevision: Int64,
        userId: String?,
        identityRevision: Int64,
        versions: EluVersionContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .mutation(mutation, actualVersions) = record else {
            return XCTFail("Expected mutation record", file: file, line: line)
        }
        XCTAssertEqual(mutation.contextRevision, contextRevision, file: file, line: line)
        XCTAssertEqual(mutation.subject.userId, userId, file: file, line: line)
        XCTAssertEqual(mutation.subject.identityRevision, identityRevision, file: file, line: line)
        XCTAssertEqual(actualVersions, versions, file: file, line: line)
    }

    private func assertAckMismatch(
        _ queue: EluSQLiteRuntimeQueue,
        _ references: [EluQueueAcknowledgementReference],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await queue.acknowledge(references)
            XCTFail("Expected acknowledgement mismatch", file: file, line: line)
        } catch let error as EluRuntimeQueueError {
            XCTAssertEqual(error, .acknowledgementMismatch, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func databaseURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("runtime-state-v1.sqlite3")
    }

    private func directoryNames(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    private func openFutureWALDatabase(_ url: URL) throws -> OpaquePointer {
        try openWALDatabase(url, mutationSQL: "PRAGMA user_version=2")
    }

    private func openWALDatabase(
        _ url: URL,
        mutationSQL: String
    ) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw EluRuntimeQueueError.databaseUnavailable
        }
        do {
            try executeSQLite(database, "PRAGMA journal_mode=WAL")
            try executeSQLite(database, "PRAGMA wal_autocheckpoint=0")
            try executeSQLite(database, "BEGIN IMMEDIATE")
            try executeSQLite(database, mutationSQL)
            try executeSQLite(database, "COMMIT")
            return database
        } catch {
            sqlite3_close_v2(database)
            throw error
        }
    }

    private func executeSQLite(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw EluRuntimeQueueError.databaseUnavailable
        }
    }

    private func withTemporaryDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "elu-runtime-queue-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await operation(directory)
    }
}

private final class TestFaultInjector: EluRuntimeQueueFaultInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private let point: EluRuntimeQueueFaultPoint
    private var hasFired = false

    init(point: EluRuntimeQueueFaultPoint) {
        self.point = point
    }

    func hit(_ candidate: EluRuntimeQueueFaultPoint) throws {
        lock.lock()
        defer { lock.unlock() }
        if candidate == point, !hasFired {
            hasFired = true
            throw EluRuntimeQueueError.faultInjected(candidate)
        }
    }
}

private final class OpenThreadRecorder: EluRuntimeQueueFaultInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValue: Bool?

    var openWasMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return recordedValue
    }

    func hit(_ point: EluRuntimeQueueFaultPoint) throws {
        guard point == .open else { return }
        lock.lock()
        recordedValue = Thread.isMainThread
        lock.unlock()
    }
}

private final class MaintenanceFaultInjector: EluRuntimeQueueFaultInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private var checkpointCount = 0
    private var vacuumCount = 0

    var checkpointHits: Int {
        lock.lock()
        defer { lock.unlock() }
        return checkpointCount
    }

    var vacuumHits: Int {
        lock.lock()
        defer { lock.unlock() }
        return vacuumCount
    }

    func hit(_ point: EluRuntimeQueueFaultPoint) throws {
        lock.lock()
        defer { lock.unlock() }
        switch point {
        case .checkpoint:
            checkpointCount += 1
            throw EluRuntimeQueueError.faultInjected(point)
        case .vacuum:
            vacuumCount += 1
            throw EluRuntimeQueueError.faultInjected(point)
        default:
            return
        }
    }
}
