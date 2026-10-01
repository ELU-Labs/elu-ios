import Foundation

/// Shared across wrappers and runtime lifetimes. Identity and consent changes
/// cannot replenish the process's bounded observation budget.
final class EluNetworkObservationBudget: @unchecked Sendable {
    static let shared = EluNetworkObservationBudget()
    private let lock = NSLock()
    private var attempted = 0
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard attempted < 200 else { return false }
        attempted += 1
        return true
    }
}

struct EluNetworkObservationContext: Equatable, Sendable {
    let identityRevision: Int64
    let contextRevision: Int64
    let sessionID: String?
    var sessionStartedAt: Date? = nil
}

/// The gate is published by the actor only after authoritative configuration
/// settles. A request never waits for initialization, configuration or storage.
final class EluNetworkObservationGate: @unchecked Sendable {
    private struct Publication {
        let context: EluNetworkObservationContext
        let current: @Sendable () -> Bool
        let emit: @Sendable (EluNetworkObservationContext, [String: EluJSONValue], @escaping @Sendable () -> Bool) -> Void
    }
    private let lock = NSLock()
    private var generation = UUID()
    private var mutations: Set<UUID> = []
    private var publication: Publication?
    private var foreground = false
    private let budget: EluNetworkObservationBudget
    private let now: @Sendable () -> UInt64

    init(budget: EluNetworkObservationBudget = .shared,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.budget = budget; self.now = now
    }
    func invalidate() {
        lock.lock(); generation = UUID(); publication = nil; lock.unlock()
    }
    func setForeground(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        foreground = value
        if !value { generation = UUID(); publication = nil }
    }
    func beginMutation() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID(); mutations.insert(id); generation = UUID(); publication = nil
        return id
    }
    func finishMutation(_ id: UUID) {
        lock.lock(); mutations.remove(id); lock.unlock()
    }
    func publish(context: EluNetworkObservationContext, current: @escaping @Sendable () -> Bool,
                 emit: @escaping @Sendable (EluNetworkObservationContext, [String: EluJSONValue], @escaping @Sendable () -> Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard foreground, mutations.isEmpty else { return }
        publication = Publication(context: context, current: current, emit: emit)
    }
    func begin(_ request: URLRequest, excludedHost: String? = nil, excludedHosts: Set<String> = []) -> EluNetworkObservation? {
        guard let url = request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty,
              host != excludedHost, !excludedHosts.contains(host), host != "elu.dev", !host.hasSuffix(".elu.dev") else { return nil }
        lock.lock(); let value = publication; let token = generation; let allowed = foreground && mutations.isEmpty; lock.unlock()
        guard allowed, let value, value.current(), isCurrent(token), budget.take() else { return nil }
        let current: @Sendable () -> Bool = { [weak self] in self?.isCurrent(token) == true && value.current() }
        return EluNetworkObservation(method: request.httpMethod ?? "GET", now: now, current: current,
                                     excludedHost: excludedHost, excludedHosts: excludedHosts) { fields in
            value.emit(value.context, fields, current)
        }
    }
    private func isCurrent(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return foreground && token == generation && mutations.isEmpty && publication != nil
    }
}

/// Contains no request, response or error object. Completion consumes it once;
/// only bounded numeric values and a sanitized HTTP method cross to the queue.
final class EluNetworkObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var began: UInt64?
    private var completed = false
    private let method: String
    private let now: @Sendable () -> UInt64
    private let current: @Sendable () -> Bool
    private let emit: @Sendable ([String: EluJSONValue]) -> Void
    private let excludedHost: String?
    private let excludedHosts: Set<String>
    init(method: String, now: @escaping @Sendable () -> UInt64,
         current: @escaping @Sendable () -> Bool,
         excludedHost: String? = nil, excludedHosts: Set<String> = [],
         emit: @escaping @Sendable ([String: EluJSONValue]) -> Void) {
        let normalized = method.uppercased()
        self.method = ["GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATCH"].contains(normalized)
            ? normalized : "UNKNOWN"
        self.excludedHost = excludedHost
        self.excludedHosts = excludedHosts
        self.now = now; self.current = current; self.emit = emit
    }
    func start() {
        lock.lock(); defer { lock.unlock() }
        if began == nil, !completed { began = now() }
    }
    func finish(response: URLResponse?, failed: Bool) {
        lock.lock()
        guard !completed, let began else { lock.unlock(); return }
        completed = true; lock.unlock()
        let ended = now()
        guard current(), ended >= began else { return }
        if let host = response?.url?.host?.lowercased(),
           host == excludedHost || excludedHosts.contains(host) || host == "elu.dev" || host.hasSuffix(".elu.dev") { return }
        let elapsed = Double(ended - began) / 1_000_000
        guard elapsed.isFinite, elapsed <= 86_400_000 else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        emit([
            "$network_method": .string(method),
            "$network_status_code": .integer((0 ... 999).contains(status) ? Int64(status) : 0),
            "$network_response_time_ms": .number((elapsed * 10).rounded() / 10),
            "$network_initiator": .string("urlsession"),
            "$network_failed": .bool(failed),
        ])
    }
}
