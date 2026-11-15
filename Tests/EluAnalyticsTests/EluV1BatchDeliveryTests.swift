import Foundation
#if canImport(UIKit)
import UIKit
#endif
import XCTest
@testable import EluAnalytics

final class EluV1BatchDeliveryTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_786_147_200)

    func testAuthorizationSnapshotRejectsUntrustedShapeAndInvalidLimits() throws {
        let https = try XCTUnwrap(URL(string: "https://ingest.elu.dev/v1/events"))
        XCTAssertNoThrow(
            try EluV1BatchAuthorizationSnapshot(
                siteKey: "elu_pk_live_test",
                eventsEndpoint: https,
                expiresAt: capturedAt.addingTimeInterval(60),
                eventBatchCount: 1_000,
                eventBatchBytes: 10_485_760
            )
        )
        for endpoint in [
            "http://ingest.elu.dev/v1/events",
            "https://user:password@ingest.elu.dev/v1/events",
            "https://ingest.elu.dev/v1/events#fragment",
            "https://other.elu.dev/v1/events",
            "https://ingest.elu.dev/v1/replay",
        ] {
            XCTAssertThrowsError(
                try EluV1BatchAuthorizationSnapshot(
                    siteKey: "elu_pk_live_test",
                    eventsEndpoint: try XCTUnwrap(URL(string: endpoint)),
                    expiresAt: capturedAt.addingTimeInterval(60),
                    eventBatchCount: 100,
                    eventBatchBytes: 100_000
                )
            )
        }
        XCTAssertThrowsError(
            try EluV1BatchAuthorizationSnapshot(
                siteKey: "elu_pk_live_test\nAuthorization: Bearer other",
                eventsEndpoint: https,
                expiresAt: capturedAt.addingTimeInterval(60),
                eventBatchCount: 0,
                eventBatchBytes: 1_023
            )
        )
    }

    func testCrossPlatformRequestIdentifierVector() throws {
        let requestId = try EluV1BatchDeliveryCoordinator.requestIdForFields(
            streamId: "stream_élü",
            schemaVersion: "1",
            contractVersion: "1",
            platform: "browser",
            runtimeName: "javascript",
            runtimeVersion: "1.2.3",
            facadeName: "elu",
            facadeVersion: "0.1.0",
            build: "build-β",
            records: [
                (kind: 1, sequence: 1, recordId: "rec-event-1"),
                (kind: 4, sequence: 2, recordId: "rec-mutation-2"),
            ]
        )
        XCTAssertEqual(
            requestId,
            "request_82bb0b782bd26908053d215014afe39ce34b66560eec3d2e151d8e108eb6dc6b"
        )
    }

    func testLargestExactRequestPrefixAndOneByteOverHeadResolution() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        let records = try await appendRecords(queue, count: 2, valueBytes: 900)
        let snapshot = try await queue.snapshot()
        let oneRecordBody = try EluQueueBatchCodec.encodeBatch(
            requestId: "request_\(String(repeating: "a", count: 64))",
            streamId: snapshot.streamId,
            sentAt: capturedAt,
            versions: records[0].versions,
            records: [records[0]]
        )
        let twoRecordBody = try EluQueueBatchCodec.encodeBatch(
            requestId: "request_\(String(repeating: "a", count: 64))",
            streamId: snapshot.streamId,
            sentAt: capturedAt,
            versions: records[0].versions,
            records: records
        )
        XCTAssertGreaterThan(oneRecordBody.count, 1_024)
        XCTAssertGreaterThan(twoRecordBody.count, oneRecordBody.count)

        let transport = TestBatchTransport(replies: [.accept, .accept])
        let clock = TestBatchClock(wall: capturedAt, monotonic: 1_000)
        let coordinator = try coordinator(
            queue: queue,
            byteLimit: oneRecordBody.count,
            transport: transport,
            clock: clock
        )
        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 2, terminallyDiscarded: 0))
        let sequences = await transport.recordSequences()
        XCTAssertEqual(sequences, [[0], [1]])
        let afterPass = try await queue.snapshot()
        XCTAssertEqual(afterPass.queuedCount, 0)

        await queue.close()

        let oversizeDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: oversizeDirectory) }
        let oversizeQueue = try await makeQueue(directory: oversizeDirectory)
        _ = try await appendRecords(oversizeQueue, count: 1, valueBytes: 900)
        _ = try await appendRecords(oversizeQueue, count: 1, valueBytes: 8)
        let oversizeTransport = TestBatchTransport(replies: [.accept])
        let oversizeCoordinator = try self.coordinator(
            queue: oversizeQueue,
            byteLimit: oneRecordBody.count - 1,
            transport: oversizeTransport,
            clock: clock
        )
        let oversizeResult = await oversizeCoordinator.trigger()
        XCTAssertEqual(oversizeResult, .resolved(delivered: 1, terminallyDiscarded: 1))
        let oversizeSequences = await oversizeTransport.recordSequences()
        XCTAssertEqual(oversizeSequences, [[1]])
        // Sequence 0 never reaches the server, so the rest of the queue goes
        // on a new wire stream that the server starts at sequence 1.
        let oversizeStreams = await oversizeTransport.streamIds()
        XCTAssertEqual(oversizeStreams, ["stream_moved_1"])
        let movedStream = try await oversizeQueue.eventDeliveryStream()
        XCTAssertEqual(movedStream.streamId, "stream_moved_1")
        XCTAssertEqual(movedStream.installationStreamId, "stream_delivery_test")
        let afterOversize = try await oversizeQueue.snapshot()
        XCTAssertEqual(afterOversize.queuedCount, 0)
        await oversizeQueue.close()
    }

    func testPackingStopsAtCaptureVersionBoundary() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 2, versions: versions(build: "build-a"))
        _ = try await appendRecords(queue, count: 1, versions: versions(build: "build-b"))
        let transport = TestBatchTransport(replies: [.accept, .accept])
        let coordinator = try coordinator(queue: queue, transport: transport)

        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 3, terminallyDiscarded: 0))
        let sequences = await transport.recordSequences()
        XCTAssertEqual(sequences, [[0, 1], [2]])
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 0)
        await queue.close()
    }

    func testPassCapsAtElevenRequestsAndContinuesOnNextTrigger() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        for index in 0 ..< 12 {
            _ = try await appendRecords(
                queue,
                count: 1,
                versions: versions(build: "bounded-\(index)")
            )
        }
        let transport = TestBatchTransport(replies: Array(repeating: .accept, count: 12))
        let coordinator = try self.coordinator(queue: queue, transport: transport)

        let first = await coordinator.trigger()
        XCTAssertEqual(first, .bounded(delivered: 11, terminallyDiscarded: 0))
        let callsAfterFirst = await transport.callCount()
        XCTAssertEqual(callsAfterFirst, 11)
        let afterFirst = try await queue.snapshot()
        XCTAssertEqual(afterFirst.headSequence, 11)
        XCTAssertEqual(afterFirst.queuedCount, 1)

        let second = await coordinator.trigger()
        XCTAssertEqual(second, .resolved(delivered: 1, terminallyDiscarded: 0))
        let callsAfterSecond = await transport.callCount()
        XCTAssertEqual(callsAfterSecond, 12)
        let afterSecond = try await queue.snapshot()
        XCTAssertEqual(afterSecond.queuedCount, 0)
        await queue.close()
    }

    func testPassCapsAtSixtyFourLocalResolutionsAndContinuesInOrder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        // Every record is larger than one request may be.
        _ = try await appendRecords(queue, count: 65, valueBytes: 2_000)
        let transport = TestBatchTransport(replies: [])
        let coordinator = try self.coordinator(
            queue: queue,
            byteLimit: EluV1BatchAuthorizationSnapshot.minimumBatchBytes,
            transport: transport
        )

        let first = await coordinator.trigger()
        XCTAssertEqual(first, .bounded(delivered: 0, terminallyDiscarded: 64))
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 0)
        let afterFirst = try await queue.snapshot()
        XCTAssertEqual(afterFirst.headSequence, 64)
        XCTAssertEqual(afterFirst.queuedCount, 1)

        let second = await coordinator.trigger()
        XCTAssertEqual(second, .resolved(delivered: 0, terminallyDiscarded: 1))
        let afterSecond = try await queue.snapshot()
        XCTAssertEqual(afterSecond.queuedCount, 0)
        await queue.close()
    }

    func testRequestIdentityIsStableAcrossQueueRestartAndChangesAfterSplit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 3)
        let firstTransport = TestBatchTransport(replies: [.network])
        let first = try coordinator(queue: queue, transport: firstTransport)
        guard case .deferred = await first.trigger() else {
            return XCTFail("Expected a deferred network retry")
        }
        let firstRequestIds = await firstTransport.requestIds()
        let initialRequestId = try XCTUnwrap(firstRequestIds.first)
        await first.cancel()
        await queue.close()

        queue = try await makeQueue(directory: directory)
        let secondTransport = TestBatchTransport(replies: [.http(413, nil), .accept, .accept])
        let second = try coordinator(queue: queue, transport: secondTransport)
        let splitResult = await second.trigger()
        XCTAssertEqual(splitResult, .resolved(delivered: 3, terminallyDiscarded: 0))
        let ids = await secondTransport.requestIds()
        XCTAssertEqual(ids.first, initialRequestId)
        XCTAssertEqual(Set(ids).count, 3)
        let splitSequences = await secondTransport.recordSequences()
        XCTAssertEqual(splitSequences, [[0, 1, 2], [0, 1], [2]])
        await queue.close()
    }

    func testNested413SplitsCeilingFirstAndSingleRecordIsTerminal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 5)
        let transport = TestBatchTransport(
            replies: [
                .http(413, nil),
                .http(413, nil),
                .accept,
                .accept,
                .accept,
            ]
        )
        let coordinator = try coordinator(queue: queue, transport: transport)
        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 5, terminallyDiscarded: 0))
        let sequences = await transport.recordSequences()
        XCTAssertEqual(sequences, [[0, 1, 2, 3, 4], [0, 1, 2], [0, 1], [2], [3, 4]])
        await queue.close()

        let oneDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: oneDirectory) }
        let oneQueue = try await makeQueue(directory: oneDirectory)
        _ = try await appendRecords(oneQueue, count: 1)
        let oneTransport = TestBatchTransport(replies: [.http(413, nil)])
        let oneCoordinator = try self.coordinator(queue: oneQueue, transport: oneTransport)
        let oneResult = await oneCoordinator.trigger()
        XCTAssertEqual(oneResult, .resolved(delivered: 0, terminallyDiscarded: 1))
        let oneSnapshot = try await oneQueue.snapshot()
        XCTAssertEqual(oneSnapshot.queuedCount, 0)
        await oneQueue.close()
    }

    func testThousandRecordAll413PassMakesExactHeadProgressAndContinues() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(
            queue,
            count: 1_000,
            fixedPropertyKey: "delivery_stress_value"
        )
        let transport = TestBatchTransport(
            replies: Array(repeating: .http(413, nil), count: 22)
        )
        let coordinator = try self.coordinator(
            queue: queue,
            byteLimit: EluV1BatchAuthorizationSnapshot.maximumBatchBytes,
            transport: transport
        )

        let first = await coordinator.trigger()
        XCTAssertEqual(first, .bounded(delivered: 0, terminallyDiscarded: 1))
        let afterFirst = try await queue.snapshot()
        XCTAssertEqual(afterFirst.headSequence, 1)
        XCTAssertEqual(afterFirst.queuedCount, 999)
        let firstCallCount = await transport.callCount()
        XCTAssertEqual(firstCallCount, 11)

        let second = await coordinator.trigger()
        XCTAssertEqual(second, .bounded(delivered: 0, terminallyDiscarded: 1))
        let afterSecond = try await queue.snapshot()
        XCTAssertEqual(afterSecond.headSequence, 2)
        XCTAssertEqual(afterSecond.queuedCount, 998)

        let sequences = await transport.recordSequences()
        XCTAssertEqual(sequences.count, 22)
        XCTAssertEqual(sequences[0].count, 1_000)
        XCTAssertEqual(sequences[10], [0])
        XCTAssertEqual(sequences[11].count, 999)
        XCTAssertEqual(sequences[21], [1])
        XCTAssertTrue(sequences.prefix(11).allSatisfy { $0.first == 0 })
        XCTAssertTrue(sequences.suffix(11).allSatisfy { $0.first == 1 })
        let streams = await transport.streamIds()
        XCTAssertTrue(streams.prefix(11).allSatisfy { $0 == "stream_delivery_test" })
        XCTAssertTrue(streams.suffix(11).allSatisfy { $0 == "stream_moved_1" })
        await queue.close()
    }

    func test413SplitKeepsARecordThatAgedAndTheServerResolvesIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestBatchClock(wall: capturedAt, monotonic: 0)
        let queue = try await makeQueue(directory: directory, clock: clock.source.wallNow)
        _ = try await appendRecords(queue, count: 1)
        clock.setWall(capturedAt.addingTimeInterval(100))
        _ = try await appendRecords(queue, count: 2)

        let initialWall = capturedAt.addingTimeInterval(
            EluV1BatchDeliveryCoordinator.maximumRecordAgeSeconds - 1
        )
        clock.setWall(initialWall)
        let transport = TestBatchTransport(
            replies: [
                .httpAndSetWall(413, nil, clock, initialWall.addingTimeInterval(2)),
                .rejectSequences([0], "record-too-old"),
                .accept,
            ]
        )
        let coordinator = try self.coordinator(
            queue: queue,
            transport: transport,
            clock: clock
        )

        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 2, terminallyDiscarded: 1))
        let sequences = await transport.recordSequences()
        XCTAssertEqual(sequences, [[0, 1, 2], [0, 1], [2]])
        let streams = await transport.streamIds()
        XCTAssertEqual(streams, Array(repeating: "stream_delivery_test", count: 3))
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 0)
        await queue.close()
    }

    func testStrictRequestBoundAcknowledgementRejectsMismatchDuplicateAndOversize() async throws {
        for reply in [
            TestBatchReply.mismatchedAcknowledgement,
            .duplicateAcknowledgementKey,
            .oversizedResponse,
        ] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let queue = try await makeQueue(directory: directory)
            _ = try await appendRecords(queue, count: 1)
            let transport = TestBatchTransport(replies: [reply])
            let coordinator = try coordinator(queue: queue, transport: transport)
            let result = await coordinator.trigger()
            XCTAssertEqual(result, .preserved(.protocolFailure))
            let snapshot = try await queue.snapshot()
            XCTAssertEqual(snapshot.queuedCount, 1)
            await queue.close()
        }
    }

    func testTerminalOutcomeCodeWithTrailingLineTerminatorDeletesNothing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 1)
        let transport = TestBatchTransport(
            replies: [.terminallyRejectWithCode("invalid-record\n")]
        )
        let coordinator = try self.coordinator(queue: queue, transport: transport)

        let result = await coordinator.trigger()
        XCTAssertEqual(result, .preserved(.protocolFailure))
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.headSequence, 0)
        XCTAssertEqual(snapshot.queuedCount, 1)
        let repeated = await coordinator.trigger()
        XCTAssertEqual(repeated, result)
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 1)
        await queue.close()
    }

    func testPartialAcknowledgementDeletesOnlyResolvedPrefixAndDefersRetryableHead() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 3)
        let transport = TestBatchTransport(replies: [.partialRetry, .accept])
        let clock = TestBatchClock(wall: capturedAt, monotonic: 10_000)
        let coordinator = try coordinator(
            queue: queue,
            transport: transport,
            clock: clock,
            randomUnit: 0
        )
        guard case let .deferred(deadline) = await coordinator.trigger() else {
            return XCTFail("Expected retryable-head deferral")
        }
        // A valid retryable acknowledgement without Retry-After uses backoff only.
        XCTAssertEqual(deadline, 500_010_000)
        let partialSnapshot = try await queue.snapshot()
        XCTAssertEqual(partialSnapshot.headSequence, 1)
        let initialSequences = await transport.recordSequences()
        XCTAssertEqual(initialSequences, [[0, 1, 2]])
        clock.setMonotonic(deadline)
        let retryResult = await coordinator.trigger()
        XCTAssertEqual(retryResult, .resolved(delivered: 2, terminallyDiscarded: 0))
        let retrySequences = await transport.recordSequences()
        XCTAssertEqual(retrySequences, [[0, 1, 2], [1, 2]])
        let finalSnapshot = try await queue.snapshot()
        XCTAssertEqual(finalSnapshot.queuedCount, 0)
        await coordinator.cancel()
        await queue.close()
    }

    func testRetryableAcknowledgementHonorsHeaderAndRejectsInvalidOrResolvedHeader() async throws {
        let validDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: validDirectory) }
        let validQueue = try await makeQueue(directory: validDirectory)
        _ = try await appendRecords(validQueue, count: 2)
        let validTransport = TestBatchTransport(replies: [.partialRetryAfter("30")])
        let validClock = TestBatchClock(wall: capturedAt, monotonic: 200)
        let validCoordinator = try coordinator(
            queue: validQueue,
            transport: validTransport,
            clock: validClock,
            randomUnit: 0
        )
        let validResult = await validCoordinator.trigger()
        XCTAssertEqual(
            validResult,
            .deferred(untilMonotonicNanoseconds: 30_000_000_200)
        )
        let validSnapshot = try await validQueue.snapshot()
        XCTAssertEqual(validSnapshot.headSequence, 1)
        await validCoordinator.cancel()
        await validQueue.close()

        for reply in [
            TestBatchReply.partialRetryAfter("not-a-delay"),
            .partialRetryWithDuplicateRetryAfter,
            .acceptWithRetryAfter("30"),
            .acceptWithDuplicateRetryAfter,
        ] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let queue = try await makeQueue(directory: directory)
            _ = try await appendRecords(queue, count: 2)
            let transport = TestBatchTransport(replies: [reply])
            let coordinator = try self.coordinator(queue: queue, transport: transport)
            let result = await coordinator.trigger()
            XCTAssertEqual(result, .preserved(.protocolFailure))
            let snapshot = try await queue.snapshot()
            XCTAssertEqual(snapshot.headSequence, 0)
            XCTAssertEqual(snapshot.queuedCount, 2)
            await queue.close()
        }
    }

    func testNetworkAnd429RetryUseMonotonicDeadlineAndStableRequestIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 1)
        let transport = TestBatchTransport(replies: [.network, .http(429, "30"), .accept])
        let clock = TestBatchClock(wall: capturedAt, monotonic: 100)
        let coordinator = try coordinator(
            queue: queue,
            transport: transport,
            clock: clock,
            randomUnit: 0
        )

        guard case let .deferred(networkDeadline) = await coordinator.trigger() else {
            return XCTFail("Expected network deferral")
        }
        XCTAssertEqual(networkDeadline, 500_000_100)
        let earlyNetworkResult = await coordinator.trigger()
        XCTAssertEqual(earlyNetworkResult, .deferred(untilMonotonicNanoseconds: networkDeadline))
        let firstCallCount = await transport.callCount()
        XCTAssertEqual(firstCallCount, 1)

        clock.setMonotonic(networkDeadline)
        guard case let .deferred(rateDeadline) = await coordinator.trigger() else {
            return XCTFail("Expected rate-limit deferral")
        }
        XCTAssertEqual(rateDeadline, networkDeadline + 30_000_000_000)
        clock.setWall(capturedAt.addingTimeInterval(-86_400))
        clock.setMonotonic(rateDeadline - 1)
        let earlyRateResult = await coordinator.trigger()
        XCTAssertEqual(earlyRateResult, .deferred(untilMonotonicNanoseconds: rateDeadline))
        let secondCallCount = await transport.callCount()
        XCTAssertEqual(secondCallCount, 2)

        clock.setMonotonic(rateDeadline)
        let finalResult = await coordinator.trigger()
        XCTAssertEqual(finalResult, .resolved(delivered: 1, terminallyDiscarded: 0))
        let ids = await transport.requestIds()
        XCTAssertEqual(Set(ids).count, 1)
        let finalSnapshot = try await queue.snapshot()
        XCTAssertEqual(finalSnapshot.queuedCount, 0)
        await coordinator.cancel()
        await queue.close()
    }

    func testValid5xxResponseSchedulesBackoffAndRetriesStableRequest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 1)
        let transport = TestBatchTransport(replies: [.http(503, nil), .accept])
        let clock = TestBatchClock(wall: capturedAt, monotonic: 25)
        let coordinator = try self.coordinator(
            queue: queue,
            transport: transport,
            clock: clock,
            randomUnit: 0
        )

        guard case let .deferred(deadline) = await coordinator.trigger() else {
            return XCTFail("Expected 5xx retry")
        }
        XCTAssertEqual(deadline, 500_000_025)
        clock.setMonotonic(deadline)
        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 1, terminallyDiscarded: 0))
        let ids = await transport.requestIds()
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 1)
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 0)
        await coordinator.cancel()
        await queue.close()
    }

    func testRetryAfterTheHeadAgedResendsTheSameRequest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestBatchClock(wall: capturedAt, monotonic: 10)
        let queue = try await makeQueue(directory: directory, clock: clock.source.wallNow)
        _ = try await appendRecords(queue, count: 1)
        clock.setWall(capturedAt.addingTimeInterval(100))
        _ = try await appendRecords(queue, count: 2)
        clock.setWall(
            capturedAt.addingTimeInterval(
                EluV1BatchDeliveryCoordinator.maximumRecordAgeSeconds - 1
            )
        )
        let transport = TestBatchTransport(
            replies: [.network, .rejectSequences([0], "record-too-old")]
        )
        let coordinator = try self.coordinator(
            queue: queue,
            transport: transport,
            clock: clock,
            randomUnit: 0
        )

        guard case let .deferred(deadline) = await coordinator.trigger() else {
            return XCTFail("Expected network retry")
        }
        clock.setWall(
            capturedAt.addingTimeInterval(
                EluV1BatchDeliveryCoordinator.maximumRecordAgeSeconds + 1
            )
        )
        clock.setMonotonic(deadline)
        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 2, terminallyDiscarded: 1))
        let sequences = await transport.recordSequences()
        XCTAssertEqual(sequences, [[0, 1, 2], [0, 1, 2]])
        let ids = await transport.requestIds()
        XCTAssertEqual(Set(ids).count, 1)
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 0)
        await coordinator.cancel()
        await queue.close()
    }

    func testRetryAfterTheHeadOutlivedTheServerOutcomeRemovesOnlyTheHead() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestBatchClock(wall: capturedAt, monotonic: 10, holdsTimers: true)
        let queue = try await makeQueue(directory: directory, clock: clock.source.wallNow)
        _ = try await appendRecords(queue, count: 1)
        clock.setWall(capturedAt.addingTimeInterval(100))
        _ = try await appendRecords(queue, count: 2)
        clock.setWall(
            capturedAt.addingTimeInterval(
                EluV1BatchDeliveryCoordinator.serverOutcomeRetentionSeconds - 1
            )
        )
        let transport = TestBatchTransport(
            replies: [.network, .rejectSequences([1, 2], "record-too-old")]
        )
        let coordinator = try self.coordinator(
            queue: queue,
            transport: transport,
            clock: clock,
            randomUnit: 0
        )

        guard try await deferAndMakeDue(coordinator, clock, "Expected network retry") else {
            return
        }
        clock.setWall(
            capturedAt.addingTimeInterval(
                EluV1BatchDeliveryCoordinator.serverOutcomeRetentionSeconds + 1
            )
        )
        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 0, terminallyDiscarded: 3))
        let sequences = await transport.recordSequences()
        XCTAssertEqual(sequences, [[0, 1, 2], [1, 2]])
        let streams = await transport.streamIds()
        XCTAssertEqual(streams, ["stream_delivery_test", "stream_moved_1"])
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 0)
        await coordinator.cancel()
        await queue.close()
    }

    func testLongRetryAfterIsCancelledAtAuthorizationExpiryWithoutEarlySend() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 1)
        let transport = TestBatchTransport(replies: [.http(429, "30"), .accept])
        let clock = TestBatchClock(wall: capturedAt, monotonic: 1_000)
        let coordinator = try self.coordinator(
            queue: queue,
            transport: transport,
            clock: clock,
            randomUnit: 0,
            authorizationExpiry: capturedAt.addingTimeInterval(2)
        )
        let initial = await coordinator.trigger()
        XCTAssertEqual(
            initial,
            .deferred(untilMonotonicNanoseconds: 30_000_001_000)
        )
        clock.setMonotonic(2_000_000_999)
        let beforeExpiry = await coordinator.trigger()
        XCTAssertEqual(
            beforeExpiry,
            .deferred(untilMonotonicNanoseconds: 30_000_001_000)
        )
        let callsBeforeExpiry = await transport.callCount()
        XCTAssertEqual(callsBeforeExpiry, 1)

        // Monotonic authorization cap wins even if wall time rolls backward.
        clock.setWall(capturedAt.addingTimeInterval(-3_600))
        clock.setMonotonic(2_000_001_000)
        let expired = await coordinator.trigger()
        XCTAssertEqual(expired, .preserved(.authorizationExpired))
        let finalCalls = await transport.callCount()
        XCTAssertEqual(finalCalls, 1)
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 1)
        await queue.close()
    }

    func testPermanentAndMalformedRetryResponsesPreserveQueue() async throws {
        for reply in [
            TestBatchReply.http(401, nil),
            .http(403, nil),
            .http(429, nil),
            .http(500, "not-a-date"),
            .http(418, nil),
        ] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let queue = try await makeQueue(directory: directory)
            _ = try await appendRecords(queue, count: 1)
            let transport = TestBatchTransport(replies: [reply])
            let coordinator = try self.coordinator(
                queue: queue,
                transport: transport
            )
            let result = await coordinator.trigger()
            switch reply {
            case .http(401, _):
                XCTAssertEqual(result, .preserved(.permanentHTTP(401)))
            case .http(403, _):
                XCTAssertEqual(result, .preserved(.permanentHTTP(403)))
            case .http(429, _), .http(500, _):
                // HTTP status is authoritative: an unusable Retry-After falls
                // back to ordinary backoff for the same request.
                XCTAssertEqual(result, .deferred(untilMonotonicNanoseconds: 750_000_000))
            default:
                XCTAssertEqual(result, .preserved(.protocolFailure))
            }
            let snapshot = try await queue.snapshot()
            XCTAssertEqual(snapshot.queuedCount, 1)
            let repeated = await coordinator.trigger()
            XCTAssertEqual(repeated, result)
            let calls = await transport.callCount()
            XCTAssertEqual(calls, 1)
            await queue.close()
        }
    }

    func testForeignServerFailureRetriesSameRequestWithCappedRetryAfter() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 1)
        let transport = TestBatchTransport(replies: [
            .raw(503, ["Retry-After": "99999999"], Data("503 Service Unavailable".utf8)),
            .raw(502, [:], Data()),
            .accept,
        ])
        let clock = TestBatchClock(wall: capturedAt, monotonic: 0)
        let coordinator = try self.coordinator(queue: queue, transport: transport, clock: clock, randomUnit: 0)
        guard case let .deferred(capped) = await coordinator.trigger() else {
            return XCTFail("Expected a retry for a plain-text 503")
        }
        XCTAssertEqual(capped, 300_000_000_000)
        clock.setMonotonic(capped)
        guard case let .deferred(backoff) = await coordinator.trigger() else {
            return XCTFail("Expected a retry for an empty 502")
        }
        XCTAssertEqual(backoff, capped + 1_000_000_000)
        clock.setMonotonic(backoff)
        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 1, terminallyDiscarded: 0))
        let ids = await transport.requestIds()
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 1)
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 0)
        await coordinator.cancel()
        await queue.close()
    }

    func testURLSessionDenialPreservesOldAndNewRowsWithoutReusingAuthorization() async throws {
        for status in [401, 403] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let queue = try await makeQueue(directory: directory)
            let original = try await appendRecords(queue, count: 1)
            DeniedBatchURLProtocol.state.reset(status: status)
            let transport = EluV1URLSessionBatchTransport(protocolClasses: [DeniedBatchURLProtocol.self])
            let coordinator = try self.coordinator(queue: queue, transport: transport)

            let denied = await coordinator.trigger()
            XCTAssertEqual(denied, .preserved(.permanentHTTP(status)))
            let preserved = try await queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
            XCTAssertEqual(preserved, original)
            let added = try await appendRecords(queue, count: 1)
            let repeated = await coordinator.trigger()
            XCTAssertEqual(repeated, denied)
            XCTAssertEqual(DeniedBatchURLProtocol.state.callCount(), 1)
            let retained = try await queue.peek(maximumCount: 10, maximumBytes: 1_000_000)
            XCTAssertEqual(retained, original + added)

            // A separately issued coordinator may deliver the preserved rows.
            let renewed = try self.coordinator(queue: queue, transport: TestBatchTransport(replies: [.accept]))
            let recovered = await renewed.trigger()
            XCTAssertEqual(recovered, .resolved(delivered: 2, terminallyDiscarded: 0))
            let snapshot = try await queue.snapshot()
            XCTAssertEqual(snapshot.queuedCount, 0)
            await queue.close()
        }
    }

    func testTransportErrorBodyLimitAcceptsExactBoundaryAndOneByteOverRetriesOnlyServerFailures() async throws {
        for (status, retryAfter, size, expected) in [
            (
                503, "30",
                EluV1BatchDeliveryCoordinator.maximumErrorResponseBytes,
                EluV1BatchDeliveryTriggerResult.deferred(untilMonotonicNanoseconds: 30_000_000_000)
            ),
            (
                503, "30",
                EluV1BatchDeliveryCoordinator.maximumErrorResponseBytes + 1,
                EluV1BatchDeliveryTriggerResult.deferred(untilMonotonicNanoseconds: 30_000_000_000)
            ),
            (
                413, nil,
                EluV1BatchDeliveryCoordinator.maximumErrorResponseBytes + 1,
                EluV1BatchDeliveryTriggerResult.preserved(.protocolFailure)
            ),
        ] as [(Int, String?, Int, EluV1BatchDeliveryTriggerResult)] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let queue = try await makeQueue(directory: directory)
            _ = try await appendRecords(queue, count: 1)
            let transport = TestBatchTransport(
                replies: [.httpWithBodySize(status, retryAfter, size)]
            )
            let coordinator = try self.coordinator(queue: queue, transport: transport)

            let result = await coordinator.trigger()
            XCTAssertEqual(result, expected)
            let repeated = await coordinator.trigger()
            XCTAssertEqual(repeated, expected)
            let calls = await transport.callCount()
            XCTAssertEqual(calls, 1)
            let snapshot = try await queue.snapshot()
            XCTAssertEqual(snapshot.queuedCount, 1)
            await coordinator.cancel()
            await queue.close()
        }
    }

    func testRecordsAreSentUntilTheServerMayHaveDroppedTheirOutcome() async throws {
        let maximumAge = EluV1BatchDeliveryCoordinator.maximumRecordAgeSeconds
        let retention = EluV1BatchDeliveryCoordinator.serverOutcomeRetentionSeconds
        XCTAssertGreaterThan(retention, maximumAge)
        // The server's answer to the record, or nil when it is not sent.
        let tooOld = TestBatchReply.rejectSequences([0], "record-too-old")
        let cases: [(TimeInterval, TestBatchReply?)] = [
            (-60, .accept),
            (maximumAge - 0.001, .accept),
            (maximumAge, tooOld),
            (maximumAge + 0.001, tooOld),
            (retention - 0.001, tooOld),
            (retention, nil),
            (retention + 0.001, nil),
        ]
        for (offset, reply) in cases {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let queue = try await makeQueue(directory: directory)
            _ = try await appendRecords(queue, count: 1)
            let transport = TestBatchTransport(replies: reply.map { [$0] } ?? [])
            let clock = TestBatchClock(
                wall: capturedAt.addingTimeInterval(offset),
                monotonic: 0
            )
            let coordinator = try self.coordinator(
                queue: queue,
                transport: transport,
                clock: clock,
                authorizationExpiry: capturedAt.addingTimeInterval(900_000)
            )
            let result = await coordinator.trigger()
            let calls = await transport.callCount()
            let stream = try await queue.eventDeliveryStream()
            switch reply {
            case .none:
                // Removed unsent; whatever follows goes on a new stream.
                XCTAssertEqual(calls, 0, "age \(offset)")
                XCTAssertEqual(result, .resolved(delivered: 0, terminallyDiscarded: 1))
                XCTAssertEqual(stream.streamId, "stream_moved_1", "age \(offset)")
            case .some(.accept):
                XCTAssertEqual(calls, 1, "age \(offset)")
                XCTAssertEqual(result, .resolved(delivered: 1, terminallyDiscarded: 0))
                XCTAssertEqual(stream.streamId, "stream_delivery_test", "age \(offset)")
            case .some:
                XCTAssertEqual(calls, 1, "age \(offset)")
                XCTAssertEqual(result, .resolved(delivered: 0, terminallyDiscarded: 1))
                XCTAssertEqual(stream.streamId, "stream_delivery_test", "age \(offset)")
            }
            let snapshot = try await queue.snapshot()
            XCTAssertEqual(snapshot.queuedCount, 0)
            await queue.close()
        }
    }

    func testAgedRecordBetweenFreshOnesIsSentInTheSameRequest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestBatchClock(
            wall: capturedAt.addingTimeInterval(100),
            monotonic: 0
        )
        let queue = try await makeQueue(directory: directory, clock: clock.source.wallNow)
        _ = try await appendRecords(queue, count: 1)
        clock.setWall(capturedAt)
        _ = try await appendRecords(queue, count: 1)
        clock.setWall(capturedAt.addingTimeInterval(200))
        _ = try await appendRecords(queue, count: 1)
        clock.setWall(
            capturedAt.addingTimeInterval(
                EluV1BatchDeliveryCoordinator.maximumRecordAgeSeconds + 50
            )
        )
        let transport = TestBatchTransport(replies: [.rejectSequences([1], "record-too-old")])
        let coordinator = try self.coordinator(
            queue: queue,
            transport: transport,
            clock: clock
        )

        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 2, terminallyDiscarded: 1))
        let sequences = await transport.recordSequences()
        XCTAssertEqual(sequences, [[0, 1, 2]])
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 0)
        await queue.close()
    }

    func testRecordPastTheServerOutcomeEndsThePrefixAndIsRemovedOnItsOwn() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestBatchClock(
            wall: capturedAt.addingTimeInterval(100),
            monotonic: 0
        )
        let queue = try await makeQueue(directory: directory, clock: clock.source.wallNow)
        _ = try await appendRecords(queue, count: 1)
        clock.setWall(capturedAt)
        _ = try await appendRecords(queue, count: 1)
        clock.setWall(capturedAt.addingTimeInterval(200))
        _ = try await appendRecords(queue, count: 1)
        clock.setWall(
            capturedAt.addingTimeInterval(
                EluV1BatchDeliveryCoordinator.serverOutcomeRetentionSeconds + 50
            )
        )
        let transport = TestBatchTransport(
            replies: [
                .rejectSequences([0], "record-too-old"),
                .rejectSequences([2], "record-too-old"),
            ]
        )
        let coordinator = try self.coordinator(
            queue: queue,
            transport: transport,
            clock: clock
        )

        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 0, terminallyDiscarded: 3))
        let sequences = await transport.recordSequences()
        XCTAssertEqual(sequences, [[0], [2]])
        let streams = await transport.streamIds()
        XCTAssertEqual(streams, ["stream_delivery_test", "stream_moved_1"])
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 0)
        await queue.close()
    }

    func testAuthorizationExpiryStopsBeforeTransport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 1)
        let transport = TestBatchTransport(replies: [.accept])
        let coordinator = try self.coordinator(
            queue: queue,
            transport: transport,
            authorizationExpiry: capturedAt
        )
        let result = await coordinator.trigger()
        XCTAssertEqual(result, .preserved(.authorizationExpired))
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 0)
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 1)
        await queue.close()
    }

    func testAuthorizationIsRecheckedAfterQueueValidationImmediatelyBeforeTransport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 1)
        let transport = TestBatchTransport(replies: [.accept])
        let expiry = capturedAt.addingTimeInterval(60)
        let clock = TestScriptedWallClock(
            values: [capturedAt, capturedAt, capturedAt, capturedAt, expiry]
        )
        let coordinator = EluV1BatchDeliveryCoordinator(
            queue: queue,
            authorization: try EluV1BatchAuthorizationSnapshot(
                siteKey: "elu_pk_live_test",
                eventsEndpoint: try XCTUnwrap(
                    URL(string: "https://ingest.elu.dev/v1/events")
                ),
                expiresAt: expiry,
                eventBatchCount: 1_000,
                eventBatchBytes: 1_000_000
            ),
            transport: transport,
            time: clock.source,
            randomUnit: { 0 }
        )

        let result = await coordinator.trigger()
        XCTAssertEqual(result, .preserved(.authorizationExpired))
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 0)
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 1)
        await queue.close()
    }

    func testRecordThatAgesAtTheNetworkBoundaryIsStillSent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 1)
        let transport = TestBatchTransport(replies: [.rejectSequences([0], "record-too-old")])
        let beforeBoundary = capturedAt.addingTimeInterval(
            EluV1BatchDeliveryCoordinator.maximumRecordAgeSeconds - 1
        )
        let atBoundary = capturedAt.addingTimeInterval(
            EluV1BatchDeliveryCoordinator.maximumRecordAgeSeconds
        )
        let clock = TestScriptedWallClock(
            values: [
                beforeBoundary,
                beforeBoundary,
                beforeBoundary,
                beforeBoundary,
                atBoundary,
            ]
        )
        let coordinator = EluV1BatchDeliveryCoordinator(
            queue: queue,
            authorization: try EluV1BatchAuthorizationSnapshot(
                siteKey: "elu_pk_live_test",
                eventsEndpoint: try XCTUnwrap(
                    URL(string: "https://ingest.elu.dev/v1/events")
                ),
                expiresAt: capturedAt.addingTimeInterval(900_000),
                eventBatchCount: 1_000,
                eventBatchBytes: 1_000_000
            ),
            transport: transport,
            time: clock.source,
            randomUnit: { 0 }
        )

        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 0, terminallyDiscarded: 1))
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 1)
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 0)
        await queue.close()
    }

    func testRecordThatOutlivesTheServerOutcomeAtTheNetworkBoundaryIsRemovedUnsent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 1)
        let transport = TestBatchTransport(replies: [])
        let beforeBoundary = capturedAt.addingTimeInterval(
            EluV1BatchDeliveryCoordinator.serverOutcomeRetentionSeconds - 1
        )
        let atBoundary = capturedAt.addingTimeInterval(
            EluV1BatchDeliveryCoordinator.serverOutcomeRetentionSeconds
        )
        let clock = TestScriptedWallClock(
            values: [
                beforeBoundary,
                beforeBoundary,
                beforeBoundary,
                beforeBoundary,
                atBoundary,
            ]
        )
        let coordinator = EluV1BatchDeliveryCoordinator(
            queue: queue,
            authorization: try EluV1BatchAuthorizationSnapshot(
                siteKey: "elu_pk_live_test",
                eventsEndpoint: try XCTUnwrap(
                    URL(string: "https://ingest.elu.dev/v1/events")
                ),
                expiresAt: capturedAt.addingTimeInterval(900_000),
                eventBatchCount: 1_000,
                eventBatchBytes: 1_000_000
            ),
            transport: transport,
            time: clock.source,
            randomUnit: { 0 },
            deliveryStreamIdGenerator: { "stream_moved_1" }
        )

        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 0, terminallyDiscarded: 1))
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 0)
        let stream = try await queue.eventDeliveryStream()
        XCTAssertEqual(stream.streamId, "stream_moved_1")
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 0)
        await queue.close()
    }

    func testRetryAfterTrimsWhitespaceAndAcceptsCanonicalHTTPDates() throws {
        let canonicalNow = Date(timeIntervalSince1970: 784_111_747)
        XCTAssertEqual(
            EluV1BatchDeliveryCoordinator.parseRetryAfter(" \t30\r\n", now: canonicalNow),
            30
        )
        for value in [
            "Sun, 06 Nov 1994 08:49:37 GMT",
            "Sunday, 06-Nov-94 08:49:37 GMT",
            "Sun Nov  6 08:49:37 1994",
        ] {
            XCTAssertEqual(
                EluV1BatchDeliveryCoordinator.parseRetryAfter(value, now: canonicalNow),
                30,
                value
            )
        }
        XCTAssertNil(
            EluV1BatchDeliveryCoordinator.parseRetryAfter(
                "Mon, 06 Nov 1994 08:49:37 GMT",
                now: canonicalNow
            )
        )
    }

    func testConcurrentTriggersNeverOverlapAndCoalesceOneFollowUp() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 2)
        let transport = TestBatchTransport(replies: [.delayedAccept(100_000_000)])
        let coordinator = try self.coordinator(queue: queue, transport: transport)

        async let first = coordinator.trigger()
        while await transport.callCount() == 0 {
            await Task.yield()
        }
        async let second = coordinator.trigger()
        let firstResult = await first
        let secondResult = await second
        let results = [firstResult, secondResult]
        XCTAssertTrue(results.contains(.coalesced))
        XCTAssertTrue(results.contains(.resolved(delivered: 2, terminallyDiscarded: 0)))
        let maximumConcurrent = await transport.maximumConcurrentCalls()
        XCTAssertEqual(maximumConcurrent, 1)
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 1)
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 0)
        await queue.close()
    }

    func testPinnedTransportFixturesArePresentAndStrictJSONRejectsDuplicateKeys() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for relative in [
            "Conformance/V1/schemas/batch-request.schema.json",
            "Conformance/V1/schemas/batch-ack.schema.json",
            "Conformance/V1/schemas/transport-error.schema.json",
            "Conformance/V1/schemas/transport-policy.schema.json",
            "Conformance/V1/Fixtures/batch-request.json",
            "Conformance/V1/Fixtures/batch-ack.json",
            "Conformance/V1/Fixtures/batch-ack-retryable-head.json",
            "Conformance/V1/Fixtures/transport-policy.json",
        ] {
            let data = try Data(contentsOf: root.appendingPathComponent(relative))
            XCTAssertNoThrow(try EluV1StrictTransportJSON.parse(data), relative)
        }
        XCTAssertThrowsError(
            try EluV1StrictTransportJSON.parse(Data(#"{"a":1,"a":2}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? EluV1StrictTransportJSONError, .duplicateKey)
        }
    }

    func testOneRecord413DiscardMovesTheRestToANewStream() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 2)
        let transport = TestBatchTransport(replies: [.http(413, nil), .http(413, nil), .accept])
        let coordinator = try self.coordinator(queue: queue, transport: transport)

        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 1, terminallyDiscarded: 1))
        let sequences = await transport.recordSequences()
        XCTAssertEqual(sequences, [[0, 1], [0], [1]])
        // The split's second half is not sent on the stream that now misses
        // sequence 0; it is packed again on the new stream.
        let streams = await transport.streamIds()
        XCTAssertEqual(streams, ["stream_delivery_test", "stream_delivery_test", "stream_moved_1"])
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 0)
        await queue.close()
    }

    func testStreamGapMovesTheHeadOnlyAfterEnoughAnswersAndResendsItAtOnce() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 2)
        let answers = Int(EluV1BatchDeliveryCoordinator.streamGapRotationAnswers)
        let transport = TestBatchTransport(
            replies: Array(repeating: TestBatchReply.streamGap, count: answers)
                + [TestBatchReply.accept]
        )
        let clock = TestBatchClock(wall: capturedAt, monotonic: 0, holdsTimers: true)
        let coordinator = try self.coordinator(
            queue: queue,
            transport: transport,
            clock: clock,
            randomUnit: 0
        )

        // The time bound is passed before the answer count is reached.
        for index in 0 ..< answers - 1 {
            clock.setWall(capturedAt.addingTimeInterval(Double(index) * 600))
            guard try await deferAndMakeDue(
                coordinator,
                clock,
                "Expected a stream-gap retry before the answer bound"
            ) else { return }
        }
        let beforeMove = try await queue.eventDeliveryStream()
        XCTAssertEqual(beforeMove.streamId, "stream_delivery_test")
        XCTAssertEqual(beforeMove.gap?.sequence, 0)
        XCTAssertEqual(beforeMove.gap?.answers, Int64(answers - 1))

        clock.setWall(capturedAt.addingTimeInterval(Double(answers) * 600))
        let moved = await coordinator.trigger()
        XCTAssertEqual(moved, .resolved(delivered: 2, terminallyDiscarded: 0))
        let streams = await transport.streamIds()
        XCTAssertEqual(
            streams,
            Array(repeating: "stream_delivery_test", count: answers) + ["stream_moved_1"]
        )
        let sequences = await transport.recordSequences()
        XCTAssertEqual(sequences, Array(repeating: [Int64(0), 1], count: answers + 1))
        let afterMove = try await queue.eventDeliveryStream()
        XCTAssertEqual(afterMove.streamId, "stream_moved_1")
        XCTAssertNil(afterMove.gap)
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 0)
        await coordinator.cancel()
        await queue.close()
    }

    func testStreamGapRotationWaitsLongerThanTheServerGapCloseGrace() {
        // The server closes a gap after 30 minutes; the SDK must wait longer
        // so the server's close is the normal path.
        XCTAssertEqual(EluV1BatchDeliveryCoordinator.serverGapCloseGraceSeconds, 1_800)
        XCTAssertGreaterThan(
            EluV1BatchDeliveryCoordinator.streamGapRotationSeconds,
            EluV1BatchDeliveryCoordinator.serverGapCloseGraceSeconds
        )
        XCTAssertEqual(EluV1BatchDeliveryCoordinator.streamGapRotationSeconds, 2_700)
        XCTAssertEqual(EluV1BatchDeliveryCoordinator.streamGapRotationAnswers, 5)
    }

    func testStreamGapMovesTheHeadOnlyAfterTheTimeBound() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 1)
        let answers = Int(EluV1BatchDeliveryCoordinator.streamGapRotationAnswers)
        let transport = TestBatchTransport(
            replies: Array(repeating: TestBatchReply.streamGap, count: answers + 2)
                + [TestBatchReply.accept]
        )
        let clock = TestBatchClock(wall: capturedAt, monotonic: 0, holdsTimers: true)
        let coordinator = try self.coordinator(
            queue: queue,
            transport: transport,
            clock: clock,
            randomUnit: 0
        )

        // The answer count is reached within one minute: no move yet.
        for index in 0 ..< answers {
            clock.setWall(capturedAt.addingTimeInterval(Double(index) * 10))
            guard try await deferAndMakeDue(
                coordinator,
                clock,
                "Expected a stream-gap retry before the time bound"
            ) else { return }
        }
        // One millisecond short of the bound: still no move.
        clock.setWall(
            capturedAt.addingTimeInterval(
                EluV1BatchDeliveryCoordinator.streamGapRotationSeconds - 0.001
            )
        )
        guard try await deferAndMakeDue(
            coordinator,
            clock,
            "Expected a stream-gap retry just before the time bound"
        ) else { return }
        let beforeMove = try await queue.eventDeliveryStream()
        XCTAssertEqual(beforeMove.streamId, "stream_delivery_test")
        XCTAssertEqual(beforeMove.gap?.answers, Int64(answers + 1))

        clock.setWall(
            capturedAt.addingTimeInterval(EluV1BatchDeliveryCoordinator.streamGapRotationSeconds)
        )
        let moved = await coordinator.trigger()
        XCTAssertEqual(moved, .resolved(delivered: 1, terminallyDiscarded: 0))
        let streams = await transport.streamIds()
        XCTAssertEqual(streams.filter { $0 == "stream_delivery_test" }.count, answers + 2)
        XCTAssertEqual(streams.last, "stream_moved_1")
        await coordinator.cancel()
        await queue.close()
    }

    func testStreamGapEvidenceBelongsToOneHeadAndRestartsWhenTheClockGoesBack() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 3)
        let answers = Int(EluV1BatchDeliveryCoordinator.streamGapRotationAnswers)
        let transport = TestBatchTransport(
            replies: Array(repeating: TestBatchReply.streamGap, count: answers - 1)
                + [TestBatchReply.acceptHeadThenStreamGap, .streamGap, .streamGap, .accept]
        )
        let clock = TestBatchClock(wall: capturedAt, monotonic: 0, holdsTimers: true)
        let coordinator = try self.coordinator(
            queue: queue,
            transport: transport,
            clock: clock,
            randomUnit: 0
        )

        for index in 0 ..< answers - 1 {
            clock.setWall(capturedAt.addingTimeInterval(Double(index) * 600))
            guard try await deferAndMakeDue(
                coordinator,
                clock,
                "Expected a stream-gap retry"
            ) else { return }
        }
        // Sequence 0 is resolved and sequence 1 is answered stream-gap. The
        // count for sequence 0 does not carry over to the new head.
        clock.setWall(capturedAt.addingTimeInterval(Double(answers) * 600))
        guard try await deferAndMakeDue(
            coordinator,
            clock,
            "Expected a stream-gap retry for the new head"
        ) else { return }
        let newHead = try await queue.eventDeliveryStream()
        XCTAssertEqual(newHead.streamId, "stream_delivery_test")
        XCTAssertEqual(newHead.gap?.sequence, 1)
        XCTAssertEqual(newHead.gap?.answers, 1)

        // A clock set back a day restarts the window at the new reading.
        let setBack = capturedAt.addingTimeInterval(-86_400)
        clock.setWall(setBack)
        guard try await deferAndMakeDue(
            coordinator,
            clock,
            "Expected a stream-gap retry after the clock went back"
        ) else { return }
        let restarted = try await queue.eventDeliveryStream()
        XCTAssertEqual(restarted.gap?.answers, 2)
        XCTAssertEqual(
            restarted.gap?.firstAnsweredAtMilliseconds,
            Int64(setBack.timeIntervalSince1970 * 1_000)
        )

        let streams = await transport.streamIds()
        XCTAssertTrue(streams.allSatisfy { $0 == "stream_delivery_test" })
        let snapshot = try await queue.snapshot()
        XCTAssertEqual(snapshot.headSequence, 1)
        await coordinator.cancel()
        await queue.close()
    }

    func testStreamGapEvidenceAndTheMovedStreamSurviveQueueRestarts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let answers = Int(EluV1BatchDeliveryCoordinator.streamGapRotationAnswers)
        let firstSession = 3
        var queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 2)
        let clock = TestBatchClock(wall: capturedAt, monotonic: 0, holdsTimers: true)
        let firstTransport = TestBatchTransport(
            replies: Array(repeating: TestBatchReply.streamGap, count: firstSession)
        )
        let first = try coordinator(
            queue: queue,
            transport: firstTransport,
            clock: clock,
            randomUnit: 0
        )
        for index in 0 ..< firstSession {
            clock.setWall(capturedAt.addingTimeInterval(Double(index) * 60))
            guard try await deferAndMakeDue(
                first,
                clock,
                "Expected a stream-gap retry"
            ) else { return }
        }
        await first.cancel()
        await queue.close()
        let file = directory.appendingPathComponent(EluV1EventDeliveryStreamStore.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // A new process: the answers already counted still count.
        queue = try await makeQueue(directory: directory)
        let reopened = try await queue.eventDeliveryStream()
        XCTAssertEqual(reopened.gap?.answers, Int64(firstSession))
        let secondTransport = TestBatchTransport(
            replies: Array(repeating: TestBatchReply.streamGap, count: answers - firstSession)
                + [TestBatchReply.accept]
        )
        let secondClock = TestBatchClock(
            wall: capturedAt.addingTimeInterval(
                EluV1BatchDeliveryCoordinator.streamGapRotationSeconds
            ),
            monotonic: 0,
            holdsTimers: true
        )
        let second = try coordinator(
            queue: queue,
            transport: secondTransport,
            clock: secondClock,
            randomUnit: 0
        )
        for _ in 0 ..< answers - firstSession - 1 {
            guard try await deferAndMakeDue(
                second,
                secondClock,
                "Expected a stream-gap retry after the restart"
            ) else { return }
        }
        let moved = await second.trigger()
        XCTAssertEqual(moved, .resolved(delivered: 2, terminallyDiscarded: 0))
        let secondStreams = await secondTransport.streamIds()
        XCTAssertEqual(
            secondStreams,
            Array(repeating: "stream_delivery_test", count: answers - firstSession)
                + ["stream_moved_1"]
        )
        await second.cancel()
        await queue.close()

        // Later records keep going on the moved stream after another restart.
        queue = try await makeQueue(directory: directory)
        let records = try await appendRecords(queue, count: 1)
        XCTAssertEqual(records.map(\.sequence), [2])
        let thirdTransport = TestBatchTransport(replies: [.accept])
        let third = try coordinator(queue: queue, transport: thirdTransport)
        let delivered = await third.trigger()
        XCTAssertEqual(delivered, .resolved(delivered: 1, terminallyDiscarded: 0))
        let thirdStreams = await thirdTransport.streamIds()
        XCTAssertEqual(thirdStreams, ["stream_moved_1"])
        await queue.close()
    }

    func testMovedStreamReaddressesEventsAndKeepsRecordIds() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 1, valueBytes: 12_000)
        let event = try await appendEvent(queue)
        let snapshot = try await queue.snapshot()
        let eventBody = try EluQueueBatchCodec.encodeBatch(
            requestId: "request_\(String(repeating: "a", count: 64))",
            streamId: snapshot.streamId,
            sentAt: capturedAt,
            versions: event.versions,
            records: [event]
        )
        let transport = TestBatchTransport(replies: [.accept])
        let coordinator = try self.coordinator(
            queue: queue,
            byteLimit: max(EluV1BatchAuthorizationSnapshot.minimumBatchBytes, eventBody.count),
            transport: transport
        )

        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 1, terminallyDiscarded: 1))
        let streams = await transport.streamIds()
        XCTAssertEqual(streams, ["stream_moved_1"])
        let eventStreams = await transport.eventStreamIds()
        XCTAssertEqual(eventStreams, [["stream_moved_1"]])
        let recordIds = await transport.recordIds()
        XCTAssertEqual(recordIds, [[event.recordId]])
        let sequences = await transport.recordSequences()
        XCTAssertEqual(sequences, [[1]])
        let after = try await queue.snapshot()
        XCTAssertEqual(after.queuedCount, 0)
        XCTAssertEqual(after.streamId, "stream_delivery_test")
        await queue.close()
    }

    func testMemoryStorageKeepsTheMovedStreamOutOfFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory, persistence: .memory)
        _ = try await appendRecords(queue, count: 1, valueBytes: 2_000)
        _ = try await appendRecords(queue, count: 1)
        let transport = TestBatchTransport(replies: [.accept])
        let coordinator = try self.coordinator(
            queue: queue,
            byteLimit: EluV1BatchAuthorizationSnapshot.minimumBatchBytes,
            transport: transport
        )

        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 1, terminallyDiscarded: 1))
        let streams = await transport.streamIds()
        XCTAssertEqual(streams, ["stream_moved_1"])
        let file = directory.appendingPathComponent(EluV1EventDeliveryStreamStore.filename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await queue.close()
    }

    func testDeliveryStreamFileForAnotherStreamOrMalformedIsIgnored() async throws {
        let foreign = try EluV1EventDeliveryStreamStore.encode(
            EluV1EventDeliveryStream(
                installationStreamId: "stream_other_install",
                streamId: "stream_other_wire",
                gap: nil
            )
        )
        for contents in [foreign, Data("not a stream document".utf8)] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try contents.write(
                to: directory.appendingPathComponent(EluV1EventDeliveryStreamStore.filename)
            )
            let queue = try await makeQueue(directory: directory)
            _ = try await appendRecords(queue, count: 1)
            let transport = TestBatchTransport(replies: [.accept])
            let coordinator = try self.coordinator(queue: queue, transport: transport)

            let result = await coordinator.trigger()
            XCTAssertEqual(result, .resolved(delivered: 1, terminallyDiscarded: 0))
            let streams = await transport.streamIds()
            XCTAssertEqual(streams, ["stream_delivery_test"])
            await queue.close()
        }
    }

    func testDeliveryStreamFileRoundTripsAndAcceptsOnlyItsOwnBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EluV1EventDeliveryStreamStore(directoryURL: directory)
        XCTAssertNil(try store.load())
        for value in [
            EluV1EventDeliveryStream.initial(installationStreamId: "stream_install"),
            EluV1EventDeliveryStream(
                installationStreamId: "stream_install",
                streamId: "stream_wire",
                gap: .init(sequence: 7, firstAnsweredAtMilliseconds: 1_786_147_200_000, answers: 3)
            ),
        ] {
            try store.save(value)
            XCTAssertEqual(try store.load(), value)
        }

        let bytes = try EluV1EventDeliveryStreamStore.encode(
            .initial(installationStreamId: "stream_install")
        )
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        for altered in [
            text + "\n",
            " " + text,
            String(text.dropLast()) + ",\"extra\":1}",
            text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
            text.replacingOccurrences(of: "\"gap\":null,", with: ""),
        ] {
            XCTAssertThrowsError(
                try EluV1EventDeliveryStreamStore.decode(Data(altered.utf8)),
                altered
            )
        }
        XCTAssertThrowsError(
            try EluV1EventDeliveryStreamStore.encode(
                EluV1EventDeliveryStream(installationStreamId: "", streamId: "stream_wire", gap: nil)
            )
        )
    }

    /// Runs one trigger that must defer a retry, waits until the retry timer
    /// is asleep (for an hour, on a clock that holds timers), then makes the
    /// retry due. The timer cannot fire on its own, so the next trigger runs
    /// the retry and nothing races it.
    private func deferAndMakeDue(
        _ coordinator: EluV1BatchDeliveryCoordinator,
        _ clock: TestBatchClock,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Bool {
        let sleeps = clock.sleepsStarted()
        guard case let .deferred(deadline) = await coordinator.trigger() else {
            XCTFail(message, file: file, line: line)
            return false
        }
        var waits = 0
        while clock.sleepsStarted() == sleeps, waits < 2_000 {
            try await Task.sleep(nanoseconds: 5_000_000)
            waits += 1
        }
        XCTAssertGreaterThan(clock.sleepsStarted(), sleeps, file: file, line: line)
        clock.setMonotonic(deadline)
        return true
    }

    private func coordinator(
        queue: EluSQLiteRuntimeQueue,
        byteLimit: Int = 1_000_000,
        transport: any EluV1BatchHTTPTransport,
        clock: TestBatchClock? = nil,
        randomUnit: Double = 0.5,
        authorizationExpiry: Date? = nil
    ) throws -> EluV1BatchDeliveryCoordinator {
        let clock = clock ?? TestBatchClock(wall: capturedAt, monotonic: 0)
        let streamIds = TestStreamIdSequence()
        return EluV1BatchDeliveryCoordinator(
            queue: queue,
            authorization: try EluV1BatchAuthorizationSnapshot(
                siteKey: "elu_pk_live_test",
                eventsEndpoint: try XCTUnwrap(URL(string: "https://ingest.elu.dev/v1/events")),
                expiresAt: authorizationExpiry ?? capturedAt.addingTimeInterval(900_000),
                eventBatchCount: 1_000,
                eventBatchBytes: byteLimit
            ),
            transport: transport,
            time: clock.source,
            randomUnit: { randomUnit },
            deliveryStreamIdGenerator: { streamIds.next() }
        )
    }

    private func makeQueue(directory: URL) async throws -> EluSQLiteRuntimeQueue {
        let fixedClock = capturedAt
        return try await makeQueue(directory: directory, clock: { fixedClock })
    }

    private func makeQueue(
        directory: URL,
        persistence: EluPersistenceMode
    ) async throws -> EluSQLiteRuntimeQueue {
        let fixedClock = capturedAt
        return try await EluSQLiteRuntimeQueue.open(
            directoryURL: directory,
            persistence: persistence,
            clock: { fixedClock },
            anonymousIdGenerator: { "anon_delivery_test" },
            streamIdGenerator: { "stream_delivery_test" },
            sessionIdGenerator: { "session_delivery_test" }
        )
    }

    @discardableResult
    private func appendEvent(_ queue: EluSQLiteRuntimeQueue) async throws -> EluQueuedRecord {
        let snapshot = try await queue.snapshot()
        if snapshot.identity.session == nil {
            _ = try await queue.recordEligibleActivity(expectedGeneration: snapshot.generation)
        }
        return try await queue.appendEvent(
            EluEventDraft(
                kind: .capture,
                name: "delivery_event",
                occurredAt: capturedAt,
                expectedSessionId: "session_delivery_test",
                properties: [:],
                versions: try versions()
            ),
            sessionUpdate: .preserve
        )
    }

    private func makeQueue(
        directory: URL,
        clock: @escaping @Sendable () -> Date
    ) async throws -> EluSQLiteRuntimeQueue {
        return try await EluSQLiteRuntimeQueue.open(
            directoryURL: directory,
            clock: clock,
            anonymousIdGenerator: { "anon_delivery_test" },
            streamIdGenerator: { "stream_delivery_test" },
            sessionIdGenerator: { "session_delivery_test" }
        )
    }

    @discardableResult
    private func appendRecords(
        _ queue: EluSQLiteRuntimeQueue,
        count: Int,
        valueBytes: Int = 8,
        versions: EluVersionContext? = nil,
        fixedPropertyKey: String? = nil
    ) async throws -> [EluQueuedRecord] {
        var records: [EluQueuedRecord] = []
        let captureVersions = try versions ?? self.versions()
        for index in 0 ..< count {
            let generation = try await queue.snapshot().generation
            let propertyKey = fixedPropertyKey ?? "value_\(index)"
            let baseValue = String(repeating: "x", count: valueBytes)
            let propertyValue = fixedPropertyKey == nil ? baseValue : "\(baseValue)-\(index)"
            records.append(
                contentsOf: try await queue.applyMutation(
                    .setPersonProperties(
                        set: [propertyKey: .string(propertyValue)],
                        setOnce: [:],
                        unset: []
                    ),
                    versions: captureVersions,
                    expectedGeneration: generation
                )
            )
        }
        return records
    }

    private func versions(build: String = "delivery-build") throws -> EluVersionContext {
        try EluVersionContext(
            runtime: EluVersionComponent(name: "elu-ios", version: "0.1.0"),
            facade: EluVersionComponent(name: "EluAnalytics", version: "0.1.0"),
            build: build
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("elu-ios-delivery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

private final class DeniedBatchURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = State()

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var status = 401
        private var calls = 0

        func reset(status: Int) {
            lock.lock(); defer { lock.unlock() }
            self.status = status
            calls = 0
        }

        func begin() -> Int {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return status
        }

        func callCount() -> Int {
            lock.lock(); defer { lock.unlock() }
            return calls
        }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.state.begin(),
            httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "99999999", "Retry-After": "invalid"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("not JSON".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private enum TestBatchReply: Sendable {
    case accept
    case acceptWithRetryAfter(String)
    case acceptWithDuplicateRetryAfter
    case partialRetry
    case partialRetryAfter(String)
    case partialRetryWithDuplicateRetryAfter
    case terminallyRejectWithCode(String)
    case http(Int, String?)
    case httpAndSetWall(Int, String?, TestBatchClock, Date)
    case httpWithBodySize(Int, String?, Int)
    case raw(Int, [String: String], Data)
    case network
    case mismatchedAcknowledgement
    case duplicateAcknowledgementKey
    case oversizedResponse
    case delayedAccept(UInt64)
    /// The head record is retryable `stream-gap`; nothing is resolved.
    case streamGap
    /// The head is accepted and the next record is retryable `stream-gap`.
    case acceptHeadThenStreamGap
    /// Listed sequences are terminally rejected with the code; the rest are accepted.
    case rejectSequences(Set<Int64>, String)
}

private enum TestBatchTransportError: Error {
    case network
}

private actor TestBatchTransport: EluV1BatchHTTPTransport {
    private var replies: [TestBatchReply]
    private var requests: [EluV1BatchHTTPRequest] = []
    private var activeCalls = 0
    private var maximumActiveCalls = 0

    init(replies: [TestBatchReply]) {
        self.replies = replies
    }

    func send(_ request: EluV1BatchHTTPRequest) async throws -> EluV1BatchHTTPResponse {
        requests.append(request)
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        defer { activeCalls -= 1 }
        let reply = replies.isEmpty ? .accept : replies.removeFirst()
        switch reply {
        case .accept:
            return try acceptedResponse(for: request)
        case let .acceptWithRetryAfter(value):
            var response = try acceptedResponse(for: request)
            response = EluV1BatchHTTPResponse(
                status: response.status,
                headers: ["Retry-After": value],
                body: response.body
            )
            return response
        case .acceptWithDuplicateRetryAfter:
            var response = try acceptedResponse(for: request)
            response = EluV1BatchHTTPResponse(
                status: response.status,
                headers: ["Retry-After": "30", "retry-after": "31"],
                body: response.body
            )
            return response
        case .partialRetry:
            return try partialRetryResponse(for: request)
        case let .partialRetryAfter(value):
            var response = try partialRetryResponse(for: request)
            response = EluV1BatchHTTPResponse(
                status: response.status,
                headers: ["Retry-After": value],
                body: response.body
            )
            return response
        case .partialRetryWithDuplicateRetryAfter:
            var response = try partialRetryResponse(for: request)
            response = EluV1BatchHTTPResponse(
                status: response.status,
                headers: ["Retry-After": "30", "retry-after": "31"],
                body: response.body
            )
            return response
        case let .terminallyRejectWithCode(code):
            return try terminallyRejectedResponse(for: request, code: code)
        case let .http(status, retryAfter):
            return try errorResponse(status: status, retryAfter: retryAfter, request: request)
        case let .httpAndSetWall(status, retryAfter, clock, wall):
            clock.setWall(wall)
            return try errorResponse(status: status, retryAfter: retryAfter, request: request)
        case let .httpWithBodySize(status, retryAfter, size):
            let response = try errorResponse(
                status: status,
                retryAfter: retryAfter,
                request: request
            )
            guard response.body.count <= size else {
                throw TestBatchTransportError.network
            }
            var body = response.body
            body.append(Data(repeating: 0x20, count: size - body.count))
            return EluV1BatchHTTPResponse(
                status: response.status,
                headers: response.headers,
                body: body
            )
        case let .raw(status, headers, body):
            return EluV1BatchHTTPResponse(status: status, headers: headers, body: body)
        case .network:
            throw TestBatchTransportError.network
        case .mismatchedAcknowledgement:
            var acknowledgement = try acknowledgementObject(for: request, result: "accepted")
            acknowledgement["requestId"] = "request_wrong"
            return EluV1BatchHTTPResponse(
                status: 200,
                headers: [:],
                body: try JSONSerialization.data(withJSONObject: acknowledgement, options: [.sortedKeys])
            )
        case .duplicateAcknowledgementKey:
            let acknowledgement = try acknowledgementObject(for: request, result: "accepted")
            let valid = try JSONSerialization.data(withJSONObject: acknowledgement, options: [.sortedKeys])
            let text = try XCTUnwrap(String(data: valid, encoding: .utf8))
            let requestId = try requestFacts(request).requestId
            let duplicate = "{\"requestId\":\"\(requestId)\"," + String(text.dropFirst())
            return EluV1BatchHTTPResponse(
                status: 200,
                headers: [:],
                body: Data(duplicate.utf8)
            )
        case .oversizedResponse:
            return EluV1BatchHTTPResponse(
                status: 200,
                headers: [:],
                body: Data(repeating: 0x20, count: EluV1BatchDeliveryCoordinator.maximumResponseBytes + 1)
            )
        case let .delayedAccept(nanoseconds):
            try await Task.sleep(nanoseconds: nanoseconds)
            return try acceptedResponse(for: request)
        case .streamGap:
            return try streamGapResponse(for: request, acceptingHead: false)
        case .acceptHeadThenStreamGap:
            return try streamGapResponse(for: request, acceptingHead: true)
        case let .rejectSequences(sequences, code):
            return try selectiveRejectionResponse(for: request, sequences: sequences, code: code)
        }
    }

    func callCount() -> Int { requests.count }

    func streamIds() -> [String] {
        requests.compactMap { try? requestFacts($0).streamId }
    }

    func recordIds() -> [[String]] {
        requests.compactMap { try? requestFacts($0).records.map(\.recordId) }
    }

    /// The `streamId` each event in each request names.
    func eventStreamIds() -> [[String]] {
        requests.compactMap { request in
            guard let object = try? JSONSerialization.jsonObject(with: request.body),
                  let root = object as? [String: Any],
                  let records = root["records"] as? [[String: Any]]
            else {
                return nil
            }
            return records.compactMap { record in
                (record["event"] as? [String: Any])?["streamId"] as? String
            }
        }
    }
    func maximumConcurrentCalls() -> Int { maximumActiveCalls }

    func requestIds() -> [String] {
        requests.compactMap { try? requestFacts($0).requestId }
    }

    func recordSequences() -> [[Int64]] {
        requests.compactMap { try? requestFacts($0).records.map(\.sequence) }
    }

    private func acceptedResponse(
        for request: EluV1BatchHTTPRequest
    ) throws -> EluV1BatchHTTPResponse {
        EluV1BatchHTTPResponse(
            status: 200,
            headers: [:],
            body: try JSONSerialization.data(
                withJSONObject: acknowledgementObject(for: request, result: "accepted"),
                options: [.sortedKeys]
            )
        )
    }

    private func partialRetryResponse(
        for request: EluV1BatchHTTPRequest
    ) throws -> EluV1BatchHTTPResponse {
        let facts = try requestFacts(request)
        guard facts.records.count >= 2 else { throw TestBatchTransportError.network }
        let first = facts.records[0]
        let second = facts.records[1]
        let body: [String: Any] = [
            "schemaVersion": 1,
            "requestId": facts.requestId,
            "streamId": facts.streamId,
            "resolvedThroughSequence": first.sequence,
            "retryFromSequence": second.sequence,
            "outcomes": [
                [
                    "sequence": first.sequence,
                    "recordId": first.recordId,
                    "kind": first.kind,
                    "result": "terminally-rejected",
                    "code": "invalid-record",
                ],
                [
                    "sequence": second.sequence,
                    "recordId": second.recordId,
                    "kind": second.kind,
                    "result": "retryable",
                    "code": "temporarily-unavailable",
                ],
            ],
        ]
        return EluV1BatchHTTPResponse(
            status: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        )
    }

    private func streamGapResponse(
        for request: EluV1BatchHTTPRequest,
        acceptingHead: Bool
    ) throws -> EluV1BatchHTTPResponse {
        let facts = try requestFacts(request)
        let resolved = acceptingHead ? Array(facts.records.prefix(1)) : []
        guard facts.records.count > resolved.count else { throw TestBatchTransportError.network }
        let gap = facts.records[resolved.count]
        var outcomes: [[String: Any]] = resolved.map { record -> [String: Any] in
            [
                "sequence": record.sequence,
                "recordId": record.recordId,
                "kind": record.kind,
                "result": "accepted",
            ]
        }
        outcomes.append([
            "sequence": gap.sequence,
            "recordId": gap.recordId,
            "kind": gap.kind,
            "result": "retryable",
            "code": "stream-gap",
        ])
        let body: [String: Any] = [
            "schemaVersion": 1,
            "requestId": facts.requestId,
            "streamId": facts.streamId,
            "resolvedThroughSequence": resolved.last.map { $0.sequence as Any } ?? NSNull(),
            "retryFromSequence": gap.sequence,
            "outcomes": outcomes,
        ]
        return EluV1BatchHTTPResponse(
            status: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        )
    }

    private func selectiveRejectionResponse(
        for request: EluV1BatchHTTPRequest,
        sequences: Set<Int64>,
        code: String
    ) throws -> EluV1BatchHTTPResponse {
        let facts = try requestFacts(request)
        let outcomes = facts.records.map { record -> [String: Any] in
            var outcome: [String: Any] = [
                "sequence": record.sequence,
                "recordId": record.recordId,
                "kind": record.kind,
                "result": sequences.contains(record.sequence) ? "terminally-rejected" : "accepted",
            ]
            if sequences.contains(record.sequence) {
                outcome["code"] = code
            }
            return outcome
        }
        let body: [String: Any] = [
            "schemaVersion": 1,
            "requestId": facts.requestId,
            "streamId": facts.streamId,
            "resolvedThroughSequence": try XCTUnwrap(facts.records.last).sequence,
            "retryFromSequence": NSNull(),
            "outcomes": outcomes,
        ]
        return EluV1BatchHTTPResponse(
            status: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        )
    }

    private func errorResponse(
        status: Int,
        retryAfter: String?,
        request: EluV1BatchHTTPRequest
    ) throws -> EluV1BatchHTTPResponse {
        let disposition: String
        switch status {
        case 401, 403:
            disposition = "permanent"
        case 413:
            disposition = "retry-after-reduction"
        case 429, 500 ... 599:
            disposition = "retryable"
        default:
            disposition = "permanent"
        }
        let facts = try requestFacts(request)
        var headers: [String: String] = [:]
        if let retryAfter { headers["Retry-After"] = retryAfter }
        let body: [String: Any] = [
            "schemaVersion": 1,
            "status": status,
            "code": status == 413 ? "payload-too-large" : "transport-failure",
            "disposition": disposition,
            "message": "The request could not be processed.",
            "requestId": facts.requestId,
        ]
        return EluV1BatchHTTPResponse(
            status: status,
            headers: headers,
            body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        )
    }

    private func terminallyRejectedResponse(
        for request: EluV1BatchHTTPRequest,
        code: String
    ) throws -> EluV1BatchHTTPResponse {
        let facts = try requestFacts(request)
        let outcomes = facts.records.map {
            [
                "sequence": $0.sequence,
                "recordId": $0.recordId,
                "kind": $0.kind,
                "result": "terminally-rejected",
                "code": code,
            ] as [String: Any]
        }
        let body: [String: Any] = [
            "schemaVersion": 1,
            "requestId": facts.requestId,
            "streamId": facts.streamId,
            "resolvedThroughSequence": try XCTUnwrap(facts.records.last).sequence,
            "retryFromSequence": NSNull(),
            "outcomes": outcomes,
        ]
        return EluV1BatchHTTPResponse(
            status: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        )
    }

    private func acknowledgementObject(
        for request: EluV1BatchHTTPRequest,
        result: String
    ) throws -> [String: Any] {
        let facts = try requestFacts(request)
        let outcomes = facts.records.map {
            [
                "sequence": $0.sequence,
                "recordId": $0.recordId,
                "kind": $0.kind,
                "result": result,
            ] as [String: Any]
        }
        return [
            "schemaVersion": 1,
            "requestId": facts.requestId,
            "streamId": facts.streamId,
            "resolvedThroughSequence": try XCTUnwrap(facts.records.last).sequence,
            "retryFromSequence": NSNull(),
            "outcomes": outcomes,
        ]
    }

    private struct RecordFact {
        let sequence: Int64
        let recordId: String
        let kind: String
    }

    private func requestFacts(
        _ request: EluV1BatchHTTPRequest
    ) throws -> (requestId: String, streamId: String, records: [RecordFact]) {
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        let requestId = try XCTUnwrap(root["requestId"] as? String)
        let streamId = try XCTUnwrap(root["streamId"] as? String)
        let rawRecords = try XCTUnwrap(root["records"] as? [[String: Any]])
        let records = try rawRecords.map { record -> RecordFact in
            let kind = try XCTUnwrap(record["kind"] as? String)
            let payload = try XCTUnwrap(record[kind] as? [String: Any])
            let sequence = try XCTUnwrap((payload["sequence"] as? NSNumber)?.int64Value)
            let idKey = kind == "event" ? "eventId" : "mutationId"
            return RecordFact(
                sequence: sequence,
                recordId: try XCTUnwrap(payload[idKey] as? String),
                kind: kind
            )
        }
        return (requestId, streamId, records)
    }
}

private final class TestStreamIdSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return "stream_moved_\(count)"
    }
}

private final class TestBatchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Date
    private var monotonic: UInt64
    /// Retry timers sleep for an hour instead of the backoff, so a slow run
    /// cannot fire a retry the test means to drive itself.
    private let holdsTimers: Bool
    private var sleeps = 0

    init(wall: Date, monotonic: UInt64, holdsTimers: Bool = false) {
        self.wall = wall
        self.monotonic = monotonic
        self.holdsTimers = holdsTimers
    }

    var source: EluV1BatchTimeSource {
        EluV1BatchTimeSource(
            wallNow: { [self] in
                lock.lock()
                defer { lock.unlock() }
                return wall
            },
            monotonicNow: { [self] in
                lock.lock()
                defer { lock.unlock() }
                return monotonic
            },
            sleep: { [self] nanoseconds in
                self.noteSleep()
                let held: UInt64 = 3_600_000_000_000
                try await Task.sleep(nanoseconds: self.holdsTimers ? held : nanoseconds)
            }
        )
    }

    func sleepsStarted() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sleeps
    }

    private func noteSleep() {
        lock.lock()
        defer { lock.unlock() }
        sleeps += 1
    }

    func setWall(_ value: Date) {
        lock.lock()
        wall = value
        lock.unlock()
    }

    func setMonotonic(_ value: UInt64) {
        lock.lock()
        monotonic = value
        lock.unlock()
    }
}

private final class TestScriptedWallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]
    private var index = 0

    init(values: [Date]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    var source: EluV1BatchTimeSource {
        EluV1BatchTimeSource(
            wallNow: { [self] in
                lock.lock()
                defer { lock.unlock() }
                let value = values[min(index, values.count - 1)]
                index += 1
                return value
            },
            monotonicNow: { 0 },
            sleep: { nanoseconds in try await Task.sleep(nanoseconds: nanoseconds) }
        )
    }
}

