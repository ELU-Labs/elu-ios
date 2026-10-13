import Foundation

/// Serial, detached bounded intake. No authority, clocks, UIKit or SQL is owned
/// here. The caller retains one rejected unit when sealRequired is returned and
/// retries it only after the original prefix commits; it must not drop/reorder it.
struct EluNativeReplayInteractionBuffer: Sendable {
    static let maximumLogicalUnits = 64 // Includes one reserved terminal unit.
    private static let terminalEstimatedBytes = 256
    enum AppendResult: Equatable { case appended, sealRequired }
    struct Seal: Equatable, Sendable {
        fileprivate let identity: UUID
        let records: [EluNativeReplayRecord]
    }

    private var initial: EluNativeReplayFrameBuffer?
    private var initialTimes: [Int64: UInt64] = [:]
    private(set) var records: [EluNativeReplayRecord] = []
    private var pending: Seal?
    private var terminal = false
    private var ready = false
    private var active = false
    private var lastTime: EluNativeInteractionTime?
    private var lastGeometryContinuous: UInt64?
    private var lastGeometryTimestamp: Int64?
    private var lastCommitContinuous: UInt64?
    private var nextOrdinal: Int64 = 0

    init(minimumDurationSeconds: Int) throws {
        initial = try .init(minimumDurationSeconds: minimumDurationSeconds)
    }

    var nextFrameOrdinal: Int64 { initial?.nextFrameOrdinal ?? nextOrdinal }
    var interactionsArmed: Bool { initial == nil && !terminal }
    var isReady: Bool { !terminal && pending == nil && (initial?.isReady ?? ready) }

    mutating func appendGeometry(_ frame: EluNativeMaskedSnapshot, continuous: UInt64,
                                 scrolling: Bool = false) throws -> AppendResult {
        var candidate = self
        let result = try candidate.appendGeometryCandidate(frame, continuous: continuous, scrolling: scrolling)
        self = candidate
        return result
    }

    private mutating func appendGeometryCandidate(_ frame: EluNativeMaskedSnapshot, continuous: UInt64,
                                                 scrolling: Bool) throws -> AppendResult {
        try requireIntake()
        // The shared v2 decoder applies its geometry floor to the initial pair
        // too; monotonic minimum eligibility cannot compensate for a short wall gap.
        if let previous = lastGeometryContinuous, let wall = lastGeometryTimestamp {
            guard continuous >= previous, continuous - previous >= 200_000_000,
                  frame.timestamp >= wall, frame.timestamp - wall >= 200 else {
                throw EluNativeInteractionError.invalidOrder
            }
        }
        if var initial {
            // Reuse the authoritative first/latest minimum algorithm. No touch
            // can reference an intermediate frame which that algorithm discards.
            try initial.append(frame, continuous: continuous)
            initialTimes[frame.ordinal] = continuous
            records = try initial.frames.map {
                guard let observed = initialTimes[$0.ordinal] else { throw EluNativeInteractionError.invalidOrder }
                return .geometry($0, continuous: observed)
            }
            self.initial = initial
            lastTime = .init(timestamp: frame.timestamp, continuous: continuous)
            lastGeometryContinuous = continuous; lastGeometryTimestamp = frame.timestamp
            return .appended
        }
        guard frame.ordinal == nextOrdinal,
              nextOrdinal < EluNativeWireframeEncoder.maximumSafeInteger else {
            throw EluNativeEncodingError.frameOrder
        }
        let record = EluNativeReplayRecord.geometry(frame, continuous: continuous)
        try validateTimes(record.times)
        if let previous = lastGeometryContinuous, let wall = lastGeometryTimestamp {
            let interval: UInt64 = active || scrolling ? 200_000_000 : 1_000_000_000
            guard continuous >= previous, continuous - previous >= interval,
                  frame.timestamp >= wall, frame.timestamp - wall >= Int64(interval / 1_000_000) else {
                throw EluNativeInteractionError.invalidOrder
            }
        }
        let result = try retain(record, terminalUnit: false)
        if result == .appended {
            nextOrdinal += 1; lastGeometryContinuous = continuous; lastGeometryTimestamp = frame.timestamp
        }
        return result
    }

    mutating func appendInteraction(_ interaction: EluNativeInteraction) throws -> AppendResult {
        var candidate = self
        try candidate.requireIntake()
        guard candidate.interactionsArmed else { throw EluNativeInteractionError.initialCommitRequired }
        if case .moves = interaction, !(1 ... 10).contains(interaction.logicalCost) {
            throw EluNativeInteractionError.invalidBatch
        }
        switch interaction {
        case .start: guard !candidate.active else { throw EluNativeInteractionError.invalidGesture }
        case .moves, .end, .cancel: guard candidate.active else { throw EluNativeInteractionError.invalidGesture }
        }
        let record = EluNativeReplayRecord.interaction(interaction)
        try candidate.validateTimes(record.times)
        let result = try candidate.retain(record, terminalUnit: interaction.isTerminal)
        if result == .appended {
            if case .start = interaction { candidate.active = true }
            if interaction.isTerminal { candidate.active = false }
        }
        self = candidate
        return result
    }

