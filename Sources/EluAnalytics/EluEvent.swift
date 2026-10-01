import Foundation

/// A detached event offered to `EluSetupOptions.beforeSend` before durable IDs
/// are assigned. Identity, session and SDK metadata remain runtime-owned.
public struct EluEvent {
    public var event: String
    public var properties: [String: Any]
    public var timestamp: Date
    /// Capture-associated person changes follow an accepted event in a separate
    /// ordered write. For `$identify`, these are the projected person maps;
    /// `$set` and `$groupidentify` use their nested `properties` maps instead.
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
