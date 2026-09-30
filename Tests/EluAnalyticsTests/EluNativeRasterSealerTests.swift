#if canImport(SwiftUI) && canImport(UIKit)
import CryptoKit
import Foundation
import UIKit
import XCTest
import zlib
@testable import EluAnalytics

@MainActor
final class EluNativeRasterSealerTests: XCTestCase {
    private let instant: Int64 = 1_704_067_200_123
    private let policyHash = "sha256:" + String(repeating: "a", count: 64)

    func testOneFrameEnvelopeRetainsIdentityAndDistinctDeclaredWitness() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var sealer = try makeSealer(fixture)
        let request = try sealer.seal(fixture.capture(), timestamp: instant)
        let decoded = try decode(request)
        XCTAssertEqual(request.sequence, 0); XCTAssertEqual(request.timestamp, instant)
        XCTAssertEqual(request.codec, "elu-native-raster-v1")
        XCTAssertEqual(request.captureProtocolGeneration, "native-raster-generation-v1")
        XCTAssertEqual(request.sessionId, "session-raster"); XCTAssertEqual(request.contextRevision, 7)
        XCTAssertEqual(request.effectivePolicyHash, policyHash)
        XCTAssertEqual(decoded.root["schemaVersion"] as? Int, 3)
        XCTAssertEqual(decoded.chunk["schemaVersion"] as? Int, 3)
        XCTAssertEqual(decoded.chunk["startedAt"] as? String, "2024-01-01T00:00:00.123Z")
        XCTAssertEqual(decoded.chunk["endedAt"] as? String, decoded.chunk["startedAt"] as? String)
        let identity = try XCTUnwrap(decoded.chunk["identity"] as? [String: Any])
        XCTAssertEqual(identity["anonymousId"] as? String, "anon-raster")
        XCTAssertEqual(identity["userId"] as? String, "user-raster"); XCTAssertEqual(identity["revision"] as? Int, 3)
        let privacy = try XCTUnwrap(decoded.chunk["privacy"] as? [String: Any])
        XCTAssertEqual(Set(privacy.keys), ["schemaVersion", "policyRevision", "effectivePolicyHash", "maskingProfileHash",
            "inputCoverage", "automaticInputDiscovery", "unknownContentClassification", "appliedBeforeSerialization",
            "requiredRegionsRedacted", "platformFallbackApplied"])
        XCTAssertEqual(privacy["inputCoverage"] as? String, "declared-regions")
        XCTAssertEqual(privacy["schemaVersion"] as? Int, 1)
        XCTAssertEqual(privacy["policyRevision"] as? String, "policy-1")
        XCTAssertEqual(privacy["effectivePolicyHash"] as? String, policyHash)
        XCTAssertEqual(privacy["automaticInputDiscovery"] as? Bool, false)
        XCTAssertEqual(privacy["unknownContentClassification"] as? Bool, false)
        XCTAssertEqual(privacy["requiredRegionsRedacted"] as? Bool, true)
        XCTAssertEqual(privacy["appliedBeforeSerialization"] as? Bool, true)
        XCTAssertEqual(privacy["platformFallbackApplied"] as? Bool, false)
        XCTAssertNil(privacy["secureInputsMasked"])
        XCTAssertEqual(privacy["maskingProfileHash"] as? String, EluNativeRasterSealer.profileHash)
        let versions = try XCTUnwrap(decoded.chunk["versions"] as? [String: Any])
        XCTAssertEqual(versions["schemaVersion"] as? Int, 2)
        XCTAssertEqual(versions["contractVersion"] as? String, "2.0.0")
        XCTAssertEqual(versions["build"] as? String, "raster-test")
        XCTAssertEqual(decoded.frame["timestamp"] as? Int64, instant)
        XCTAssertEqual(decoded.frame["type"] as? String, "frame")
        XCTAssertEqual(decoded.frame["schemaVersion"] as? Int, 1)
        XCTAssertEqual(decoded.png.prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
    }

