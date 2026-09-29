import Foundation

/// Client capture admission. Identity mutations and replay chunks are not events.
/// Invalid/non-positive values use the defaults; burst is never below the rate.
public struct EluRateLimitingOptions: Sendable, Equatable {
    public var eventsPerSecond: Double
    public var eventsBurstLimit: Double

    public init(eventsPerSecond: Double = 10, eventsBurstLimit: Double? = nil) {
        let rate = eventsPerSecond.isFinite && eventsPerSecond > 0 ? eventsPerSecond : 10
        let fallback = rate * 10
        self.eventsPerSecond = rate
        self.eventsBurstLimit = max(eventsBurstLimit.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? (fallback.isFinite ? fallback : Double.greatestFiniteMagnitude), rate)
    }

    var normalized: Self { Self(eventsPerSecond: eventsPerSecond, eventsBurstLimit: eventsBurstLimit) }
}
