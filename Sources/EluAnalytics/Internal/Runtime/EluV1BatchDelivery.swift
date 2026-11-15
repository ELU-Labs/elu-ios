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
        endpointPolicy: EluEndpointPolicy = .cloud,
        expiresAt: Date,
        eventBatchCount: Int,
        eventBatchBytes: Int
    ) throws {
        guard !siteKey.isEmpty,
              siteKey.unicodeScalars.count <= 512,
              siteKey.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              endpointPolicy.endpoint(eventsEndpoint.absoluteString, role: .events) != nil,
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

/// Where a batch goes: the queue's installation stream, whose references
/// acknowledge rows locally, and the wire stream the request carries.
private struct EluV1DeliveryTarget: Equatable, Sendable {
    let installationStreamId: String
    let streamId: String
}

private struct EluV1PreparedBatch: Sendable {
    let requestId: String
    let target: EluV1DeliveryTarget
    let records: [EluQueuedRecord]
    let references: [EluQueueAcknowledgementReference]
    let body: Data

    var streamId: String { target.streamId }
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
    /// The pass continues from the queue head: the wire stream moved, or a
    /// prepared record outlived its server outcome before it was sent. The
    /// counts are what was resolved before that.
    case restart(delivered: Int, terminallyDiscarded: Int)
    case resolved(delivered: Int, terminallyDiscarded: Int)
    case bounded(delivered: Int, terminallyDiscarded: Int)
    case deferred(UInt64)
    case preserved(EluV1BatchPreservationReason)

    var triggerResult: EluV1BatchDeliveryTriggerResult {
        switch self {
        case .idle:
            return .idle
        case let .restart(delivered, terminallyDiscarded):
            return delivered == 0 && terminallyDiscarded == 0
                ? .idle
                : .resolved(delivered: delivered, terminallyDiscarded: terminallyDiscarded)
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
    let retryCode: String?
}

actor EluV1BatchDeliveryCoordinator {
    /// The server's record age bound. A record this old is still sent: the
    /// server stores its terminal `record-too-old` outcome and moves its
    /// stream past it. A record dropped here instead would leave its sequence
    /// missing, and the server would answer every later record of the stream
    /// with `stream-gap`.
    static let maximumRecordAgeSeconds: TimeInterval = 604_800
    /// How long the server keeps the outcome it stored for a record, counted
    /// from when it first answered it. A record resent within that time gets
    /// the stored outcome again. A record resent later may find it deleted
    /// and be refused as a conflict, so records stop going out before then
    /// (`resendBoundarySeconds`).
    static let serverOutcomeRetentionSeconds: TimeInterval = 691_200
    /// A record younger than this is sent. An older one is sent only on a
    /// wire stream that first sent it less than this long ago: the server
    /// stored nothing for it before that send, so it still holds whatever it
    /// stored since. Any other record this old is removed without sending it,
    /// and, as for any record that leaves unanswered, the rest of the queue
    /// moves to a new wire stream first, unless later records have already
    /// gone out with it on this one (`discardUnsendable`). Twelve hours
    /// inside the server's retention, as in the other ELU SDKs, to allow for
    /// clock changes.
    static let resendBoundarySeconds: TimeInterval = 648_000
    private static let resendBoundaryMilliseconds = Int64(resendBoundarySeconds * 1_000)
    static let maximumResponseBytes = 1_048_576
    static let maximumErrorResponseBytes = 65_536
    static let requestTimeoutSeconds: TimeInterval = 30
    static let baseRetryNanoseconds: UInt64 = 1_000_000_000
    static let maximumRetryNanoseconds: UInt64 = 60_000_000_000
    static let maximumNetworkRequestsPerPass = 11
    static let maximumLocalResolutionsPerPass = 64
    /// The retryable outcome code for a record whose stream is still waiting
    /// for an earlier sequence.
    static let streamGapCode = "stream-gap"
    /// A head answered `stream-gap` at least this many times, over at least
    /// this long by the device clock, moves to a new wire stream. The bound
    /// is well past a transient gap (two senders racing) and past both
    /// bounds after which the server closes a gap itself, so the server's
    /// close is the normal path and rotation is only the fallback for a
    /// stream the server will never advance. Both counts persist across
    /// restarts.
    static let streamGapRotationAnswers: Int64 = 5
    static let streamGapRotationSeconds: TimeInterval = 2_700
    /// The server closes a gap once it has been presented this many times
    /// (the closing request included) over this long since the first. If
    /// the server's bounds change, both rotation bounds must stay above
    /// them.
    static let serverGapClosePresentations: Int64 = 3
    static let serverGapCloseGraceSeconds: TimeInterval = 1_800

    private let queue: EluSQLiteRuntimeQueue
    private let authorization: EluV1BatchAuthorizationSnapshot
    private let transport: any EluV1BatchHTTPTransport
    private let time: EluV1BatchTimeSource
    private let randomUnit: @Sendable () -> Double
    private let deliveryStreamIdGenerator: @Sendable () -> String

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
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0 ... 1) },
        deliveryStreamIdGenerator: @escaping @Sendable () -> String = {
            "stream_" + EluRuntimeIdentifier.compactUUID()
        }
    ) {
        self.queue = queue
        self.authorization = authorization
        self.transport = transport
        self.time = time
        self.randomUnit = randomUnit
        self.deliveryStreamIdGenerator = deliveryStreamIdGenerator
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
            case let .restart(segmentDelivered, segmentDiscarded):
                // A restart follows an answered send or a local resolution,
                // both capped per pass above, or another coordinator's move
                // of the stream; the next segment reads the queue head again.
                delivered += segmentDelivered
                terminallyDiscarded += segmentDiscarded
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
            let (target, stream) = try await currentTarget()
            let records = try await queue.peek(
                maximumCount: authorization.eventBatchCount,
                maximumBytes: EluV1BatchAuthorizationSnapshot.maximumBatchBytes
            )
            guard !records.isEmpty else { return .idle }

            // Records past the server's age bound are still sent: the server
            // judges age and stores a terminal outcome for a record that is
            // too old, which keeps the stream contiguous. Only records the
            // server may no longer hold an earlier outcome for are removed.
            let now = try currentWallTime()
            let expired = Array(records.prefix { outlivesServerOutcome($0, at: now, on: stream) })
            if !expired.isEmpty {
                guard localResolutionsInPass < Self.maximumLocalResolutionsPerPass else {
                    return .bounded(delivered: 0, terminallyDiscarded: 0)
                }
                try await discardUnsendable(
                    references(for: expired, streamId: target.installationStreamId),
                    target: target,
                    serverStoredNone: false
                )
                localResolutionsInPass += 1
                return .resolved(delivered: 0, terminallyDiscarded: expired.count)
            }
            let sendable = Array(records.prefix { !outlivesServerOutcome($0, at: now, on: stream) })
            return await sendLargestHomogeneousPrefix(
                sendable,
                target: target,
                attempt: 0
            )
        } catch {
            return .preserved(.queueFailure)
        }
    }

    private func currentTarget() async throws -> (EluV1DeliveryTarget, EluV1EventDeliveryStream) {
        let snapshot = try await queue.snapshot()
        let stream = try await queue.eventDeliveryStream()
        guard stream.installationStreamId == snapshot.streamId else {
            throw EluRuntimeQueueError.generationMismatch
        }
        let target = EluV1DeliveryTarget(
            installationStreamId: snapshot.streamId,
            streamId: stream.streamId
        )
        return (target, stream)
    }

    private func performRetry(_ retry: EluV1PendingBatchRetry) async -> EluV1SegmentResult {
        let segment = await performRetrySegment(retry)
        if case let .restart(delivered, terminallyDiscarded) = segment {
            return await performFreshPass().adding(
                delivered: delivered,
                terminallyDiscarded: terminallyDiscarded
            )
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
            let (target, _) = try await currentTarget()
            guard try await recordsStillMatchHead(
                retry.records,
                streamId: target.installationStreamId
            ) else {
                return await performFreshPass()
            }
            return await sendExactRecords(
                retry.records,
                target: target,
                attempt: retry.attempt
            )
        } catch {
            return .preserved(.queueFailure)
        }
    }

    private func sendLargestHomogeneousPrefix(
        _ records: [EluQueuedRecord],
        target: EluV1DeliveryTarget,
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
                target: target,
                sentAt: sentAt
            ) else {
                // The head alone is larger than a request may be. It can
                // have gone out with later records only under an earlier,
                // larger limit, whose answer then never arrived or stored
                // nothing.
                guard localResolutionsInPass < Self.maximumLocalResolutionsPerPass else {
                    return .bounded(delivered: 0, terminallyDiscarded: 0)
                }
                try await discardUnsendable(
                    references(for: [head], streamId: target.installationStreamId),
                    target: target,
                    serverStoredNone: false
                )
                localResolutionsInPass += 1
                return .resolved(delivered: 0, terminallyDiscarded: 1)
            }
            return await send(prepared, attempt: attempt)
        } catch {
            return .preserved(.queueFailure)
        }
    }

    /// Removes records that cannot be sent: larger than any request may be,
    /// refused 413 on their own, or past the resend boundary. If the server
    /// never answered them, it would hold every later record of the wire
    /// stream as `stream-gap`, so the rest of the queue moves to a new wire
    /// stream first, unless the stream may stay
    /// (`EluV1EventDeliveryStream.keepsStream`). `serverStoredNone` is true
    /// when the server's own answer shows it stored no request that carried
    /// these records. The records stay queued when the queue cannot take
    /// that step (it is closed or has failed, or now belongs to another
    /// installation stream). Writing the moved stream to its file is best
    /// effort, and a failed write does not keep them. If the process ends
    /// between the two steps, the record is removed again on the new stream
    /// instead of leaving a gap.
    private func discardUnsendable(
        _ references: [EluQueueAcknowledgementReference],
        target: EluV1DeliveryTarget,
        serverStoredNone: Bool
    ) async throws {
        guard let last = references.last?.sequence else { return }
        try await moveDeliveryStream(
            from: target,
            removingThrough: last,
            serverStoredNone: serverStoredNone
        )
        try await queue.acknowledge(references)
    }

    /// Moves the wire stream away from `target` before the queue head through
    /// `last` is removed unanswered, unless another coordinator already has,
    /// or the stream may stay. The decision and the move are one step on the
    /// queue's actor. Throws when the stream could not be read or changed, or
    /// when the queue now belongs to another installation stream.
    private func moveDeliveryStream(
        from target: EluV1DeliveryTarget,
        removingThrough last: Int64,
        serverStoredNone: Bool
    ) async throws {
        let generator = deliveryStreamIdGenerator
        let after = try await queue.updateEventDeliveryStream { current in
            guard current.installationStreamId == target.installationStreamId,
                  current.streamId == target.streamId,
                  !current.keepsStream(removingThrough: last, serverStoredNone: serverStoredNone)
            else {
                return nil
            }
            return current.moved(
                to: EluV1BatchDeliveryCoordinator.newDeliveryStreamId(generator, avoiding: current)
            )
        }
        guard after.installationStreamId == target.installationStreamId else {
            throw EluRuntimeQueueError.generationMismatch
        }
    }

    private static func newDeliveryStreamId(
        _ generator: @Sendable () -> String,
        avoiding current: EluV1EventDeliveryStream
    ) -> String {
        let candidate = generator()
        if EluV1EventDeliveryStreamStore.validStreamId(candidate),
           candidate != current.streamId,
           candidate != current.installationStreamId
        {
            return candidate
        }
        return "stream_" + EluRuntimeIdentifier.compactUUID()
    }

    /// Counts a `stream-gap` answer for the head at `sequence`, persisted with
    /// the wire stream. Returns true when the head now has a different wire
    /// stream to go on: either this answer reached the bound and moved it, or
    /// another coordinator moved it already. An answer from a stream that has
    /// moved on is not counted against the new one.
    private func noteStreamGap(
        sequence: Int64,
        target: EluV1DeliveryTarget
    ) async -> Bool {
        guard let now = Self.milliseconds(time.wallNow()) else { return false }
        let generator = deliveryStreamIdGenerator
        do {
            let after = try await queue.updateEventDeliveryStream { current in
                guard current.installationStreamId == target.installationStreamId,
                      current.streamId == target.streamId
                else {
                    return nil
                }
                var gap = current.gap.flatMap { $0.sequence == sequence ? $0 : nil }
                    ?? EluV1EventDeliveryStream.Gap(
                        sequence: sequence,
                        firstAnsweredAtMilliseconds: now,
                        answers: 0
                    )
                // A clock set back starts the window again rather than
                // stretching it. A clock set forward shortens it, which is
                // harmless: the server stores nothing for a `stream-gap`
                // answer, and the head goes again on the new stream.
                if now < gap.firstAnsweredAtMilliseconds {
                    gap.firstAnsweredAtMilliseconds = now
                }
                gap.answers = gap.answers < Int64.max ? gap.answers + 1 : Int64.max
                let elapsed = now.subtractingReportingOverflow(gap.firstAnsweredAtMilliseconds)
                let bound = Int64(EluV1BatchDeliveryCoordinator.streamGapRotationSeconds * 1_000)
                if gap.answers >= EluV1BatchDeliveryCoordinator.streamGapRotationAnswers,
                   !elapsed.overflow,
                   elapsed.partialValue >= bound
                {
                    return current.moved(
                        to: EluV1BatchDeliveryCoordinator.newDeliveryStreamId(
                            generator,
                            avoiding: current
                        )
                    )
                }
                var next = current
                next.gap = gap
                return next
            }
            return after.installationStreamId == target.installationStreamId
                && after.streamId != target.streamId
        } catch {
            return false
        }
    }

    private static func milliseconds(_ date: Date) -> Int64? {
        let value = (date.timeIntervalSince1970 * 1_000).rounded(.down)
        guard value.isFinite,
              value > -9_000_000_000_000_000,
              value < 9_000_000_000_000_000
        else {
            return nil
        }
        return Int64(value)
    }

    /// Records, before the request starts, that the prepared records go out
    /// on their wire stream at `now`, so a resend after an answer that never
    /// arrived knows the server stored nothing for them before then. Returns
    /// false when the wire stream moved meanwhile.
    private func recordSend(_ prepared: EluV1PreparedBatch, at now: Date) async throws -> Bool {
        guard let first = prepared.records.first?.sequence,
              let last = prepared.records.last?.sequence,
              let sentAt = Self.milliseconds(now)
        else {
            return true
        }
        let streamId = prepared.streamId
        let after = try await queue.updateEventDeliveryStream { current in
            guard current.streamId == streamId else { return nil }
            return current.recordingSend(first: first, last: last, atMilliseconds: sentAt)
        }
        return after.streamId == streamId
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
        let stream: EluV1EventDeliveryStream
        do {
            guard try await recordsStillMatchHead(
                prepared.records,
                streamId: prepared.target.installationStreamId
            ) else {
                return .preserved(.queueFailure)
            }
            stream = try await queue.eventDeliveryStream()
            // The wire stream may have moved since this batch was prepared:
            // by another coordinator, or by a one-record 413 in the first
            // half of a split. The pass then packs again from the queue head.
            guard stream.streamId == prepared.streamId else {
                return .restart(delivered: 0, terminallyDiscarded: 0)
            }
        } catch {
            return .preserved(.queueFailure)
        }
        // The queue check above crosses an actor boundary. Use one fresh wall
        // reading to revalidate authorization and every prepared row's age
        // at the final network boundary.
        let preflightNow: Date
        do {
            preflightNow = try currentWallTime()
        } catch {
            return .preserved(.protocolFailure)
        }
        guard authorizationIsCurrent(at: preflightNow) else {
            return .preserved(.authorizationExpired)
        }
        if prepared.records.contains(where: {
            outlivesServerOutcome($0, at: preflightNow, on: stream)
        }) {
            // The next segment removes it. Counted as a local resolution so a
            // clock that moves back and forth cannot loop without bound.
            guard localResolutionsInPass < Self.maximumLocalResolutionsPerPass else {
                return .bounded(delivered: 0, terminallyDiscarded: 0)
            }
            localResolutionsInPass += 1
            return .restart(delivered: 0, terminallyDiscarded: 0)
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
        do {
            guard try await recordSend(prepared, at: preflightNow) else {
                return .restart(delivered: 0, terminallyDiscarded: 0)
            }
        } catch {
            return .preserved(.queueFailure)
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
        // URLSession stops reading denied responses at their headers. A denial
        // applies to this authorization even when no error body is available;
        // adding records must not turn it into another send with the same key.
        if response.status == 401 || response.status == 403 {
            let reason = EluV1BatchPreservationReason.permanentHTTP(response.status)
            authorizationBlock = reason
            return .preserved(reason)
        }
        guard response.body.count <= Self.maximumResponseBytes else {
            return failClosed(response, prepared, attempt: attempt)
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
            if acknowledgement.retryCode == Self.streamGapCode,
               let head = retrySuffix.first,
               await noteStreamGap(sequence: head.sequence, target: prepared.target)
            {
                // The head goes again at once, on the new wire stream.
                return .restart(
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
            return failClosed(response, prepared, attempt: attempt)
        }
        let retryAfterHeader: String?
        do {
            retryAfterHeader = try Self.header(named: "Retry-After", in: response.headers)
        } catch {
            return failClosed(response, prepared, attempt: attempt)
        }
        guard Self.validateErrorResponse(
            response.body,
            status: response.status,
            requestId: prepared.requestId
        ) else {
            return failClosed(response, prepared, attempt: attempt)
        }

        switch response.status {
        case 413:
            guard retryAfterHeader == nil else {
                return blockRequest(prepared.requestId, reason: .protocolFailure)
            }
            if prepared.records.count == 1 {
                // Every request that carried this record was larger than
                // this one, so under the same limit the server refused them
                // all, and the records after it may go on a new stream at
                // once.
                do {
                    try await discardUnsendable(
                        prepared.references,
                        target: prepared.target,
                        serverStoredNone: true
                    )
                    return .resolved(delivered: 0, terminallyDiscarded: 1)
                } catch {
                    return .preserved(.queueFailure)
                }
            }
            let firstCount = (prepared.records.count + 1) / 2
            let firstRecords = Array(prepared.records.prefix(firstCount))
            let secondRecords = Array(prepared.records.dropFirst(firstCount))
            let first = await sendExactRecords(firstRecords, target: prepared.target)
            guard case let .resolved(firstDelivered, firstDiscarded) = first else {
                return first
            }
            // If a one-record 413 in the first half moved the wire stream,
            // `send` does not send the second half on the old one: the pass
            // packs it again from the queue head on the new stream.
            let second = await sendExactRecords(secondRecords, target: prepared.target)
            return second.adding(delivered: firstDelivered, terminallyDiscarded: firstDiscarded)

        case 429:
            guard let retryAfterHeader,
                  let delay = Self.parseRetryAfter(retryAfterHeader, now: time.wallNow())
            else {
                return failClosed(response, prepared, attempt: attempt)
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
                    return failClosed(response, prepared, attempt: attempt)
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

    /// HTTP status is authoritative for 429 and 5xx. When the response is not
    /// the validated error object (for example an intermediary's plain-text,
    /// HTML, empty or oversized body, or an unreadable Retry-After), the same
    /// request is retried with backoff. Every other status still fails closed.
    private func failClosed(
        _ response: EluV1BatchHTTPResponse,
        _ prepared: EluV1PreparedBatch,
        attempt: Int
    ) -> EluV1SegmentResult {
        guard Self.isRetryableStatus(response.status) else {
            return blockRequest(prepared.requestId, reason: .protocolFailure)
        }
        return scheduleRetry(
            records: prepared.records,
            attempt: attempt + 1,
            retryAfter: Self.foreignRetryAfter(response.headers, now: time.wallNow())
        )
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
        target: EluV1DeliveryTarget,
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
            guard let prepared = try prepareExact(
                records: records,
                target: target,
                sentAt: now
            ) else {
                return .preserved(.protocolFailure)
            }
            return await send(prepared, attempt: attempt)
        } catch {
            return .preserved(.queueFailure)
        }
    }

    private func largestFittingPrefix(
        _ records: [EluQueuedRecord],
        target: EluV1DeliveryTarget,
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
                target: target,
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
        target: EluV1DeliveryTarget,
        sentAt: Date
    ) throws -> EluV1PreparedBatch? {
        guard let versions = records.first?.versions,
              !records.isEmpty,
              records.count <= authorization.eventBatchCount,
              records.allSatisfy({ $0.versions == versions })
        else {
            return nil
        }
        // References acknowledge rows in the queue, under the installation
        // stream. The request names the wire stream, and so does every event
        // in it; record ids and sequences are unchanged.
        let references = references(for: records, streamId: target.installationStreamId)
        let requestId = try Self.requestId(
            streamId: target.streamId,
            versions: versions,
            references: references
        )
        let body = try EluQueueBatchCodec.encodeBatch(
            requestId: requestId,
            streamId: target.streamId,
            sentAt: sentAt,
            versions: versions,
            records: records.map { $0.addressed(toStream: target.streamId) }
        )
        guard body.count <= authorization.eventBatchBytes else {
            return nil
        }
        return EluV1PreparedBatch(
            requestId: requestId,
            target: target,
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

    /// Whether `record` may no longer be sent on `stream`: it is at least
    /// `resendBoundarySeconds` old, and was not first sent on this wire
    /// stream less than that long ago. Retention counts from the server's
    /// first answer, which comes after the first send, so a record sent on
    /// this stream since then gets its stored outcome again, or, if the
    /// server never stored it, the answer for a new record.
    private func outlivesServerOutcome(
        _ record: EluQueuedRecord,
        at now: Date,
        on stream: EluV1EventDeliveryStream
    ) -> Bool {
        guard now.timeIntervalSince(record.occurredAt) >= Self.resendBoundarySeconds else {
            return false
        }
        guard let sent = stream.sent,
              record.sequence <= sent.throughSequence,
              let nowMilliseconds = Self.milliseconds(now)
        else {
            return true
        }
        let sinceFirstSend = nowMilliseconds.subtractingReportingOverflow(
            sent.firstSentAtMilliseconds
        )
        return sinceFirstSend.overflow
            || sinceFirstSend.partialValue >= Self.resendBoundaryMilliseconds
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

private extension EluQueuedRecord {
    /// The same record as sent on `streamId`. An event names its stream; a
    /// mutation does not.
    func addressed(toStream streamId: String) -> EluQueuedRecord {
        guard case var .event(event) = self, event.streamId != streamId else {
            return self
        }
        event.streamId = streamId
        return .event(event)
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
        case let .restart(currentDelivered, currentDiscarded):
            return .restart(
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
        var retryCode: String?
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
                retryCode = outcome["code"]?.stringValue
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
            retryFromSequence: expectedRetry,
            retryCode: retryCode
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

    /// Longest pause honoured from a 429/5xx that is not the validated error
    /// object. Such a response never sets a longer, endpoint-wide pause.
    static let foreignMaximumRetryAfterSeconds: TimeInterval = 300

    static func isRetryableStatus(_ status: Int) -> Bool {
        status == 429 || (500 ... 599).contains(status)
    }

    /// Exactly one readable Retry-After is honoured, capped at five minutes.
    /// A missing, repeated or unreadable value yields 0 so backoff applies.
    static func foreignRetryAfter(_ headers: [String: String], now: Date) -> TimeInterval {
        let values = headers.filter { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }
        guard values.count == 1, let value = values.first?.value,
              let parsed = parseRetryAfter(value, now: now) else { return 0 }
        return min(max(0, parsed), foreignMaximumRetryAfterSeconds)
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
