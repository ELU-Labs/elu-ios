import Foundation

/// Internal bounded foreground transport. It refuses redirects so the injected
/// authorization header can never be forwarded to a different origin, and it
/// stops buffering as soon as the response ceiling is crossed.
final class EluV1URLSessionBatchTransport: EluV1AuthorizedBatchTransport, @unchecked Sendable {
    private let slot = EluV1PhysicalTransportSlot()
    private let protocolClasses: [AnyClass]?

    init(protocolClasses: [AnyClass]? = nil) { self.protocolClasses = protocolClasses }

    func send(_ request: EluV1BatchHTTPRequest) async throws -> EluV1BatchHTTPResponse {
        try await send(request, binding: nil)
    }

    func send(_ request: EluV1BatchHTTPRequest, authority: EluV1TransportAuthority) async throws -> EluV1BatchHTTPResponse {
        try await send(request, binding: authority)
    }

    private func send(_ request: EluV1BatchHTTPRequest, binding: EluV1TransportAuthority?) async throws -> EluV1BatchHTTPResponse {
        guard slot.acquire() else { throw EluV1BoundTransportError.occupied }
        defer { slot.release() }
        try Task.checkCancellation()
        if let binding, !(await binding.revalidate()) { throw EluV1BoundTransportError.staleAuthority }
        try Task.checkCancellation()
        guard EluV1Validation.isAbsoluteHTTPSURI(request.url.absoluteString),
              let parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.lowercased() == "ingest.elu.dev",
              parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.percentEncodedPath == "/v1/events",
              parts.queryItems?.contains(where: { $0.name == "site_key" }) != true,
              !request.body.isEmpty,
              request.body.count <= EluV1BatchAuthorizationSnapshot.maximumBatchBytes,
              request.timeoutSeconds.isFinite,
              (1 ... 60).contains(request.timeoutSeconds),
              (1 ... EluV1BatchDeliveryCoordinator.maximumResponseBytes)
                  .contains(request.maximumResponseBytes)
        else {
            throw EluV1BatchDeliveryError.invalidRequest
        }

        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: request.timeoutSeconds
        )
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let operation = EluV1BoundedURLSessionOperation(
            request: urlRequest,
            maximumResponseBytes: request.maximumResponseBytes,
            protocolClasses: protocolClasses,
            authority: binding
        )
        return try await withTaskCancellationHandler(
            operation: { try await operation.run() },
            onCancel: { operation.cancel() }
        )
    }
}

private final class EluV1BoundedURLSessionOperation: NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let request: URLRequest
    private let maximumResponseBytes: Int
    private let protocolClasses: [AnyClass]?
    private let authority: EluV1TransportAuthority?
    private let lock = NSLock()

    private var continuation: CheckedContinuation<EluV1BatchHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var completed = false
    private var outcome: Result<EluV1BatchHTTPResponse, Error>?
    private var cancelled = false
    private var taskCompleted = false
    private var sessionInvalidated = false

    init(request: URLRequest, maximumResponseBytes: Int, protocolClasses: [AnyClass]?, authority: EluV1TransportAuthority?) {
        self.request = request
        self.maximumResponseBytes = maximumResponseBytes
        self.protocolClasses = protocolClasses
        self.authority = authority
    }

    func run() async throws -> EluV1BatchHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled {
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
            configuration.timeoutIntervalForRequest = request.timeoutInterval
            configuration.timeoutIntervalForResource = request.timeoutInterval
            configuration.waitsForConnectivity = false
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
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
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.url == request.url,
              (100 ... 599).contains(http.statusCode)
        else {
            completionHandler(.cancel)
            finish(.failure(EluV1BatchDeliveryError.malformedResponse))
            return
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            completionHandler(.cancel)
            finish(.success(Self.response(http, body: Data())))
            return
        }
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            completionHandler(.cancel)
            finish(.failure(EluV1BatchDeliveryError.responseTooLarge))
            return
        }
        lock.lock()
        self.response = http
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        let exceedsLimit = data.count > maximumResponseBytes - body.count
        if !exceedsLimit {
            body.append(data)
        }
        let task = task
        lock.unlock()
        if exceedsLimit {
            task?.cancel()
            finish(.failure(EluV1BatchDeliveryError.responseTooLarge))
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never forward the bearer routing credential across a redirect.
        completionHandler(nil)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); taskCompleted = true; lock.unlock()
        defer { resumeAfterCleanup() }
        if let response = task.response as? HTTPURLResponse, response.url == request.url,
           response.statusCode == 401 || response.statusCode == 403 {
            finish(.success(Self.response(response, body: Data())))
            return
        }
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let response = response
        let body = body
        lock.unlock()
        guard let response else {
            finish(.failure(EluV1BatchDeliveryError.malformedResponse))
            return
        }
        finish(.success(Self.response(response, body: body)))
    }

    private static func response(_ response: HTTPURLResponse, body: Data) -> EluV1BatchHTTPResponse {
        var headers: [String: String] = [:]
        for (rawName, rawValue) in response.allHeaderFields {
            guard let name = rawName as? String else { continue }
            headers[name] = String(describing: rawValue)
        }
        return EluV1BatchHTTPResponse(status: response.statusCode, headers: headers, body: body)
    }

    private func finish(_ result: Result<EluV1BatchHTTPResponse, Error>) {
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
