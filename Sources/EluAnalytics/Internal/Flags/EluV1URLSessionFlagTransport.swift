import Foundation

enum EluV1FlagTransportError: Error, Equatable {
    case untrustedEndpoint
    case invalidResponse
    case httpStatus(Int)
}

/// Concrete internal POST transport. The existing flag client/SQLite owner
/// supplies and validates identity, context and cache witnesses. This adapter
/// never constructs identity or returns fallback values on HTTP failure.
final class EluV1URLSessionFlagTransport: EluV1AuthorizedFlagTransport, @unchecked Sendable {
    private let slot = EluV1PhysicalTransportSlot()
    private let siteKey: String
    private let protocolClasses: [AnyClass]?
    static let timeoutSeconds: TimeInterval = 10

    init(siteKey: String, protocolClasses: [AnyClass]? = nil) throws {
        // Reuse the canonical issued-key boundary without fetching config.
        _ = try EluV2ConfigRequest(siteKey: siteKey, configHost: URL(string: "https://elu.dev")!)
        self.siteKey = siteKey
        self.protocolClasses = protocolClasses
    }

    func send(endpoint: URL, requestBody: Data) async throws -> Data {
        try await send(endpoint: endpoint, requestBody: requestBody, binding: nil)
    }

    func send(endpoint: URL, requestBody: Data, authority: EluV1TransportAuthority) async throws -> Data {
        try await send(endpoint: endpoint, requestBody: requestBody, binding: authority)
    }

    private func send(endpoint: URL, requestBody: Data, binding: EluV1TransportAuthority?) async throws -> Data {
        guard slot.acquire() else { throw EluV1BoundTransportError.occupied }
        defer { slot.release() }
        try Task.checkCancellation()
        if let binding, !(await binding.revalidate()) { throw EluV1BoundTransportError.staleAuthority }
        try Task.checkCancellation()
        guard EluV1Validation.isAbsoluteHTTPSURI(endpoint.absoluteString),
              let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.lowercased() == "ingest.elu.dev",
              parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.percentEncodedPath == "/v1/flags",
              parts.queryItems?.contains(where: { $0.name == "site_key" }) != true
        else { throw EluV1FlagTransportError.untrustedEndpoint }
        guard requestBody.count <= EluV1FlagJSON.maximumWireBytes else {
            throw EluV1FlagContractError.requestTooLarge
        }
        let request = try EluV1FlagJSON.parse(requestBody)
        guard request.objectMembers != nil,
              try EluV1FlagJSON.canonicalData(for: request) == requestBody
        else { throw EluV1FlagContractError.malformedRequest }
        var urlRequest = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: EluV1URLSessionFlagTransport.timeoutSeconds
        )
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = requestBody
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(siteKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let operation = EluV1BoundedFlagOperation(
            request: urlRequest, protocolClasses: protocolClasses, authority: binding
        )
        return try await withTaskCancellationHandler(
            operation: { try await operation.run() },
            onCancel: { operation.cancel() }
        )
    }
}

private final class EluV1BoundedFlagOperation: NSObject,
    URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable
{
    private let request: URLRequest
    private let protocolClasses: [AnyClass]?
    private let authority: EluV1TransportAuthority?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var responseReceived = false
    private var body = Data()
    private var completed = false
    private var outcome: Result<Data, Error>?
    private var cancelled = false
    private var taskCompleted = false
    private var sessionInvalidated = false

    init(request: URLRequest, protocolClasses: [AnyClass]?, authority: EluV1TransportAuthority?) {
        self.request = request
        self.protocolClasses = protocolClasses
        self.authority = authority
    }

    func run() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = protocolClasses
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = EluV1URLSessionFlagTransport.timeoutSeconds
            configuration.timeoutIntervalForResource = EluV1URLSessionFlagTransport.timeoutSeconds
            configuration.waitsForConnectivity = false
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: request)
            self.task = task
            let mayStart = !cancelled && (authority?.isCurrent() ?? true)
            lock.unlock()
            if mayStart { task.resume() }
            else { finish(.failure(EluV1BoundTransportError.staleAuthority)) }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.url == request.url
        else {
            finish(.failure(EluV1FlagTransportError.invalidResponse))
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 else {
            finish(.failure(EluV1FlagTransportError.httpStatus(http.statusCode)))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(EluV1FlagJSON.maximumWireBytes) else {
            finish(.failure(EluV1FlagContractError.responseTooLarge))
            completionHandler(.cancel)
            return
        }
        lock.lock()
        responseReceived = true
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        let exceeds = data.count > EluV1FlagJSON.maximumWireBytes - body.count
        if !exceeds { body.append(data) }
        lock.unlock()
        if exceeds { finish(.failure(EluV1FlagContractError.responseTooLarge)) }
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(EluV1FlagTransportError.invalidResponse))
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); taskCompleted = true; lock.unlock()
        defer { resumeAfterCleanup() }
        // URLSession may complete a failed body before delivering its response
        // delegate callback. A known refusal still wins over that body failure.
        if let response = task.response as? HTTPURLResponse {
            guard response.url == request.url else {
                finish(.failure(EluV1FlagTransportError.invalidResponse))
                return
            }
            if response.statusCode != 200 {
                finish(.failure(EluV1FlagTransportError.httpStatus(response.statusCode)))
                return
            }
        }
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let received = responseReceived
        let result = body
        lock.unlock()
        finish(received ? .success(result) : .failure(EluV1FlagTransportError.invalidResponse))
    }

    /// Completion remains pending until Foundation acknowledges session cleanup.
    /// Logical cancellation must not release the channel's physical slot early.
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        outcome = result
        let session = session
        if session == nil {
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
            return
        }
        lock.unlock()
        session?.invalidateAndCancel()
    }

    func urlSession(_: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        sessionInvalidated = true
        if outcome == nil, let error { outcome = .failure(error) }
        lock.unlock()
        resumeAfterCleanup()
    }

    private func resumeAfterCleanup() {
        lock.lock()
        guard taskCompleted, sessionInvalidated, let outcome else { lock.unlock(); return }
        let continuation = continuation
        self.continuation = nil
        self.session = nil
        self.task = nil
        lock.unlock()
        continuation?.resume(with: outcome)
    }
}
