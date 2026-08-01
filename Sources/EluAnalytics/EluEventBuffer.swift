import Foundation

/// A facade operation held while the SDK is `pending` (no usable config yet).
enum EluBufferedOp {
    case capture(event: String, properties: [String: Any]?)
    case identify(distinctId: String, userProperties: [String: Any]?)
    case screen(name: String, properties: [String: Any]?)
    case alias(String)
    case register([String: Any])
    case unregister(String)
    case group(type: String, key: String, properties: [String: Any]?)
    case setPersonProperties([String: Any])
    case setPersonPropertiesForFlags([String: Any])
    case setGroupPropertiesForFlags(type: String, properties: [String: Any])
    case captureException(Error, properties: [String: Any]?)
    /// Ordered so a pre-config logout replays as capture → reset → capture,
    /// delivering pre-reset events under the pre-reset identity (web parity).
    case reset
}

/// In-memory FIFO for pre-config facade calls. Cap 100, drop-oldest.
/// Never persisted, never sent until the EU/enabled decision is made.
struct EluEventBuffer {
    static let capacity = 100

    private(set) var ops: [EluBufferedOp] = []

    mutating func push(_ op: EluBufferedOp) {
        if ops.count >= Self.capacity {
            ops.removeFirst(ops.count - Self.capacity + 1)
        }
        ops.append(op)
    }

    mutating func drain() -> [EluBufferedOp] {
        let drained = ops
        ops = []
        return drained
    }

    mutating func dropAll() {
        ops = []
    }
}
