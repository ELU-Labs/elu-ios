import Foundation
import XCTest
@testable import EluAnalytics

final class EluV1URLSessionBatchTransportTests: XCTestCase {
    func testExactRequestBodyHeadersAndFinalResponse() async throws {
        BatchURLProtocol.hooks.set { request, client, instance in
            XCTAssertEqual(request.url?.absoluteString, "https://ingest.elu.dev/v1/events?route=2")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
            XCTAssertFalse(request.httpShouldHandleCookies)
            client.urlProtocol(instance, didReceive: Self.response(request, status: 200), cacheStoragePolicy: .notAllowed)
            client.urlProtocol(instance, didLoad: Data("reply".utf8))
            client.urlProtocolDidFinishLoading(instance)
        }
        let result = try await transport().send(request())
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.body, Data("reply".utf8))
    }

    func testRoleOriginAndDecodedReservedQueryFailBeforeNetwork() async throws {
        BatchURLProtocol.hooks.set { _, _, _ in XCTFail("Foreign endpoint reached network") }
        for url in ["https://evil.test/v1/events", "https://ingest.elu.dev/v1/flags", "https://ingest.elu.dev/v1/events?%73ite_key=foreign", "https://user@ingest.elu.dev/v1/events", "https://ingest.elu.dev:444/v1/events"] {
            do { _ = try await transport().send(request(url: url)); XCTFail("Untrusted request accepted") }
            catch { XCTAssertEqual(error as? EluV1BatchDeliveryError, .invalidRequest) }
        }
    }

    func testOwnerAndFinalStartAuthorityFailuresPreventURLSessionStart() async throws {
        BatchURLProtocol.hooks.set { _, _, _ in XCTFail("Stale request reached network") }
        for ownerAllows in [false, true] {
            let authority = EluV1TransportAuthority(revalidate: { ownerAllows }, isCurrent: { false })
            do { _ = try await transport().send(request(), authority: authority); XCTFail("Stale authority accepted") }
            catch { XCTAssertEqual(error as? EluV1BoundTransportError, .staleAuthority) }
        }
    }

    func testRefusalStatusSurvivesInvalidOrOversizedBody() async throws {
        for status in [401, 403] {
            BatchURLProtocol.hooks.set { request, client, instance in
                client.urlProtocol(instance, didReceive: Self.response(request, status: status, headers: ["Content-Length": "99999999"]), cacheStoragePolicy: .notAllowed)
                client.urlProtocol(instance, didLoad: Data("not JSON".utf8))
                client.urlProtocolDidFinishLoading(instance)
            }
            let result = try await transport().send(request())
            XCTAssertEqual(result.status, status)
            XCTAssertTrue(result.body.isEmpty)
        }
    }

    func testGenerationWrappersShareOnePhysicalSlotAndReuseAfterCancellationCleanup() async throws {
        let started = expectation(description: "request started")
        let concrete = EluV1URLSessionBatchTransport(protocolClasses: [BatchCleanupURLProtocol.self])
        let old = EluV1BoundBatchTransport(transport: concrete,
            authority: EluV1TransportAuthority(revalidate: { true }, isCurrent: { true }))
        let next = EluV1BoundBatchTransport(transport: concrete,
            authority: EluV1TransportAuthority(revalidate: { true }, isCurrent: { true }))
        let request = request()
        BatchCleanupURLProtocol.hooks.set { _, _, _ in started.fulfill() }
        let task = Task { try await old.send(request) }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await next.send(request); XCTFail("New generation reused occupied physical slot") }
        catch { XCTAssertEqual(error as? EluV1BoundTransportError, .occupied) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled send succeeded") } catch {}
        BatchCleanupURLProtocol.hooks.set { request, client, instance in
            client.urlProtocol(instance, didReceive: Self.response(request, status: 200), cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(instance)
        }
        let result = try await next.send(request)
        XCTAssertEqual(result.status, 200)
    }

    private func transport() -> EluV1URLSessionBatchTransport {
        EluV1URLSessionBatchTransport(protocolClasses: [BatchURLProtocol.self])
    }
    private func request(url: String = "https://ingest.elu.dev/v1/events?route=2") -> EluV1BatchHTTPRequest {
        EluV1BatchHTTPRequest(url: URL(string: url)!, headers: ["Authorization": "Bearer synthetic", "Content-Type": "application/json"],
            body: Data("{}".utf8), timeoutSeconds: 10, maximumResponseBytes: 1024)
    }
    private static func response(_ request: URLRequest, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

private final class BatchURLProtocol: URLProtocol, @unchecked Sendable {
    static let hooks = Hooks()
    final class Hooks: @unchecked Sendable {
        private let lock = NSLock()
        private var start: (URLRequest, URLProtocolClient, URLProtocol) -> Void = { _, _, _ in }
        private var stop: () -> Void = {}
        func set(_ callback: @escaping (URLRequest, URLProtocolClient, URLProtocol) -> Void) { lock.lock(); start = callback; lock.unlock() }
        func setStop(_ callback: @escaping () -> Void) { lock.lock(); stop = callback; lock.unlock() }
        func begin(_ request: URLRequest, _ client: URLProtocolClient, _ instance: URLProtocol) {
            lock.lock(); let callback = start; lock.unlock(); callback(request, client, instance)
        }
        func end() { lock.lock(); let callback = stop; lock.unlock(); callback() }
    }
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { if let client { Self.hooks.begin(request, client, self) } }
    override func stopLoading() { Self.hooks.end() }
}

private final class BatchCleanupURLProtocol: URLProtocol, @unchecked Sendable {
    static let hooks = BatchURLProtocol.Hooks()
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { if let client { Self.hooks.begin(request, client, self) } }
    override func stopLoading() { Self.hooks.end() }
}
