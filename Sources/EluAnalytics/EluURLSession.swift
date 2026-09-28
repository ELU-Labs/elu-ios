import Foundation

/// Explicit instrumentation of customer requests using the supplied session.
/// ELU records only method, status, elapsed time, initiator and failure status.
/// URLs, paths, headers, bodies and error descriptions are never recorded.
public final class EluURLSession: @unchecked Sendable {
    private let session: URLSession
    private let observe: @Sendable (URLRequest) -> EluNetworkObservation?

    /// Retains the session and its existing configuration and delegates.
    /// Creating a wrapper neither initializes ELU nor starts a request.
    public init(session: URLSession = .shared) {
        self.session = session
        observe = { EluCore.shared.beginNetworkObservation($0) }
    }

    init(session: URLSession, observe: @escaping @Sendable (URLRequest) -> EluNetworkObservation?) {
        self.session = session; self.observe = observe
    }

    /// Creates and immediately resumes the actual session task. Cancel it using
    /// the returned task. Its completion queue, response, data and error are
    /// supplied by Foundation; telemetry permission never prevents the request.
    @discardableResult
    public func perform(_ request: URLRequest,
                        completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        let observation = observe(request)
        let task = session.dataTask(with: request) { data, response, error in
            observation?.finish(response: response, failed: error != nil)
            completionHandler(data, response, error)
        }
        observation?.start()
        task.resume()
        return task
    }

    /// Uses Foundation's async request and cancellation behavior unchanged.
    @available(iOS 15.0, macOS 12.0, *)
    public func data(for request: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, URLResponse) {
        let observation = observe(request)
        observation?.start()
        do {
            let result = try await session.data(for: request, delegate: delegate)
            observation?.finish(response: result.1, failed: false)
            return result
        } catch {
            observation?.finish(response: nil, failed: true)
            throw error
        }
    }
}
