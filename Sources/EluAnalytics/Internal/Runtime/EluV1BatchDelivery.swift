import CryptoKit
import Dispatch
import Foundation

enum EluV1BatchDeliveryError: Error, Equatable, Sendable {
    case invalidAuthorization
    case invalidClock
    case invalidRequest
    case malformedResponse
    case responseTooLarge
}

struct EluV1BatchAuthorizationSnapshot: Equatable, Sendable {
    static let maximumBatchCount = 1_000
    static let minimumBatchBytes = 1_024
    static let maximumBatchBytes = 10_485_760

    let siteKey: String
    let eventsEndpoint: URL
    let expiresAt: Date
    let eventBatchCount: Int
    let eventBatchBytes: Int

    init(
        siteKey: String,
        eventsEndpoint: URL,
        expiresAt: Date,
        eventBatchCount: Int,
        eventBatchBytes: Int
    ) throws {
        let components = URLComponents(url: eventsEndpoint, resolvingAgainstBaseURL: false)
        guard !siteKey.isEmpty,
              siteKey.unicodeScalars.count <= 512,
              siteKey.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              let components,
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "ingest.elu.dev",
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.percentEncodedPath == "/v1/events",
              components.queryItems?.contains(where: { $0.name == "site_key" }) != true,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              (1 ... Self.maximumBatchCount).contains(eventBatchCount),
              (Self.minimumBatchBytes ... Self.maximumBatchBytes).contains(eventBatchBytes)
        else {
            throw EluV1BatchDeliveryError.invalidAuthorization
        }
        self.siteKey = siteKey
        self.eventsEndpoint = eventsEndpoint
        self.expiresAt = expiresAt
        self.eventBatchCount = eventBatchCount
        self.eventBatchBytes = eventBatchBytes
    }
}

struct EluV1BatchHTTPRequest: Equatable, Sendable {
    let url: URL
    let headers: [String: String]
    let body: Data
    let timeoutSeconds: TimeInterval
    let maximumResponseBytes: Int
}

struct EluV1BatchHTTPResponse: Equatable, Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

protocol EluV1BatchHTTPTransport: Sendable {
    func send(_ request: EluV1BatchHTTPRequest) async throws -> EluV1BatchHTTPResponse
}

struct EluV1BatchTimeSource: Sendable {
    let wallNow: @Sendable () -> Date
    let monotonicNow: @Sendable () -> UInt64
    let sleep: @Sendable (UInt64) async throws -> Void

    static let system = EluV1BatchTimeSource(
        wallNow: { Date() },
        monotonicNow: { DispatchTime.now().uptimeNanoseconds },
        sleep: { nanoseconds in try await Task.sleep(nanoseconds: nanoseconds) }
    )
}

enum EluV1BatchPreservationReason: Equatable, Sendable {
    case authorizationExpired
    case permanentHTTP(Int)
    case protocolFailure
    case queueFailure
    case cancelled
}

enum EluV1BatchDeliveryTriggerResult: Equatable, Sendable {
    case idle
    case coalesced
    case deferred(untilMonotonicNanoseconds: UInt64)
    case resolved(delivered: Int, terminallyDiscarded: Int)
    case bounded(delivered: Int, terminallyDiscarded: Int)
    case preserved(EluV1BatchPreservationReason)
}

private struct EluV1PreparedBatch: Sendable {
    let requestId: String
    let streamId: String
    let records: [EluQueuedRecord]
    let references: [EluQueueAcknowledgementReference]
    let body: Data
}

private struct EluV1PendingBatchRetry: Sendable {
    let records: [EluQueuedRecord]
    let attempt: Int
    let notBefore: UInt64
    let authorizationExpiry: UInt64
}

private struct EluV1BlockedBatchRequest: Sendable {
    let requestId: String
    let reason: EluV1BatchPreservationReason
}

private struct EluV1HTTPDateParts {
    let weekday: Int
    let day: Int
    let month: Int
    var year: Int
    let hour: Int
    let minute: Int
    let second: Int
}

private enum EluV1SegmentResult: Sendable {
    case idle
    case restart
    case resolved(delivered: Int, terminallyDiscarded: Int)
    case bounded(delivered: Int, terminallyDiscarded: Int)
    case deferred(UInt64)
    case preserved(EluV1BatchPreservationReason)

    var triggerResult: EluV1BatchDeliveryTriggerResult {
        switch self {
        case .idle:
            return .idle
        case .restart:
            return .idle
        case let .resolved(delivered, terminallyDiscarded):
            return .resolved(delivered: delivered, terminallyDiscarded: terminallyDiscarded)
        case let .bounded(delivered, terminallyDiscarded):
            return .bounded(delivered: delivered, terminallyDiscarded: terminallyDiscarded)
        case let .deferred(deadline):
            return .deferred(untilMonotonicNanoseconds: deadline)
        case let .preserved(reason):
            return .preserved(reason)
        }
    }
}

private struct EluV1ValidatedBatchAcknowledgement: Sendable {
    let deletableReferences: [EluQueueAcknowledgementReference]
    let acceptedCount: Int
    let terminallyRejectedCount: Int
    let retryFromSequence: Int64?
}

