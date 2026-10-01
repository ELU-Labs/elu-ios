import Foundation

/// One bounded synchronous producer/one serial drainer. Detached values only;
/// no task is created per event. Source/queue admission remains the owner’s job.
final class EluNativeReplayInteractionMailbox: @unchecked Sendable {
    static let maximumLogicalUnits = 64
    private let lock = NSLock()
    private var values: [EluNativeInteraction] = []
    private var units = 0
    private var active = false
    private var terminal = false
    private var lastTime: EluNativeInteractionTime?

    enum Offer: Equatable { case retained, cancelled, refused }

    func offer(_ value: EluNativeInteraction) -> Offer {
        lock.lock(); defer { lock.unlock() }
        guard !terminal, !value.times.isEmpty,
              value.times.count <= 10, ordered(value.times) else { return .refused }
        switch value {
        case .start: guard !active else { return .refused }
        case let .moves(points):
            guard active, let first = points.first,
                  points.allSatisfy({ $0.geometryOrdinal == first.geometryOrdinal }),
                  zip(points, points.dropFirst()).allSatisfy({ $0.1.time.timestamp > $0.0.time.timestamp })
            else { return .refused }
        case .end, .cancel: guard active else { return .refused }
        }
        let maximum = value.isTerminal ? Self.maximumLogicalUnits : Self.maximumLogicalUnits - 1
        guard value.logicalCost <= maximum - units else {
            // No coordinate from the rejected value crosses the boundary. The
            // reserved slot closes the already-observed gesture in order.
            if active, units < Self.maximumLogicalUnits, let time = value.times.first {
                values.append(.cancel(time)); units += 1; lastTime = time; active = false
                return .cancelled
            }
            return .refused
        }
        if case let .moves(points) = value, case let .moves(previous)? = values.last,
           previous.count + points.count <= 10,
           let first = previous.first, let last = points.last,
           last.time.timestamp - first.time.timestamp <= 900,
           let boundary = previous.last, let next = points.first,
           next.time.timestamp > boundary.time.timestamp,
           previous.allSatisfy({ $0.geometryOrdinal == next.geometryOrdinal }) {
            values[values.count - 1] = .moves(previous + points)
        } else { values.append(value) }
        units += value.logicalCost; lastTime = value.times.last
        if case .start = value { active = true }
        if value.isTerminal { active = false }
        return .retained
    }

    /// Draining is an ownership transfer, never an acknowledgement/queue commit.
    /// The future capture owner must keep this prefix ordered with geometry and
    /// retain it across early sealing; it may not drop a drained value on backpressure.
    func drain() -> [EluNativeInteraction] {
        lock.lock(); defer { lock.unlock() }
        guard !terminal else { return [] }
        let result = values; values.removeAll(keepingCapacity: false); units = 0
        return result
    }

    func withdraw() {
        lock.lock(); defer { lock.unlock() }
        terminal = true; values.removeAll(keepingCapacity: false); units = 0; active = false
    }

    private func ordered(_ times: [EluNativeInteractionTime]) -> Bool {
        var previous = lastTime
        for time in times {
            guard (1 ... 253_402_300_799_999).contains(time.timestamp),
                  previous.map({ time.timestamp >= $0.timestamp && time.continuous >= $0.continuous }) ?? true else { return false }
            previous = time
        }
        return true
    }
}

extension EluNativeInteraction {
    var points: [EluNativeInteractionPoint] {
        switch self {
        case let .start(point), let .end(point): return [point]
        case let .moves(points): return points
        case .cancel: return []
        }
    }
}
