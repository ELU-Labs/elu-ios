import Foundation

/// A detached event offered to `EluSetupOptions.beforeSend` before durable IDs
/// are assigned. Identity, session and SDK metadata remain runtime-owned.
public struct EluEvent {
    public var event: String
    public var properties: [String: Any]
    public var timestamp: Date
    /// Capture-associated person changes. They follow an accepted manual event
    /// in a separate ordered write; they are not part of event properties.
    public var set: [String: Any]?
    public var setOnce: [String: Any]?

    public init(event: String, properties: [String: Any] = [:], timestamp: Date,
                set: [String: Any]? = nil, setOnce: [String: Any]? = nil) {
        self.event = event
        self.properties = properties
        self.timestamp = timestamp
        self.set = set
        self.setOnce = setOnce
    }
}
