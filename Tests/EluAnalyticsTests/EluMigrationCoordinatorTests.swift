import Foundation
import XCTest
@testable import EluAnalytics

final class EluMigrationCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_775_260_800)

    func testEmptySourceWritesCompleteWitnessWithoutTouchingTarget() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            let source = ScriptedLegacyStateSource(values: [:])
            let target = RecordingMigrationTarget()
            let metrics = RecordingMigrationMetrics()

            let first = await self.makeCoordinator(
                source: source, target: target, store: store, metrics: metrics
            ).run()
            XCTAssertEqual(first.outcome, .completed(importedLegacyState: false))
            XCTAssertEqual(first.phaseBefore, .unseen)
            XCTAssertEqual(first.phaseAfter, .complete)
            XCTAssertEqual(first.sourceReadCount, 1)
            XCTAssertEqual(target.adoptCount, 0)
            XCTAssertEqual(target.readBackCount, 0)

            guard case let .loaded(witness) = try store.load() else {
                return XCTFail("Expected a persisted witness")
            }
            XCTAssertEqual(witness.phase, .complete)
            XCTAssertNil(witness.snapshot)
            XCTAssertEqual(witness.completedAt, self.now)
            XCTAssertEqual(witness.source.sourceSchema, "fixture-layout")

            let second = await self.makeCoordinator(
                source: source, target: target, store: store, metrics: metrics
            ).run()
            XCTAssertEqual(second.outcome, .alreadyComplete)
            XCTAssertEqual(second.sourceReadCount, 0)
            XCTAssertEqual(source.readCount, 1)
            XCTAssertEqual(
                metrics.recorded,
                [
                    .phaseEntered(.complete),
                    .outcome(.completed(importedLegacyState: false)),
                    .outcome(.alreadyComplete),
                ]
            )
        }
    }

    func testImportAdvancesThroughEveryPhaseOnceAndIsIdempotent() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            let source = self.makeSource()
            let target = RecordingMigrationTarget()
            let metrics = RecordingMigrationMetrics()

            let report = await self.makeCoordinator(
                source: source, target: target, store: store, metrics: metrics
            ).run()
            XCTAssertEqual(report.outcome, .completed(importedLegacyState: true))
            XCTAssertEqual(report.phaseBefore, .unseen)
            XCTAssertEqual(report.phaseAfter, .complete)
            XCTAssertEqual(report.sourceReadCount, 10)
            XCTAssertEqual(source.readCount, 9)
            XCTAssertEqual(source.queueReadCount, 1)
            XCTAssertEqual(target.adoptCount, 1)
            XCTAssertEqual(target.readBackCount, 1)

            let adopted = try XCTUnwrap(target.adoptedSnapshot)
            XCTAssertEqual(adopted.identity.anonymousId, "anon-legacy")
            XCTAssertEqual(adopted.identity.userId, "user-42")
            XCTAssertFalse(adopted.identity.optedOut)
            XCTAssertEqual(adopted.context.superProperties["plan"], .string("pro"))
            XCTAssertEqual(adopted.context.groups["organization"], "org-1")
            XCTAssertEqual(adopted.context.flagPersonProperties["beta"], .bool(true))
            XCTAssertEqual(adopted.context.flagGroupProperties["organization"]?["tier"], .integer(2))
            XCTAssertEqual(adopted.stream.streamId, "stream-minted")
            XCTAssertEqual(adopted.stream.nextSequence, 0)
            XCTAssertEqual(adopted.queuePrefix.records.map(\.position), [10, 11, 12])
            XCTAssertFalse(adopted.queuePrefix.truncated)

            guard case let .loaded(persisted) = try store.load() else {
                return XCTFail("Expected a persisted checkpoint")
            }
            XCTAssertEqual(persisted.phase, .complete)
            XCTAssertEqual(persisted.checkpointId, "checkpoint-1")
            XCTAssertEqual(persisted.snapshot, adopted)
            XCTAssertEqual(persisted.importedAt, self.now)
            XCTAssertEqual(persisted.committedAt, self.now)
            XCTAssertEqual(persisted.verifiedAt, self.now)
            XCTAssertEqual(persisted.completedAt, self.now)
            XCTAssertEqual(
                metrics.recorded,
                [
                    .phaseEntered(.importing),
                    .phaseEntered(.committed),
                    .phaseEntered(.verified),
                    .phaseEntered(.complete),
                    .outcome(.completed(importedLegacyState: true)),
                ]
            )

            let again = await self.makeCoordinator(
                source: source, target: target, store: store
            ).run()
            XCTAssertEqual(again.outcome, .alreadyComplete)
            XCTAssertEqual(again.phaseBefore, .complete)
            XCTAssertEqual(again.sourceReadCount, 0)
            XCTAssertEqual(source.readCount, 9)
            XCTAssertEqual(target.adoptCount, 1)
            XCTAssertEqual(target.readBackCount, 1)
        }
    }

    func testCrashAtEveryPointResumesWithoutChangingIdentityOrReimportingQueue() async throws {
        let cases: [(point: EluMigrationFaultPoint, durablePhase: EluMigrationPhase)] = [
            (.beforeCheckpointWrite(.importing), .unseen),
            (.afterCheckpointWrite(.importing), .importing),
            (.beforeTargetAdopt, .importing),
            (.afterTargetAdopt, .importing),
            (.beforeCheckpointWrite(.committed), .importing),
            (.afterCheckpointWrite(.committed), .committed),
            (.beforeReadBack, .committed),
            (.beforeCheckpointWrite(.verified), .committed),
            (.afterCheckpointWrite(.verified), .verified),
            (.beforeCheckpointWrite(.complete), .verified),
            (.afterCheckpointWrite(.complete), .complete),
        ]

        for testCase in cases {
            try await withTemporaryDirectory { directory in
                let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
                let source = self.makeSource()
                let target = RecordingMigrationTarget()
                let fault = OneShotMigrationFaultInjector(point: testCase.point)

                let interrupted = await self.makeCoordinator(
                    source: source, target: target, store: store, faultInjector: fault
                ).run()
                XCTAssertEqual(
                    interrupted.outcome,
                    .interrupted(atPhase: testCase.durablePhase),
                    "\(testCase.point)"
                )
                XCTAssertEqual(interrupted.phaseAfter, testCase.durablePhase, "\(testCase.point)")
                XCTAssertTrue(fault.fired, "\(testCase.point)")
                XCTAssertLessThanOrEqual(target.adoptCount, 1, "\(testCase.point)")

                var checkpointIdBeforeRestart: String?
                switch try store.load() {
                case let .loaded(checkpoint):
                    XCTAssertEqual(checkpoint.phase, testCase.durablePhase, "\(testCase.point)")
                    checkpointIdBeforeRestart = checkpoint.checkpointId
                    // Whatever the source says after the snapshot was
                    // persisted must not influence the resumed run.
                    source.set(.anonymousId, to: .string("anon-changed"))
                case .missing:
                    XCTAssertEqual(testCase.durablePhase, .unseen, "\(testCase.point)")
                case let .unreadable(defect):
                    XCTFail("Unexpected defect \(defect) at \(testCase.point)")
                }
                let readsBeforeRestart = source.readCount

                let resumed = await self.makeCoordinator(
                    source: source, target: target, store: store
                ).run()
                let expectedOutcome: EluMigrationOutcome = testCase.durablePhase == .complete
                    ? .alreadyComplete
                    : .completed(importedLegacyState: true)
                XCTAssertEqual(resumed.outcome, expectedOutcome, "\(testCase.point)")
                XCTAssertEqual(resumed.phaseBefore, testCase.durablePhase, "\(testCase.point)")
                XCTAssertEqual(resumed.phaseAfter, .complete, "\(testCase.point)")
                if checkpointIdBeforeRestart != nil {
                    XCTAssertEqual(resumed.sourceReadCount, 0, "\(testCase.point)")
                    XCTAssertEqual(source.readCount, readsBeforeRestart, "\(testCase.point)")
                }

                XCTAssertEqual(target.adoptCount, 1, "\(testCase.point)")
                let adopted = try XCTUnwrap(target.adoptedSnapshot, "\(testCase.point)")
                XCTAssertEqual(adopted.identity.anonymousId, "anon-legacy", "\(testCase.point)")
                XCTAssertEqual(adopted.queuePrefix.records.count, 3, "\(testCase.point)")
                XCTAssertEqual(target.importedRecordCount, 3, "\(testCase.point)")

                guard case let .loaded(final) = try store.load() else {
                    return XCTFail("Expected a persisted checkpoint at \(testCase.point)")
                }
                XCTAssertEqual(final.phase, .complete, "\(testCase.point)")
                XCTAssertEqual(final.snapshot?.identity.anonymousId, "anon-legacy", "\(testCase.point)")
                if let checkpointIdBeforeRestart {
                    XCTAssertEqual(final.checkpointId, checkpointIdBeforeRestart, "\(testCase.point)")
                }
                XCTAssertEqual(target.adoptedCheckpointId, final.checkpointId, "\(testCase.point)")
                XCTAssertFalse(try store.hasQuarantinedDocument(), "\(testCase.point)")

                let settled = await self.makeCoordinator(
                    source: source, target: target, store: store
                ).run()
                XCTAssertEqual(settled.outcome, .alreadyComplete, "\(testCase.point)")
                XCTAssertEqual(target.adoptCount, 1, "\(testCase.point)")
            }
        }
    }

    func testSourceIsNeverReadAgainOnceTheImportingCheckpointExists() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            let source = self.makeSource()
            let target = RecordingMigrationTarget()
            let fault = OneShotMigrationFaultInjector(point: .afterCheckpointWrite(.importing))

            _ = await self.makeCoordinator(
                source: source, target: target, store: store, faultInjector: fault
            ).run()
            XCTAssertEqual(source.readCount, 9)
            source.set(.anonymousId, to: .string("anon-changed"))
            source.set(.userId, to: .string("user-changed"))
            source.failingKeys = Set(EluLegacyStateKey.allCases)
            source.queueFails = true

            let resumed = await self.makeCoordinator(
                source: source, target: target, store: store
            ).run()
            XCTAssertEqual(resumed.outcome, .completed(importedLegacyState: true))
            XCTAssertEqual(resumed.sourceReadCount, 0)
            XCTAssertEqual(source.readCount, 9)
            XCTAssertEqual(source.queueReadCount, 1)
            XCTAssertEqual(target.adoptedSnapshot?.identity.anonymousId, "anon-legacy")
            XCTAssertEqual(target.adoptedSnapshot?.identity.userId, "user-42")
        }
    }

    func testCorruptCheckpointIsQuarantinedWithBytesIntactAndBlocksLaterRuns() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            let corrupt = Data("{\"schemaVersion\": 1, \"checkpointId\": \"trunc".utf8)
            try corrupt.write(to: store.checkpointFileURL)
            let source = self.makeSource()
            let target = RecordingMigrationTarget()

            let first = await self.makeCoordinator(
                source: source, target: target, store: store
            ).run()
            XCTAssertEqual(first.outcome, .quarantined(.malformedCheckpoint))
            XCTAssertEqual(first.phaseAfter, .unseen)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.checkpointFileURL.path))
            XCTAssertEqual(try Data(contentsOf: store.quarantineFileURL), corrupt)
            XCTAssertEqual(source.readCount, 0)
            XCTAssertEqual(target.adoptCount, 0)

            let second = await self.makeCoordinator(
                source: source, target: target, store: store
            ).run()
            XCTAssertEqual(second.outcome, .quarantined(.priorQuarantine))
            XCTAssertEqual(source.readCount, 0)
            XCTAssertEqual(target.adoptCount, 0)
            XCTAssertEqual(try Data(contentsOf: store.quarantineFileURL), corrupt)
        }
    }

    func testFutureCheckpointSchemaAndUnknownKeysAreQuarantinedNotGuessed() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            let checkpoint = try self.makeCheckpoint(phase: .committed)
            var object = try self.jsonObject(for: checkpoint)
            object["schemaVersion"] = 2
            object["phase"] = "settled"
            let future = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try future.write(to: store.checkpointFileURL)
            let source = self.makeSource()
            let target = RecordingMigrationTarget()

            let report = await self.makeCoordinator(
                source: source, target: target, store: store
            ).run()
            XCTAssertEqual(report.outcome, .quarantined(.unsupportedCheckpointSchema))
            XCTAssertEqual(try Data(contentsOf: store.quarantineFileURL), future)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.checkpointFileURL.path))
            XCTAssertEqual(source.readCount, 0)
            XCTAssertEqual(target.adoptCount, 0)
        }

        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            var object = try self.jsonObject(for: self.makeCheckpoint(phase: .committed))
            object["resumeToken"] = "opaque"
            let extended = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try extended.write(to: store.checkpointFileURL)
            let target = RecordingMigrationTarget()

            let report = await self.makeCoordinator(
                source: self.makeSource(), target: target, store: store
            ).run()
            XCTAssertEqual(report.outcome, .quarantined(.unknownCheckpointExtension))
            XCTAssertEqual(try Data(contentsOf: store.quarantineFileURL), extended)
            XCTAssertEqual(target.adoptCount, 0)
        }
    }

    func testOversizedCheckpointIsQuarantinedWithoutBeingParsed() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            var oversized = Data("{".utf8)
            oversized.append(
                contentsOf: [UInt8](
                    repeating: 0x20,
                    count: EluFileMigrationCheckpointStore.maximumDocumentBytes
                )
            )
            try oversized.write(to: store.checkpointFileURL)
            let target = RecordingMigrationTarget()

            let report = await self.makeCoordinator(
                source: self.makeSource(), target: target, store: store
            ).run()
            XCTAssertEqual(report.outcome, .quarantined(.oversizedCheckpoint))
            XCTAssertEqual(try Data(contentsOf: store.quarantineFileURL).count, oversized.count)
            XCTAssertEqual(target.adoptCount, 0)
        }
    }

    func testFutureSourceSchemaIsRejectedBeforeAnyValueIsRead() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            let source = self.makeSource(schemaVersion: 2)
            let target = RecordingMigrationTarget()

            let report = await self.makeCoordinator(
                source: source, target: target, store: store
            ).run()
            XCTAssertEqual(report.outcome, .sourceRejected(.unsupportedSchema))
            XCTAssertEqual(report.phaseAfter, .unseen)
            XCTAssertEqual(source.readCount, 0)
            XCTAssertEqual(source.queueReadCount, 0)
            XCTAssertEqual(target.adoptCount, 0)
            XCTAssertEqual(try store.load(), .missing)
            XCTAssertFalse(try store.hasQuarantinedDocument())
        }
    }

    func testOversizedCorruptAndInvalidSourceValuesAreRejectedWithoutWriting() async throws {
        var large: [String: EluJSONValue] = [:]
        for index in 0 ..< 5 {
            large["key-\(index)"] = .string(String(repeating: "x", count: 60_000))
        }
        let oversized = makeSource()
        oversized.set(.superProperties, to: .json(.object(large)))

        let unreadable = makeSource()
        unreadable.failingKeys = [.groups]

        let unavailable = makeSource()
        unavailable.failingKeys = [.optedOut]
        unavailable.unavailableKeys = [.optedOut]

        let wrongShape = makeSource()
        wrongShape.set(.optedOut, to: .string("yes"))

        let emptyIdentifier = makeSource()
        emptyIdentifier.set(.anonymousId, to: .string(""))

        let badQueue = makeSource(
            queued: [
                EluLegacyQueuedRecord(position: 5, payload: Data([1])),
                EluLegacyQueuedRecord(position: 5, payload: Data([2])),
            ]
        )

        let queueFailure = makeSource()
        queueFailure.queueFails = true

        let cases: [(source: ScriptedLegacyStateSource, rejection: EluMigrationSourceRejection)] = [
            (oversized, .valueTooLarge(.superProperties)),
            (unreadable, .unreadable(.groups)),
            (unavailable, .unavailable),
            (wrongShape, .invalidValue(.optedOut)),
            (emptyIdentifier, .invalidValue(.anonymousId)),
            (badQueue, .invalidQueue),
            (queueFailure, .queueUnreadable),
        ]

        for testCase in cases {
            try await withTemporaryDirectory { directory in
                let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
                let target = RecordingMigrationTarget()
                let report = await self.makeCoordinator(
                    source: testCase.source, target: target, store: store
                ).run()
                XCTAssertEqual(report.outcome, .sourceRejected(testCase.rejection))
                XCTAssertEqual(report.phaseAfter, .unseen)
                XCTAssertEqual(target.adoptCount, 0)
                XCTAssertEqual(try store.load(), .missing)
                XCTAssertFalse(try store.hasQuarantinedDocument())
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: store.checkpointFileURL.path)
                )
            }
        }
    }

    func testQueuePrefixIsBoundedAndTruncationIsRecordedNotHidden() async throws {
        let overflow = EluMigrationQueuePrefix.maximumRecords + 5
        let queued = (0 ..< overflow).map { index in
            EluLegacyQueuedRecord(position: Int64(index), payload: Data([UInt8(index % 251)]))
        }
        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            let source = self.makeSource(queued: queued)
            let target = RecordingMigrationTarget()
            let metrics = RecordingMigrationMetrics()

            let report = await self.makeCoordinator(
                source: source, target: target, store: store, metrics: metrics
            ).run()
            XCTAssertEqual(report.outcome, .completed(importedLegacyState: true))
            XCTAssertEqual(source.lastQueueRequest?.maximumCount, EluMigrationQueuePrefix.maximumRecords + 1)
            let adopted = try XCTUnwrap(target.adoptedSnapshot)
            XCTAssertEqual(adopted.queuePrefix.records.count, EluMigrationQueuePrefix.maximumRecords)
            XCTAssertTrue(adopted.queuePrefix.truncated)
            XCTAssertEqual(
                adopted.queuePrefix.records.last?.position,
                Int64(EluMigrationQueuePrefix.maximumRecords - 1)
            )
            XCTAssertEqual(target.importedRecordCount, EluMigrationQueuePrefix.maximumRecords)
            XCTAssertTrue(
                metrics.recorded.contains(
                    .queuePrefixTruncated(retainedCount: EluMigrationQueuePrefix.maximumRecords)
                )
            )
            XCTAssertEqual(source.queued.count, overflow)
        }

        let heavy = (0 ..< 8).map { index in
            EluLegacyQueuedRecord(
                position: Int64(index),
                payload: Data(repeating: 0x41, count: 40 * 1_024)
            )
        }
        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            let source = self.makeSource(queued: heavy)
            let target = RecordingMigrationTarget()
            let report = await self.makeCoordinator(
                source: source, target: target, store: store
            ).run()
            XCTAssertEqual(report.outcome, .completed(importedLegacyState: true))
            let adopted = try XCTUnwrap(target.adoptedSnapshot)
            XCTAssertEqual(adopted.queuePrefix.records.count, 6)
            XCTAssertTrue(adopted.queuePrefix.truncated)
        }
    }

    func testReadBackMismatchOrAbsenceQuarantinesInsteadOfCompleting() async throws {
        for mode in [RecordingMigrationTarget.ReadBackMode.mismatchedIdentity, .missing] {
            try await withTemporaryDirectory { directory in
                let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
                let source = self.makeSource()
                let target = RecordingMigrationTarget()
                target.readBackMode = mode

                let report = await self.makeCoordinator(
                    source: source, target: target, store: store
                ).run()
                let expected: EluMigrationQuarantineReason = mode == .missing
                    ? .readBackMissing
                    : .readBackMismatch
                XCTAssertEqual(report.outcome, .quarantined(expected), "\(mode)")
                XCTAssertEqual(report.phaseAfter, .committed, "\(mode)")
                XCTAssertEqual(target.adoptCount, 1, "\(mode)")
                XCTAssertTrue(try store.hasQuarantinedDocument(), "\(mode)")
                XCTAssertEqual(try store.load(), .missing, "\(mode)")

                let quarantined = EluFileMigrationCheckpointStore.decode(
                    try Data(contentsOf: store.quarantineFileURL)
                )
                guard case let .loaded(document) = quarantined else {
                    return XCTFail("Expected the committed document to be preserved for \(mode)")
                }
                XCTAssertEqual(document.phase, .committed, "\(mode)")
                XCTAssertEqual(document.snapshot?.identity.anonymousId, "anon-legacy", "\(mode)")

                target.readBackMode = .faithful
                let later = await self.makeCoordinator(
                    source: source, target: target, store: store
                ).run()
                XCTAssertEqual(later.outcome, .quarantined(.priorQuarantine), "\(mode)")
                XCTAssertEqual(target.adoptCount, 1, "\(mode)")
                XCTAssertEqual(target.readBackCount, 1, "\(mode)")
            }
        }
    }

    func testTargetHoldingAnotherCheckpointIsNeverOverwritten() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            let source = self.makeSource()
            let target = RecordingMigrationTarget()
            let earlier = try self.makeCheckpoint(phase: .importing, checkpointId: "checkpoint-earlier")
            XCTAssertEqual(try target.adopt(earlier), .adopted)

            let report = await self.makeCoordinator(
                source: source, target: target, store: store
            ).run()
            XCTAssertEqual(report.outcome, .quarantined(.targetConflict))
            XCTAssertEqual(report.phaseAfter, .importing)
            XCTAssertEqual(target.adoptedCheckpointId, "checkpoint-earlier")
            XCTAssertEqual(target.adoptCount, 1)
            XCTAssertTrue(try store.hasQuarantinedDocument())
            XCTAssertEqual(try store.load(), .missing)
        }
    }

    func testCheckpointDocumentIsClosedVersionedAndRoundTrips() throws {
        let checkpoint = try makeCheckpoint(phase: .verified)
        let data = try EluStateCoding.encoder().encode(checkpoint)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), EluMigrationCheckpoint.persistedKeys)
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["phase"] as? String, "verified")
        XCTAssertTrue(object["completedAt"] is NSNull)
        let snapshot = try XCTUnwrap(object["snapshot"] as? [String: Any])
        XCTAssertEqual(Set(snapshot.keys), Set(["identity", "context", "stream", "queuePrefix"]))
        let identity = try XCTUnwrap(snapshot["identity"] as? [String: Any])
        XCTAssertEqual(Set(identity.keys), Set(["anonymousId", "userId", "optedOut"]))

        XCTAssertEqual(EluFileMigrationCheckpointStore.decode(data), .loaded(checkpoint))

        var nested = object
        var nestedIdentity = identity
        nestedIdentity["deviceId"] = "unexpected"
        var nestedSnapshot = snapshot
        nestedSnapshot["identity"] = nestedIdentity
        nested["snapshot"] = nestedSnapshot
        let extended = try JSONSerialization.data(withJSONObject: nested, options: [.sortedKeys])
        XCTAssertEqual(EluFileMigrationCheckpointStore.decode(extended), .unreadable(.invalid))

        var unseen = object
        unseen["phase"] = "unseen"
        let unseenData = try JSONSerialization.data(withJSONObject: unseen, options: [.sortedKeys])
        XCTAssertEqual(EluFileMigrationCheckpointStore.decode(unseenData), .unreadable(.invalid))

        XCTAssertThrowsError(
            try EluMigrationCheckpoint(
                checkpointId: "checkpoint-x",
                phase: .committed,
                source: checkpoint.source,
                snapshot: checkpoint.snapshot,
                importedAt: now
            )
        ) { error in
            XCTAssertEqual(error as? EluMigrationCheckpointError, .invalidPhase)
        }
        XCTAssertThrowsError(
            try EluMigrationCheckpoint(
                checkpointId: "checkpoint-x",
                phase: .importing,
                source: checkpoint.source,
                snapshot: nil,
                importedAt: now
            )
        ) { error in
            XCTAssertEqual(error as? EluMigrationCheckpointError, .invalidPhase)
        }
    }

    func testStoreSaveReplacesAtomicallyAndKeepsExistingQuarantine() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            let first = try self.makeCheckpoint(phase: .importing)
            try store.save(first)
            XCTAssertEqual(try store.load(), .loaded(first))

            let second = try self.makeCheckpoint(phase: .committed)
            try store.save(second)
            XCTAssertEqual(try store.load(), .loaded(second))
            let staged = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".staged") }
            XCTAssertTrue(staged.isEmpty)

            try store.quarantine()
            XCTAssertTrue(try store.hasQuarantinedDocument())
            XCTAssertEqual(try store.load(), .missing)

            let third = try self.makeCheckpoint(phase: .verified)
            try store.save(third)
            try store.quarantine()
            XCTAssertEqual(
                EluFileMigrationCheckpointStore.decode(try Data(contentsOf: store.quarantineFileURL)),
                .loaded(second)
            )
            XCTAssertEqual(try store.load(), .loaded(third))
        }
    }

    func testProcessRestartRebuildsTheCoordinatorAndTheStoreOverTheSameDirectory() async throws {
        try await withTemporaryDirectory { directory in
            let source = self.makeSource()
            // The target stands in for the runtime state, which outlives a
            // process restart the same way the checkpoint file does.
            let target = RecordingMigrationTarget()

            let firstStore = try EluFileMigrationCheckpointStore(directoryURL: directory)
            let interrupted = await self.makeCoordinator(
                source: source,
                target: target,
                store: firstStore,
                faultInjector: OneShotMigrationFaultInjector(point: .afterCheckpointWrite(.committed))
            ).run()
            XCTAssertEqual(interrupted.outcome, .interrupted(atPhase: .committed))
            XCTAssertEqual(target.adoptCount, 1)
            let adoptedCheckpointId = try XCTUnwrap(target.adoptedCheckpointId)

            // Nothing from the first process is carried over: the store is
            // opened again from the same directory and the coordinator is
            // built from scratch around it.
            let secondStore = try EluFileMigrationCheckpointStore(directoryURL: directory)
            let resumed = await self.makeCoordinator(
                source: source, target: target, store: secondStore
            ).run()
            XCTAssertEqual(resumed.outcome, .completed(importedLegacyState: true))
            XCTAssertEqual(resumed.phaseBefore, .committed)
            XCTAssertEqual(resumed.phaseAfter, .complete)
            XCTAssertEqual(resumed.sourceReadCount, 0)
            XCTAssertEqual(source.readCount, 9)
            XCTAssertEqual(source.queueReadCount, 1)
            XCTAssertEqual(target.adoptCount, 1)
            XCTAssertEqual(target.adoptedCheckpointId, adoptedCheckpointId)
            XCTAssertEqual(target.importedRecordCount, 3)

            let thirdStore = try EluFileMigrationCheckpointStore(directoryURL: directory)
            guard case let .loaded(persisted) = try thirdStore.load() else {
                return XCTFail("Expected the completed checkpoint to survive the restart")
            }
            XCTAssertEqual(persisted.phase, .complete)
            XCTAssertEqual(persisted.checkpointId, adoptedCheckpointId)
            XCTAssertEqual(persisted.snapshot?.identity.anonymousId, "anon-legacy")

            let settled = await self.makeCoordinator(
                source: source, target: target, store: thirdStore
            ).run()
            XCTAssertEqual(settled.outcome, .alreadyComplete)
            XCTAssertEqual(target.adoptCount, 1)
            XCTAssertEqual(target.importedRecordCount, 3)
        }
    }

    func testEmptyCheckpointDocumentIsQuarantinedRatherThanTreatedAsAbsent() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            try Data().write(to: store.checkpointFileURL)
            let source = self.makeSource()
            let target = RecordingMigrationTarget()

            let report = await self.makeCoordinator(
                source: source, target: target, store: store
            ).run()
            XCTAssertEqual(report.outcome, .quarantined(.malformedCheckpoint))
            XCTAssertEqual(source.readCount, 0)
            XCTAssertEqual(target.adoptCount, 0)
            XCTAssertTrue(try store.hasQuarantinedDocument())
            XCTAssertEqual(try Data(contentsOf: store.quarantineFileURL), Data())
        }
    }

    func testUnconfirmedDurabilityReportsTheLastAcknowledgedPhaseAndResumesFromDisk() async throws {
        try await withTemporaryDirectory { directory in
            let synchronizer = FlakyDirectorySynchronizer()
            // The importing document is written first; fail the directory
            // synchronisation that follows the committed document.
            synchronizer.fail(onCall: 2)
            let store = try EluFileMigrationCheckpointStore(
                directoryURL: directory,
                directorySynchronizer: synchronizer
            )
            let source = self.makeSource()
            let target = RecordingMigrationTarget()

            let interrupted = await self.makeCoordinator(
                source: source, target: target, store: store
            ).run()
            // The coordinator reports the last phase it saw acknowledged,
            // never a later one it could not confirm.
            XCTAssertEqual(interrupted.outcome, .interrupted(atPhase: .importing))
            XCTAssertEqual(target.adoptCount, 1)

            let reopened = try EluFileMigrationCheckpointStore(directoryURL: directory)
            guard case let .loaded(persisted) = try reopened.load() else {
                return XCTFail("Expected the replaced document to be readable")
            }
            XCTAssertEqual(persisted.phase, .committed)

            let resumed = await self.makeCoordinator(
                source: source, target: target, store: reopened
            ).run()
            XCTAssertEqual(resumed.outcome, .completed(importedLegacyState: true))
            XCTAssertEqual(resumed.phaseBefore, .committed)
            XCTAssertEqual(resumed.sourceReadCount, 0)
            XCTAssertEqual(target.adoptCount, 1)
            XCTAssertEqual(target.importedRecordCount, 3)
        }
    }

    func testCheckpointTimestampsMustNotMoveBackwards() throws {
        let checkpoint = try makeCheckpoint(phase: .verified)
        XCTAssertThrowsError(
            try EluMigrationCheckpoint(
                checkpointId: checkpoint.checkpointId,
                phase: .verified,
                source: checkpoint.source,
                snapshot: checkpoint.snapshot,
                importedAt: now,
                committedAt: now,
                verifiedAt: now.addingTimeInterval(-1)
            )
        ) { error in
            XCTAssertEqual(error as? EluMigrationCheckpointError, .invalidTimestamp)
        }

        var object = try jsonObject(for: checkpoint)
        object["committedAt"] = EluRFC3339.string(from: now.addingTimeInterval(-60))
        let reordered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertEqual(EluFileMigrationCheckpointStore.decode(reordered), .unreadable(.invalid))
    }

    func testBackwardsWallClockDoesNotStallAResumedMigration() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            let source = self.makeSource()
            let target = RecordingMigrationTarget()

            let interrupted = await self.makeCoordinator(
                source: source,
                target: target,
                store: store,
                faultInjector: OneShotMigrationFaultInjector(point: .afterCheckpointWrite(.importing))
            ).run()
            XCTAssertEqual(interrupted.outcome, .interrupted(atPhase: .importing))

            // The device clock steps back an hour between the two runs, so
            // every stamp the resumed run mints precedes the one on disk.
            let rolledBack = self.now.addingTimeInterval(-3_600)
            let metrics = RecordingMigrationMetrics()
            let resumed = await self.makeCoordinator(
                source: source, target: target, store: store, clock: { rolledBack }, metrics: metrics
            ).run()
            XCTAssertEqual(resumed.outcome, .completed(importedLegacyState: true))
            XCTAssertEqual(resumed.phaseBefore, .importing)
            XCTAssertEqual(resumed.phaseAfter, .complete)
            XCTAssertEqual(resumed.sourceReadCount, 0)
            XCTAssertEqual(target.adoptCount, 1)
            XCTAssertEqual(target.importedRecordCount, 3)
            XCTAssertFalse(try store.hasQuarantinedDocument())

            guard case let .loaded(persisted) = try store.load() else {
                return XCTFail("Expected the completed checkpoint to be readable")
            }
            XCTAssertEqual(persisted.phase, .complete)
            XCTAssertNoThrow(try persisted.validate())
            XCTAssertEqual(persisted.importedAt, self.now)
            XCTAssertEqual(persisted.committedAt, self.now)
            XCTAssertEqual(persisted.verifiedAt, self.now)
            XCTAssertEqual(persisted.completedAt, self.now)
            XCTAssertEqual(
                metrics.recorded.filter { metric in
                    if case .phaseStampClamped = metric { return true }
                    return false
                },
                [
                    .phaseStampClamped(.committed),
                    .phaseStampClamped(.verified),
                    .phaseStampClamped(.complete),
                ]
            )
        }

        // A clock that moves forward is still recorded as it is.
        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            let source = self.makeSource()
            let target = RecordingMigrationTarget()

            _ = await self.makeCoordinator(
                source: source,
                target: target,
                store: store,
                faultInjector: OneShotMigrationFaultInjector(point: .afterCheckpointWrite(.importing))
            ).run()

            let later = self.now.addingTimeInterval(90)
            let metrics = RecordingMigrationMetrics()
            let resumed = await self.makeCoordinator(
                source: source, target: target, store: store, clock: { later }, metrics: metrics
            ).run()
            XCTAssertEqual(resumed.outcome, .completed(importedLegacyState: true))
            XCTAssertFalse(
                metrics.recorded.contains { metric in
                    if case .phaseStampClamped = metric { return true }
                    return false
                }
            )

            guard case let .loaded(persisted) = try store.load() else {
                return XCTFail("Expected the completed checkpoint to be readable")
            }
            XCTAssertEqual(persisted.importedAt, self.now)
            XCTAssertEqual(persisted.committedAt, later)
            XCTAssertEqual(persisted.verifiedAt, later)
            XCTAssertEqual(persisted.completedAt, later)
        }
    }

    func testStoredCheckpointWithReversedStampsIsQuarantined() async throws {
        try await withTemporaryDirectory { directory in
            let store = try EluFileMigrationCheckpointStore(directoryURL: directory)
            var object = try self.jsonObject(for: self.makeCheckpoint(phase: .committed))
            object["committedAt"] = EluRFC3339.string(from: self.now.addingTimeInterval(-60))
            let reversed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try reversed.write(to: store.checkpointFileURL)
            let source = self.makeSource()
            let target = RecordingMigrationTarget()

            let report = await self.makeCoordinator(
                source: source, target: target, store: store
            ).run()
            XCTAssertEqual(report.outcome, .quarantined(.invalidCheckpoint))
            XCTAssertEqual(report.phaseAfter, .unseen)
            XCTAssertEqual(source.readCount, 0)
            XCTAssertEqual(target.adoptCount, 0)
            XCTAssertEqual(try Data(contentsOf: store.quarantineFileURL), reversed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.checkpointFileURL.path))

            let later = await self.makeCoordinator(
                source: source, target: target, store: store
            ).run()
            XCTAssertEqual(later.outcome, .quarantined(.priorQuarantine))
            XCTAssertEqual(target.adoptCount, 0)
        }
    }

    // MARK: - Helpers

    private func makeCoordinator(
        source: ScriptedLegacyStateSource,
        target: RecordingMigrationTarget,
        store: EluFileMigrationCheckpointStore,
        clock: (@Sendable () -> Date)? = nil,
        metrics: RecordingMigrationMetrics? = nil,
        faultInjector: OneShotMigrationFaultInjector? = nil
    ) -> EluMigrationCoordinator {
        let checkpointIds = LockedCounter(prefix: "checkpoint-")
        return EluMigrationCoordinator(
            source: source,
            target: target,
            store: store,
            clock: clock ?? { self.now },
            checkpointIdGenerator: { checkpointIds.next() },
            streamIdGenerator: { "stream-minted" },
            metrics: metrics,
            faultInjector: faultInjector
        )
    }

    private func makeSource(
        schemaVersion: Int = 1,
        queued: [EluLegacyQueuedRecord]? = nil
    ) -> ScriptedLegacyStateSource {
        ScriptedLegacyStateSource(
            descriptor: EluLegacyStateSourceDescriptor(
                sourceSchema: "fixture-layout",
                schemaVersion: schemaVersion
            ),
            values: [
                .anonymousId: .string("anon-legacy"),
                .userId: .string("user-42"),
                .optedOut: .bool(false),
                .superProperties: .json(.object(["plan": .string("pro")])),
                .groups: .json(.object(["organization": .string("org-1")])),
                .flagPersonProperties: .json(.object(["beta": .bool(true)])),
                .flagGroupProperties: .json(.object(["organization": .object(["tier": .integer(2)])])),
            ],
            queued: queued ?? [
                EluLegacyQueuedRecord(position: 10, payload: Data("event-a".utf8)),
                EluLegacyQueuedRecord(position: 11, payload: Data("event-b".utf8)),
                EluLegacyQueuedRecord(position: 12, payload: Data("event-c".utf8)),
            ]
        )
    }

    private func makeCheckpoint(
        phase: EluMigrationPhase,
        checkpointId: String = "checkpoint-fixture"
    ) throws -> EluMigrationCheckpoint {
        let snapshot = try EluMigrationSnapshot(
            identity: EluMigrationIdentitySnapshot(
                anonymousId: "anon-legacy",
                userId: "user-42",
                optedOut: false
            ),
            context: EluMigrationContextSnapshot(
                superProperties: ["plan": .string("pro")],
                groups: ["organization": "org-1"]
            ),
            stream: EluMigrationStreamSnapshot(streamId: "stream-minted", nextSequence: 4),
            queuePrefix: EluMigrationQueuePrefix(
                records: [EluMigrationQueuedRecord(position: 10, payload: Data("event-a".utf8))],
                truncated: false
            )
        )
        let reached: [EluMigrationPhase]
        switch phase {
        case .unseen, .importing:
            reached = []
        case .committed:
            reached = [.committed]
        case .verified:
            reached = [.committed, .verified]
        case .complete:
            reached = [.committed, .verified, .complete]
        }
        return try EluMigrationCheckpoint(
            checkpointId: checkpointId,
            phase: phase,
            source: EluMigrationSourceRecord(sourceSchema: "fixture-layout", schemaVersion: 1),
            snapshot: snapshot,
            importedAt: now,
            committedAt: reached.contains(.committed) ? now : nil,
            verifiedAt: reached.contains(.verified) ? now : nil,
            completedAt: reached.contains(.complete) ? now : nil
        )
    }

    private func jsonObject(for checkpoint: EluMigrationCheckpoint) throws -> [String: Any] {
        let data = try EluStateCoding.encoder().encode(checkpoint)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func withTemporaryDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "elu-migration-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await operation(directory)
    }
}

