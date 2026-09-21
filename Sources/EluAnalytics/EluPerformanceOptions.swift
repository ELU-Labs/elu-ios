import Foundation

/// Opt-in native process-memory and main-thread responsiveness measurements.
/// Remote policy, consent, and foreground lifecycle must also permit collection.
public struct EluPerformanceOptions: Sendable, Equatable {
    public var enabled: Bool
    public var memory: Bool
    public var mainThreadStalls: Bool
    public var sampleIntervalMilliseconds: Int
    public var mainThreadStallThresholdMilliseconds: Int

    public init(enabled: Bool = false, memory: Bool = true, mainThreadStalls: Bool = true,
                sampleIntervalMilliseconds: Int = 30_000,
                mainThreadStallThresholdMilliseconds: Int = 250) {
        self.enabled = enabled; self.memory = memory; self.mainThreadStalls = mainThreadStalls
        self.sampleIntervalMilliseconds = sampleIntervalMilliseconds
        self.mainThreadStallThresholdMilliseconds = mainThreadStallThresholdMilliseconds
    }
}