actor EluV1BatchDeliveryCoordinator {
    static let maximumRecordAgeSeconds: TimeInterval = 604_800
    static let maximumResponseBytes = 1_048_576
    static let maximumErrorResponseBytes = 65_536
    static let requestTimeoutSeconds: TimeInterval = 30
    static let baseRetryNanoseconds: UInt64 = 1_000_000_000
    static let maximumRetryNanoseconds: UInt64 = 60_000_000_000
    static let maximumNetworkRequestsPerPass = 11
    static let maximumLocalResolutionsPerPass = 64

    private let queue: EluSQLiteRuntimeQueue
    private let authorization: EluV1BatchAuthorizationSnapshot
    private let transport: any EluV1BatchHTTPTransport
    private let time: EluV1BatchTimeSource
    private let randomUnit: @Sendable () -> Double

    private var running = false
    private var followUpRequested = false
    private var pendingRetry: EluV1PendingBatchRetry?
    private var retryTimer: Task<Void, Never>?
    private var networkRequestsInPass = 0
    private var localResolutionsInPass = 0
    private var authorizationBlock: EluV1BatchPreservationReason?
    private var blockedRequest: EluV1BlockedBatchRequest?

    init(
        queue: EluSQLiteRuntimeQueue,
        authorization: EluV1BatchAuthorizationSnapshot,
        transport: any EluV1BatchHTTPTransport,
        time: EluV1BatchTimeSource = .system,
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0 ... 1) }
    ) {
        self.queue = queue
        self.authorization = authorization
        self.transport = transport
        self.time = time
        self.randomUnit = randomUnit
    }

    func trigger() async -> EluV1BatchDeliveryTriggerResult {
        if running {
            followUpRequested = true
            return .coalesced
        }

        if let pendingRetry {
            let monotonicNow = time.monotonicNow()
            if monotonicNow >= pendingRetry.authorizationExpiry || !authorizationIsCurrent() {
                self.pendingRetry = nil
                retryTimer?.cancel()
                retryTimer = nil
                followUpRequested = false
                return .preserved(.authorizationExpired)
            }
            if monotonicNow < pendingRetry.notBefore {
                followUpRequested = true
                ensureRetryTimer(for: pendingRetry)
                return .deferred(untilMonotonicNanoseconds: pendingRetry.notBefore)
            }
        }

        running = true
        networkRequestsInPass = 0
        localResolutionsInPass = 0
        let retry = pendingRetry
        pendingRetry = nil
        retryTimer?.cancel()
        retryTimer = nil

        let result: EluV1BatchDeliveryTriggerResult
        if Task.isCancelled {
            result = .preserved(.cancelled)
        } else if let retry {
            result = await performRetry(retry).triggerResult
        } else {
            result = await performFreshPass().triggerResult
        }
        running = false

        if followUpRequested,
           pendingRetry == nil,
           !Task.isCancelled
        {
            followUpRequested = false
            return result.merging(await trigger())
        }
        return result
    }

    func cancel() {
        retryTimer?.cancel()
        retryTimer = nil
        pendingRetry = nil
        followUpRequested = false
    }

    private func performFreshPass() async -> EluV1SegmentResult {
        var delivered = 0
        var terminallyDiscarded = 0
        while true {
            if let authorizationBlock {
                return .preserved(authorizationBlock)
            }
            guard authorizationIsCurrent() else {
                return .preserved(.authorizationExpired)
            }
            guard networkRequestsInPass < Self.maximumNetworkRequestsPerPass,
                  localResolutionsInPass < Self.maximumLocalResolutionsPerPass
            else {
                return .bounded(
                    delivered: delivered,
                    terminallyDiscarded: terminallyDiscarded
                )
            }

            let segment = await performFreshSegment()
            switch segment {
            case .idle:
                return delivered == 0 && terminallyDiscarded == 0
                    ? .idle
                    : .resolved(
                        delivered: delivered,
                        terminallyDiscarded: terminallyDiscarded
                    )
            case .restart:
                continue
            case let .resolved(segmentDelivered, segmentDiscarded):
                delivered += segmentDelivered
                terminallyDiscarded += segmentDiscarded
                guard segmentDelivered > 0 || segmentDiscarded > 0 else {
                    return .resolved(
                        delivered: delivered,
                        terminallyDiscarded: terminallyDiscarded
                    )
                }
            case let .bounded(segmentDelivered, segmentDiscarded):
                return .bounded(
                    delivered: delivered + segmentDelivered,
                    terminallyDiscarded: terminallyDiscarded + segmentDiscarded
                )
            case .deferred, .preserved:
                return segment
            }
        }
    }

    private func performFreshSegment() async -> EluV1SegmentResult {
        do {
            let snapshot = try await queue.snapshot()
            let records = try await queue.peek(
                maximumCount: authorization.eventBatchCount,
                maximumBytes: EluV1BatchAuthorizationSnapshot.maximumBatchBytes
            )
            guard !records.isEmpty else { return .idle }

            let now = try currentWallTime()
            if recordIsAged(records[0], at: now) {
                guard localResolutionsInPass < Self.maximumLocalResolutionsPerPass else {
                    return .bounded(delivered: 0, terminallyDiscarded: 0)
                }
                try await queue.acknowledge(
                    references(for: [records[0]], streamId: snapshot.streamId)
                )
                localResolutionsInPass += 1
                return .resolved(delivered: 0, terminallyDiscarded: 1)
            }
            let ageEligible = Array(records.prefix { !recordIsAged($0, at: now) })

            return await sendLargestHomogeneousPrefix(
                ageEligible,
                streamId: snapshot.streamId,
                attempt: 0
            )
        } catch {
            return .preserved(.queueFailure)
        }
    }

    private func performRetry(_ retry: EluV1PendingBatchRetry) async -> EluV1SegmentResult {
        let segment = await performRetrySegment(retry)
        if case .restart = segment {
            return await performFreshPass()
        }
        guard case let .resolved(delivered, terminallyDiscarded) = segment else {
            return segment
        }
        let continuation = await performFreshPass()
        return continuation.adding(
            delivered: delivered,
            terminallyDiscarded: terminallyDiscarded
        )
    }

    private func performRetrySegment(
        _ retry: EluV1PendingBatchRetry
    ) async -> EluV1SegmentResult {
        if let authorizationBlock {
            return .preserved(authorizationBlock)
        }
        guard authorizationIsCurrent() else {
            return .preserved(.authorizationExpired)
        }
        do {
            let snapshot = try await queue.snapshot()
            guard try await recordsStillMatchHead(retry.records, streamId: snapshot.streamId) else {
                return await performFreshPass()
            }
            return await sendExactRecords(
                retry.records,
                streamId: snapshot.streamId,
                attempt: retry.attempt
            )
        } catch {
            return .preserved(.queueFailure)
        }
    }

    private func sendLargestHomogeneousPrefix(
        _ records: [EluQueuedRecord],
        streamId: String,
        attempt: Int
    ) async -> EluV1SegmentResult {
        guard let head = records.first else {
            return .resolved(delivered: 0, terminallyDiscarded: 0)
        }
        let homogeneous = Array(records.prefix { $0.versions == head.versions })
        do {
            let sentAt = try currentWallTime()
            guard let prepared = try largestFittingPrefix(
                homogeneous,
                streamId: streamId,
                sentAt: sentAt
            ) else {
                guard localResolutionsInPass < Self.maximumLocalResolutionsPerPass else {
                    return .bounded(delivered: 0, terminallyDiscarded: 0)
                }
                try await queue.acknowledge(references(for: [head], streamId: streamId))
                localResolutionsInPass += 1
                return .resolved(delivered: 0, terminallyDiscarded: 1)
            }
            return await send(prepared, attempt: attempt)
        } catch {
            return .preserved(.queueFailure)
        }
    }

    private func send(
        _ prepared: EluV1PreparedBatch,
        attempt: Int
    ) async -> EluV1SegmentResult {
        guard authorizationIsCurrent() else {
            return .preserved(.authorizationExpired)
        }
        guard !Task.isCancelled else {
            return .preserved(.cancelled)
        }
        do {
            guard try await recordsStillMatchHead(
                prepared.records,
                streamId: prepared.streamId
            ) else {
                return .preserved(.queueFailure)
            }
        } catch {
            return .preserved(.queueFailure)
        }
        // The queue check above crosses an actor boundary. Use one fresh wall
        // reading to revalidate both authorization and every prepared row at
        // the final network boundary.
        let preflightNow: Date
        do {
            preflightNow = try currentWallTime()
        } catch {
            return .preserved(.protocolFailure)
        }
        guard authorizationIsCurrent(at: preflightNow) else {
            return .preserved(.authorizationExpired)
        }
        guard prepared.records.allSatisfy({ !recordIsAged($0, at: preflightNow) }) else {
            return .restart
        }
        guard !Task.isCancelled else {
            return .preserved(.cancelled)
        }
        if let blockedRequest, blockedRequest.requestId == prepared.requestId {
            return .preserved(blockedRequest.reason)
        }
        guard networkRequestsInPass < Self.maximumNetworkRequestsPerPass else {
            return .bounded(delivered: 0, terminallyDiscarded: 0)
        }
        networkRequestsInPass += 1

        let response: EluV1BatchHTTPResponse
        do {
            response = try await transport.send(
                EluV1BatchHTTPRequest(
                    url: authorization.eventsEndpoint,
                    headers: [
                        "Accept": "application/json",
                        "Authorization": "Bearer \(authorization.siteKey)",
                        "Content-Type": "application/json",
                    ],
                    body: prepared.body,
                    timeoutSeconds: Self.requestTimeoutSeconds,
                    maximumResponseBytes: Self.maximumResponseBytes
                )
            )
        } catch is CancellationError {
            return .preserved(.cancelled)
        } catch is EluV1BatchDeliveryError {
            return blockRequest(prepared.requestId, reason: .protocolFailure)
        } catch {
            return scheduleRetry(records: prepared.records, attempt: attempt + 1, retryAfter: 0)
        }
        guard response.body.count <= Self.maximumResponseBytes else {
            return blockRequest(prepared.requestId, reason: .protocolFailure)
        }
        if (200 ... 299).contains(response.status) {
            let result = await applyAcknowledgement(response, to: prepared, attempt: attempt)
            if case .preserved(.protocolFailure) = result {
                return blockRequest(prepared.requestId, reason: .protocolFailure)
            }
            return result
        }
        return await handleHTTPFailure(response, for: prepared, attempt: attempt)
    }

    private func applyAcknowledgement(
        _ response: EluV1BatchHTTPResponse,
        to prepared: EluV1PreparedBatch,
        attempt: Int
    ) async -> EluV1SegmentResult {
        let acknowledgement: EluV1ValidatedBatchAcknowledgement
        do {
            acknowledgement = try Self.validateAcknowledgement(response.body, request: prepared)
        } catch {
            return .preserved(.protocolFailure)
        }

        let retryAfterHeader: String?
        do {
            retryAfterHeader = try Self.header(named: "Retry-After", in: response.headers)
        } catch {
            return .preserved(.protocolFailure)
        }
        let retryAfter: TimeInterval
        if acknowledgement.retryFromSequence == nil {
            guard retryAfterHeader == nil else {
                return .preserved(.protocolFailure)
            }
            retryAfter = 0
        } else if let retryAfterHeader {
            guard let parsed = Self.parseRetryAfter(retryAfterHeader, now: time.wallNow()) else {
                return .preserved(.protocolFailure)
            }
            retryAfter = parsed
        } else {
            retryAfter = 0
        }

        let retrySuffix: [EluQueuedRecord]?
        let nextAttempt: Int
        if let retryFromSequence = acknowledgement.retryFromSequence {
            guard let retryIndex = prepared.records.firstIndex(where: {
                $0.sequence == retryFromSequence
            }) else {
                return .preserved(.protocolFailure)
            }
            retrySuffix = Array(prepared.records[retryIndex...])
            nextAttempt = retryIndex == 0 ? attempt + 1 : 1
        } else {
            retrySuffix = nil
            nextAttempt = 0
        }

        do {
            if !acknowledgement.deletableReferences.isEmpty {
                try await queue.acknowledge(acknowledgement.deletableReferences)
            }
            guard let retrySuffix else {
                return .resolved(
                    delivered: acknowledgement.acceptedCount,
                    terminallyDiscarded: acknowledgement.terminallyRejectedCount
                )
            }
            let deferred = scheduleRetry(
                records: retrySuffix,
                attempt: nextAttempt,
                retryAfter: retryAfter
            )
            if acknowledgement.deletableReferences.isEmpty {
                return deferred
            }
            // The resolved prefix has been committed. The deferred result still
            // records the monotonic boundary; queue state is the source of truth.
            return deferred
        } catch {
            return .preserved(.queueFailure)
        }
    }

    private func handleHTTPFailure(
        _ response: EluV1BatchHTTPResponse,
        for prepared: EluV1PreparedBatch,
        attempt: Int
    ) async -> EluV1SegmentResult {
        guard response.body.count <= Self.maximumErrorResponseBytes else {
            return blockRequest(prepared.requestId, reason: .protocolFailure)
        }
        let retryAfterHeader: String?
        do {
            retryAfterHeader = try Self.header(named: "Retry-After", in: response.headers)
        } catch {
            return blockRequest(prepared.requestId, reason: .protocolFailure)
        }
        guard Self.validateErrorResponse(
            response.body,
            status: response.status,
            requestId: prepared.requestId
        ) else {
            return blockRequest(prepared.requestId, reason: .protocolFailure)
        }

        switch response.status {
        case 401, 403:
            guard retryAfterHeader == nil else {
                return blockRequest(prepared.requestId, reason: .protocolFailure)
            }
            let reason = EluV1BatchPreservationReason.permanentHTTP(response.status)
            authorizationBlock = reason
            return .preserved(reason)

        case 413:
            guard retryAfterHeader == nil else {
                return blockRequest(prepared.requestId, reason: .protocolFailure)
            }
            if prepared.records.count == 1 {
                do {
                    try await queue.acknowledge(prepared.references)
                    return .resolved(delivered: 0, terminallyDiscarded: 1)
                } catch {
                    return .preserved(.queueFailure)
                }
            }
            let firstCount = (prepared.records.count + 1) / 2
            let firstRecords = Array(prepared.records.prefix(firstCount))
            let secondRecords = Array(prepared.records.dropFirst(firstCount))
            let first = await sendExactRecords(firstRecords, streamId: prepared.streamId)
            guard case let .resolved(firstDelivered, firstDiscarded) = first else {
                return first
            }
            let second = await sendExactRecords(secondRecords, streamId: prepared.streamId)
            return second.adding(delivered: firstDelivered, terminallyDiscarded: firstDiscarded)

        case 429:
            guard let retryAfterHeader,
                  let delay = Self.parseRetryAfter(retryAfterHeader, now: time.wallNow())
            else {
                return blockRequest(prepared.requestId, reason: .protocolFailure)
            }
            return scheduleRetry(
                records: prepared.records,
                attempt: attempt + 1,
                retryAfter: delay
            )

        case 500 ... 599:
            let delay: TimeInterval
            if let retryAfterHeader {
                guard let parsed = Self.parseRetryAfter(retryAfterHeader, now: time.wallNow()) else {
                    return blockRequest(prepared.requestId, reason: .protocolFailure)
                }
                delay = parsed
            } else {
                delay = 0
            }
            return scheduleRetry(
                records: prepared.records,
                attempt: attempt + 1,
                retryAfter: delay
            )

        default:
            return blockRequest(
                prepared.requestId,
                reason: .permanentHTTP(response.status)
            )
        }
    }

    private func blockRequest(
        _ requestId: String,
        reason: EluV1BatchPreservationReason
    ) -> EluV1SegmentResult {
        blockedRequest = EluV1BlockedBatchRequest(requestId: requestId, reason: reason)
        return .preserved(reason)
    }

    private func sendExactRecords(
        _ records: [EluQueuedRecord],
        streamId: String,
        attempt: Int = 0
    ) async -> EluV1SegmentResult {
        guard !records.isEmpty else {
            return .resolved(delivered: 0, terminallyDiscarded: 0)
        }
        guard authorizationIsCurrent() else {
            return .preserved(.authorizationExpired)
        }
        do {
            let now = try currentWallTime()
            if recordIsAged(records[0], at: now) {
                guard localResolutionsInPass < Self.maximumLocalResolutionsPerPass else {
                    return .bounded(delivered: 0, terminallyDiscarded: 0)
                }
                try await queue.acknowledge(references(for: [records[0]], streamId: streamId))
                localResolutionsInPass += 1
                guard records.count > 1 else {
                    return .resolved(delivered: 0, terminallyDiscarded: 1)
                }
                guard localResolutionsInPass < Self.maximumLocalResolutionsPerPass else {
                    return .bounded(delivered: 0, terminallyDiscarded: 1)
                }
                let continuation = await sendExactRecords(
                    Array(records.dropFirst()),
                    streamId: streamId,
                    attempt: 0
                )
                return continuation.addingTerminallyDiscarded(1)
            }

            let ageEligible = Array(records.prefix { !recordIsAged($0, at: now) })
            guard let prepared = try prepareExact(
                records: ageEligible,
                streamId: streamId,
                sentAt: now
            ) else {
                return .preserved(.protocolFailure)
            }
            let result = await send(
                prepared,
                attempt: ageEligible.count == records.count ? attempt : 0
            )
            guard case let .resolved(delivered, terminallyDiscarded) = result,
                  ageEligible.count < records.count
            else {
                return result
            }
            let continuation = await sendExactRecords(
                Array(records.dropFirst(ageEligible.count)),
                streamId: streamId,
                attempt: 0
            )
            return continuation.adding(
                delivered: delivered,
                terminallyDiscarded: terminallyDiscarded
            )
        } catch {
            return .preserved(.queueFailure)
        }
    }

    private func largestFittingPrefix(
        _ records: [EluQueuedRecord],
        streamId: String,
        sentAt: Date
    ) throws -> EluV1PreparedBatch? {
        guard !records.isEmpty else { return nil }
        var low = 1
        var high = records.count
        var best: EluV1PreparedBatch?
        while low <= high {
            let count = low + (high - low) / 2
            let candidate = try prepareExact(
                records: Array(records.prefix(count)),
                streamId: streamId,
                sentAt: sentAt
            )
            guard let candidate else {
                high = count - 1
                continue
            }
            if candidate.body.count <= authorization.eventBatchBytes {
                best = candidate
                low = count + 1
            } else {
                high = count - 1
            }
        }
        return best
    }

    private func prepareExact(
        records: [EluQueuedRecord],
        streamId: String,
        sentAt: Date
    ) throws -> EluV1PreparedBatch? {
        guard let versions = records.first?.versions,
              !records.isEmpty,
              records.count <= authorization.eventBatchCount,
              records.allSatisfy({ $0.versions == versions })
        else {
            return nil
        }
        let references = references(for: records, streamId: streamId)
        let requestId = try Self.requestId(
            streamId: streamId,
            versions: versions,
            references: references
        )
        let body = try EluQueueBatchCodec.encodeBatch(
            requestId: requestId,
            streamId: streamId,
            sentAt: sentAt,
            versions: versions,
            records: records
        )
        guard body.count <= authorization.eventBatchBytes else {
            return nil
        }
        return EluV1PreparedBatch(
            requestId: requestId,
            streamId: streamId,
            records: records,
            references: references,
            body: body
        )
    }

    private func recordsStillMatchHead(
        _ records: [EluQueuedRecord],
        streamId: String
    ) async throws -> Bool {
        guard !records.isEmpty else { return false }
        let snapshot = try await queue.snapshot()
        guard snapshot.streamId == streamId else { return false }
        let head = try await queue.peek(
            maximumCount: records.count,
            maximumBytes: EluV1BatchAuthorizationSnapshot.maximumBatchBytes
        )
        return references(for: head, streamId: streamId)
            == references(for: records, streamId: streamId)
    }

    private func references(
        for records: [EluQueuedRecord],
        streamId: String
    ) -> [EluQueueAcknowledgementReference] {
        records.map {
            EluQueueAcknowledgementReference(
                streamId: streamId,
                sequence: $0.sequence,
                kind: $0.kind,
                recordId: $0.recordId
            )
        }
    }

    private func recordIsAged(_ record: EluQueuedRecord, at now: Date) -> Bool {
        now.timeIntervalSince(record.occurredAt) >= Self.maximumRecordAgeSeconds
    }

    private func authorizationIsCurrent() -> Bool {
        let now = time.wallNow()
        return authorizationIsCurrent(at: now)
    }

    private func authorizationIsCurrent(at now: Date) -> Bool {
        now.timeIntervalSinceReferenceDate.isFinite && now < authorization.expiresAt
    }

    private func currentWallTime() throws -> Date {
        let now = time.wallNow()
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw EluV1BatchDeliveryError.invalidClock
        }
        return now
    }

    private func scheduleRetry(
        records: [EluQueuedRecord],
        attempt: Int,
        retryAfter: TimeInterval
    ) -> EluV1SegmentResult {
        let wallNow = time.wallNow()
        let remainingAuthorization = authorization.expiresAt.timeIntervalSince(wallNow)
        guard wallNow.timeIntervalSinceReferenceDate.isFinite,
              remainingAuthorization.isFinite,
              remainingAuthorization > 0
        else {
            pendingRetry = nil
            retryTimer?.cancel()
            retryTimer = nil
            return .preserved(.authorizationExpired)
        }
        let exponent = min(max(attempt - 1, 0), 16)
        let multiplier = UInt64(1) << UInt64(exponent)
        let uncapped = Self.baseRetryNanoseconds.multipliedReportingOverflow(by: multiplier)
        let exponential = uncapped.overflow
            ? Self.maximumRetryNanoseconds
            : min(uncapped.partialValue, Self.maximumRetryNanoseconds)
        let sample = randomUnit()
        let unit = sample.isFinite ? min(max(sample, 0), 1) : 0.5
        let jittered = UInt64(Double(exponential) * (0.5 + unit * 0.5))
        let retryAfterNanoseconds = Self.nanoseconds(from: retryAfter)
        let delay = max(jittered, retryAfterNanoseconds)
        let now = time.monotonicNow()
        let deadline = now.addingReportingOverflow(delay)
        let notBefore = deadline.overflow ? UInt64.max : deadline.partialValue
        let expiryDelay = Self.nanoseconds(from: remainingAuthorization)
        let expiry = now.addingReportingOverflow(expiryDelay)
        let authorizationExpiry = expiry.overflow ? UInt64.max : expiry.partialValue
        let pending = EluV1PendingBatchRetry(
            records: records,
            attempt: attempt,
            notBefore: notBefore,
            authorizationExpiry: authorizationExpiry
        )
        pendingRetry = pending
        ensureRetryTimer(for: pending)
        return .deferred(notBefore)
    }

    private func ensureRetryTimer(for retry: EluV1PendingBatchRetry) {
        guard retryTimer == nil else { return }
        let time = self.time
        let wakeAt = min(retry.notBefore, retry.authorizationExpiry)
        retryTimer = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let now = time.monotonicNow()
                    guard now < wakeAt else { break }
                    try await time.sleep(wakeAt - now)
                }
                guard !Task.isCancelled else { return }
                await self?.retryTimerFired(
                    notBefore: retry.notBefore,
                    authorizationExpiry: retry.authorizationExpiry
                )
            } catch {
                // Cancellation is the only expected timer error. Durable rows
                // remain untouched and a future trigger can resume the pass.
            }
        }
    }

    private func retryTimerFired(
        notBefore: UInt64,
        authorizationExpiry: UInt64
    ) async {
        guard pendingRetry?.notBefore == notBefore,
              pendingRetry?.authorizationExpiry == authorizationExpiry
        else {
            return
        }
        retryTimer = nil
        if time.monotonicNow() >= authorizationExpiry || !authorizationIsCurrent() {
            pendingRetry = nil
            followUpRequested = false
            return
        }
        _ = await trigger()
    }

    private static func nanoseconds(from seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let value = seconds * 1_000_000_000
        return value >= Double(UInt64.max) ? UInt64.max : UInt64(value.rounded(.up))
    }

    private static func requestId(
        streamId: String,
        versions: EluVersionContext,
        references: [EluQueueAcknowledgementReference]
    ) throws -> String {
        try requestIdForFields(
            streamId: streamId,
            schemaVersion: String(versions.schemaVersion),
            contractVersion: versions.contractVersion,
            platform: versions.platform,
            runtimeName: versions.runtime.name,
            runtimeVersion: versions.runtime.version,
            facadeName: versions.facade.name,
            facadeVersion: versions.facade.version,
            build: versions.build,
            records: references.map {
                (
                    kind: $0.kind == .event ? UInt8(1) : UInt8(4),
                    sequence: $0.sequence,
                    recordId: $0.recordId
                )
            }
        )
    }

    static func requestIdForFields(
        streamId: String,
        schemaVersion: String,
        contractVersion: String,
        platform: String,
        runtimeName: String,
        runtimeVersion: String,
        facadeName: String,
        facadeVersion: String,
        build: String?,
        records: [(kind: UInt8, sequence: Int64, recordId: String)]
    ) throws -> String {
        func appendUInt32(_ value: UInt32, to data: inout Data) {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }

        func appendInt64(_ value: Int64, to data: inout Data) {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }

        func appendString(_ value: String, to data: inout Data) throws {
            let bytes = Data(value.utf8)
            guard bytes.count <= Int(UInt32.max) else {
                throw EluV1BatchDeliveryError.invalidRequest
            }
            appendUInt32(UInt32(bytes.count), to: &data)
            data.append(bytes)
        }

        let strings = [
            streamId, schemaVersion, contractVersion, platform, runtimeName,
            runtimeVersion, facadeName, facadeVersion,
        ]
        guard strings.allSatisfy({ !$0.isEmpty }),
              records.count <= Int(UInt32.max),
              records.allSatisfy({
                  ($0.kind == 1 || $0.kind == 4)
                      && $0.sequence >= 0
                      && !$0.recordId.isEmpty
              })
        else {
            throw EluV1BatchDeliveryError.invalidRequest
        }

        var material = Data("elu-sdk-batch-request-v1".utf8)
        material.append(0)
        for value in strings {
            try appendString(value, to: &material)
        }
        if let build {
            material.append(1)
            try appendString(build, to: &material)
        } else {
            material.append(0)
        }
        appendUInt32(UInt32(records.count), to: &material)
        for record in records {
            material.append(record.kind)
            appendInt64(record.sequence, to: &material)
            try appendString(record.recordId, to: &material)
        }

        let digest = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        return "request_\(digest)"
    }
}

