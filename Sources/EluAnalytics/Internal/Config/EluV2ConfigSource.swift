import Darwin
import Foundation

/// Raw config data is not capture, flag, or replay authorization. Each channel
/// must still apply its privacy and identity checks through the config manager.
enum EluV2ConfigRefreshResult: Equatable, Sendable {
    case document(Data)
    case unavailable
    case superseded
}

enum EluV2ConfigSourceError: Error, Equatable {
    case invalidSiteKey
    case untrustedConfigHost
    case invalidResponse
    case responseTooLarge
    case invalidLease
}

struct EluV2ConfigRequest: Sendable {
    let url: URL
    static let maximumResponseBytes = 65_536
    static let timeoutSeconds: TimeInterval = 10

    init(siteKey: String, configHost: URL) throws {
        // Matches the public config service boundary. Do not trim or rewrite a
        // credential, and never permit it to become URL syntax.
        guard siteKey.range(
            of: #"\Aelu_pk_(live|test)_[A-Za-z0-9]{22,64}\z"#,
            options: .regularExpression
        ) != nil else { throw EluV2ConfigSourceError.invalidSiteKey }
        guard case let .approved(origin) = EluConfigHostAllowlist.resolve(
            configHost: configHost
        ) else { throw EluV2ConfigSourceError.untrustedConfigHost }
        url = origin.appendingPathComponent("sdk/v2/\(siteKey)/config")
    }
}

protocol EluV2ConfigTransport: Sendable {
    /// Returns only a bounded HTTP 200 response from the exact request URL.
    func fetch(_ request: EluV2ConfigRequest) async throws -> Data
}

struct EluV2ConfigLease: Equatable, Sendable {
    let data: Data
    let expiresAt: EluV1Timestamp
    let continuousDeadline: UInt64
}

struct EluV2ConfigClock: Sendable {
    let wallNow: @Sendable () -> Date
    let continuousNow: @Sendable () -> UInt64
    let floorTicks: @Sendable (UInt64) -> UInt64?
    let floorNanoseconds: @Sendable (UInt64) -> UInt64?

    init(
        wallNow: @escaping @Sendable () -> Date,
        continuousNow: @escaping @Sendable () -> UInt64,
        floorTicks: @escaping @Sendable (UInt64) -> UInt64?,
        floorNanoseconds: @escaping @Sendable (UInt64) -> UInt64? = {
            EluV2ConfigClock.continuousNanoseconds(forTicks: $0)
        }
    ) {
        self.wallNow = wallNow
        self.continuousNow = continuousNow
        self.floorTicks = floorTicks
        self.floorNanoseconds = floorNanoseconds
    }

    private static func continuousNanoseconds(forTicks ticks: UInt64) -> UInt64? {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else {
            return nil
        }
        let numerator = UInt64(info.numer)
        let denominator = UInt64(info.denom)
        let (whole, overflow) = (ticks / denominator).multipliedReportingOverflow(by: numerator)
        let (partial, partialOverflow) = (ticks % denominator).multipliedReportingOverflow(by: numerator)
        guard !overflow, !partialOverflow else { return nil }
        let (result, sumOverflow) = whole.addingReportingOverflow(partial / denominator)
        return sumOverflow ? nil : result
    }

    static let live = EluV2ConfigClock(
        wallNow: { Date() },
        continuousNow: { EluMachContinuousClock.now() },
        floorTicks: { EluMachContinuousClock.floorTicks(forNanoseconds: $0) }
    )
}