private final class ScriptedLegacyStateSource: EluLegacyStateSource, @unchecked Sendable {
    struct QueueRequest: Equatable {
        var maximumCount: Int
        var maximumBytes: Int
    }

    let descriptor: EluLegacyStateSourceDescriptor

    private let lock = NSLock()
    private var values: [EluLegacyStateKey: EluLegacyStateValue]
    private var queuedRecords: [EluLegacyQueuedRecord]
    private var reads = 0
    private var queueReads = 0
    private var lastRequest: QueueRequest?
    private var failing: Set<EluLegacyStateKey> = []
    private var unavailable: Set<EluLegacyStateKey> = []
    private var queueFailure = false

    init(
        descriptor: EluLegacyStateSourceDescriptor = EluLegacyStateSourceDescriptor(
            sourceSchema: "fixture-layout",
            schemaVersion: 1
        ),
        values: [EluLegacyStateKey: EluLegacyStateValue],
        queued: [EluLegacyQueuedRecord] = []
    ) {
        self.descriptor = descriptor
        self.values = values
        queuedRecords = queued
    }

    var readCount: Int { withLock { reads } }
    var queueReadCount: Int { withLock { queueReads } }
    var lastQueueRequest: QueueRequest? { withLock { lastRequest } }
    var queued: [EluLegacyQueuedRecord] { withLock { queuedRecords } }

