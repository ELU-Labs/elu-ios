import Foundation
import XCTest
@testable import EluAnalytics

final class EluNativeWireframeV2EncoderTests: XCTestCase {
    private let first = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let base: Int64 = 1_785_888_060_000

    func testExactSharedInitialStartMoveEndAndCancelBytes() throws {
        var encoder = try EluNativeWireframeV2Encoder(profile: .sensitiveMask())
        let initial = try encoder.encode([geometry(0)])
        XCTAssertEqual(initial.data, Data(initialFixture.utf8))
        let started = try encoder.encode([.interaction(.start(point(200, x: 10))),
            .interaction(.moves([point(300, x: 20), point(400, x: 30)]))])
        XCTAssertEqual(started.data, Data(startFixture.utf8))
        XCTAssertEqual(started.eventCount, 2, "The descriptive count matches outer JSON records")
        let ended = try encoder.encode([.interaction(.moves([point(500, x: 40)])),
            .interaction(.end(point(500, x: 40)))])
        XCTAssertEqual(ended.data, Data(endFixture.utf8)); XCTAssertNil(encoder.state.activeIdentity)
        var canceled = try EluNativeWireframeV2Encoder(profile: .sensitiveMask())
        _ = try canceled.encode([geometry(0)])
        _ = try canceled.encode([.interaction(.start(point(200, x: 10))),
            .interaction(.moves([point(300, x: 20), point(400, x: 30)]))])
        let cancel = try canceled.encode([.interaction(.cancel(time(500)))])
        XCTAssertEqual(cancel.data, Data(cancelFixture.utf8))
        XCTAssertFalse(String(decoding: cancel.data, as: UTF8.self).contains("\"x\""))
    }

    func testV1GeometryBytesStayIdenticalApartFromRequiredInitialMetaDiscriminator() throws {
        var v1 = try EluNativeWireframeEncoder()
        var v2 = try EluNativeWireframeV2Encoder(profile: .sensitiveMask())
        let frames = try [frame(0), frame(1, offset: 1_000, nodes: [node(first), node(second, kind: .rectangle)]),
                          frame(2, offset: 2_000, nodes: [node(second, kind: .rectangle)])]
        for (index, frame) in frames.enumerated() {
            let a = try v1.encode([frame]), b = try v2.encode([.geometry(frame, continuous: UInt64(index) * 1_000_000_000)])
            let expected = index == 0 ? String(decoding: a.data, as: UTF8.self)
                .replacingOccurrences(of: "{\"data\":{\"height\"", with: "{\"data\":{\"codec\":\"elu-native-wireframe-v2\",\"height\"") : String(decoding: a.data, as: UTF8.self)
            XCTAssertEqual(String(decoding: b.data, as: UTF8.self), expected)
            XCTAssertEqual(v1.state, v2.state.geometry)
        }
    }

    func testTouchCannotArmInTheInitialUncommittedSnapshotCandidate() throws {
        var encoder = try EluNativeWireframeV2Encoder(profile: .sensitiveMask())
        let before = encoder.state
        XCTAssertThrowsError(try encoder.encode([geometry(0), .interaction(.start(point(0)))])) {
            XCTAssertEqual($0 as? EluNativeInteractionError, .initialCommitRequired)
        }
        XCTAssertEqual(encoder.state, before)
        _ = try encoder.encode([geometry(0)])
        XCTAssertNoThrow(try encoder.encode([.interaction(.start(point(0))), .interaction(.end(point(0)))]))
    }

    func testBlanketAndStructurallyPrivateTargetsNeverProduceTouchCoordinates() throws {
        let kinds: [EluNativeMaskedKind] = [.text, .ordinaryText("[masked]"), .input(secure: false), .input(secure: true), .placeholder]
        for kind in kinds {
            var encoder = try EluNativeWireframeV2Encoder(profile: .sensitiveMask())
            _ = try encoder.encode([geometry(0, nodes: [node(first, kind: kind)])])
            let before = encoder.state
            XCTAssertThrowsError(try encoder.encode([.interaction(.start(point(100)))])) {
                XCTAssertEqual($0 as? EluNativeInteractionError, .privateTarget)
            }
            XCTAssertEqual(encoder.state, before)
        }
        var blanket = try EluNativeWireframeV2Encoder(profile: .blanketMask())
        _ = try blanket.encode([geometry(0, nodes: [node(first, kind: .rectangle)])])
        XCTAssertThrowsError(try blanket.encode([.interaction(.start(point(100)))])) {
            XCTAssertEqual($0 as? EluNativeInteractionError, .privateTarget)
        }
    }

