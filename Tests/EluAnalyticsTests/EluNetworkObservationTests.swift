import Foundation
import XCTest
@testable import EluAnalytics

final class EluNetworkObservationTests: XCTestCase {
    private let context = EluNetworkObservationContext(identityRevision: 1, contextRevision: 2, sessionID: "session-a")
    private let request = URLRequest(url: URL(string: "https://example.test/private/123?secret=hidden#private")!)

    func testPublicationMutationAndWithdrawalCannotReviveOldObservation() throws {
        let output = NetworkTestState(), gate = EluNetworkObservationGate(budget: .init(), now: { 42 })
        XCTAssertNil(gate.begin(request))
        gate.setForeground(true)
        func publish() { gate.publish(context: context, current: { true }) { _, fields, current in
            if current() { output.append(fields) }
        } }
        publish()
        let before = try XCTUnwrap(gate.begin(request)); before.start()
        let mutation = gate.beginMutation()
        publish(); XCTAssertNil(gate.begin(request))
        gate.finishMutation(mutation); publish()
        before.finish(response: nil, failed: false)
        XCTAssertTrue(output.values.isEmpty)
        let after = try XCTUnwrap(gate.begin(request)); after.start()
        gate.invalidate(); publish(); after.finish(response: nil, failed: false)
        XCTAssertTrue(output.values.isEmpty)
    }

    func testBackgroundCannotBeOverriddenByLaterConfigurationPublication() throws {
        let output = NetworkTestState(), gate = EluNetworkObservationGate(budget: .init())
        func publish() { gate.publish(context: context, current: { true }) { _, fields, current in if current() { output.append(fields) } } }
        publish(); XCTAssertNil(gate.begin(request))
        gate.setForeground(true); publish()
        let observation = try XCTUnwrap(gate.begin(request)); observation.start()
        gate.setForeground(false); publish(); XCTAssertNil(gate.begin(request))
        gate.setForeground(true); publish()
        observation.finish(response: nil, failed: false)
        XCTAssertTrue(output.values.isEmpty)
        XCTAssertNotNil(gate.begin(request))
    }

    func testBudgetSharedAcrossWrappersAndRepublishingCannotReplenishIt() throws {
        let budget = EluNetworkObservationBudget()
        let first = EluNetworkObservationGate(budget: budget), second = EluNetworkObservationGate(budget: budget)
        for gate in [first, second] { gate.setForeground(true); gate.publish(context: context, current: { true }) { _, _, _ in } }
        for index in 0 ..< 200 { XCTAssertNotNil((index % 2 == 0 ? first : second).begin(request)) }
        XCTAssertNil(first.begin(request)); XCTAssertNil(second.begin(request))
        first.invalidate(); first.publish(context: context, current: { true }) { _, _, _ in }
        XCTAssertNil(first.begin(request))
    }

    func testDeniedAndSDKRequestsDoNotSpendEligibleBudget() {
        let gate = EluNetworkObservationGate(budget: .init())
        gate.setForeground(true)
        for _ in 0 ..< 300 { XCTAssertNil(gate.begin(request)) }
        gate.publish(context: context, current: { false }) { _, _, _ in XCTFail("Denied") }
        for _ in 0 ..< 300 { XCTAssertNil(gate.begin(request)) }
        gate.publish(context: context, current: { true }) { _, _, _ in }
        for raw in ["file:///secret", "https://elu.dev/v1/key/config", "https://ingest.elu.dev/v2/events", "https://lab.elu.dev/sdk/config"] {
            XCTAssertNil(gate.begin(URLRequest(url: URL(string: raw)!)))
        }
        for _ in 0 ..< 200 { XCTAssertNotNil(gate.begin(request)) }
        XCTAssertNil(gate.begin(request))
    }