    var failingKeys: Set<EluLegacyStateKey> {
        get { withLock { failing } }
        set { withLock { failing = newValue } }
    }

    var unavailableKeys: Set<EluLegacyStateKey> {
        get { withLock { unavailable } }
        set { withLock { unavailable = newValue } }
    }

    var queueFails: Bool {
        get { withLock { queueFailure } }
        set { withLock { queueFailure = newValue } }
    }

    func set(_ key: EluLegacyStateKey, to value: EluLegacyStateValue?) {
        withLock { values[key] = value }
    }

    func readValue(for key: EluLegacyStateKey, maximumBytes _: Int) throws -> EluLegacyStateValue? {
        try withLock {
            reads += 1
            if unavailable.contains(key) {
                throw EluLegacyStateSourceError.unavailable
            }
            if failing.contains(key) {
                throw EluLegacyStateSourceError.unreadable(key)
            }
            return values[key]
        }
    }

    func readQueuedRecords(maximumCount: Int, maximumBytes: Int) throws -> [EluLegacyQueuedRecord] {
        try withLock {
            queueReads += 1
            lastRequest = QueueRequest(maximumCount: maximumCount, maximumBytes: maximumBytes)
            if queueFailure {
                throw EluLegacyStateSourceError.queueUnreadable
            }
            var result: [EluLegacyQueuedRecord] = []
            var bytes = 0
            for record in queuedRecords {
                guard result.count < maximumCount, bytes + record.payload.count <= maximumBytes else {
                    break
                }
                result.append(record)
                bytes += record.payload.count
            }
            return result
        }
    }