    func testPointsRequireCurrentProjectionOrdinalPositiveClipAndViewport() throws {
        let clipped = try node(first, clip: .init(x: 10, y: 10, width: 20, height: 20))
        var encoder = try EluNativeWireframeV2Encoder(profile: .sensitiveMask())
        _ = try encoder.encode([geometry(0, nodes: [clipped])])
        for bad in [point(100, identity: second), point(100, ordinal: 1), point(100, x: 9),
                    point(100, x: 30), point(100, y: 30), point(100, x: -1), point(100, x: 100)] {
            let before = encoder.state
            XCTAssertThrowsError(try encoder.encode([.interaction(.start(bad))]))
            XCTAssertEqual(encoder.state, before)
        }
        _ = try encoder.encode([.interaction(.start(point(100, x: 10, y: 10)))])
        XCTAssertEqual(encoder.state.activeIdentity, first)
        var hidden = try EluNativeWireframeV2Encoder(profile: .sensitiveMask())
        _ = try hidden.encode([geometry(0, nodes: [node(first, clip: .init(x: 0, y: 0, width: 0, height: 0))])])
        XCTAssertThrowsError(try hidden.encode([.interaction(.start(point(100)))]))
    }

    func testActiveGestureSurvivesFullOnlyWhileSameLawfulIdentityHasPositiveClip() throws {
        var encoder = try started()
        _ = try encoder.encode([geometry(1, offset: 1_000)]) // unchanged geometry forces a full snapshot
        XCTAssertEqual(encoder.state.activeIdentity, first)
        XCTAssertThrowsError(try encoder.encode([.interaction(.moves([point(1_100)]))])) {
            XCTAssertEqual($0 as? EluNativeInteractionError, .staleGeometry)
        }
        _ = try encoder.encode([.interaction(.moves([point(1_100, ordinal: 1)]))])
        for nodes in [[], [try node(first, kind: .text)], [try node(first, clip: .init(x: 0, y: 0, width: 0, height: 0))]] {
            let before = encoder.state
            XCTAssertThrowsError(try encoder.encode([geometry(2, offset: 1_200, nodes: nodes)])) {
                XCTAssertEqual($0 as? EluNativeInteractionError, .privateTarget)
            }
            XCTAssertEqual(encoder.state, before)
        }
        _ = try encoder.encode([.interaction(.cancel(time(1_200))), geometry(2, offset: 1_200, nodes: [])])
        XCTAssertNil(encoder.state.activeIdentity)
        XCTAssertThrowsError(try encoder.encode([geometry(3, offset: 1_400)])) {
            XCTAssertEqual($0 as? EluNativeEncodingError, .retiredIdentity)
        }
    }

    func testEndMayUseAnotherLawfulTargetButNoNestedOrUnstartedGestureIsAdmitted() throws {
        var encoder = try EluNativeWireframeV2Encoder(profile: .sensitiveMask())
        _ = try encoder.encode([geometry(0, nodes: [node(first), node(second, kind: .rectangle)])])
        for value in [EluNativeInteraction.end(point(100)), .moves([point(100)]), .cancel(time(100))] {
            XCTAssertThrowsError(try encoder.encode([.interaction(value)]))
        }
        _ = try encoder.encode([.interaction(.start(point(100)))])
        let before = encoder.state
        XCTAssertThrowsError(try encoder.encode([.interaction(.start(point(100)))]))
        XCTAssertEqual(encoder.state, before)
        _ = try encoder.encode([.interaction(.end(point(100, identity: second)))])
        XCTAssertNil(encoder.state.activeIdentity)
    }

    func testEarliestLogicalSamplePrecedesFirstOuterTimestampWithoutSyntheticGeometry() throws {
        var encoder = try started()
        let chunk = try encoder.encode([.interaction(.moves([point(200), point(300), point(400)]))])
        XCTAssertEqual(chunk.firstTimestamp, base + 200)
        XCTAssertEqual(chunk.lastTimestamp, base + 400); XCTAssertEqual(chunk.eventCount, 1)
        let events = try decode(chunk); XCTAssertEqual(events.count, 1)
        XCTAssertEqual((events[0]["timestamp"] as? NSNumber)?.int64Value, base + 400)
        let data = try XCTUnwrap(events[0]["data"] as? [String: Any])
        let positions = try XCTUnwrap(data["positions"] as? [[String: Any]])
        XCTAssertEqual(positions.compactMap { ($0["timeOffset"] as? NSNumber)?.intValue }, [-200, -100, 0])
        XCTAssertEqual(try EluV1StrictCanonicalJSON.parse(chunk.data).canonicalData, chunk.data)
        XCTAssertFalse(String(decoding: chunk.data, as: UTF8.self).contains(first.uuidString))
    }

