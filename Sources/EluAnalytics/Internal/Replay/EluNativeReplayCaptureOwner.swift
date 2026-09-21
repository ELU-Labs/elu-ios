import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum EluNativeReplayCaptureError: Error, Equatable {
    case withdrawn
    case occupied
    case invalidClock
    case frameOrder
    case bufferLimit
    case settlementPending
}

enum EluNativeReplayCaptureClock {
    /// Floors the exact represented clock value; multiplying Date's floating
    /// point seconds could round an earlier instant into a later millisecond.
    static func milliseconds(_ wall: Date) throws -> Int64 {
        try milliseconds(EluV1Timestamp.exactClock(wall))
    }

    static func admits(startedAt: EluV1Timestamp, endedAt: EluV1Timestamp,
                       after firstStartAt: EluV1Timestamp) throws -> Bool {
        // Native wire timestamps have millisecond precision. Retain the exact
        // ledger start for duration accounting; compare only its wire bucket.
        guard [startedAt, endedAt].allSatisfy({
            !$0.storageIsLeapSecond && $0.storageFractionDigits.utf8.dropFirst(3).allSatisfy { $0 == 48 }
        }) else { return false }
        return try milliseconds(startedAt) >= milliseconds(firstStartAt)
    }

    static func milliseconds(_ exact: EluV1Timestamp) throws -> Int64 {
        guard !exact.storageIsLeapSecond else { throw EluNativeReplayCaptureError.invalidClock }
        let (day, dayOverflow) = exact.storageDay.multipliedReportingOverflow(by: 86_400_000)
        let (second, secondOverflow) = exact.storageSecondOfDay.multipliedReportingOverflow(by: 1_000)
        let digits = Array(exact.storageFractionDigits.utf8.prefix(3))
        var fraction: Int64 = 0
        for index in 0 ..< 3 {
            let digit = index < digits.count ? digits[index] : 48
            guard (48 ... 57).contains(digit) else { throw EluNativeReplayCaptureError.invalidClock }
            fraction = fraction * 10 + Int64(digit - 48)
        }
        let (whole, wholeOverflow) = day.addingReportingOverflow(second)
        let (value, fractionOverflow) = whole.addingReportingOverflow(fraction)
        guard !dayOverflow, !secondOverflow, !wholeOverflow, !fractionOverflow,
              (1 ... 253_402_300_799_999).contains(value)
        else { throw EluNativeReplayCaptureError.invalidClock }
        return value
    }
}

/// Bounded masked values only. Timing starts with the first lawful frame, and
/// replacing an unencoded latest frame never consumes an encoder ordinal.
struct EluNativeReplayFrameBuffer: Sendable {
    static let maximumFrames = 16
    static let maximumNodes = 16_384
    static let maximumEstimatedBytes = 8_388_608
    static let flushNanoseconds: UInt64 = 10_000_000_000
    private let minimumNanoseconds: UInt64
    private(set) var frames: [EluNativeMaskedSnapshot] = []
    private var firstContinuous: UInt64?
    private var lastContinuous: UInt64?
    private var lastFlushContinuous: UInt64?
    private var lastTimestamp: Int64?
    private var nextOrdinal: Int64 = 0
    private var firstChunkCommitted = false
    private var ready = false
    private var sealing = false
    private var terminal = false

    init(minimumDurationSeconds: Int) throws {
        guard (0 ... 3_600).contains(minimumDurationSeconds) else {
            throw EluNativeReplayCaptureError.invalidClock
        }
        minimumNanoseconds = UInt64(minimumDurationSeconds) * 1_000_000_000
    }

    var nextFrameOrdinal: Int64 {
        firstChunkCommitted ? nextOrdinal + Int64(frames.count) : (frames.isEmpty ? 0 : 1)
    }
    var isReady: Bool { ready && !sealing && !terminal }