/// Internal one-shot source, privately owned by EluV2ConfigLifecycle for renewal
/// and independent withdrawal behind the public facade.
/// No cached/provider fallback is used, and failed fetches retain the manager's
/// anti-rollback boundary while withdrawing the published document.
actor EluV2ConfigSource {
    private let request: EluV2ConfigRequest
    private let transport: any EluV2ConfigTransport
    private let clock: EluV2ConfigClock
    private let manager = EluV1ConfigManager(readbackProvenReplayTransports: EluStandaloneRuntime.readbackProvenReplayCapabilities.transports)
    private var lease: EluV2ConfigLease?
    private var acceptedIssuedAt: EluV1Timestamp?
    private var acceptedDeadline: UInt64?
    private var attempt: UUID?
    private var pending: Task<Data, Error>?
    private var closed = false
    private var clockInvalid = false
    private var lastWall: Date?
    private var lastContinuous: UInt64?

    init(
        siteKey: String,
        configHost: URL = URL(string: "https://elu.dev")!,
        transport: any EluV2ConfigTransport = EluV2URLSessionConfigTransport(),
        clock: EluV2ConfigClock = .live
    ) throws {
        request = try EluV2ConfigRequest(siteKey: siteKey, configHost: configHost)
        self.transport = transport
        self.clock = clock
    }

    func currentDocument() -> Data? {
        currentLease()?.data
    }

    func currentLease() -> EluV2ConfigLease? {
        guard !closed, let sample = sampleClock() else {
            lease = nil
            return nil
        }
        guard let lease,
              !lease.expiresAt.isAtOrBefore(sample.wall),
              sample.continuous < lease.continuousDeadline
        else {
            lease = nil
            return nil
        }
        return lease
    }

    func refresh() async -> EluV2ConfigRefreshResult {
        guard !closed, !Task.isCancelled, let startedAt = sampleClock() else {
            lease = nil
            return .unavailable
        }
        _ = currentDocument()
        pending?.cancel()
        let token = UUID()
        attempt = token
        let request = request
        let transport = transport
        let task = Task { try await transport.fetch(request) }
        pending = task
        do {
            let data = try await withTaskCancellationHandler(
                operation: { try await task.value },
                onCancel: { task.cancel() }
            )
            guard !closed, attempt == token else { return .superseded }
            pending = nil
            guard !Task.isCancelled, !task.isCancelled,
                  let sample = sampleClock()
            else { throw EluV2ConfigSourceError.invalidLease }
            guard data.count <= EluV2ConfigRequest.maximumResponseBytes else {
                throw EluV2ConfigSourceError.responseTooLarge
            }
            let strict = try EluV1StrictCanonicalJSON.parse(data)
            let document = try JSONDecoder().decode(
                EluV1ConfigDocument.self, from: strict.canonicalData
            )
            guard document.schemaVersion == EluV1ConfigDocument.v2SchemaVersion,
                  Self.validWindow(document, now: sample.wall)
            else { throw EluV2ConfigSourceError.invalidLease }

            // Update before testing remaining life: a validated expired/revoked
            // document still establishes a boundary against older responses.
            let update = try manager.update(configData: data, now: sample.wall)
            if case .stale = update {
                return currentDocument().map(EluV2ConfigRefreshResult.document) ?? .unavailable
            }
            guard !document.expiresAt.isAtOrBefore(sample.wall),
                  let remaining = document.expiresAt.floorNanoseconds(after: sample.wall),
                  remaining > 0, let ticks = clock.floorTicks(remaining), ticks > 0
            else { throw EluV2ConfigSourceError.invalidLease }
            let (receivedDeadline, overflow) = sample.continuous.addingReportingOverflow(ticks)
            guard !overflow,
                  let startingBudget = document.expiresAt.floorNanoseconds(after: startedAt.wall),
                  let startingTicks = clock.floorTicks(startingBudget)
            else { throw EluV2ConfigSourceError.invalidLease }
            let (startedDeadline, startingOverflow) = startedAt.continuous.addingReportingOverflow(startingTicks)
            guard !startingOverflow else { throw EluV2ConfigSourceError.invalidLease }
            // Network time also consumes the lease if the wall clock stalls.
            let deadline = min(receivedDeadline, startedDeadline)
            let boundedDeadline: UInt64
            if acceptedIssuedAt == document.issuedAt, let previous = acceptedDeadline {
                boundedDeadline = min(previous, deadline)
            } else {
                boundedDeadline = deadline
            }
            acceptedIssuedAt = document.issuedAt
            acceptedDeadline = boundedDeadline
            guard sample.continuous < boundedDeadline else {
                throw EluV2ConfigSourceError.invalidLease
            }
            lease = EluV2ConfigLease(data: data, expiresAt: document.expiresAt, continuousDeadline: boundedDeadline)
            return .document(data)
        } catch {
            guard !closed, attempt == token else { return .superseded }
            pending = nil
            lease = nil
            return .unavailable
        }
    }

    /// Revokes the published lease and pending attempt without forgetting
    /// newest issuance/conflict or spent continuous-deadline witnesses.
    func withdraw() {
        attempt = nil
        pending?.cancel()
        pending = nil
        lease = nil
    }

    func close() {
        closed = true
        withdraw()
    }

    private func sampleClock() -> (wall: Date, continuous: UInt64)? {
        guard !clockInvalid else { return nil }
        let wall = clock.wallNow()
        let continuous = clock.continuousNow()
        guard (try? EluV1Timestamp.exactClock(wall)) != nil,
              lastWall.map({ wall >= $0 }) ?? true,
              lastContinuous.map({ continuous >= $0 }) ?? true
        else {
            clockInvalid = true
            lease = nil
            return nil
        }
        lastWall = wall
        lastContinuous = continuous
        return (wall, continuous)
    }

    private static func validWindow(_ document: EluV1ConfigDocument, now: Date) -> Bool {
        let start = document.issuedAt
        let end = document.expiresAt
        guard start < end, start.isAtOrBefore(now),
              !start.storageIsLeapSecond, !end.storageIsLeapSecond
        else { return false }
        let seconds = (end.storageDay - start.storageDay) * 86_400
            + end.storageSecondOfDay - start.storageSecondOfDay
        if seconds < 600 { return true }
        guard seconds == 600 else { return false }
        // A subnanosecond excess must not pass through duration rounding.
        let count = max(start.storageFractionDigits.count, end.storageFractionDigits.count)
        let startFraction = start.storageFractionDigits.padding(
            toLength: count, withPad: "0", startingAt: 0
        )
        let endFraction = end.storageFractionDigits.padding(
            toLength: count, withPad: "0", startingAt: 0
        )
        return endFraction <= startFraction
    }
}