    func testOnlyFiveFieldsAndOneCompletionWithMonotonicElapsedTime() throws {
        let state = NetworkTestState()
        let gate = EluNetworkObservationGate(budget: .init(), now: { state.now })
        gate.setForeground(true)
        gate.publish(context: context, current: { true }) { _, fields, current in if current() { state.append(fields) } }
        var request = self.request; request.httpMethod = "post"; request.httpBody = Data("secret-body".utf8)
        request.setValue("secret-token", forHTTPHeaderField: "Authorization")
        let observation = try XCTUnwrap(gate.begin(request)); observation.start()
        state.now = 123_456_789
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: ["secret": "private"])
        observation.finish(response: response, failed: false); observation.finish(response: response, failed: true)
        XCTAssertEqual(state.values, [["$network_method": .string("POST"), "$network_status_code": .integer(503),
            "$network_response_time_ms": .number(123.5), "$network_initiator": .string("urlsession"), "$network_failed": .bool(false)]])
    }

    func testUnknownMethodFailureMissingResponseAndRegressingClock() {
        let output = NetworkTestState()
        let observation = EluNetworkObservation(method: "private@example.test", now: { output.now }, current: { true }, emit: { output.append($0) })
        observation.start(); observation.finish(response: nil, failed: true)
        XCTAssertEqual(output.values.first?["$network_method"], .string("UNKNOWN"))
        XCTAssertEqual(output.values.first?["$network_status_code"], .integer(0))
        XCTAssertEqual(output.values.first?["$network_failed"], .bool(true))
        output.now = 2
        let backwards = EluNetworkObservation(method: "GET", now: { output.now }, current: { true }, emit: { output.append($0) })
        backwards.start(); output.now = 1; backwards.finish(response: nil, failed: false)
        XCTAssertEqual(output.values.count, 1)
    }

    func testRedirectToSDKOrConfiguredDevelopmentOriginIsExcluded() throws {
        let output = NetworkTestState(), gate = EluNetworkObservationGate(budget: .init())
        gate.setForeground(true)
        gate.publish(context: context, current: { true }) { _, fields, _ in output.append(fields) }
        XCTAssertNil(gate.begin(URLRequest(url: URL(string: "http://localhost:8787/config")!), excludedHost: "localhost"))
        for host in ["ingest.elu.dev", "localhost"] {
            let observation = try XCTUnwrap(gate.begin(request, excludedHost: "localhost")); observation.start()
            observation.finish(response: HTTPURLResponse(url: URL(string: "https://\(host)/private")!, statusCode: 200, httpVersion: nil, headerFields: nil), failed: false)
        }
        XCTAssertTrue(output.values.isEmpty)
    }

    func testSuppliedSessionRequestResponseAndCompletionSurviveDeniedTelemetry() async throws {
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let wrapper = EluURLSession(session: session, observe: { _ in nil })
        var request = self.request; request.httpBody = Data("customer-body".utf8); request.httpMethod = "POST"
        request.setValue("customer-value", forHTTPHeaderField: "X-Customer")
        let result = await withCheckedContinuation { continuation in
            let task = wrapper.perform(request) { data, response, error in continuation.resume(returning: (data, response, error)) }
            XCTAssertEqual(task.originalRequest, request)
        }
        XCTAssertNil(result.2); XCTAssertEqual(result.0, Data("customer-response".utf8))
        XCTAssertEqual((result.1 as? HTTPURLResponse)?.statusCode, 207)
    }

    func testCancellationUsesActualTaskAndPreservesFoundationError() async throws {
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let output = NetworkTestState()
        let wrapper = EluURLSession(session: session, observe: { _ in
            EluNetworkObservation(method: "GET", now: { 42 }, current: { true }, emit: { output.append($0) })
        })
        let cancelled = URLRequest(url: URL(string: "https://example.test/hold")!)
        let error = await withCheckedContinuation { continuation in
            wrapper.perform(cancelled) { _, _, error in continuation.resume(returning: error as NSError?) }.cancel()
        }
        XCTAssertEqual(error?.domain, NSURLErrorDomain); XCTAssertEqual(error?.code, NSURLErrorCancelled)
        XCTAssertEqual(output.values.first?["$network_failed"], .bool(true))
    }

    @available(iOS 15.0, macOS 12.0, *)
    func testAsyncUsesSuppliedSessionAndPropagatesOriginalFailure() async throws {
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let wrapper = EluURLSession(session: session, observe: { _ in nil })
        let (data, response) = try await wrapper.data(for: request)
        XCTAssertEqual(data, Data("customer-response".utf8)); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 207)
        do {
            _ = try await wrapper.data(for: URLRequest(url: URL(string: "https://example.test/fail")!))
            XCTFail("Expected unchanged Foundation failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, "CustomerTestError")
            XCTAssertEqual((error as NSError).code, 17)
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkTestProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class NetworkTestState: @unchecked Sendable {
    private let lock = NSLock(); private var clock: UInt64 = 0; private var fields: [[String: EluJSONValue]] = []
    var now: UInt64 { get { lock.lock(); defer { lock.unlock() }; return clock } set { lock.lock(); clock = newValue; lock.unlock() } }
    var values: [[String: EluJSONValue]] { lock.lock(); defer { lock.unlock() }; return fields }
    func append(_ value: [String: EluJSONValue]) { lock.lock(); fields.append(value); lock.unlock() }
}
private final class NetworkTestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/hold" { return }
        if request.url?.path == "/fail" {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "CustomerTestError", code: 17)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 207, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("customer-response".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