    mutating func append(_ frame: EluNativeMaskedSnapshot, continuous: UInt64) throws {
        do {
            guard !terminal, !sealing, !ready else { throw EluNativeReplayCaptureError.withdrawn }
            guard frame.ordinal == nextFrameOrdinal,
                  frame.ordinal < EluNativeWireframeEncoder.maximumSafeInteger else {
                throw EluNativeReplayCaptureError.frameOrder
            }
            guard (1 ... 253_402_300_799_999).contains(frame.timestamp),
                  lastTimestamp.map({ frame.timestamp >= $0 }) ?? true,
                  lastContinuous.map({ continuous >= $0 }) ?? true else {
                throw EluNativeReplayCaptureError.invalidClock
            }
            guard frame.nodes.count <= 9_999 else { throw EluNativeReplayCaptureError.bufferLimit }
            var candidate = frames
            if !firstChunkCommitted, !candidate.isEmpty {
                if candidate.count == 2 { candidate[1] = frame } else { candidate.append(frame) }
            } else { candidate.append(frame) }
            guard candidate.count <= Self.maximumFrames else { throw EluNativeReplayCaptureError.bufferLimit }
            var nodes = 0
            for snapshot in candidate {
                guard snapshot.nodes.count <= Self.maximumNodes - nodes else {
                    throw EluNativeReplayCaptureError.bufferLimit
                }
                nodes += snapshot.nodes.count
            }
            // Charge geometry/style plus bounded UTF-8 text before retaining it.
            var estimatedBytes = nodes * 512 + candidate.count * 256
            for snapshot in candidate {
                for node in snapshot.nodes {
                    if case let .ordinaryText(text) = node.kind {
                        let count = text.utf8.count
                        guard count <= 4_096, count <= Self.maximumEstimatedBytes - estimatedBytes else {
                            throw EluNativeReplayCaptureError.bufferLimit
                        }
                        estimatedBytes += count
                    }
                }
            }
            guard estimatedBytes <= Self.maximumEstimatedBytes else {
                throw EluNativeReplayCaptureError.bufferLimit
            }
            frames = candidate
            if firstContinuous == nil { firstContinuous = continuous }
            lastContinuous = continuous; lastTimestamp = frame.timestamp
            if firstChunkCommitted, let lastFlushContinuous {
                ready = continuous - lastFlushContinuous >= Self.flushNanoseconds
            } else if let firstContinuous {
                ready = minimumNanoseconds == 0 || (frames.count == 2 && continuous - firstContinuous >= minimumNanoseconds)
            }
        } catch {
            withdraw()
            throw error
        }
    }

    /// Caller owns the returned immutable prefix until its exact admission ends.
    mutating func beginSealing() throws -> [EluNativeMaskedSnapshot] {
        guard isReady, !frames.isEmpty else { throw EluNativeReplayCaptureError.withdrawn }
        sealing = true
        return frames
    }

    mutating func committed() throws {
        guard !terminal, sealing, let last = frames.last, let lastContinuous,
              last.ordinal < EluNativeWireframeEncoder.maximumSafeInteger else {
            throw EluNativeReplayCaptureError.frameOrder
        }
        nextOrdinal = last.ordinal + 1
        firstChunkCommitted = true; lastFlushContinuous = lastContinuous
        frames.removeAll(keepingCapacity: false); sealing = false; ready = false
    }

    mutating func withdraw() {
        terminal = true; ready = false; sealing = false
        frames.removeAll(keepingCapacity: false)
    }
}

#if canImport(UIKit)
enum EluNativeReplayCaptureOutcome: Sendable {
    case settled
    case quarantined
}

/// No UIKit, SQL, await or callback executes under this local cancellation lock.
private final class EluNativeReplayCaptureFence: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var stopCollector: (@Sendable () -> Void)?

    func isCurrent() -> Bool {
        lock.lock(); defer { lock.unlock() }; return active
    }
    func installCollector(_ stop: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        let accepted = active && stopCollector == nil
        if accepted { stopCollector = stop }
        lock.unlock()
        if !accepted { stop() }
        return accepted
    }
    func withdraw() {
        lock.lock(); active = false
        let stop = stopCollector; stopCollector = nil
        lock.unlock(); stop?()
    }
}

/// Internal physical owner. The public stack creates no capture owner until its
/// original engine/readback capability gate is enabled separately.
final class EluNativeReplayCaptureOwner: @unchecked Sendable {
    private let fence: EluNativeReplayCaptureFence
    private let task: Task<EluNativeReplayCaptureOutcome, Never>

