import Foundation
import XCTest
@testable import EluAnalytics

final class EluV2URLSessionConfigTransportTests: XCTestCase {
    func testGETDisablesCookieAndCacheAndPreservesExactRequestPath() async throws {
        let request = try makeRequest()
        EluV2ConfigURLProtocol.handler.set { observed, client, protocolInstance in
            XCTAssertEqual(observed.url, request.url)
            XCTAssertEqual(observed.httpMethod, "GET")
            XCTAssertNil(observed.httpBody)
            XCTAssertFalse(observed.httpShouldHandleCookies)
            XCTAssertEqual(observed.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            XCTAssertEqual(observed.timeoutInterval, 10)
            XCTAssertEqual(observed.value(forHTTPHeaderField: "Accept"), "application/json")
            client.urlProtocol(protocolInstance, didReceive: Self.response(observed, status: 200), cacheStoragePolicy: .notAllowed)
            client.urlProtocol(protocolInstance, didLoad: Data("{}".utf8))
            client.urlProtocolDidFinishLoading(protocolInstance)
        }
        let body = try await transport().fetch(request)
        XCTAssertEqual(body, Data("{}".utf8))
    }

    func testNon200AndForeignFinalURLFailClosed() async throws {
        for status in [204, 301, 304, 401, 403, 429, 500] {
            EluV2ConfigURLProtocol.handler.set { observed, client, protocolInstance in
                client.urlProtocol(protocolInstance, didReceive: Self.response(observed, status: status), cacheStoragePolicy: .notAllowed)
                client.urlProtocol(protocolInstance, didLoad: Data("{unreadable".utf8))
                client.urlProtocolDidFinishLoading(protocolInstance)
            }
            await expectFailure()
        }
        EluV2ConfigURLProtocol.handler.set { _, client, protocolInstance in
            let response = HTTPURLResponse(url: URL(string: "https://evil.test/config")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(protocolInstance)
        }
        await expectFailure()
    }

    func testAnnouncedAndStreamingOversizeBodiesAreRejected() async throws {
        for announce in [true, false] {
            EluV2ConfigURLProtocol.handler.set { observed, client, protocolInstance in
                let headers = announce ? ["Content-Length": "65537"] : [:]
                client.urlProtocol(protocolInstance, didReceive: Self.response(observed, status: 200, headers: headers), cacheStoragePolicy: .notAllowed)
                client.urlProtocol(protocolInstance, didLoad: Data(repeating: 32, count: 32_768))
                client.urlProtocol(protocolInstance, didLoad: Data(repeating: 32, count: 32_769))
                client.urlProtocolDidFinishLoading(protocolInstance)
            }
            await expectFailure()
        }
    }

    func testExactBodyCeilingIsAccepted() async throws {
        EluV2ConfigURLProtocol.handler.set { observed, client, protocolInstance in
            client.urlProtocol(protocolInstance, didReceive: Self.response(observed, status: 200), cacheStoragePolicy: .notAllowed)
            client.urlProtocol(protocolInstance, didLoad: Data(repeating: 32, count: 65_536))
            client.urlProtocolDidFinishLoading(protocolInstance)
        }
        let body = try await transport().fetch(makeRequest())
        XCTAssertEqual(body.count, 65_536)
    }

    func testRedirectIsRefusedWithoutSecondRequest() async throws {
        let count = EluV2ConfigRequestCount()
        EluV2ConfigURLProtocol.handler.set { observed, client, protocolInstance in
            count.increment()
            client.urlProtocol(protocolInstance, wasRedirectedTo: URLRequest(url: URL(string: "https://evil.test/config")!), redirectResponse: Self.response(observed, status: 302))
        }
        await expectFailure()
        XCTAssertEqual(count.read(), 1)
    }

    func testNetworkFailureAndCanceledFetchThrow() async throws {
        EluV2ConfigURLProtocol.handler.set { _, client, protocolInstance in
            client.urlProtocol(protocolInstance, didFailWithError: URLError(.timedOut))
        }
        await expectFailure()
        let started = expectation(description: "request started")
        EluV2ConfigURLProtocol.handler.set { _, _, _ in started.fulfill() }
        let request = try makeRequest()
        let task = Task { try await transport().fetch(request) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled config fetch succeeded") } catch {}
    }

    private func makeRequest() throws -> EluV2ConfigRequest {
        try EluV2ConfigRequest(siteKey: "elu_pk_test_" + String(repeating: "a", count: 22), configHost: URL(string: "https://elu.dev")!)
    }
    private func transport() -> EluV2URLSessionConfigTransport {
        EluV2URLSessionConfigTransport(protocolClasses: [EluV2ConfigURLProtocol.self])
    }
    private func expectFailure() async {
        do { _ = try await transport().fetch(makeRequest()); XCTFail("Untrusted config response succeeded") } catch {}
    }
    private static func response(_ request: URLRequest, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

private final class EluV2ConfigURLProtocol: URLProtocol, @unchecked Sendable {
    static let handler = Handler()
    final class Handler: @unchecked Sendable {
        typealias Callback = (URLRequest, URLProtocolClient, URLProtocol) -> Void
        private let lock = NSLock()
        private var callback: Callback?
        func set(_ callback: @escaping Callback) { lock.lock(); self.callback = callback; lock.unlock() }
        func call(_ request: URLRequest, _ client: URLProtocolClient, _ instance: URLProtocol) {
            lock.lock(); let callback = callback; lock.unlock()
            callback?(request, client, instance)
        }
    }
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let client else { return }
        Self.handler.call(request, client, self)
    }
    override func stopLoading() {}
}

private final class EluV2ConfigRequestCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
