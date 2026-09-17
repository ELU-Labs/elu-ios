import Foundation

/// The path credential stays on the configured ELU origin. Responses are never
/// cached, redirects never followed, and non-200 bodies are never buffered.
final class EluV2URLSessionConfigTransport: EluV2ConfigTransport, @unchecked Sendable {
    private let protocolClasses: [AnyClass]?

    init(protocolClasses: [AnyClass]? = nil) {
        self.protocolClasses = protocolClasses
    }

    func fetch(_ request: EluV2ConfigRequest) async throws -> Data {
        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: EluV2ConfigRequest.timeoutSeconds
        )
        urlRequest.httpMethod = "GET"
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let operation = EluV2BoundedConfigOperation(
            request: urlRequest, protocolClasses: protocolClasses
        )
        return try await withTaskCancellationHandler(
            operation: { try await operation.run() },
            onCancel: { operation.cancel() }
        )
    }
}

private final class EluV2BoundedConfigOperation: NSObject,
    URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable
{
    private let request: URLRequest
    private let protocolClasses: [AnyClass]?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var responseReceived = false
    private var body = Data()
    private var completed = false
    private var cancelled = false

    init(request: URLRequest, protocolClasses: [AnyClass]?) {
        self.request = request
        self.protocolClasses = protocolClasses
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
            configuration.timeoutIntervalForRequest = EluV2ConfigRequest.timeoutSeconds
            configuration.timeoutIntervalForResource = EluV2ConfigRequest.timeoutSeconds
            configuration.waitsForConnectivity = false
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: request)
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == request.url
        else {
            completionHandler(.cancel)
            finish(.failure(EluV2ConfigSourceError.invalidResponse))
            return
        }
        guard response.expectedContentLength <= Int64(EluV2ConfigRequest.maximumResponseBytes) else {
            completionHandler(.cancel)
            finish(.failure(EluV2ConfigSourceError.responseTooLarge))
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
        let exceeds = data.count > EluV2ConfigRequest.maximumResponseBytes - body.count
        if !exceeds { body.append(data) }
        lock.unlock()
        if exceeds { finish(.failure(EluV2ConfigSourceError.responseTooLarge)) }
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(EluV2ConfigSourceError.invalidResponse))
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let received = responseReceived
        let result = body
        lock.unlock()
        finish(received ? .success(result) : .failure(EluV2ConfigSourceError.invalidResponse))
    }

    private func finish(_ result: Result<Data, Error>) {
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
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
