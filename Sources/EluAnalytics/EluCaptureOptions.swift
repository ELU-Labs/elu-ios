import Foundation

/// Optional person changes follow an accepted event in the same ordered call.
/// They are separate durable writes; a crash can retain the event alone.
public struct EluCaptureOptions {
    public let set: [String: Any]?
    public let setOnce: [String: Any]?
    public let timestamp: Date?

    public init(set: [String: Any]? = nil, setOnce: [String: Any]? = nil, timestamp: Date? = nil) {
        self.set = set
        self.setOnce = setOnce
        self.timestamp = timestamp
    }
}
