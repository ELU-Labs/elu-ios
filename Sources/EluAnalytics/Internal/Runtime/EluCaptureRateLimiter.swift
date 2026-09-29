import Foundation

/// Site/base scoped, deliberately independent of identity, session and consent.
/// Wall-clock regression subtracts tokens; resetting an identity does not forgive debt.
struct EluCaptureRateBucket: Equatable, Sendable, Codable {
    var tokens: Double
    var last: Double

    func encoded() throws -> Data {
        guard tokens.isFinite, last.isFinite else { throw EluRuntimeQueueError.corruptStorage }
        return try EluV1StrictCanonicalJSON.parse(JSONSerialization.data(withJSONObject:
            ["tokens": tokens, "last": last])).canonicalData
    }

    static func decode(_ data: Data) throws -> Self? {
        if data == Data("null".utf8) { return nil }
        guard (1...256).contains(data.count) else { throw EluRuntimeQueueError.corruptStorage }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard try value.encoded() == data else { throw EluRuntimeQueueError.corruptStorage }
        return value
    }
}

struct EluCaptureRateDecision: Sendable {
    let limited: Bool
    let warning: String?
}

/// One original submit may retry its authority witness. It must not debit a
/// second token for the same call, or reuse that debit for another command/owner.
final class EluCaptureRateAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var original: (UUID, EluV1CaptureCommand)?
    func claim(owner: UUID, command: EluV1CaptureCommand) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let original {
            guard original.0 == owner, original.1 == command else { throw EluRuntimeQueueError.invalidState }
            return false
        }
        original = (owner, command)
        return true
    }
}

struct EluCaptureRateLimiter: Sendable {
    static let warningEvent = "$$client_ingestion_warning"
    static let warningProperty = "$$client_ingestion_warning_message"
    let settings: EluRateLimitingOptions
    private(set) var held: EluCaptureRateBucket?
    private var lastEventRateLimited = false

    init(settings: EluRateLimitingOptions) { self.settings = settings.normalized }

    /// The constructor calls this once with checkOnly. Persistence is performed
    /// by the queue using its original lease and connection; held remains the
    /// fallback if a known, rolled-back metadata write cannot be persisted.
    mutating func context(stored: EluCaptureRateBucket?, at: Date, checkOnly: Bool) throws -> EluCaptureRateDecision {
        let now = at.timeIntervalSince1970 * 1_000
        guard now.isFinite else { throw EluRuntimeQueueError.invalidState }
        var bucket = stored ?? held ?? .init(tokens: settings.eventsBurstLimit, last: now)
        bucket.tokens += ((now - bucket.last) / 1_000) * settings.eventsPerSecond
        bucket.last = now
        // Positive overflow is a full refill. Negative overflow remains denied,
        // represented by the largest finite debt so storage stays canonical.
        if bucket.tokens > settings.eventsBurstLimit { bucket.tokens = settings.eventsBurstLimit }
        if bucket.tokens == -.infinity { bucket.tokens = -Double.greatestFiniteMagnitude }
        guard bucket.tokens.isFinite else { throw EluRuntimeQueueError.invalidState }
        let limited = bucket.tokens < 1
        if !limited && !checkOnly { bucket.tokens = max(0, bucket.tokens - 1) }
        let warning = limited && !lastEventRateLimited && !checkOnly
            ? "Analytics SDK client rate limited. Config is set to \(Self.number(settings.eventsPerSecond)) events per second and \(Self.number(settings.eventsBurstLimit)) events burst limit."
            : nil
        lastEventRateLimited = limited
        held = bucket
        return .init(limited: limited, warning: warning)
    }

    private static func number(_ value: Double) -> String {
        // Avoid a trailing .0 for the normal integer settings in the web message.
        if value < Double(Int64.max), value.rounded() == value { return String(Int64(value)) }
        return String(value)
    }
}