private extension EluV1SegmentResult {
    func adding(delivered: Int, terminallyDiscarded: Int) -> EluV1SegmentResult {
        switch self {
        case let .resolved(currentDelivered, currentDiscarded):
            return .resolved(
                delivered: delivered + currentDelivered,
                terminallyDiscarded: terminallyDiscarded + currentDiscarded
            )
        case let .bounded(currentDelivered, currentDiscarded):
            return .bounded(
                delivered: delivered + currentDelivered,
                terminallyDiscarded: terminallyDiscarded + currentDiscarded
            )
        case .idle where delivered > 0 || terminallyDiscarded > 0:
            return .resolved(
                delivered: delivered,
                terminallyDiscarded: terminallyDiscarded
            )
        default:
            return self
        }
    }

    func addingTerminallyDiscarded(_ count: Int) -> EluV1SegmentResult {
        adding(delivered: 0, terminallyDiscarded: count)
    }
}

private extension EluV1BatchDeliveryTriggerResult {
    func merging(_ later: EluV1BatchDeliveryTriggerResult) -> EluV1BatchDeliveryTriggerResult {
        switch (self, later) {
        case let (
            .resolved(firstDelivered, firstDiscarded),
            .resolved(secondDelivered, secondDiscarded)
        ):
            return .resolved(
                delivered: firstDelivered + secondDelivered,
                terminallyDiscarded: firstDiscarded + secondDiscarded
            )
        case let (
            .resolved(firstDelivered, firstDiscarded),
            .bounded(secondDelivered, secondDiscarded)
        ), let (
            .bounded(firstDelivered, firstDiscarded),
            .bounded(secondDelivered, secondDiscarded)
        ):
            return .bounded(
                delivered: firstDelivered + secondDelivered,
                terminallyDiscarded: firstDiscarded + secondDiscarded
            )
        case let (
            .bounded(firstDelivered, firstDiscarded),
            .resolved(secondDelivered, secondDiscarded)
        ):
            return .resolved(
                delivered: firstDelivered + secondDelivered,
                terminallyDiscarded: firstDiscarded + secondDiscarded
            )
        case (.bounded, .idle):
            return self
        case (.resolved, .idle), (.idle, .resolved), (.idle, .idle):
            return self == .idle ? later : self
        default:
            return later
        }
    }
}

