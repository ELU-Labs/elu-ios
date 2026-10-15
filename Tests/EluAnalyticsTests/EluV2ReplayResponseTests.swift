import Foundation
import XCTest
@testable import EluAnalytics

final class EluV2ReplayResponseTests: XCTestCase {
    func testExactAcknowledgementAndEquivalentIntegerLexemes() throws {
        let request = try prepared()
        let base = ack(request)
        for text in [base, base.replacingOccurrences(of: "\"schemaVersion\":2", with: "\"schemaVersion\":2.0").replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1e0")] {
            XCTAssertEqual(classify(200, text, request), .accepted)
        }
        for text in [base.replacingOccurrences(of: "accepted", with: "rejected"), base.replacingOccurrences(of: request.chunkId, with: "wrong"), base.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1.5"), base.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":9007199254740992"), base.replacingOccurrences(of: "\"schemaVersion\":2", with: "\"schemaVersion\":2,\"schemaVersion\":2"), base.dropLast() + ",\"unknown\":true}"] {
            XCTAssertEqual(classify(200, text, request), .protocolBlocked)
        }
        XCTAssertEqual(classify(200, base, request, headers: ["Retry-After":"1"]), .protocolBlocked)
    }
    func testRefusalStatusDominatesBodyAndInvalidHeaders() throws {
        let request = try prepared()
        for status in [401,403] {
            XCTAssertEqual(classify(status, "invalid", request, headers: ["Retry-After":"bad","retry-after":"1"]), .credentialBlocked(status: status))
            let response = EluV1BatchHTTPResponse(status: status, headers: [:], body: Data(repeating: 255, count: 65_537))
            XCTAssertEqual(EluV2ReplayResponse.classify(response, request: request, now: Date()), .credentialBlocked(status: status))
        }
    }
    func testStructured413RetryAndCooldownRules() throws {
        let request = try prepared()
        func error(_ status: Int, _ disposition: String) -> String {
            "{\"schemaVersion\":1,\"status\":\(status),\"code\":\"fixture-error\",\"disposition\":\"\(disposition)\",\"message\":\"fixture\",\"requestId\":\"\(request.requestId)\"}"
        }
        XCTAssertEqual(classify(413, error(413,"retry-after-reduction"), request), .rejectedTooLarge)
        XCTAssertEqual(classify(413, error(413,"retry-after-reduction"), request, headers:["Retry-After":"1"]), .protocolBlocked)
        XCTAssertEqual(classify(429, error(429,"retryable"), request), .retry(afterSeconds:0))
        XCTAssertEqual(classify(429, error(429,"retryable"), request, headers:["Retry-After":"2"]), .endpointCooldown(seconds:2))
        XCTAssertEqual(classify(429, error(429,"retryable"), request, headers:["Retry-After":"999999"]), .endpointCooldown(seconds:86_400))
        XCTAssertEqual(classify(503, error(503,"retryable"), request), .retry(afterSeconds:0))
        XCTAssertEqual(classify(503, error(503,"retryable"), request, headers:["Retry-After":"invalid"]), .retry(afterSeconds:0))
        XCTAssertEqual(classify(413, error(413,"retry-after-reduction").replacingOccurrences(of: request.requestId, with:"wrong"), request), .protocolBlocked)
        XCTAssertEqual(classify(400,"{}",request), .protocolBlocked)
    }
    func testForeignRetryableStatusRetriesPerRowWithCappedHint() throws {
        let request = try prepared(), html = "<html>busy</html>"
        XCTAssertEqual(classify(503, "503 Service Unavailable", request, headers:["Retry-After":"5"]), .retry(afterSeconds:5))
        XCTAssertEqual(classify(502, "", request), .retry(afterSeconds:0))
        XCTAssertEqual(classify(504, html, request, headers:["retry-after":"120"]), .retry(afterSeconds:120))
        XCTAssertEqual(classify(503, html, request, headers:["Retry-After":"86400"]), .retry(afterSeconds:300))
        XCTAssertEqual(classify(503, html, request, headers:["Retry-After":"Sat, 01 Jan 2050 00:00:00 GMT"]), .retry(afterSeconds:300))
        for headers in [["Retry-After":"5, 5"], ["Retry-After":"5","retry-after":"9"], ["Retry-After":"-1"], ["Retry-After":"99999999999999999999999"]] {
            XCTAssertEqual(classify(503, html, request, headers:headers), .retry(afterSeconds:0), "\(headers)")
        }
        XCTAssertEqual(classify(500, ack(request), request), .retry(afterSeconds:0))
        let oversized = EluV1BatchHTTPResponse(status:503, headers:["Retry-After":"7"], body:Data(repeating:0x20, count:65_537))
        XCTAssertEqual(EluV2ReplayResponse.classify(oversized, request:request, now:Date(timeIntervalSince1970:1_785_888_090)), .retry(afterSeconds:7))
        XCTAssertEqual(classify(501, "", request), .retry(afterSeconds:0))
        // A foreign 429 never becomes an endpoint-wide pause.
        XCTAssertEqual(classify(429, html, request, headers:["Retry-After":"86400"]), .retry(afterSeconds:300))
        XCTAssertEqual(classify(429, "", request), .retry(afterSeconds:0))
    }
    func testValidatedErrorObjectKeepsExactSemantics() throws {
        let request = try prepared()
        let limited = "{\"schemaVersion\":1,\"status\":429,\"code\":\"rate-limited\",\"disposition\":\"retryable\",\"message\":\"fixture\"}"
        let unavailable = "{\"schemaVersion\":1,\"status\":503,\"code\":\"service-unavailable\",\"disposition\":\"retryable\",\"message\":\"fixture\"}"
        XCTAssertEqual(classify(429, limited, request, headers:["Retry-After":"30"]), .endpointCooldown(seconds:30))
        XCTAssertEqual(classify(429, limited, request, headers:["Retry-After":"999999"]), .endpointCooldown(seconds:86_400))
        XCTAssertEqual(classify(503, unavailable, request, headers:["Retry-After":"5"]), .retry(afterSeconds:5))
        XCTAssertEqual(classify(503, unavailable, request, headers:["Retry-After":"999999"]), .retry(afterSeconds:86_400))
        for status in [401,403] {
            XCTAssertEqual(classify(status, "<html>denied</html>", request), .credentialBlocked(status:status))
            XCTAssertEqual(classify(status, "", request, headers:["Retry-After":"bad"]), .credentialBlocked(status:status))
            let oversized = EluV1BatchHTTPResponse(status:status, headers:[:], body:Data(repeating:0x20, count:65_537))
            XCTAssertEqual(EluV2ReplayResponse.classify(oversized, request:request, now:Date()), .credentialBlocked(status:status))
        }
    }
    func testAcknowledgementsAnd4xxStayStrict() throws {
        let request = try prepared()
        let tooLarge = "{\"schemaVersion\":1,\"status\":413,\"code\":\"replay-chunk-too-large\",\"disposition\":\"retry-after-reduction\",\"message\":\"fixture\"}"
        let cases: [(Int, String, [String:String])] = [
            (200, "<html>portal</html>", [:]), (200, ack(request), ["Retry-After":"1"]), (302, "", [:]),
            (400, "{\"schemaVersion\":2,\"error\":\"replay-request-invalid\"}", [:]), (404, "<html>missing</html>", [:]),
            (418, "", [:]), (413, "", [:]), (413, tooLarge, ["Retry-After":"1"]),
        ]
        for (status, body, headers) in cases {
            XCTAssertEqual(classify(status, body, request, headers:headers), .protocolBlocked, "HTTP \(status)")
        }
        XCTAssertEqual(classify(413, tooLarge, request), .rejectedTooLarge)
    }
    func testUnknownAndPartialDurableMetadataCannotBecomePending() throws {
        XCTAssertEqual(try EluV2ReplayDeliveryState.decode(EluV2ReplayDeliveryState.pending.encoded()), .pending)
        for body in ["{\"schemaVersion\":2,\"attemptCount\":0}","{\"schemaVersion\":1,\"attemptCount\":0,\"unknown\":1}","{\"schemaVersion\":1,\"attemptCount\":0,\"retry\":{}}","{\"schemaVersion\":1,\"attemptCount\":9007199254740992}"] {
            XCTAssertThrowsError(try EluV2ReplayDeliveryState.decode(Data(body.utf8)))
        }
    }
    func testCredentialFactOverridesEarlierCancellationOrSizeFailureOnly() throws {
        for error in [CancellationError() as Error, EluV1BatchDeliveryError.responseTooLarge as Error] {
            for status in [401,403] {
                let refusal = EluV1BatchHTTPResponse(status:status,headers:[:],body:Data())
                let value = EluV2ReplayResponse.preservingRefusal(.success(refusal),over:.failure(error))
                XCTAssertEqual(try value.get().status,status)
                let later = EluV2ReplayResponse.preservingRefusal(.failure(CancellationError()),over:value)
                XCTAssertEqual(try later.get().status,status)
            }
            XCTAssertThrowsError(try EluV2ReplayResponse.preservingRefusal(.success(EluV1BatchHTTPResponse(status:200,headers:[:],body:Data())),over:.failure(error)).get())
        }
    }
    private func prepared() throws -> EluV2ReplayPreparedRequest {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try EluV2ReplayPreparedRequest(Data(contentsOf:root.appendingPathComponent("Conformance/V2/fixtures/replay-request.json")), captureProtocolGeneration:"fixture")
    }
    private func ack(_ value: EluV2ReplayPreparedRequest) -> String {
        "{\"schemaVersion\":2,\"requestId\":\"\(value.requestId)\",\"replayId\":\"\(value.replayId)\",\"chunkId\":\"\(value.chunkId)\",\"sequence\":\(value.sequence),\"result\":\"accepted\"}"
    }
    private func classify(_ status:Int,_ text:String,_ request:EluV2ReplayPreparedRequest,headers:[String:String]=[:]) -> EluV2ReplayResponseOutcome {
        EluV2ReplayResponse.classify(EluV1BatchHTTPResponse(status:status,headers:headers,body:Data(text.utf8)),request:request,now:Date(timeIntervalSince1970:1_785_888_090))
    }
}