#if canImport(UIKit)
@MainActor
final class EluV1BatchBackgroundAdapterTests: XCTestCase {
    func testBackgroundAssertionEndsOnceOnSuccessFailureCancellationAndExpiry() async {
        let successEnded = expectation(description: "successful pass ended")
        let success = TestBackgroundTaskManager { _ in successEnded.fulfill() }
        let successAdapter = EluV1BatchBackgroundAdapter(manager: success)
        XCTAssertTrue(successAdapter.start {})
        await fulfillment(of: [successEnded], timeout: 1)
        XCTAssertEqual(success.ended.count, 1)

        let failureEnded = expectation(description: "failed pass ended")
        let failure = TestBackgroundTaskManager { _ in failureEnded.fulfill() }
        let failureAdapter = EluV1BatchBackgroundAdapter(manager: failure)
        XCTAssertTrue(failureAdapter.start { throw TestBatchTransportError.network })
        await fulfillment(of: [failureEnded], timeout: 1)
        XCTAssertEqual(failure.ended.count, 1)

        let cancellation = TestBackgroundTaskManager()
        let cancellationAdapter = EluV1BatchBackgroundAdapter(manager: cancellation)
        XCTAssertTrue(cancellationAdapter.start {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        })
        cancellationAdapter.cancel()
        XCTAssertEqual(cancellation.ended.count, 1)
        cancellationAdapter.cancel()
        XCTAssertEqual(cancellation.ended.count, 1)

        let expiry = TestBackgroundTaskManager()
        let expiryAdapter = EluV1BatchBackgroundAdapter(manager: expiry)
        XCTAssertTrue(expiryAdapter.start {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        })
        expiry.expire()
        XCTAssertEqual(expiry.ended.count, 1)
        await Task.yield()
        XCTAssertEqual(expiry.ended.count, 1)
    }