    private func requireIntake() throws {
        guard !terminal else { throw EluNativeInteractionError.withdrawn }
        guard pending == nil else { throw EluNativeInteractionError.pendingSeal }
    }

    private func validateTimes(_ times: [EluNativeInteractionTime]) throws {
        guard !times.isEmpty else { throw EluNativeInteractionError.invalidBatch }
        var previous = lastTime
        for time in times {
            guard (1 ... 253_402_300_799_999).contains(time.timestamp),
                  previous.map({ time.timestamp >= $0.timestamp && time.continuous >= $0.continuous }) ?? true else {
                throw EluNativeInteractionError.invalidOrder
            }
            previous = time
        }
    }

    private mutating func retain(_ record: EluNativeReplayRecord, terminalUnit: Bool) throws -> AppendResult {
        // Reject an oversized single value without allocating an unbounded list.
        let maximumBytes = EluNativeReplayFrameBuffer.maximumEstimatedBytes -
            (terminalUnit ? 0 : Self.terminalEstimatedBytes)
        guard fits([record], maximumUnits: Self.maximumLogicalUnits, maximumBytes: maximumBytes) else {
            throw EluNativeInteractionError.bufferLimit
        }
        let candidate = records + [record]
        let maximum = terminalUnit ? Self.maximumLogicalUnits : Self.maximumLogicalUnits - 1
        guard fits(candidate, maximumUnits: maximum, maximumBytes: maximumBytes) else {
            guard !records.isEmpty else { throw EluNativeInteractionError.bufferLimit }
            ready = true
            return .sealRequired
        }
        records = candidate; lastTime = record.times.last
        if let lastCommitContinuous, let lastTime {
            ready = ready || lastTime.continuous - lastCommitContinuous >= EluNativeReplayFrameBuffer.flushNanoseconds
        }
        return .appended
    }

    private func fits(_ values: [EluNativeReplayRecord], maximumUnits: Int, maximumBytes: Int) -> Bool {
        var units = 0, frames = 0, nodes = 0, bytes = 0
        for value in values {
            guard value.logicalCost <= maximumUnits - units else { return false }
            units += value.logicalCost
            switch value {
            case let .geometry(frame, _):
                guard frames < EluNativeReplayFrameBuffer.maximumFrames,
                      frame.nodes.count <= 9_999,
                      frame.nodes.count <= EluNativeReplayFrameBuffer.maximumNodes - nodes else { return false }
                frames += 1; nodes += frame.nodes.count
                bytes += frame.nodes.count * 512 + 256
                guard bytes <= maximumBytes else { return false }
                for node in frame.nodes {
                    if case let .ordinaryText(text) = node.kind {
                        let count = text.utf8.count
                        guard count <= 4_096,
                              count <= maximumBytes - bytes else { return false }
                        bytes += count
                    }
                }
            case .interaction:
                bytes += value.logicalCost * 256
            }
            guard bytes <= maximumBytes else { return false }
        }
        return true
    }

    /// Before the first actual snapshot commit, neither graceful stop nor space
    /// pressure can manufacture minimum eligibility from a later timer reading.
    mutating func beginSealing(graceful: Bool = false) throws -> Seal? {
        try requireIntake()
        guard !records.isEmpty else { return nil }
        if var initial {
            if graceful {
                guard try initial.beginGracefulSealing() != nil else { return nil }
            } else {
                guard initial.isReady else { return nil }
                _ = try initial.beginSealing()
            }
            self.initial = initial
        } else if !graceful && !ready { return nil }
        let seal = Seal(identity: UUID(), records: records)
        pending = seal
        return seal
    }

    /// Call only after the exact prepared prefix has durably committed. A failed
    /// seal stays pending, so retries return the original bytes at the owner; no
    /// buffer dequeue or second encoding is permitted by this value API.
    mutating func committed(_ seal: Seal) throws {
        guard !terminal, let pending, pending == seal, let lastTime else {
            throw EluNativeInteractionError.invalidSeal
        }
        if var initial {
            try initial.committed()
            nextOrdinal = initial.nextFrameOrdinal
            self.initial = nil; initialTimes.removeAll(keepingCapacity: false)
        }
        records.removeAll(keepingCapacity: false)
        self.pending = nil; ready = false; lastCommitContinuous = lastTime.continuous
    }

    mutating func withdraw() {
        terminal = true; initial?.withdraw(); initial = nil
        initialTimes.removeAll(keepingCapacity: false)
        records.removeAll(keepingCapacity: false)
        pending = nil; ready = false; active = false
    }
}
