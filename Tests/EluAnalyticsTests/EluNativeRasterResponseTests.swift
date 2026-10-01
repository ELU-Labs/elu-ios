#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import UIKit
import XCTest
@testable import EluAnalytics

@MainActor
final class EluNativeRasterResponseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 0)

    func testOnlyOriginalSchemaThreeHTTP200CanAcknowledgeActualSealedRequest() throws {
        let request = try prepared()
        XCTAssertEqual(request.codec, "elu-native-raster-v1")
        XCTAssertEqual(request.captureProtocolGeneration, "native-raster-generation-v1")
        let body = try encoded(ack(request))
        XCTAssertEqual(classify(200, body, request), .accepted)
        let equivalent = String(decoding: body, as: UTF8.self)
            .replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":3.0")
            .replacingOccurrences(of: "\"sequence\":0", with: "\"sequence\":0e0")
        XCTAssertEqual(classify(200, Data(equivalent.utf8), request), .accepted)
        for status in [201, 202, 204, 206, 299, 400, 409, 413, 429, 500] {
            XCTAssertEqual(classify(status, body, request), .protocolBlocked, "HTTP \(status)")
        }
        for schema in [1, 2, 4] {
            var wrong = ack(request); wrong["schemaVersion"] = schema
            XCTAssertEqual(classify(200, try encoded(wrong), request), .protocolBlocked)
        }
    }

    func testEveryAckIdentityMustMatchOriginalAndCannotDischargeAnotherEpoch() throws {
        let request = try prepared(), other = try prepared(replayId: "other-epoch")
        let original = request.body
        for key in ["requestId", "replayId", "chunkId", "sequence", "result"] {
            var wrong = ack(request); wrong[key] = "wrong"
            if key == "sequence" { wrong[key] = 1 }
            XCTAssertEqual(classify(200, try encoded(wrong), request), .protocolBlocked, key)
        }
        XCTAssertEqual(classify(200, try encoded(ack(other)), request), .protocolBlocked)
        XCTAssertEqual(classify(200, try encoded(ack(request)), other), .protocolBlocked)
        for _ in 0..<3 { XCTAssertEqual(classify(200, try encoded(ack(request)), request), .accepted) }
        XCTAssertEqual(request.body, original)
    }

    func testUTF16IdentityAcceptsEscapesButNeverNormalizesDistinctOriginalBytes() throws {
        let request = try prepared(replayId: "r\u{e9}play-\u{1f600}")
        let original = String(decoding: try encoded(ack(request)), as: UTF8.self)
        let escaped = original.replacingOccurrences(of: "\u{e9}", with: "\\u00e9")
            .replacingOccurrences(of: "\u{1f600}", with: "\\ud83d\\ude00")
        XCTAssertEqual(classify(200, Data(escaped.utf8), request), .accepted)
        var decomposed = ack(request); decomposed["replayId"] = "re\u{301}play-\u{1f600}"
        XCTAssertEqual(classify(200, try encoded(decomposed), request), .protocolBlocked)
    }

    func testAckClosedShapeAndStrictJSONRejectAmbiguousOrUnsupportedValues() throws {
        let request = try prepared(), body = try encoded(ack(request))
        for key in ack(request).keys {
            var missing = ack(request); missing.removeValue(forKey: key)
            XCTAssertEqual(classify(200, try encoded(missing), request), .protocolBlocked, key)
        }
        for value in [true, NSNull(), "0", -1, 0.5, 9_007_199_254_740_992 as Int64] as [Any] {
            var wrong = ack(request); wrong["sequence"] = value
            XCTAssertEqual(classify(200, try encoded(wrong), request), .protocolBlocked)
        }
        var extra = ack(request); extra["unknown"] = true
        XCTAssertEqual(classify(200, try encoded(extra), request), .protocolBlocked)
        let text = String(decoding: body, as: UTF8.self)
        for invalid in [text.dropLast() + ",\"schemaVersion\":3}",
                        text.dropLast() + ",\"schema\\u0056ersion\":3}",
                        text + "false", "[]", "null", "{\"bad\":\"\\ud800\"}"] {
            XCTAssertEqual(classify(200, Data(invalid.utf8), request), .protocolBlocked)
        }
        XCTAssertEqual(classify(200, Data([0xC0, 0xAF]), request), .protocolBlocked)
    }

    func testResponseByteLimitIsExactAndDoesNotReclassifyCredentialRefusal() throws {
        let request = try prepared(), body = try encoded(ack(request))
        let exact = body + Data(repeating: 0x20, count: EluNativeRasterResponse.maximumBytes - body.count)
        XCTAssertEqual(classify(200, exact, request), .accepted)
        XCTAssertEqual(classify(200, exact + Data([0x20]), request), .protocolBlocked)
        for status in [401, 403] {
            XCTAssertEqual(classify(status, Data(repeating: 255, count: 65_537), request,
                headers: ["Retry-After": "bad", "retry-after": "1"]), .credentialBlocked(status: status))
        }
    }

    func testOnlyClosedOriginalIdentityConflictsExposeAValidatedScope() throws {
        let request = try prepared()
        for scope in [EluNativeRasterConflictScope.request, .chunk, .sequence] {
            let body = try encoded(conflict(request, scope.rawValue))
            XCTAssertEqual(classify(409, body, request), .identityConflict(scope: scope))
            for status in [200, 201, 400, 413, 429, 500] {
                XCTAssertEqual(classify(status, body, request), .protocolBlocked)
            }
        }
    }

    func testCrossedMissingUnknownAndRetryableConflictsStayProtocolBlocked() throws {
        let request = try prepared()
        let mutations: [(String, Any)] = [
            ("schemaVersion", 2), ("requestId", "other"), ("status", 200),
            ("code", "other-conflict"), ("disposition", "retryable"), ("conflictScope", "session"),
        ]
        for (key, value) in mutations {
            var wrong = conflict(request); wrong[key] = value
            XCTAssertEqual(classify(409, try encoded(wrong), request), .protocolBlocked, key)
        }
        for key in conflict(request).keys {
            var wrong = conflict(request); wrong.removeValue(forKey: key)
            XCTAssertEqual(classify(409, try encoded(wrong), request), .protocolBlocked, key)
        }
        var extra = conflict(request); extra["message"] = "not-in-closed-conflict"
        XCTAssertEqual(classify(409, try encoded(extra), request), .protocolBlocked)
        XCTAssertEqual(classify(409, try encoded(conflict(request)), request, headers: ["Retry-After": "1"]), .protocolBlocked)
        let text = String(decoding: try encoded(conflict(request)), as: UTF8.self)
        XCTAssertEqual(classify(409, Data((text.dropLast() + ",\"requestId\":\"other\"}").utf8), request), .protocolBlocked)
    }

    func testSchemaOneSizeRefusalPreservesOriginalRequestBinding() throws {
        let request = try prepared(), body = try encoded(error(413, request))
        XCTAssertEqual(classify(413, body, request), .rejectedTooLarge)
        XCTAssertEqual(classify(413, body, request, headers: ["Retry-After": "1"]), .protocolBlocked)
        var optional = error(413, request); optional.removeValue(forKey: "requestId")
        XCTAssertEqual(classify(413, try encoded(optional), request), .rejectedTooLarge)
        let mutations: [(String, Any)] = [("schemaVersion", 3), ("status", 429),
            ("requestId", "wrong"), ("disposition", "retryable")]
        for (key, value) in mutations {
            var wrong = error(413, request); wrong[key] = value
            XCTAssertEqual(classify(413, try encoded(wrong), request), .protocolBlocked)
        }
    }

    func testOriginalRetryAfterRulesIncludeDatesClampAndCaseInsensitiveDuplicates() throws {
        let request = try prepared(), limited = try encoded(error(429, request))
        XCTAssertEqual(classify(429, limited, request), .protocolBlocked)
        XCTAssertEqual(classify(429, limited, request, headers: ["rEtRy-AfTeR": "2"]), .endpointCooldown(seconds: 2))
        XCTAssertEqual(classify(429, limited, request, headers: ["Retry-After": "999999"]), .endpointCooldown(seconds: 86_400))
        XCTAssertEqual(classify(429, limited, request, headers: ["Retry-After": "Thu, 01 Jan 1970 00:00:03 GMT"]), .endpointCooldown(seconds: 3))
        for bad in ["invalid", "-1", "1.5"] {
            XCTAssertEqual(classify(429, limited, request, headers: ["Retry-After": bad]), .protocolBlocked)
        }
        for status in [200, 409, 413, 429, 503] {
            let value = status == 200 ? ack(request) : status == 409 ? conflict(request) : error(status, request)
            XCTAssertEqual(classify(status, try encoded(value), request,
                headers: ["Retry-After": "1", "retry-after": "1"]), .protocolBlocked)
        }
        XCTAssertEqual(classify(200, try encoded(ack(request)), request, headers: ["Retry-After": "0"]), .protocolBlocked)
    }

    func testServerFailuresRetainBoundedStructuredTransportSemantics() throws {
        let request = try prepared()
        for status in [500, 503, 599] {
            let body = try encoded(error(status, request))
            XCTAssertEqual(classify(status, body, request), .retry(afterSeconds: 0))
            XCTAssertEqual(classify(status, body, request, headers: ["Retry-After": "3"]), .retry(afterSeconds: 3))
        }
        let mutations: [(String, Any)] = [("message", ""), ("message", String(repeating: "x", count: 257)),
            ("code", "Upper"), ("code", String(repeating: "x", count: 65)), ("requestId", NSNull()),
            ("status", 500), ("schemaVersion", 3), ("disposition", "permanent"), ("extra", true)]
        for (key, value) in mutations {
            var wrong = error(503, request); wrong[key] = value
            XCTAssertEqual(classify(503, try encoded(wrong), request), .protocolBlocked, key)
        }
        XCTAssertEqual(classify(503, Data(), request), .protocolBlocked)
    }

    private func ack(_ request: EluNativeRasterPreparedRequest) -> [String: Any] {
        ["schemaVersion": 3, "requestId": request.requestId, "replayId": request.replayId,
         "chunkId": request.chunkId, "sequence": request.sequence, "result": "accepted"]
    }
    private func conflict(_ request: EluNativeRasterPreparedRequest, _ scope: String = "request") -> [String: Any] {
        ["schemaVersion": 3, "requestId": request.requestId, "status": 409,
         "code": "replay-identity-conflict", "disposition": "permanent", "conflictScope": scope]
    }
    private func error(_ status: Int, _ request: EluNativeRasterPreparedRequest) -> [String: Any] {
        ["schemaVersion": 1, "requestId": request.requestId, "status": status,
         "code": "fixture-error", "disposition": status == 413 ? "retry-after-reduction" : "retryable", "message": "fixture"]
    }
    private func encoded(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func classify(_ status: Int, _ body: Data, _ request: EluNativeRasterPreparedRequest,
                          headers: [String: String] = [:]) -> EluNativeRasterResponseOutcome {
        EluNativeRasterResponse.classify(.init(status: status, headers: headers, body: body), request: request, now: now)
    }

    // All requests come from the real one-shot collector -> sealer path. The
    // controlled draw/clock isolates response grammar; it qualifies no deadline.
    private func prepared(replayId: String = "raster-response-epoch") throws -> EluNativeRasterPreparedRequest {
        let window = try EluUIKitTestHost.window(), previous = window.rootViewController
        defer { window.rootViewController = previous }
        let controller = UIViewController(); window.rootViewController = controller
        controller.loadViewIfNeeded(); controller.view.frame = window.bounds
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 64, height: 64)); controller.view.addSubview(parent)
        let registry = EluSwiftUIReplayRegistry(requiredRegions: ["private"])
        let root = EluSwiftUIReplayMarkerView(region: nil, registry: registry); root.frame = parent.bounds
        let marker = EluSwiftUIReplayMarkerView(region: "private", registry: registry)
        marker.frame = CGRect(x: 10, y: 10, width: 20, height: 20)
        parent.addSubview(root); parent.addSubview(marker)
        window.makeKeyAndVisible(); window.layoutIfNeeded(); parent.layoutIfNeeded(); CATransaction.flush()
        let instant = Date(timeIntervalSince1970: 1_704_067_200)
        let identity = try EluIdentitySnapshot(identity: .init(revision: 3, contextRevision: 7,
            anonymousId: "anon-raster", userId: "user-raster", groups: [:], superProperties: [:],
            session: .init(id: "session-raster", startedAt: instant, lastActivityAt: instant, timeoutSeconds: 1800),
            optedOut: false, updatedAt: instant), streamId: "stream-raster", nextSequence: 0, flagContext: .init())
        var sealer = try EluNativeRasterSealer(replayId: replayId, identity: identity,
            policy: .init(policyRevision: "policy-1", effectivePolicyHash: "sha256:" + String(repeating: "a", count: 64),
                contextRevision: 7, maximumRequestBytes: EluNativeRasterPreparedRequest.maximumBytes),
            versions: .init(runtime: .init(name: "elu-ios", version: "1.0.0"), facade: .init(name: "EluAnalytics", version: "1.0.0")),
            sourceIdentity: registry.sourceIdentity(), sourceIsCurrent: { true })
        let frame = try registry.capture(deadline: 1, clock: { 0 }, draw: { _, _, context in
            context.setFillColor(UIColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64)); return true
        })
        return try sealer.seal(frame, timestamp: 1_704_067_200_000)
    }
}
#endif