    private func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private final class RecordingMigrationTarget: EluMigrationTarget, @unchecked Sendable {
    enum ReadBackMode: Equatable {
        case faithful
        case missing
        case mismatchedIdentity
    }

    private let lock = NSLock()
    private var checkpointId: String?
    private var snapshot: EluMigrationSnapshot?
    private var importedRecords = 0
    private var adopts = 0
    private var readBacks = 0
    private var mode = ReadBackMode.faithful

    var adoptedCheckpointId: String? { withLock { checkpointId } }
    var adoptedSnapshot: EluMigrationSnapshot? { withLock { snapshot } }
    var importedRecordCount: Int { withLock { importedRecords } }
    var adoptCount: Int { withLock { adopts } }
    var readBackCount: Int { withLock { readBacks } }

    var readBackMode: ReadBackMode {
        get { withLock { mode } }
        set { withLock { mode = newValue } }
    }

    func adopt(_ checkpoint: EluMigrationCheckpoint) throws -> EluMigrationAdoptionResult {
        try withLock {
            if let checkpointId {
                guard checkpointId == checkpoint.checkpointId else {
                    throw EluMigrationTargetError.checkpointConflict
                }
                return .alreadyAdopted
            }
            guard let incoming = checkpoint.snapshot else {
                throw EluMigrationTargetError.unavailable
            }
            adopts += 1
            checkpointId = checkpoint.checkpointId
            snapshot = incoming
            importedRecords += incoming.queuePrefix.records.count
            return .adopted
        }
    }

    func readBack() throws -> EluMigrationReadBack? {
        try withLock {
            readBacks += 1
            guard let checkpointId, let snapshot else { return nil }
            switch mode {
            case .missing:
                return nil
            case .faithful:
                return EluMigrationReadBack(
                    checkpointId: checkpointId,
                    identity: snapshot.identity,
                    context: snapshot.context,
                    stream: snapshot.stream,
                    importedQueueRecordCount: importedRecords
                )
            case .mismatchedIdentity:
                return EluMigrationReadBack(
                    checkpointId: checkpointId,
                    identity: try EluMigrationIdentitySnapshot(
                        anonymousId: "anon-other",
                        userId: snapshot.identity.userId,
                        optedOut: snapshot.identity.optedOut
                    ),
                    context: snapshot.context,
                    stream: snapshot.stream,
                    importedQueueRecordCount: importedRecords
                )
            }
        }
    }

    private func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private final class OneShotMigrationFaultInjector: EluMigrationFaultInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private let point: EluMigrationFaultPoint
    private var hasFired = false

    init(point: EluMigrationFaultPoint) {
        self.point = point
    }

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasFired
    }