extension EluV1BatchDeliveryCoordinator {
    private static func validateAcknowledgement(
        _ data: Data,
        request: EluV1PreparedBatch
    ) throws -> EluV1ValidatedBatchAcknowledgement {
        let root = try EluV1StrictTransportJSON.parse(data)
        let object = try requireObject(
            root,
            required: [
                "schemaVersion", "requestId", "streamId", "resolvedThroughSequence",
                "retryFromSequence", "outcomes",
            ]
        )
        guard object["schemaVersion"]?.int64Value == 1,
              object["requestId"]?.stringValue == request.requestId,
              object["streamId"]?.stringValue == request.streamId,
              let outcomes = object["outcomes"]?.arrayValue,
              (1 ... 1_000).contains(outcomes.count),
              outcomes.count <= request.references.count
        else {
            throw EluV1BatchDeliveryError.malformedResponse
        }

        var retryableIndex: Int?
        var resolvedResults: [String] = []
        for (index, value) in outcomes.enumerated() {
            let outcome = try requireObject(
                value,
                required: ["sequence", "recordId", "kind", "result"],
                optional: ["code"]
            )
            let reference = request.references[index]
            guard outcome["sequence"]?.int64Value == reference.sequence,
                  outcome["recordId"]?.stringValue == reference.recordId,
                  outcome["kind"]?.stringValue == reference.kind.rawValue,
                  let result = outcome["result"]?.stringValue,
                  ["accepted", "terminally-rejected", "retryable"].contains(result)
            else {
                throw EluV1BatchDeliveryError.malformedResponse
            }
            if result == "accepted" {
                guard outcome["code"] == nil else {
                    throw EluV1BatchDeliveryError.malformedResponse
                }
            } else {
                guard let code = outcome["code"]?.stringValue,
                      validCode(code)
                else {
                    throw EluV1BatchDeliveryError.malformedResponse
                }
            }
            if result == "retryable" {
                guard retryableIndex == nil, index == outcomes.count - 1 else {
                    throw EluV1BatchDeliveryError.malformedResponse
                }
                retryableIndex = index
            } else {
                resolvedResults.append(result)
            }
        }

        if retryableIndex == nil, outcomes.count != request.references.count {
            throw EluV1BatchDeliveryError.malformedResponse
        }
        let resolvedCount = retryableIndex ?? outcomes.count
        let expectedResolved = resolvedCount == 0
            ? nil
            : request.references[resolvedCount - 1].sequence
        let expectedRetry = retryableIndex.map { request.references[$0].sequence }
        guard try nullableInt64(object["resolvedThroughSequence"]) == expectedResolved,
              try nullableInt64(object["retryFromSequence"]) == expectedRetry
        else {
            throw EluV1BatchDeliveryError.malformedResponse
        }
        return EluV1ValidatedBatchAcknowledgement(
            deletableReferences: Array(request.references.prefix(resolvedCount)),
            acceptedCount: resolvedResults.prefix(resolvedCount).filter { $0 == "accepted" }.count,
            terminallyRejectedCount: resolvedResults.prefix(resolvedCount)
                .filter { $0 == "terminally-rejected" }.count,
            retryFromSequence: expectedRetry
        )
    }

