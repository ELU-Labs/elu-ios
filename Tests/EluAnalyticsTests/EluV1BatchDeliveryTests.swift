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
        _ = try await appendRecords(queue, count: 65)
        let transport = TestBatchTransport(replies: [])
        let clock = TestBatchClock(
            wall: capturedAt.addingTimeInterval(
                EluV1BatchDeliveryCoordinator.maximumRecordAgeSeconds
            ),
            monotonic: 0
        )
        let coordinator = try self.coordinator(
            queue: queue,
            transport: transport,
            clock: clock
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
        _ = try await appendRecords(queue, count: 1_000)
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
        await queue.close()
    }

    func test413AgeTransitionDeletesOnlyAgedPrefixThenContinuesSubsegment() async throws {
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
                .accept,
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
        XCTAssertEqual(sequences, [[0, 1, 2], [1], [2]])
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

    func testRetryAgeTransitionDeletesOnlyAgedPrefixThenContinuesSuffix() async throws {
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
        let transport = TestBatchTransport(replies: [.network, .accept])
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
        XCTAssertEqual(sequences, [[0, 1, 2], [1, 2]])
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

    func testTransportErrorBodyLimitAcceptsExactBoundaryAndBlocksOneByteOver() async throws {
        for (size, expected) in [
            (
                EluV1BatchDeliveryCoordinator.maximumErrorResponseBytes,
                EluV1BatchDeliveryTriggerResult.preserved(.permanentHTTP(401))
            ),
            (
                EluV1BatchDeliveryCoordinator.maximumErrorResponseBytes + 1,
                EluV1BatchDeliveryTriggerResult.preserved(.protocolFailure)
            ),
        ] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let queue = try await makeQueue(directory: directory)
            _ = try await appendRecords(queue, count: 1)
            let transport = TestBatchTransport(
                replies: [.httpWithBodySize(401, nil, size)]
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
            await queue.close()
        }
    }

    func testSevenDayBoundaryAndFutureTimestampHandling() async throws {
        for (offset, shouldDiscard) in [
            (EluV1BatchDeliveryCoordinator.maximumRecordAgeSeconds - 0.001, false),
            (EluV1BatchDeliveryCoordinator.maximumRecordAgeSeconds, true),
            (EluV1BatchDeliveryCoordinator.maximumRecordAgeSeconds + 0.001, true),
            (-60.0, false),
        ] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let queue = try await makeQueue(directory: directory)
            _ = try await appendRecords(queue, count: 1)
            let transport = TestBatchTransport(replies: [.accept])
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
            if shouldDiscard {
                XCTAssertEqual(result, .resolved(delivered: 0, terminallyDiscarded: 1))
                let calls = await transport.callCount()
                XCTAssertEqual(calls, 0)
            } else {
                XCTAssertEqual(result, .resolved(delivered: 1, terminallyDiscarded: 0))
                let calls = await transport.callCount()
                XCTAssertEqual(calls, 1)
            }
            await queue.close()
        }
    }

    func testNonMonotonicRecordAgesStopPrefixBeforeAgedRow() async throws {
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
        let transport = TestBatchTransport(replies: [.accept, .accept])
        let coordinator = try self.coordinator(
            queue: queue,
            transport: transport,
            clock: clock
        )

        let result = await coordinator.trigger()
        XCTAssertEqual(result, .resolved(delivered: 2, terminallyDiscarded: 1))
        let sequences = await transport.recordSequences()
        XCTAssertEqual(sequences, [[0], [2]])
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

    func testAgeIsRecheckedAfterQueueValidationImmediatelyBeforeTransport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await makeQueue(directory: directory)
        _ = try await appendRecords(queue, count: 1)
        let transport = TestBatchTransport(replies: [.accept])
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
        XCTAssertEqual(calls, 0)
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

    private func coordinator(
        queue: EluSQLiteRuntimeQueue,
        byteLimit: Int = 1_000_000,
        transport: TestBatchTransport,
        clock: TestBatchClock? = nil,
        randomUnit: Double = 0.5,
        authorizationExpiry: Date? = nil
    ) throws -> EluV1BatchDeliveryCoordinator {
        let clock = clock ?? TestBatchClock(wall: capturedAt, monotonic: 0)
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
            randomUnit: { randomUnit }
        )
    }

    private func makeQueue(directory: URL) async throws -> EluSQLiteRuntimeQueue {
        let fixedClock = capturedAt
        return try await makeQueue(directory: directory, clock: { fixedClock })
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
        versions: EluVersionContext? = nil
    ) async throws -> [EluQueuedRecord] {
        var records: [EluQueuedRecord] = []
        let captureVersions = try versions ?? self.versions()
        for index in 0 ..< count {
            let generation = try await queue.snapshot().generation
            records.append(
                contentsOf: try await queue.applyMutation(
                    .setPersonProperties(
                        set: ["value_\(index)": .string(String(repeating: "x", count: valueBytes))],
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
    case network
    case mismatchedAcknowledgement
    case duplicateAcknowledgementKey
    case oversizedResponse
    case delayedAccept(UInt64)
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
        }
    }

    func callCount() -> Int { requests.count }
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

private final class TestBatchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Date
    private var monotonic: UInt64

    init(wall: Date, monotonic: UInt64) {
        self.wall = wall
        self.monotonic = monotonic
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
            sleep: { nanoseconds in try await Task.sleep(nanoseconds: nanoseconds) }
        )
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
        let success = TestBackgroundTaskManager()
        let successAdapter = EluV1BatchBackgroundAdapter(manager: success)
        XCTAssertTrue(successAdapter.start {})
        await eventually { success.ended.count == 1 }
        XCTAssertEqual(success.ended.count, 1)

        let failure = TestBackgroundTaskManager()
        let failureAdapter = EluV1BatchBackgroundAdapter(manager: failure)
        XCTAssertTrue(failureAdapter.start { throw TestBatchTransportError.network })
        await eventually { failure.ended.count == 1 }
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

    private func eventually(_ predicate: @MainActor () -> Bool) async {
        for _ in 0 ..< 100 where !predicate() {
            await Task.yield()
        }
    }
}

@MainActor
private final class TestBackgroundTaskManager: EluV1IOSBackgroundTaskManaging {
    var began = 0
    var ended: [UIBackgroundTaskIdentifier] = []
    private var expiration: (@MainActor @Sendable () -> Void)?
    private let expireSynchronously: Bool

    init(expireSynchronously: Bool = false) {
        self.expireSynchronously = expireSynchronously
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
    }

    func expire() {
        expiration?()
    }
}
#endif
