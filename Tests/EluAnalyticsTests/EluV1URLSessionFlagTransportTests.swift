import Foundation
import XCTest
@testable import EluAnalytics

final class EluV1URLSessionFlagTransportTests: XCTestCase {
    private let key = "elu_pk_live_" + String(repeating: "a", count: 22)
    private let endpoint = URL(string: "https://ingest.elu.dev/v1/flags?route=2")!

    func testSendsExactCanonicalWitnessBodyAndBearerOnlyToDiscoveredEndpoint() async throws {
        let body = try requestBody()
        let reply = try fixture("flags-response.json")
        let expectedEndpoint = endpoint
        let expectedKey = key
        FlagURLProtocol.handler.set { request, client, instance in
            XCTAssertEqual(request.url, expectedEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(expectedKey)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            XCTAssertEqual(request.timeoutInterval, 10)
            XCTAssertEqual(Self.readBody(request), body)
            client.urlProtocol(instance, didReceive: Self.response(request, status: 200), cacheStoragePolicy: .notAllowed)
            client.urlProtocol(instance, didLoad: reply)
            client.urlProtocolDidFinishLoading(instance)
        }
        let result = try await transport().send(endpoint: endpoint, requestBody: body)
        XCTAssertEqual(result, reply)
    }

    func testRejectsUntrustedRoleOriginCredentialQueryAndURLSyntaxBeforeNetwork() async throws {
        FlagURLProtocol.handler.set { _, _, _ in XCTFail("Untrusted endpoint reached network") }
        for value in [
            "http://ingest.elu.dev/v1/flags", "https://ingest.elu.dev.evil.test/v1/flags",
            "https://elu.dev/v1/flags", "https://ingest.elu.dev/v1/events",
            "https://ingest.elu.dev/v1/%66lags", "https://ingest.elu.dev:444/v1/flags",
            "https://user@ingest.elu.dev/v1/flags", "https://ingest.elu.dev/v1/flags#fragment",
            "https://ingest.elu.dev/v1/flags?site_key=another", "https://ingest.elu.dev/v1/flags?%73ite_key=another",
        ] {
            do {
                _ = try await transport().send(endpoint: URL(string: value)!, requestBody: requestBody())
                XCTFail("Untrusted endpoint accepted: \(value)")
            } catch { XCTAssertEqual(error as? EluV1FlagTransportError, .untrustedEndpoint) }
        }
        XCTAssertThrowsError(try EluV1URLSessionFlagTransport(siteKey: "wrong\nkey"))
    }

    func testRejectsOversizedMalformedAndNoncanonicalRequestWithoutRewritingIt() async throws {
        FlagURLProtocol.handler.set { _, _, _ in XCTFail("Invalid request reached network") }
        for body in [
            Data(repeating: 32, count: EluV1FlagJSON.maximumWireBytes + 1),
            Data("{\"x\":1,\"x\":2}".utf8), Data("[1]".utf8),
            Data("{ \"x\": 1 }".utf8), Data(),
        ] {
            do { _ = try await transport().send(endpoint: endpoint, requestBody: body); XCTFail("Invalid request accepted") }
            catch {}
        }
    }

    func testEveryNon200RejectsBeforeParsingMalformedErrorBody() async throws {
        for status in [204, 301, 304, 401, 403, 413, 429, 500] {
            FlagURLProtocol.handler.set { request, client, instance in
                client.urlProtocol(instance, didReceive: Self.response(request, status: status), cacheStoragePolicy: .notAllowed)
                client.urlProtocol(instance, didLoad: Data("not JSON".utf8))
                client.urlProtocolDidFinishLoading(instance)
            }
            do { _ = try await transport().send(endpoint: endpoint, requestBody: requestBody()); XCTFail("HTTP failure accepted") }
            catch { XCTAssertEqual(error as? EluV1FlagTransportError, .httpStatus(status)) }
        }
    }

    func testBodyFailureBeforeFoundationDeliversHeadersStillFailsClosed() async throws {
        // URLProtocol may fail before Foundation exposes either its response
        // delegate callback or task.response. The adapter cannot invent status
        // from absent headers, but must never yield a flag body or fallback.
        for status in [401, 403] {
            FlagURLProtocol.handler.set { request, client, instance in
                client.urlProtocol(instance, didReceive: Self.response(request, status: status), cacheStoragePolicy: .notAllowed)
                client.urlProtocol(instance, didFailWithError: URLError(.cannotDecodeContentData))
            }
            do { _ = try await transport().send(endpoint: endpoint, requestBody: requestBody()); XCTFail("Unreadable refusal accepted") }
            catch {
                if let failure = error as? EluV1FlagTransportError {
                    XCTAssertEqual(failure, .httpStatus(status))
                } else {
                    XCTAssertEqual((error as? URLError)?.code, .cannotDecodeContentData)
                }
            }
        }
    }

    func testAnnouncedAndStreamingResponseLimitsAndExactCeiling() async throws {
        for announce in [true, false] {
            FlagURLProtocol.handler.set { request, client, instance in
                let headers = announce ? ["Content-Length": "1048577"] : [:]
                client.urlProtocol(instance, didReceive: Self.response(request, status: 200, headers: headers), cacheStoragePolicy: .notAllowed)
                client.urlProtocol(instance, didLoad: Data(repeating: 32, count: 524_288))
                client.urlProtocol(instance, didLoad: Data(repeating: 32, count: 524_289))
                client.urlProtocolDidFinishLoading(instance)
            }
            do { _ = try await transport().send(endpoint: endpoint, requestBody: requestBody()); XCTFail("Oversized response accepted") }
            catch { XCTAssertEqual(error as? EluV1FlagContractError, .responseTooLarge) }
        }
        FlagURLProtocol.handler.set { request, client, instance in
            client.urlProtocol(instance, didReceive: Self.response(request, status: 200), cacheStoragePolicy: .notAllowed)
            client.urlProtocol(instance, didLoad: Data(repeating: 32, count: 1_048_576))
            client.urlProtocolDidFinishLoading(instance)
        }
        let exact = try await transport().send(endpoint: endpoint, requestBody: requestBody())
        XCTAssertEqual(exact.count, 1_048_576)
    }

    func testRedirectAndForeignFinalURLAreRejected() async throws {
        FlagURLProtocol.handler.set { request, client, instance in
            XCTAssertEqual(request.url?.host, "ingest.elu.dev")
            client.urlProtocol(instance, wasRedirectedTo: URLRequest(url: URL(string: "https://evil.test/v1/flags")!), redirectResponse: Self.response(request, status: 302))
        }
        do { _ = try await transport().send(endpoint: endpoint, requestBody: requestBody()); XCTFail("Redirect accepted") }
        catch { XCTAssertEqual(error as? EluV1FlagTransportError, .invalidResponse) }
        FlagURLProtocol.handler.set { _, client, instance in
            let response = HTTPURLResponse(url: URL(string: "https://evil.test/v1/flags")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(instance)
        }
        do { _ = try await transport().send(endpoint: endpoint, requestBody: requestBody()); XCTFail("Foreign response accepted") }
        catch { XCTAssertEqual(error as? EluV1FlagTransportError, .invalidResponse) }
    }

    func testCancellationAndNetworkFailureThrowWithoutFabricatedFlagValues() async throws {
        FlagURLProtocol.handler.set { _, client, instance in
            client.urlProtocol(instance, didFailWithError: URLError(.notConnectedToInternet))
        }
        do { _ = try await transport().send(endpoint: endpoint, requestBody: requestBody()); XCTFail("Network failure accepted") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        let started = expectation(description: "flag request started")
        FlagURLProtocol.handler.set { _, _, _ in started.fulfill() }
        let transport = try transport()
        let body = try requestBody()
        let endpoint = endpoint
        let task = Task { try await transport.send(endpoint: endpoint, requestBody: body) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled flag request succeeded") } catch {}
    }

    func testBoundAuthorityChecksOwnerThenFinalStartWithoutNetwork() async throws {
        FlagURLProtocol.handler.set { _, _, _ in XCTFail("Withdrawn request reached URLSession") }
        for ownerAllows in [false, true] {
            let authority = EluV1TransportAuthority(revalidate: { ownerAllows }, isCurrent: { false })
            do {
                _ = try await transport().send(endpoint: endpoint, requestBody: requestBody(), authority: authority)
                XCTFail("Missing authority accepted")
            } catch { XCTAssertEqual(error as? EluV1BoundTransportError, .staleAuthority) }
        }
    }

    func testOnePhysicalSlotAndCancellationCleanupBeforeReuse() async throws {
        let started = expectation(description: "request started")
        let transport = try EluV1URLSessionFlagTransport(siteKey: key, protocolClasses: [FlagCleanupURLProtocol.self])
        let body = try requestBody()
        let endpoint = URL(string: "https://ingest.elu.dev/v1/flags?cleanup=\(UUID().uuidString)")!
        FlagCleanupURLProtocol.handler.set { _, _, _ in started.fulfill() }
        let task = Task { try await transport.send(endpoint: endpoint, requestBody: body) }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await transport.send(endpoint: endpoint, requestBody: body); XCTFail("Two requests occupied one transport") }
        catch { XCTAssertEqual(error as? EluV1BoundTransportError, .occupied) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled operation succeeded") } catch {}
        FlagCleanupURLProtocol.handler.set { request, client, instance in
            client.urlProtocol(instance, didReceive: Self.response(request, status: 200), cacheStoragePolicy: .notAllowed)
            client.urlProtocol(instance, didLoad: Data("ok".utf8))
            client.urlProtocolDidFinishLoading(instance)
        }
        let next = try await transport.send(endpoint: endpoint, requestBody: body)
        XCTAssertEqual(next, Data("ok".utf8))
    }

    private func transport() throws -> EluV1URLSessionFlagTransport {
        try EluV1URLSessionFlagTransport(siteKey: key, protocolClasses: [FlagURLProtocol.self])
    }
    private func requestBody() throws -> Data {
        try EluV1FlagJSON.canonicalData(for: EluV1FlagJSON.parse(fixture("flags-request.json")))
    }
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("Conformance/V1/Fixtures/\(name)"))
    }
    private static func response(_ request: URLRequest, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

private final class FlagURLProtocol: URLProtocol, @unchecked Sendable {
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

/// A separate protocol class isolates this test's pending request callbacks.
private final class FlagCleanupURLProtocol: URLProtocol, @unchecked Sendable {
    static let handler = FlagURLProtocol.Handler()
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { if let client { Self.handler.call(request, client, self) } }
    override func stopLoading() {}
}
