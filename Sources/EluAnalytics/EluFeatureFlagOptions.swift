/// Controls one feature-flag read without changing its identity or configuration authority.
public struct EluFeatureFlagOptions: Sendable {
    /// Report a deduplicated exposure for this read. Defaults to true.
    public var sendEvent: Bool
    /// Require this value to have been received remotely during this SDK owner's lifetime.
    /// This does not fetch flags or extend the cached value's expiry.
    public var fresh: Bool

    public init(sendEvent: Bool = true, fresh: Bool = false) {
        self.sendEvent = sendEvent
        self.fresh = fresh
    }
}