    init(queue: EluSQLiteRuntimeQueue, authority: EluNativeReplayAuthority,
         prepared: EluNativeReplayPreparedAuthority, selection: EluNativeReplaySelection,
         versions: EluVersionContext, wallClock: @escaping @Sendable () -> Date,
         continuousNanoseconds: @escaping @Sendable () -> UInt64?,
         onCommitted: @escaping @Sendable () -> Void = {}) {
        let run = EluNativeReplayCaptureRun(queue: queue, authority: authority,
            prepared: prepared, selection: selection, versions: versions,
            wallClock: wallClock, continuousNanoseconds: continuousNanoseconds, onCommitted: onCommitted)
        fence = run.fence
        // This task owns physical completion independently of the handle. It
        // deliberately captures run, never self, so deinit can withdraw intake.
        task = Task { await run.execute() }
    }

    func withdraw() { fence.withdraw(); task.cancel() }
    func stop() async -> EluNativeReplayCaptureOutcome {
        withdraw()
        return await task.value
    }
    func finished() async -> EluNativeReplayCaptureOutcome { await task.value }
    deinit { fence.withdraw(); task.cancel() }
}

private final class EluNativeReplayCaptureRun: @unchecked Sendable {
    let fence = EluNativeReplayCaptureFence()
    private let queue: EluSQLiteRuntimeQueue
    private let authority: EluNativeReplayAuthority
    private let prepared: EluNativeReplayPreparedAuthority
    private let selection: EluNativeReplaySelection
    private let versions: EluVersionContext
    private let wallClock: @Sendable () -> Date
    private let continuousNanoseconds: @Sendable () -> UInt64?
    private let onCommitted: @Sendable () -> Void

    init(queue: EluSQLiteRuntimeQueue, authority: EluNativeReplayAuthority,
         prepared: EluNativeReplayPreparedAuthority, selection: EluNativeReplaySelection,
         versions: EluVersionContext, wallClock: @escaping @Sendable () -> Date,
         continuousNanoseconds: @escaping @Sendable () -> UInt64?,
         onCommitted: @escaping @Sendable () -> Void = {}) {
        self.queue = queue; self.authority = authority; self.prepared = prepared
        self.selection = selection; self.versions = versions
        self.wallClock = wallClock; self.continuousNanoseconds = continuousNanoseconds
        self.onCommitted = onCommitted
    }

    private func checkLocalIntake() throws {
        guard !Task.isCancelled, fence.isCurrent(), selection.isCurrent() else {
            throw EluNativeReplayCaptureError.withdrawn
        }
    }

    private func check(_ permit: EluNativeReplayPermit? = nil) throws {
        try checkLocalIntake()
        guard
              permit.map({ $0.isCurrent() }) ?? prepared.isCurrent(), fence.isCurrent()
        else { throw EluNativeReplayCaptureError.withdrawn }
    }

