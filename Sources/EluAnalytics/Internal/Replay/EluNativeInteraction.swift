import Foundation

/// Detached producer values, not a permission or a public raw-event API. The
/// future UIKit owner must prove current hierarchy privacy before constructing a
/// point. The encoder independently joins its UUID/ordinal to committed geometry.
struct EluNativeInteractionTime: Equatable, Sendable {
    let timestamp: Int64
    let continuous: UInt64
}

struct EluNativeInteractionPoint: Equatable, Sendable {
    let identity: UUID
    let geometryOrdinal: Int64
    let time: EluNativeInteractionTime
    let x: Int64
    let y: Int64
}

enum EluNativeInteraction: Equatable, Sendable {
    case start(EluNativeInteractionPoint)
    case moves([EluNativeInteractionPoint])
    case end(EluNativeInteractionPoint)
    case cancel(EluNativeInteractionTime)

    var times: [EluNativeInteractionTime] {
        switch self {
        case let .start(point), let .end(point): return [point.time]
        case let .moves(points): return points.map(\.time)
        case let .cancel(time): return [time]
        }
    }
    var logicalCost: Int {
        if case let .moves(points) = self { return points.count }
        return 1
    }
    var isTerminal: Bool {
        switch self { case .end, .cancel: return true; case .start, .moves: return false }
    }
}

enum EluNativeReplayRecord: Equatable, Sendable {
    case geometry(EluNativeMaskedSnapshot, continuous: UInt64)
    case interaction(EluNativeInteraction)

    var times: [EluNativeInteractionTime] {
        switch self {
        case let .geometry(frame, continuous): return [.init(timestamp: frame.timestamp, continuous: continuous)]
        case let .interaction(value): return value.times
        }
    }
    var logicalCost: Int {
        switch self { case .geometry: return 1; case let .interaction(value): return value.logicalCost }
    }
}

enum EluNativeInteractionError: Error, Equatable, Sendable {
    case invalidOrder
    case invalidPoint
    case privateTarget
    case staleGeometry
    case invalidGesture
    case moveRate
    case invalidBatch
    case initialCommitRequired
    case bufferLimit
    case pendingSeal
    case invalidSeal
    case withdrawn
}