    func testMoveRatePersistsAcrossChunksGesturesAndBothClockDomains() throws {
        var encoder = try started()
        _ = try encoder.encode([.interaction(.moves([point(200)]))])
        for bad in [point(299), point(300, continuous: 299_000_000)] {
            let before = encoder.state
            XCTAssertThrowsError(try encoder.encode([.interaction(.moves([bad]))])) {
                XCTAssertEqual($0 as? EluNativeInteractionError, .moveRate)
            }
            XCTAssertEqual(encoder.state, before)
        }
        _ = try encoder.encode([.interaction(.end(point(250))), .interaction(.start(point(250)))])
        XCTAssertThrowsError(try encoder.encode([.interaction(.moves([point(299)]))]))
        _ = try encoder.encode([.interaction(.moves([point(300)]))])
    }

    func testCoalescedBatchBoundsOrderingAndCrossEventLowerBoundAreAtomic() throws {
        for bad in [[], [point(200), point(200)], [point(200), point(1_200)], (0..<11).map { point(200 + Int64($0) * 100) }] {
            var encoder = try started(); let before = encoder.state
            XCTAssertThrowsError(try encoder.encode([.interaction(.moves(bad))]))
            XCTAssertEqual(encoder.state, before)
        }
        var encoder = try started()
        _ = try encoder.encode([geometry(1, offset: 1_000)])
        let before = encoder.state
        XCTAssertThrowsError(try encoder.encode([.interaction(.moves([point(900, ordinal: 1), point(1_100, ordinal: 1)]))])) {
            XCTAssertEqual($0 as? EluNativeInteractionError, .invalidOrder)
        }
        XCTAssertEqual(encoder.state, before)
    }

    func testLogicalEventLimitCountsPositionsExactlyAndDoesNotResetStateOnFailure() throws {
        var encoder = try EluNativeWireframeV2Encoder(profile: .sensitiveMask(), limits: .init(events: 2))
        _ = try encoder.encode([geometry(0)])
        _ = try encoder.encode([.interaction(.start(point(100)))])
        let before = encoder.state
        XCTAssertThrowsError(try encoder.encode([.interaction(.moves([point(200), point(300), point(400)]))])) {
            XCTAssertEqual($0 as? EluNativeEncodingError, .eventLimit)
        }
        XCTAssertEqual(encoder.state, before)
        let allowed = try encoder.encode([.interaction(.moves([point(200), point(300)]))])
        XCTAssertEqual(allowed.eventCount, 1); XCTAssertEqual(try decode(allowed).count, 1)
    }

    func testFailedLaterInteractionDoesNotCommitEarlierGeometryOrNodeAllocation() throws {
        var encoder = try started(); let before = encoder.state
        XCTAssertThrowsError(try encoder.encode([geometry(1, offset: 1_000, nodes: [node(first), node(second)]),
            .interaction(.moves([point(1_100, identity: second, ordinal: 0)]))]))
        XCTAssertEqual(encoder.state, before)
        _ = try encoder.encode([geometry(1, offset: 1_000, nodes: [node(first), node(second)])])
        XCTAssertEqual(encoder.state.geometry.live.map(\.id), [10_000_001, 10_000_002])
    }

    func testByteLimitAndViewportFailureDoNotAdvanceOriginalState() throws {
        var expected = try EluNativeWireframeV2Encoder(profile: .sensitiveMask())
        let initial = try expected.encode([geometry(0)])
        var short = try EluNativeWireframeV2Encoder(profile: .sensitiveMask(), limits: .init(decodedBytes: initial.data.count - 1))
        let before = short.state
        XCTAssertThrowsError(try short.encode([geometry(0)])) { XCTAssertEqual($0 as? EluNativeEncodingError, .byteLimit) }
        XCTAssertEqual(short.state, before)
        var exact = try EluNativeWireframeV2Encoder(profile: .sensitiveMask(), limits: .init(decodedBytes: initial.data.count))
        XCTAssertEqual(try exact.encode([geometry(0)]), initial)
        let state = exact.state
        let changed = EluNativeMaskedSnapshot(ordinal: 1, timestamp: base + 1_000,
            viewport: try .init(width: 200, height: 100), nodes: [])
        XCTAssertThrowsError(try exact.encode([.geometry(changed, continuous: 1_000_000_000)])) {
            XCTAssertEqual($0 as? EluNativeEncodingError, .invalidViewport)
        }
        XCTAssertEqual(exact.state, state)
    }

