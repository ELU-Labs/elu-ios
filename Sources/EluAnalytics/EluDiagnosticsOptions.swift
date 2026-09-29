import Foundation

/// Delayed numeric OS diagnostic and launch summaries. No crash stacks or text.
/// Collection also requires provable consent/identity continuity and current
/// analytics permission. MetricKit delivery is not guaranteed by the OS.
public struct EluDiagnosticsOptions: Sendable, Equatable {
    public var enabled: Bool
    /// OS launch/resume histograms additionally require current server
    /// responsiveness permission. This option is independently disabled.
    public var launchSummaries: Bool
    public init(enabled: Bool = false, launchSummaries: Bool = false) {
        self.enabled = enabled; self.launchSummaries = launchSummaries
    }
}
