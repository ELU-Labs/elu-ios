import Foundation

/// A facade operation held while the SDK is `pending` (no usable config yet).
enum EluBufferedOp {
    case capture(event: String, properties: [String: Any]?)
    case identify(distinctId: String, userProperties: [String: Any]?)
    case screen(name: String, properties: [String: Any]?)
    case alias(String)
    case register([String: Any])
    case registerOnce([String: Any], defaultValue: Any?)
    case unregister(String)
    case group(type: String, key: String, properties: [String: Any]?)
    case setPersonProperties([String: Any])
    case setPersonPropertiesForFlags([String: Any])
    case setGroupPropertiesForFlags(type: String, properties: [String: Any])
    case captureException(Error, properties: [String: Any]?)
    /// Ordered so a pre-config logout replays as capture → reset → capture,
    /// delivering pre-reset events under the pre-reset identity (web parity).
    case reset
    case consent(EluConsentOperation)
}

/// In-memory FIFO for pre-config facade calls. Cap 100, drop-oldest.
/// Never persisted, never sent until the EU/enabled decision is made.
struct EluEventBuffer {
    static let capacity = 100

    private(set) var ops: [EluBufferedOp] = []
    /// Calls the cap discarded, counted rather than reported: the facade never
    /// tells the caller a call was dropped.
    private(set) var droppedCount = 0

    mutating func push(_ op: EluBufferedOp) {
        if ops.count >= Self.capacity {
            let overflow = ops.count - Self.capacity + 1
            ops.removeFirst(overflow)
            droppedCount += overflow
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

/// One consent intent is accepted synchronously, then committed in call order.
/// A later opt-out must not be undone by an older in-flight opt-in.
final class EluConsentOperation: @unchecked Sendable {
    let id = UUID()
    let optedOut: Bool
    let event: String?
    let properties: [String: Any]?
    private let lock = NSLock()
    private var accepted = false

    init(optedOut: Bool, event: String? = nil, properties: [String: Any]? = nil) {
        self.optedOut = optedOut; self.event = event; self.properties = properties
    }
    func acceptOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !accepted else { return false }
        accepted = true
        return true
    }
}