    func testGeometryRateChecksBothWireAndMonotonicClocksAcrossChunks() throws {
        var encoder = try EluNativeWireframeV2Encoder(profile: .sensitiveMask())
        _ = try encoder.encode([geometry(0)])
        let original = encoder.state
        for record in [EluNativeReplayRecord.geometry(try frame(1, offset: 199), continuous: 200_000_000),
                       .geometry(try frame(1, offset: 200), continuous: 199_000_000)] {
            XCTAssertThrowsError(try encoder.encode([record])) {
                XCTAssertEqual($0 as? EluNativeInteractionError, .invalidOrder)
            }
            XCTAssertEqual(encoder.state, original)
        }
        _ = try encoder.encode([geometry(1, offset: 200)])
        let committed = encoder.state
        XCTAssertThrowsError(try encoder.encode([geometry(2, offset: 399)]))
        XCTAssertEqual(encoder.state, committed)
        _ = try encoder.encode([geometry(2, offset: 400)])
    }

    func testBlanketGeometryCannotSerializeOrdinaryTextEvenWithoutTouches() throws {
        var encoder = try EluNativeWireframeV2Encoder(profile: .blanketMask())
        let original = encoder.state
        XCTAssertThrowsError(try encoder.encode([geometry(0)])) {
            XCTAssertEqual($0 as? EluNativeInteractionError, .privateTarget)
        }
        XCTAssertEqual(encoder.state, original)
        XCTAssertNoThrow(try encoder.encode([geometry(0, nodes: [node(first, kind: .text)])]))
    }

    private func started() throws -> EluNativeWireframeV2Encoder {
        var encoder = try EluNativeWireframeV2Encoder(profile: .sensitiveMask())
        _ = try encoder.encode([geometry(0)])
        _ = try encoder.encode([.interaction(.start(point(100)))])
        return encoder
    }
    private func time(_ offset: Int64, continuous: UInt64? = nil) -> EluNativeInteractionTime {
        .init(timestamp: base + offset, continuous: continuous ?? UInt64(offset) * 1_000_000)
    }
    private func point(_ offset: Int64, identity: UUID? = nil, ordinal: Int64 = 0,
                       x: Int64 = 10, y: Int64 = 10, continuous: UInt64? = nil) -> EluNativeInteractionPoint {
        .init(identity: identity ?? first, geometryOrdinal: ordinal, time: time(offset, continuous: continuous), x: x, y: y)
    }
    private func node(_ identity: UUID, kind: EluNativeMaskedKind = .ordinaryText("Visible native label"),
                      clip: EluNativeRect? = nil) throws -> EluNativeMaskedNode {
        let bounds = try EluNativeRect(x: 0, y: 0, width: 100, height: 40)
        return .init(identity: identity, kind: kind, bounds: bounds, clip: clip ?? bounds, style: try .init())
    }
    private func frame(_ ordinal: Int64, offset: Int64 = 0, nodes: [EluNativeMaskedNode]? = nil) throws -> EluNativeMaskedSnapshot {
        .init(ordinal: ordinal, timestamp: base + offset, viewport: try .init(width: 100, height: 100), nodes: try nodes ?? [node(first)])
    }
    private func geometry(_ ordinal: Int64, offset: Int64 = 0, nodes: [EluNativeMaskedNode]? = nil) throws -> EluNativeReplayRecord {
        .geometry(try frame(ordinal, offset: offset, nodes: nodes), continuous: UInt64(offset) * 1_000_000)
    }
    private func decode(_ chunk: EluNativeEncodedChunk) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: chunk.data) as? [[String: Any]])
    }

    // Frozen shared Rust/frontend fixtures, byte-for-byte; no runtime file lookup.
    private let initialFixture = #"[{"data":{"codec":"elu-native-wireframe-v2","height":100,"width":100},"timestamp":1785888060000,"type":4},{"data":{"initialOffset":{"left":0,"top":0},"wireframes":[{"childWireframes":[{"clip":{"height":40,"width":100,"x":0,"y":0},"height":40,"id":10000001,"text":"Visible native label","type":"text","width":100,"x":0,"y":0}],"height":100,"id":10000000,"type":"div","width":100,"x":0,"y":0}]},"timestamp":1785888060000,"type":2}]"#
    private let startFixture = #"[{"data":{"id":10000001,"pointerType":2,"source":2,"type":7,"x":10,"y":10},"timestamp":1785888060200,"type":3},{"data":{"positions":[{"id":10000001,"timeOffset":-100,"x":20,"y":10},{"id":10000001,"timeOffset":0,"x":30,"y":10}],"source":6},"timestamp":1785888060400,"type":3}]"#
    private let endFixture = #"[{"data":{"positions":[{"id":10000001,"timeOffset":0,"x":40,"y":10}],"source":6},"timestamp":1785888060500,"type":3},{"data":{"id":10000001,"pointerType":2,"source":2,"type":9,"x":40,"y":10},"timestamp":1785888060500,"type":3}]"#
    private let cancelFixture = #"[{"data":{"id":10000000,"pointerType":2,"source":2,"type":10},"timestamp":1785888060500,"type":3}]"#
}