    func execute() async -> EluNativeReplayCaptureOutcome {
        var enrollment: EluNativeReplayCaptureEnrollment?
        var physicalUse: EluNativeReplayCapturePhysicalUse?
        var pendingRequest: EluV2ReplayPreparedRequest?
        var buffer: EluNativeReplayFrameBuffer?
        do {
            // Source guards may record a durable clock denial. Do not consume
            // one before owning the physical+accounting settlement path.
            try checkLocalIntake()
            guard let enrolled = try await queue.enrollNativeReplayCapture() else {
                throw EluNativeReplayCaptureError.occupied
            }
            enrollment = enrolled
            try checkLocalIntake()
            guard let use = enrolled.takePhysicalUse() else { throw EluNativeReplayCaptureError.occupied }
            physicalUse = use
            try check()
            guard let permit = try await authority.start(prepared, selection: selection, physicalUse: use)
            else { throw EluNativeReplayCaptureError.withdrawn }
            try check(permit)
            let admission = try await authority.captureAdmission(for: permit, physicalUse: use)
            try check(permit)
            guard admission.isCurrent() else { throw EluNativeReplayCaptureError.withdrawn }
            buffer = try EluNativeReplayFrameBuffer(minimumDurationSeconds: admission.minimumDurationSeconds)
            var sealer = try EluNativeReplaySealer(replayId: permit.replayId, identity: permit.identity,
                authorization: permit.resolution, privacy: permit.privacy, profile: permit.profile, versions: versions)
            let collector = try await MainActor.run {
                try self.check(permit)
                guard permit.isCurrentForCollection(), admission.isCurrent() else {
                    throw EluNativeReplayCaptureError.withdrawn
                }
                let collector = try EluUIKitReplayCollector()
                guard self.fence.installCollector({ collector.withdraw() }) else {
                    throw EluNativeReplayCaptureError.withdrawn
                }
                return collector
            }
            while true {
                try check(permit)
                guard admission.isCurrent(), let ordinal = buffer?.nextFrameOrdinal else {
                    throw EluNativeReplayCaptureError.withdrawn
                }
                let captured = try await MainActor.run {
                    try self.check(permit)
                    guard permit.isCurrentForCollection(), admission.isCurrent(),
                          let continuous = self.continuousNanoseconds() else {
                        throw EluNativeReplayCaptureError.withdrawn
                    }
                    let timestamp = try EluNativeReplayCaptureClock.milliseconds(self.wallClock())
                    let frame = try self.selection.consumeRoot { root in
                        try collector.collect(root: root, ordinal: ordinal, timestamp: timestamp,
                            hasUnresolvedConfiguredBlockRules: admission.hasUnresolvedBlockRules,
                            profile: permit.profile,
                            isCurrent: {
                                self.fence.isCurrent() && permit.isCurrentForCollection()
                                    && admission.isCurrent() && self.fence.isCurrent()
                            })
                    }
                    try self.check(permit)
                    guard admission.isCurrent() else { throw EluNativeReplayCaptureError.withdrawn }
                    return (frame, continuous)
                }
                try check(permit)
                guard admission.isCurrent() else { throw EluNativeReplayCaptureError.withdrawn }
                try buffer?.append(captured.0, continuous: captured.1)
                if buffer?.isReady == true {
                    guard let prefix = try buffer?.beginSealing() else { throw EluNativeReplayCaptureError.withdrawn }
                    try check(permit)
                    guard admission.isCurrent() else { throw EluNativeReplayCaptureError.withdrawn }
                    let request = try sealer.seal(prefix)
                    pendingRequest = request
                    try check(permit)
                    guard admission.isCurrent() else { throw EluNativeReplayCaptureError.withdrawn }
                    let append = try await queue.appendNativeReplay(request, admission: admission, physicalUse: use)
                    switch append {
                    case .committed:
                        pendingRequest = nil
                        onCommitted()
                    case .committedThenWithdrawn:
                        pendingRequest = nil
                        onCommitted()
                        throw EluNativeReplayCaptureError.withdrawn
                    }
                    try check(permit)
                    guard admission.isCurrent() else { throw EluNativeReplayCaptureError.withdrawn }
                    try buffer?.committed()
                }
                // One serial capture per actual interval; no overlap, missed-frame
                // backfill, authority renewal, or timer-only minimum permission.
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            // Withdrawal/failure discards every unsealed value. It never flushes
            // under expired permission or encodes a suffix after unknown commit.
            fence.withdraw()
            buffer?.withdraw()
        }
        fence.withdraw()
        guard let enrollment else { return .settled }
        if let physicalUse {
            physicalUse.settle()
        } else {
            enrollment.cancelUnused()
        }
        do {
            if physicalUse != nil {
                switch try await authority.stop() {
                case .settled: break
                case .physicalWorkPending:
                    enrollment.quarantine(retaining: pendingRequest)
                    return .quarantined
                }
            }
            // Even an unused enrollment needs the queue's exact no-start read
            // before resources can be released; cancellation alone is no proof.
            switch try await queue.finishNativeReplayCapture(enrollment) {
            case .settled: return .settled
            case .physicalWorkPending, .accountingPending, .stale:
                enrollment.quarantine(retaining: pendingRequest)
                return .quarantined
            }
        } catch {
            enrollment.quarantine(retaining: pendingRequest)
            return .quarantined
        }
    }
}
#endif