    func testBackgroundAdapterCoalescesWhileOnePassIsActive() async {
        let manager = TestBackgroundTaskManager()
        let adapter = EluV1BatchBackgroundAdapter(manager: manager)
        XCTAssertTrue(adapter.start {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        })
        XCTAssertFalse(adapter.start {})
        manager.expire()
        XCTAssertEqual(manager.began, 1)
        XCTAssertEqual(manager.ended.count, 1)
    }

    func testSynchronousBackgroundExpirationEndsInstalledAssertionExactlyOnce() async {
        let manager = TestBackgroundTaskManager(expireSynchronously: true)
        let adapter = EluV1BatchBackgroundAdapter(manager: manager)

        XCTAssertTrue(adapter.start {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        })
        XCTAssertEqual(manager.began, 1)
        XCTAssertEqual(manager.ended.count, 1)
        await Task.yield()
        XCTAssertEqual(manager.ended.count, 1)
        adapter.cancel()
        XCTAssertEqual(manager.ended.count, 1)
    }
}

@MainActor
private final class TestBackgroundTaskManager: EluV1IOSBackgroundTaskManaging {
    var began = 0
    var ended: [UIBackgroundTaskIdentifier] = []
    private var expiration: (@MainActor @Sendable () -> Void)?
    private let expireSynchronously: Bool
    private let onEnd: (@MainActor (UIBackgroundTaskIdentifier) -> Void)?

    init(
        expireSynchronously: Bool = false,
        onEnd: (@MainActor (UIBackgroundTaskIdentifier) -> Void)? = nil
    ) {
        self.expireSynchronously = expireSynchronously
        self.onEnd = onEnd
    }

    func begin(
        name _: String,
        expiration: @escaping @MainActor @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier {
        began += 1
        self.expiration = expiration
        if expireSynchronously {
            expiration()
        }
        return UIBackgroundTaskIdentifier(rawValue: began)
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
        onEnd?(identifier)
    }

    func expire() {
        expiration?()
    }
}
#endif
