import Foundation

/// A facade operation held while the SDK is `pending` (no usable config yet).
enum EluBufferedOp {
    case capture(event: String, properties: [String: Any]?, timestamp: Date? = nil,
                 set: [String: Any]? = nil, setOnce: [String: Any]? = nil)
    case identify(distinctId: String, userProperties: [String: Any]?, userPropertiesOnce: [String: Any] = [:])
    case screen(name: String, properties: [String: Any]?)
    case alias(String)
    case register([String: Any])
    case registerOnce([String: Any], defaultValue: Any?)
    case unregister(String)
    case group(type: String, key: String, properties: [String: Any]?)
    case setPersonProperties([String: Any], propertiesOnce: [String: Any] = [:])
    case setPersonPropertiesForFlags([String: Any])
    case setGroupPropertiesForFlags(type: String, properties: [String: Any])
    case captureException(Error, properties: [String: Any]?)
    /// Ordered so a pre-config logout replays as capture → reset → capture,
    /// delivering pre-reset events under the pre-reset identity (web parity).
    case reset
    case resetDeviceIdentity
    case resetGroups
    case resetPersonPropertiesForFlags
    case resetGroupPropertiesForFlags(String?)
    case consent(EluConsentOperation)
}

/// A pre-config facade call and the time the app made it.
struct EluHeldCall {
    let op: EluBufferedOp
    /// Kept when the call runs, so a held call is not stamped late.
    let calledAt: Date
}

/// In-memory FIFO for pre-config facade calls. Cap 100: once full, the newest
/// call is dropped, never an older one, so the held calls stay an unbroken
/// prefix of the app's identity history. Never persisted, never sent until
/// the EU/enabled decision is made.
struct EluEventBuffer {
    static let capacity = 100

    private(set) var calls: [EluHeldCall] = []
    var ops: [EluBufferedOp] { calls.map(\.op) }
    /// Calls the cap discarded, counted rather than reported: the facade never
    /// tells the caller a call was dropped.
    private(set) var droppedCount = 0

    mutating func push(_ op: EluBufferedOp, calledAt: Date = Date()) {
        guard calls.count < Self.capacity else {
            droppedCount += 1
            return
        }
        calls.append(EluHeldCall(op: op, calledAt: calledAt))
    }

    mutating func drain() -> [EluBufferedOp] {
        drainCalls().map(\.op)
    }

    mutating func drainCalls() -> [EluHeldCall] {
        let drained = calls
        calls = []
        return drained
    }

    /// An opt-out discards held calls made before it, except resets: a reset
    /// collects nothing and keeps the consent choice, so it still applies.
    mutating func dropAllExceptResets() {
        calls.removeAll { !$0.op.isReset }
    }
}

extension EluBufferedOp {
    var isReset: Bool {
        switch self {
        case .reset, .resetDeviceIdentity: return true
        default: return false
        }
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
