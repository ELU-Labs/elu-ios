import Foundation

/// Internal bounded foreground transport. It refuses redirects so the injected
/// authorization header can never be forwarded to a different origin, and it
/// stops buffering as soon as the response ceiling is crossed.
final class EluV1URLSessionBatchTransport: EluV1BatchHTTPTransport, @unchecked Sendable {
    func send(_ request: EluV1BatchHTTPRequest) async throws -> EluV1BatchHTTPResponse {
        guard request.url.scheme?.lowercased() == "https",
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
            maximumResponseBytes: request.maximumResponseBytes
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
    private let lock = NSLock()

    private var continuation: CheckedContinuation<EluV1BatchHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var completed = false
    private var cancelled = false

    init(request: URLRequest, maximumResponseBytes: Int) {
        self.request = request
        self.maximumResponseBytes = maximumResponseBytes
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
            lock.unlock()
            task.resume()
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
        guard let http = response as? HTTPURLResponse,
              (100 ... 599).contains(http.statusCode)
        else {
            completionHandler(.cancel)
            finish(.failure(EluV1BatchDeliveryError.malformedResponse))
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

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
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
        var headers: [String: String] = [:]
        for (rawName, rawValue) in response.allHeaderFields {
            guard let name = rawName as? String else { continue }
            headers[name] = String(describing: rawValue)
        }
        finish(
            .success(
                EluV1BatchHTTPResponse(
                    status: response.statusCode,
                    headers: headers,
                    body: body
                )
            )
        )
    }

    private func finish(_ result: Result<EluV1BatchHTTPResponse, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        task = nil
        lock.unlock()

        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