    func hit(_ candidate: EluMigrationFaultPoint) throws {
        lock.lock()
        defer { lock.unlock() }
        if candidate == point, !hasFired {
            hasFired = true
            throw EluMigrationCoordinatorError.faultInjected(candidate)
        }
    }
}

private final class RecordingMigrationMetrics: EluMigrationMetricsRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: [EluMigrationMetric] = []

    var recorded: [EluMigrationMetric] {
        lock.lock()
        defer { lock.unlock() }
        return metrics
    }

    func record(_ metric: EluMigrationMetric) {
        lock.lock()
        metrics.append(metric)
        lock.unlock()
    }
}

private enum FlakyDirectorySyncError: Error, Equatable {
    case forcedFailure
}

/// Makes the directory synchronisation that follows a chosen write fail, so a
/// save can be left visible but unconfirmed.
private final class FlakyDirectorySynchronizer: EluDirectorySynchronizing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var failingCalls: Set<Int> = []

    func fail(onCall call: Int) {
        lock.lock()
        defer { lock.unlock() }
        failingCalls.insert(call)
    }

    func synchronize(directoryURL _: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if failingCalls.remove(calls) != nil {
            throw FlakyDirectorySyncError.forcedFailure
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let prefix: String
    private var value = 0

    init(prefix: String) {
        self.prefix = prefix
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return "\(prefix)\(value)"
    }
}