    private static func validateErrorResponse(
        _ data: Data,
        status: Int,
        requestId: String
    ) -> Bool {
        do {
            let root = try EluV1StrictTransportJSON.parse(data)
            let object = try requireObject(
                root,
                required: ["schemaVersion", "status", "code", "disposition", "message"],
                optional: ["requestId"]
            )
            let expectedDisposition: String
            switch status {
            case 401, 403:
                expectedDisposition = "permanent"
            case 413:
                expectedDisposition = "retry-after-reduction"
            case 429, 500 ... 599:
                expectedDisposition = "retryable"
            default:
                return false
            }
            guard object["schemaVersion"]?.int64Value == 1,
                  object["status"]?.int64Value == Int64(status),
                  object["disposition"]?.stringValue == expectedDisposition,
                  let code = object["code"]?.stringValue,
                  validCode(code),
                  let message = object["message"]?.stringValue,
                  (1 ... 256).contains(message.unicodeScalars.count)
            else {
                return false
            }
            if let responseRequestId = object["requestId"]?.stringValue {
                guard responseRequestId == requestId else { return false }
            } else if object["requestId"] != nil {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private static func requireObject(
        _ value: EluV1StrictTransportJSONValue,
        required: Set<String>,
        optional: Set<String> = []
    ) throws -> [String: EluV1StrictTransportJSONValue] {
        guard let object = value.objectValue,
              required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: required.union(optional))
        else {
            throw EluV1BatchDeliveryError.malformedResponse
        }
        return object
    }

    private static func nullableInt64(
        _ value: EluV1StrictTransportJSONValue?
    ) throws -> Int64? {
        guard let value else {
            throw EluV1BatchDeliveryError.malformedResponse
        }
        if case .null = value { return nil }
        guard let integer = value.int64Value, integer >= 0 else {
            throw EluV1BatchDeliveryError.malformedResponse
        }
        return integer
    }

    private static func validCode(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1 ... 64).contains(bytes.count),
              let first = bytes.first,
              (0x61 ... 0x7A).contains(first)
        else {
            return false
        }
        return bytes.dropFirst().allSatisfy {
            (0x61 ... 0x7A).contains($0)
                || (0x30 ... 0x39).contains($0)
                || $0 == 0x2D
        }
    }

    private static func header(
        named name: String,
        in headers: [String: String]
    ) throws -> String? {
        let matches = headers.filter { $0.key.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count <= 1 else {
            throw EluV1BatchDeliveryError.malformedResponse
        }
        return matches.first?.value
    }

    static func parseRetryAfter(_ value: String, now: Date) -> TimeInterval? {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty,
           normalized.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }),
           let seconds = UInt64(normalized)
        {
            return seconds > UInt64(Int64.max)
                ? nil
                : TimeInterval(seconds)
        }
        guard let date = parseHTTPDate(normalized, now: now) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    private static func parseHTTPDate(_ value: String, now: Date) -> Date? {
        let shortWeekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let longWeekdays = [
            "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
        ]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

        func parts(
            weekday: String,
            weekdays: [String],
            day: String,
            month: String,
            year: String,
            hour: String,
            minute: String,
            second: String
        ) -> EluV1HTTPDateParts? {
            guard let weekdayIndex = weekdays.firstIndex(of: weekday),
                  let monthIndex = months.firstIndex(of: month),
                  let dayValue = Int(day),
                  let yearValue = Int(year),
                  let hourValue = Int(hour),
                  let minuteValue = Int(minute),
                  let secondValue = Int(second)
            else {
                return nil
            }
            return EluV1HTTPDateParts(
                weekday: weekdayIndex,
                day: dayValue,
                month: monthIndex + 1,
                year: yearValue,
                hour: hourValue,
                minute: minuteValue,
                second: secondValue
            )
        }

        var parsed: EluV1HTTPDateParts?
        if let fields = regexCaptures(
            #"^([A-Z][a-z]{2}), ([0-9]{2}) ([A-Z][a-z]{2}) ([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT$"#,
            in: value
        ) {
            parsed = parts(
                weekday: fields[0],
                weekdays: shortWeekdays,
                day: fields[1],
                month: fields[2],
                year: fields[3],
                hour: fields[4],
                minute: fields[5],
                second: fields[6]
            )
        } else if let fields = regexCaptures(
            #"^([A-Z][a-z]+), ([0-9]{2})-([A-Z][a-z]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT$"#,
            in: value
        ) {
            guard var candidate = parts(
                weekday: fields[0],
                weekdays: longWeekdays,
                day: fields[1],
                month: fields[2],
                year: fields[3],
                hour: fields[4],
                minute: fields[5],
                second: fields[6]
            ), let resolvedYear = resolveTwoDigitHTTPYear(candidate, now: now)
            else {
                return nil
            }
            candidate.year = resolvedYear
            parsed = candidate
        } else if let fields = regexCaptures(
            #"^([A-Z][a-z]{2}) ([A-Z][a-z]{2}) (?: ([0-9])|([0-9]{2})) ([0-9]{2}):([0-9]{2}):([0-9]{2}) ([0-9]{4})$"#,
            in: value
        ) {
            parsed = parts(
                weekday: fields[0],
                weekdays: shortWeekdays,
                day: fields[2].isEmpty ? fields[3] : fields[2],
                month: fields[1],
                year: fields[7],
                hour: fields[4],
                minute: fields[5],
                second: fields[6]
            )
        }
        guard let parsed else { return nil }
        return verifiedHTTPDate(parsed)
    }

    private static func regexCaptures(_ pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex ..< value.endIndex, in: value)
              ),
              match.range == NSRange(value.startIndex ..< value.endIndex, in: value)
        else {
            return nil
        }
        return (1 ..< match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: value)
            else {
                return ""
            }
            return String(value[swiftRange])
        }
    }

    private static func httpCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func unverifiedHTTPDate(_ parts: EluV1HTTPDateParts) -> Date? {
        var components = DateComponents()
        components.calendar = httpCalendar()
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = parts.year
        components.month = parts.month
        components.day = parts.day
        components.hour = parts.hour
        components.minute = parts.minute
        components.second = parts.second
        components.nanosecond = 0
        return components.date
    }

    private static func verifiedHTTPDate(_ parts: EluV1HTTPDateParts) -> Date? {
        guard let date = unverifiedHTTPDate(parts) else { return nil }
        let values = httpCalendar().dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday],
            from: date
        )
        guard values.year == parts.year,
              values.month == parts.month,
              values.day == parts.day,
              values.hour == parts.hour,
              values.minute == parts.minute,
              values.second == parts.second,
              values.weekday == parts.weekday + 1
        else {
            return nil
        }
        return date
    }

    private static func resolveTwoDigitHTTPYear(
        _ parts: EluV1HTTPDateParts,
        now: Date
    ) -> Int? {
        let calendar = httpCalendar()
        guard let currentYear = calendar.dateComponents([.year], from: now).year,
              let pastBoundary = calendar.date(byAdding: .year, value: -50, to: now),
              let futureBoundary = calendar.date(byAdding: .year, value: 50, to: now)
        else {
            return nil
        }
        var candidate = parts
        candidate.year = (currentYear / 100) * 100 + parts.year
        guard let candidateDate = unverifiedHTTPDate(candidate) else { return nil }
        if candidateDate < pastBoundary {
            return candidate.year + 100
        }
        if candidateDate > futureBoundary {
            return candidate.year - 100
        }
        return candidate.year
    }
}
