import Foundation

/// A flag result from one current identity and configuration snapshot.
public struct EluFeatureFlagResult {
    public let key: String
    public let enabled: Bool
    public let variant: String?
    /// JSON-compatible data. Explicit JSON null is `NSNull()`; absent is nil.
    public let payload: Any?
}