    func testActualInwardCropIsTheLogicalViewportAndNullableIdentityStaysExplicit() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.root.frame.size = CGSize(width: 63.75, height: 62.5)
        var identity = try identity(); identity.identity.userId = nil
        var sealer = try makeSealer(fixture, identity: identity)
        let request = try sealer.seal(fixture.capture(), timestamp: instant)
        let decoded = try decode(request)
        let viewport = try XCTUnwrap(decoded.frame["viewport"] as? [String: Int])
        let image = try XCTUnwrap(decoded.frame["image"] as? [String: Any])
        XCTAssertEqual(viewport, ["width": 63, "height": 62])
        XCTAssertEqual(image["width"] as? Int, 63); XCTAssertEqual(image["height"] as? Int, 62)
        XCTAssertEqual(request.width, 63); XCTAssertEqual(request.height, 62)
        XCTAssertTrue((decoded.chunk["identity"] as? [String: Any])?["userId"] is NSNull)
    }

    func testCanonicalBytesAndRequestHashUseV3DomainAndExactRetryBytes() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var first = try makeSealer(fixture), same = try makeSealer(fixture)
        let request = try first.seal(fixture.capture(), timestamp: instant)
        let again = try same.seal(fixture.capture(at: 1), timestamp: instant)
        XCTAssertEqual(request, again)
        XCTAssertEqual(request.body, try EluV1StrictCanonicalJSON.parse(request.body).canonicalData)
        let decoded = try decode(request)
        XCTAssertEqual(request.requestId, try requestHash(decoded.chunk, domain: "elu-sdk-replay-request-v3"))
        XCTAssertNotEqual(request.requestId, try requestHash(decoded.chunk, domain: "elu-sdk-replay-request-v2"))
        XCTAssertEqual(request.digest, "sha256:" + digest(request.body))
        let retainedRetry = request
        _ = try first.seal(fixture.capture(at: 2), timestamp: instant + 1_000)
        XCTAssertEqual(retainedRetry, again)
    }

    func testCompletePrefixRequiresActualOneSecondWallPacingWithoutAdjustingTime() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var sealer = try makeSealer(fixture)
        let first = try sealer.seal(fixture.capture(), timestamp: instant)
        for (index, time) in [instant - 1, instant, instant + 999].enumerated() {
            assertFailure(.invalidTimestamp) {
                _ = try sealer.seal(fixture.capture(at: Double(index + 1)), timestamp: time)
            }
        }
        let second = try sealer.seal(fixture.capture(at: 4), timestamp: instant + 1_000)
        XCTAssertEqual(second.sequence, 1); XCTAssertEqual(second.timestamp, instant + 1_000)
        XCTAssertEqual(first.replayId, second.replayId); XCTAssertNotEqual(first.chunkId, second.chunkId)
    }

    func testTimestampBoundsConsumeCandidateButDoNotAdvancePrefix() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var sealer = try makeSealer(fixture)
        for (index, time) in [Int64.min, 0, 253_402_300_800_000, Int64.max].enumerated() {
            let frame = try fixture.capture(at: Double(index))
            assertFailure(.invalidTimestamp) { _ = try sealer.seal(frame, timestamp: time) }
            XCTAssertThrowsError(try frame.encodePNG())
        }
        let first = try sealer.seal(fixture.capture(at: 4), timestamp: 1)
        XCTAssertEqual(first.sequence, 0)
        XCTAssertEqual(try decode(first).chunk["startedAt"] as? String, "1970-01-01T00:00:00.001Z")
        var last = try makeSealer(fixture)
        let upper = try last.seal(fixture.capture(at: 5), timestamp: 253_402_300_799_999)
        XCTAssertEqual(try decode(upper).chunk["startedAt"] as? String, "9999-12-31T23:59:59.999Z")
    }

    func testChangedViewportRequiresNewEpochInsteadOfSilentlyStretchingOrResetting() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var sealer = try makeSealer(fixture)
        let originalSource = try fixture.registry.sourceIdentity()
        let first = try sealer.seal(fixture.capture(), timestamp: instant)
        fixture.root.frame.size.width = 63
        let resizedSource = try fixture.registry.sourceIdentity()
        XCTAssertFalse(originalSource.isCurrent()); XCTAssertFalse(originalSource === resizedSource)
        // Root-marker geometry now retires the original source before sealing;
        // that stronger fence precedes the sealer's unchanged viewport guard.
        assertFailure(.sourceMismatch) { _ = try sealer.seal(fixture.capture(at: 1), timestamp: instant + 1_000) }
        fixture.root.frame.size.width = 64
        let restoredSource = try fixture.registry.sourceIdentity()
        XCTAssertFalse(resizedSource.isCurrent()); XCTAssertFalse(originalSource === restoredSource)
        XCTAssertFalse(resizedSource === restoredSource)
        assertFailure(.sourceMismatch) { _ = try sealer.seal(fixture.capture(at: 2), timestamp: instant + 1_000) }
        var replacement = try makeSealer(fixture, replayId: "raster-next-epoch")
        let next = try replacement.seal(fixture.capture(at: 3), timestamp: instant + 1_000)
        XCTAssertEqual(next.sequence, 0); XCTAssertNotEqual(next.replayId, first.replayId)
        XCTAssertEqual(next.width, first.width); XCTAssertEqual(next.height, first.height)
    }

    func testSourceWithdrawalAtEveryHandoffLeavesHistoryAndConsumesFrame() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        // Seal's five checks: before pixels, after PNG, after payload, after
        // envelope and after prepared request digest. The original closure stays.
        for failingCheck in 1...5 {
            let source = Source()
            var sealer = try makeSealer(fixture, source: source)
            source.refuse(on: failingCheck)
            let frame = try fixture.capture(at: Double(failingCheck * 2))
            assertFailure(.withdrawn) { _ = try sealer.seal(frame, timestamp: instant) }
            XCTAssertThrowsError(try frame.encodePNG())
            source.allow()
            let accepted = try sealer.seal(fixture.capture(at: Double(failingCheck * 2 + 1)), timestamp: instant)
            XCTAssertEqual(accepted.sequence, 0)
        }
    }

    func testOriginalGeometryRevocationAndAlreadyConsumedFrameCannotBecomePayload() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var sealer = try makeSealer(fixture)
        let stale = try fixture.capture()
        fixture.privateMarker.frame.origin.x += 1
        XCTAssertThrowsError(try sealer.seal(stale, timestamp: instant)) {
            XCTAssertEqual($0 as? EluSwiftUIReplayFailure, .staleGeometry)
        }
        let consumed = try fixture.capture(at: 1); _ = try consumed.encodePNG()
        XCTAssertThrowsError(try sealer.seal(consumed, timestamp: instant))
        XCTAssertEqual(try sealer.seal(fixture.capture(at: 2), timestamp: instant).sequence, 0)
    }

    func testTwoLiveSourcesCannotCrossEvenWithSameWindowViewportAndCurrentAuthority() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let other = EluSwiftUIReplayRegistry(requiredRegions: ["private"])
        let root = EluSwiftUIReplayMarkerView(region: nil, registry: other)
        root.frame = fixture.root.frame; fixture.parent.addSubview(root)
        let marker = EluSwiftUIReplayMarkerView(region: "private", registry: other)
        marker.frame = fixture.privateMarker.frame; fixture.parent.addSubview(marker)
        defer { root.removeFromSuperview(); marker.removeFromSuperview() }
        let source = Source()
        var sealer = try makeSealer(fixture, source: source)
        XCTAssertFalse(try fixture.registry.sourceIdentity() === other.sourceIdentity())
        // Both original registries are lawful and mounted simultaneously. Equal
        // geometry and a true A permission closure do not authorize B's frame.
        let foreign = try other.capture(deadline: 1, clock: { 0 }, draw: { _, _, _ in true })
        assertFailure(.sourceMismatch) { _ = try sealer.seal(foreign, timestamp: instant) }
        XCTAssertThrowsError(try foreign.encodePNG())
        // A mismatch must not encode before refusing: the foreign candidate's
        // revoked geometry would independently throw staleGeometry if reached.
        let revokedForeign = try other.capture(deadline: 2, clock: { 1 }, draw: { _, _, _ in true })
        marker.frame.origin.x += 1
        assertFailure(.sourceMismatch) { _ = try sealer.seal(revokedForeign, timestamp: instant) }
        XCTAssertEqual(try sealer.seal(fixture.capture(), timestamp: instant).sequence, 0)
    }

    func testRootReplacementAndDetachRebindRequireNewCollectorIdentity() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let original = try fixture.registry.sourceIdentity()
        var old = try makeSealer(fixture)
        fixture.root.removeFromSuperview()
        let replacement = EluSwiftUIReplayMarkerView(region: nil, registry: fixture.registry)
        replacement.frame = fixture.root.frame; fixture.parent.addSubview(replacement)
        let replaced = try fixture.registry.sourceIdentity()
        XCTAssertFalse(original === replaced)
        assertFailure(.sourceMismatch) { _ = try old.seal(fixture.capture(), timestamp: instant) }
        replacement.removeFromSuperview(); fixture.parent.addSubview(fixture.root)
        let rebound = try fixture.registry.sourceIdentity()
        XCTAssertFalse(original === rebound); XCTAssertFalse(replaced === rebound)
        assertFailure(.sourceMismatch) { _ = try old.seal(fixture.capture(at: 1), timestamp: instant) }
        var fresh = try makeSealer(fixture)
        XCTAssertEqual(try fresh.seal(fixture.capture(at: 2), timestamp: instant).sequence, 0)
        let container = UIView(frame: fixture.parent.bounds); fixture.parent.addSubview(container)
        container.addSubview(fixture.root); fixture.parent.addSubview(fixture.root)
        XCTAssertFalse(rebound === (try fixture.registry.sourceIdentity()))
        assertFailure(.sourceMismatch) { _ = try fresh.seal(fixture.capture(at: 3), timestamp: instant + 1_000) }
    }

    func testExactRequestByteLimitAndCompressionFailureDoNotAdvanceState() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var reference = try makeSealer(fixture)
        let expected = try reference.seal(fixture.capture(), timestamp: instant)
        var exact = try makeSealer(fixture, maximumBytes: expected.body.count)
        assertFailure(.requestLimit) { _ = try exact.seal(fixture.capture(at: 1, noise: true), timestamp: instant) }
        XCTAssertEqual(try exact.seal(fixture.capture(at: 2), timestamp: instant), expected)
        var short = try makeSealer(fixture, maximumBytes: expected.body.count - 1)
        assertFailure(.requestLimit) { _ = try short.seal(fixture.capture(at: 3), timestamp: instant) }
        var small = try makeSealer(fixture, maximumBytes: 128)
        let frame = try fixture.capture(at: 4)
        assertFailure(.requestLimit) { _ = try small.seal(frame, timestamp: instant) }
        XCTAssertThrowsError(try frame.encodePNG())
    }

    func testSpeculativeCopyDoesNotCommitOriginalQueueHistory() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var original = try makeSealer(fixture), candidate = original
        let request = try candidate.seal(fixture.capture(), timestamp: instant)
        XCTAssertEqual(try original.seal(fixture.capture(at: 1), timestamp: instant), request)
        XCTAssertEqual(try candidate.seal(fixture.capture(at: 2), timestamp: instant + 1_000).sequence, 1)
    }

    func testClosedBindingRejectsMissingSessionOptOutContextAndMalformedPolicy() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var missing = try identity(); missing.identity.session = nil
        XCTAssertThrowsError(try makeSealer(fixture, identity: missing))
        var optedOut = try identity(); optedOut.identity.optedOut = true
        XCTAssertThrowsError(try makeSealer(fixture, identity: optedOut))
        var changed = try identity(); changed.identity.contextRevision += 1
        XCTAssertThrowsError(try makeSealer(fixture, identity: changed))
        var unsafe = try identity(); unsafe.identity.revision = 9_007_199_254_740_992
        XCTAssertThrowsError(try makeSealer(fixture, identity: unsafe))
        for bad in ["", "sha256:" + String(repeating: "A", count: 64), policyHash + "0", "sha256:" + String(repeating: "g", count: 64)] {
            XCTAssertThrowsError(try EluNativeRasterPolicyBinding(policyRevision: "policy-1", effectivePolicyHash: bad,
                contextRevision: 7, maximumRequestBytes: 1024))
        }
        for limit in [0, EluNativeRasterPreparedRequest.maximumBytes + 1] {
            XCTAssertThrowsError(try makeSealer(fixture, maximumBytes: limit))
        }
        let withdrawn = Source(); withdrawn.refuse(on: 1)
        assertFailure(.withdrawn) { _ = try makeSealer(fixture, source: withdrawn) }
    }

    func testFrozenEngineProfileAndRequestVectorMatchIndependentHashOracle() throws {
        // Exact immutable engine profile.json and request.json fields. This is a
        // cross-language hash vector, not an engine admission/runtime test.
        let profile = #"{"automaticInputDiscovery":false,"contentAccess":"declared-root-raster","imageFormat":"opaque-png","inputCoverage":"declared-regions","privatePaint":"erase","profileKind":"elu-native-declared-regions-v1","redactionBoundary":"before-encoding","requiredBindingBehavior":"deny-incomplete-or-stale","schemaVersion":1,"unknownContentClassification":false}"#
        XCTAssertEqual("sha256:" + digest(Data(profile.utf8)), EluNativeRasterSealer.profileHash)
        let fixture = #"{"chunkId":"chunk-0","codec":"elu-native-raster-v1","compression":"gzip","contentEncoding":"base64","contextRevision":0,"endedAt":"2024-01-01T00:00:00.000Z","identity":{"anonymousId":"anonymous-1","revision":0,"userId":null},"payload":"H4sIAAAAAAACE01Pyw6CMBD8lz0TUxVf3KAgMSYiIMTEeGikto0WGqgSY/h3Ww/GOex7Z2dPbxCSMAreGzgVjGvwxg6omoEHogySrEfbmDW+wS4veFQwG0bWBNjfGIfTarynthBG9ygtM7eOkxSHdjDu/PzWt0Fx9L9r9/Xhlj9SiTE40ItKc3NucKC7cCpJSdtONPVXgRaSdppIZbIFctF8MUEWpvNSRi5cWyKpYXkK2qum1f8fLF33Rz9dodFsGM4fd/sO2uoAAAA=","privacy":{"appliedBeforeSerialization":true,"automaticInputDiscovery":false,"effectivePolicyHash":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","inputCoverage":"declared-regions","maskingProfileHash":"sha256:e374338e6100edcad1d11de079f6bdfc24df043107628b83a559bb3e87206422","platformFallbackApplied":false,"policyRevision":"policy-1","requiredRegionsRedacted":true,"schemaVersion":1,"unknownContentClassification":false},"replayId":"replay-1","schemaVersion":3,"sequence":0,"sessionId":"session-1","startedAt":"2024-01-01T00:00:00.000Z","versions":{"contractVersion":"2.0.0","facade":{"name":"elu-ios","version":"1.0.0"},"platform":"ios","runtime":{"name":"elu-ios","version":"1.0.0"},"schemaVersion":2}}"#
        let chunk = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        XCTAssertEqual(try requestHash(chunk, domain: "elu-sdk-replay-request-v3"),
            "request_8c99ac217a5e1920d8b96a2bd45aacdf7caeb32c429e87936ce7528fbf036c30")
    }

    private func makeSealer(_ fixture: Fixture, identity original: EluIdentitySnapshot? = nil,
                            maximumBytes: Int = EluNativeRasterPreparedRequest.maximumBytes,
                            replayId: String = "raster-epoch",
                            source: Source = Source()) throws -> EluNativeRasterSealer {
        try EluNativeRasterSealer(replayId: replayId, identity: original ?? identity(),
            policy: .init(policyRevision: "policy-1", effectivePolicyHash: policyHash, contextRevision: 7, maximumRequestBytes: maximumBytes),
            versions: .init(runtime: .init(name: "elu-ios", version: "1.0.0"),
                facade: .init(name: "EluAnalytics", version: "1.0.0"), build: "raster-test"),
            sourceIdentity: fixture.registry.sourceIdentity(), sourceIsCurrent: { source.current() })
    }
    private func identity() throws -> EluIdentitySnapshot {
        let now = Date(timeIntervalSince1970: 1_704_067_200)
        return try .init(identity: .init(revision: 3, contextRevision: 7, anonymousId: "anon-raster", userId: "user-raster",
            groups: [:], superProperties: [:], session: .init(id: "session-raster", startedAt: now, lastActivityAt: now,
                timeoutSeconds: 1800), optedOut: false, updatedAt: now), streamId: "stream-raster", nextSequence: 0, flagContext: .init())
    }
    private func assertFailure(_ expected: EluNativeRasterSealingError, file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? EluNativeRasterSealingError, expected, file: file, line: line)
        }
    }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func requestHash(_ chunk: [String: Any], domain: String) throws -> String {
        let canonical = try EluV1StrictCanonicalJSON.parse(JSONSerialization.data(withJSONObject: chunk)).canonicalData
        var bytes = Data(domain.utf8); bytes.append(0)
        let size = UInt32(canonical.count)
        bytes.append(contentsOf: [UInt8(truncatingIfNeeded: size >> 24), UInt8(truncatingIfNeeded: size >> 16),
            UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)])
        bytes.append(canonical); return "request_" + digest(bytes)
    }
    private struct Decoded {
        let root: [String: Any], chunk: [String: Any], frame: [String: Any]
        let png: Data
    }
    private func decode(_ request: EluNativeRasterPreparedRequest) throws -> Decoded {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let chunk = try XCTUnwrap(root["chunk"] as? [String: Any])
        let base64 = try XCTUnwrap(chunk["payload"] as? String)
        var compressed = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(compressed.base64EncodedString(), base64)
        var output = Data(count: EluNativeRasterSealer.maximumPayloadBytes)
        var stream = z_stream()
        XCTAssertEqual(inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { inflateEnd(&stream) }
        let result = compressed.withUnsafeMutableBytes { input in
            output.withUnsafeMutableBytes { destination -> Int32 in
                stream.next_in = input.bindMemory(to: UInt8.self).baseAddress; stream.avail_in = uInt(input.count)
                stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = uInt(destination.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        XCTAssertEqual(result, Z_STREAM_END); XCTAssertEqual(stream.avail_in, 0)
        output.removeSubrange(Int(stream.total_out)..<output.count)
        XCTAssertEqual(output, try EluV1StrictCanonicalJSON.parse(output).canonicalData)
        let frames = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [[String: Any]])
        XCTAssertEqual(frames.count, 1)
        let frame = try XCTUnwrap(frames.first), image = try XCTUnwrap(frame["image"] as? [String: Any])
        let png = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(image["png"] as? String)))
        return Decoded(root: root, chunk: chunk, frame: frame, png: png)
    }
    private final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0, deniedAt: Int?
        func current() -> Bool { lock.lock(); defer { lock.unlock() }; calls += 1; return deniedAt.map { calls < $0 } ?? true }
        func refuse(on call: Int) { lock.lock(); defer { lock.unlock() }; calls = 0; deniedAt = call }
        func allow() { lock.lock(); defer { lock.unlock() }; calls = 0; deniedAt = nil }
    }
    @MainActor
    private final class Fixture {
        let window: UIWindow, previous: UIViewController?
        let parent: UIView
        let registry: EluSwiftUIReplayRegistry
        let root: EluSwiftUIReplayMarkerView, privateMarker: EluSwiftUIReplayMarkerView
        init() throws {
            window = try EluUIKitTestHost.window(); previous = window.rootViewController
            let controller = UIViewController(); window.rootViewController = controller
            controller.loadViewIfNeeded(); controller.view.frame = window.bounds
            parent = UIView(frame: CGRect(x: 0, y: 0, width: 64, height: 64)); controller.view.addSubview(parent)
            registry = EluSwiftUIReplayRegistry(requiredRegions: ["private"])
            root = EluSwiftUIReplayMarkerView(region: nil, registry: registry); root.frame = parent.bounds
            privateMarker = EluSwiftUIReplayMarkerView(region: "private", registry: registry)
            privateMarker.frame = CGRect(x: 10.25, y: 10.25, width: 20.5, height: 20.5)
            parent.addSubview(root); parent.addSubview(privateMarker)
            window.makeKeyAndVisible(); window.layoutIfNeeded(); parent.layoutIfNeeded(); CATransaction.flush()
        }
        func capture(at time: TimeInterval = 0, noise: Bool = false) throws -> EluSwiftUIReplayFrame {
            try registry.capture(deadline: time + 1, clock: { time }, draw: { _, _, context in
                if noise {
                    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
                    var state: UInt32 = 0x98178623
                    for index in 0..<(context.bytesPerRow * context.height) where index % 4 != 3 {
                        state ^= state << 13; state ^= state >> 17; state ^= state << 5
                        pixels[index] = UInt8(truncatingIfNeeded: state)
                    }
                    return true
                }
                context.setFillColor(UIColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64)); return true
            })
        }
        func close() { window.rootViewController = previous }
    }
}
#endif
