import Foundation

/// Delayed OS diagnostics. Numeric summaries and individual crash reports have
/// separate local opt-ins. No stack tree or raw OS payload is collected.
/// Collection also requires provable consent/identity continuity and current
/// analytics permission. MetricKit delivery is not guaranteed by the OS.
public struct EluDiagnosticsOptions: Sendable, Equatable {
    public var enabled: Bool
    /// OS launch/resume histograms additionally require current server
    /// responsiveness permission. This option is independently disabled.
    public var launchSummaries: Bool
    /// Requires `enabled`, continuous local report consent and a current supported
    /// server exception grant. iOS 14+; OS delivery is not guaranteed.
    public var crashReports: Bool = false
    /// Separately permits bounded iOS 17+ Objective-C name/reason details.
    /// Has no effect unless both `enabled` and `crashReports` are true.
    public var crashReportDetails: Bool = false
    public init(enabled: Bool = false, launchSummaries: Bool = false) {
        self.enabled = enabled; self.launchSummaries = launchSummaries
    }
    public init(enabled: Bool, launchSummaries: Bool = false,
                crashReports: Bool, crashReportDetails: Bool = false) {
        self.enabled = enabled; self.launchSummaries = launchSummaries
        self.crashReports = crashReports; self.crashReportDetails = crashReportDetails
    }
}
