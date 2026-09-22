import Foundation
import XCTest
@testable import EluAnalytics

final class EluNativeWireframeEncoderTests: XCTestCase {
    private let first = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let third = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    private let time: Int64 = 1_788_883_200_000

    func testOrdinaryTextSurvivesInitialChangedAndInsertedFrames() throws {
        var encoder = try EluNativeWireframeEncoder()
        let initial = try encoder.encode([frame(0, nodes: [node(first, .ordinaryText("Welcome to ELU"))])])
        let changed = try encoder.encode([frame(1, nodes: [node(first, .ordinaryText("Order confirmed")),
                                                            node(second, .ordinaryText("Continue shopping"))])])
        XCTAssertTrue(String(decoding: initial.data, as: UTF8.self).contains("Welcome to ELU"))
        let text = String(decoding: changed.data, as: UTF8.self)
        XCTAssertTrue(text.contains("Order confirmed"))
        XCTAssertTrue(text.contains("Continue shopping"))
        XCTAssertFalse(text.contains("Welcome to ELU"))
    }

    func testOrdinaryTextUsesUtf8ByteLimitAndFailedEncodingDoesNotAdvanceState() throws {
        var encoder = try EluNativeWireframeEncoder()
        let original = encoder.state
        XCTAssertThrowsError(try encoder.encode([frame(0, nodes: [node(first, .ordinaryText(String(repeating: "é", count: 2_049)))])])) {
            XCTAssertEqual($0 as? EluNativeEncodingError, .invalidText)
        }
        XCTAssertEqual(encoder.state, original)
        _ = try encoder.encode([frame(0, nodes: [node(first, .ordinaryText(String(repeating: "é", count: 2_048)))])])
    }

    func testInitialCanonicalFixedTokensAndNoLocalIdentityOnWire() throws {
        var encoder = try EluNativeWireframeEncoder()
        let nodes = try [node(first, .text), node(second, .input(secure: true)), node(third, .placeholder)]
        let chunk = try encoder.encode([frame(0, nodes: nodes)])
        let events = try decode(chunk)
        XCTAssertEqual(chunk.sequence, 0); XCTAssertEqual(chunk.eventCount, 2)
        XCTAssertEqual(chunk.firstTimestamp, time); XCTAssertEqual(chunk.lastTimestamp, time)
        XCTAssertEqual((events[0]["type"] as? NSNumber)?.intValue, 4)
        let leaves = try fullLeaves(events[1])
        XCTAssertEqual(leaves[0]["text"] as? String, "[masked]")
        XCTAssertEqual(leaves[1]["value"] as? String, "[masked]")
        XCTAssertEqual(leaves[1]["inputType"] as? String, "password")
        XCTAssertEqual(leaves[1]["disabled"] as? Bool, true)
        XCTAssertEqual(leaves[2]["label"] as? String, "Content hidden")
        XCTAssertFalse(String(decoding: chunk.data, as: UTF8.self).contains(first.uuidString))
        XCTAssertFalse(String(decoding: chunk.data, as: UTF8.self).contains("ordinal"))
        XCTAssertEqual(try EluV1StrictCanonicalJSON.parse(chunk.data).canonicalData, chunk.data)
        XCTAssertEqual(encoder.state.live.map(\.id), [10_000_001, 10_000_002, 10_000_003])
    }

    func testSameMillisecondDistinctFramesAreLegalButDuplicateFrameFailsAtomically() throws {
        var encoder = try EluNativeWireframeEncoder()
        let a = try node(first, .rectangle)
        let initial = frame(0, nodes: [a])
        let before = encoder.state
        XCTAssertThrowsError(try encoder.encode([initial, initial])) { XCTAssertEqual($0 as? EluNativeEncodingError, .frameOrder) }
        XCTAssertEqual(encoder.state, before)
        let chunk = try encoder.encode([initial, frame(1, nodes: [a])])
        XCTAssertEqual(chunk.eventCount, 3)
        XCTAssertEqual(try decode(chunk).map { ($0["timestamp"] as! NSNumber).int64Value }, [time, time, time])
    }

    func testFractionalInvalidAndChangedViewportRefused() throws {
        for value in [0.0, 390.5, Double.nan, .infinity, 16_385] {
            XCTAssertThrowsError(try EluNativeViewport(width: value, height: 844))
            XCTAssertThrowsError(try EluNativeViewport(width: 390, height: value))
        }
        var encoder = try EluNativeWireframeEncoder()
        _ = try encoder.encode([frame(0)])
        let old = encoder.state
        let rotated = EluNativeMaskedSnapshot(ordinal: 1, timestamp: time, viewport: try .init(width: 844, height: 390), nodes: [])
        XCTAssertThrowsError(try encoder.encode([rotated])) { XCTAssertEqual($0 as? EluNativeEncodingError, .invalidViewport) }
        XCTAssertEqual(encoder.state, old)
    }

    func testBadGeometryAndClipOutsideViewportOrOwnBoundsRefused() throws {
        for x in [Double.nan, .infinity, -1_000_001, 1_000_001] {
            XCTAssertThrowsError(try EluNativeRect(x: x, y: 0, width: 10, height: 10))
        }
        XCTAssertThrowsError(try EluNativeRect(x: 0, y: 0, width: -1, height: 10))
        XCTAssertThrowsError(try EluNativeStyle(fontSize: .nan))
        let bounds = try EluNativeRect(x: 0, y: 0, width: 20, height: 20)
        for clip in [try EluNativeRect(x: 0, y: 0, width: 21, height: 20), try EluNativeRect(x: -1, y: 0, width: 1, height: 1)] {
            var encoder = try EluNativeWireframeEncoder(); let old = encoder.state
            let value = EluNativeMaskedNode(identity: first, kind: .text, bounds: bounds, clip: clip, style: try .init())
            XCTAssertThrowsError(try encoder.encode([frame(0, nodes: [value])]))
            XCTAssertEqual(encoder.state, old)
        }
    }

    func testClipPreservesUntrimmedOriginAndEmptyVisibleArea() throws {
        var encoder = try EluNativeWireframeEncoder()
        let visible = EluNativeMaskedNode(identity: first, kind: .text,
            bounds: try .init(x: -20, y: 20, width: 100, height: 30),
            clip: try .init(x: 0, y: 25, width: 50, height: 20), style: try .init())
        let empty = EluNativeMaskedNode(identity: second, kind: .placeholder,
            bounds: try .init(x: 900, y: 20, width: 10, height: 10),
            clip: try .init(x: 390, y: 20, width: 0, height: 0), style: try .init())
        let leaves = try fullLeaves(decode(encoder.encode([frame(0, nodes: [visible, empty])]))[1])
        XCTAssertEqual((leaves[0]["x"] as? NSNumber)?.intValue, -20)
        XCTAssertEqual((leaves[0]["clip"] as? [String: NSNumber])?["x"]?.intValue, 0)
        XCTAssertEqual((leaves[1]["clip"] as? [String: NSNumber])?["width"]?.intValue, 0)
    }

    func testDuplicateNodeOperationsRejectedBeforeStateChanges() throws {
        var encoder = try EluNativeWireframeEncoder()
        let a = try node(first, .rectangle); _ = try encoder.encode([frame(0, nodes: [a])])
        let old = encoder.state
        XCTAssertThrowsError(try encoder.encode([frame(1, nodes: [a, a])])) { XCTAssertEqual($0 as? EluNativeEncodingError, .duplicateIdentity) }
        XCTAssertEqual(encoder.state, old)
        let valid = try encoder.encode([frame(1, nodes: [a, node(second, .text)])])
        let operations = try XCTUnwrap(decode(valid)[0]["data"] as? [String: Any])
        XCTAssertEqual((operations["adds"] as? [Any])?.count, 1)
        XCTAssertEqual((operations["updates"] as? [Any])?.count, 0)
        XCTAssertEqual((operations["removes"] as? [Any])?.count, 0)
    }

    func testRemoveAndSuffixAddPreserveSurvivorPaintOrder() throws {
        var encoder = try EluNativeWireframeEncoder()
        let a = try node(first, .text), b = try node(second, .rectangle), c = try node(third, .placeholder)
        _ = try encoder.encode([frame(0, nodes: [a, b])])
        let chunk = try encoder.encode([frame(1, nodes: [b, c])])
        let event = try decode(chunk)[0], data = try XCTUnwrap(event["data"] as? [String: Any])
        XCTAssertEqual((event["type"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(encoder.state.live.map(\.id), [10_000_002, 10_000_003])
        let removes = try XCTUnwrap(data["removes"] as? [[String: NSNumber]])
        XCTAssertEqual(removes, [["id": 10_000_001, "parentId": 10_000_000]])
        XCTAssertEqual((data["adds"] as? [Any])?.count, 1)
    }

    func testExistingChangeReorderAndMiddleInsertionUseFullSnapshot() throws {
        let a = try node(first, .text), b = try node(second, .rectangle), c = try node(third, .placeholder)
        for nodes in [[try node(first, .text, x: 15), b], [b, a], [a, c, b]] {
            var encoder = try EluNativeWireframeEncoder()
            _ = try encoder.encode([frame(0, nodes: [a, b])])
            let result = try encoder.encode([frame(1, nodes: nodes)])
            XCTAssertEqual((try decode(result)[0]["type"] as? NSNumber)?.intValue, 2)
            XCTAssertEqual(encoder.state.live.map(\.value.identity), nodes.map(\.identity))
            XCTAssertEqual(encoder.state.live.first { $0.value.identity == first }?.id, 10_000_001)
        }
    }

    func testRetiredIdentityCannotReturnAfterMutationOrFullSnapshot() throws {
        for changed in [false, true] {
            var encoder = try EluNativeWireframeEncoder()
            let a = try node(first, .text), b = try node(second, .rectangle)
            _ = try encoder.encode([frame(0, nodes: [a, b])])
            _ = try encoder.encode([frame(1, nodes: [changed ? node(second, .rectangle, x: 15) : b])])
            let old = encoder.state
            XCTAssertThrowsError(try encoder.encode([frame(2, nodes: [a, b])])) { XCTAssertEqual($0 as? EluNativeEncodingError, .retiredIdentity) }
            XCTAssertEqual(encoder.state, old)
            _ = try encoder.encode([frame(2, nodes: [b, node(third, .text)])])
            XCTAssertEqual(encoder.state.live.last?.id, 10_000_003)
        }
    }

    func testFullSnapshotDoesNotRenewLifetimeIDBudget() throws {
        var encoder = try EluNativeWireframeEncoder(limits: .init(liveNodes: 3, lifetimeIDs: 3))
        _ = try encoder.encode([frame(0, nodes: [node(first, .text), node(second, .rectangle)])])
        _ = try encoder.encode([frame(1, nodes: [node(first, .text, x: 15)])])
        let old = encoder.state
        XCTAssertThrowsError(try encoder.encode([frame(2, nodes: [node(first, .text), node(third, .placeholder)])])) { XCTAssertEqual($0 as? EluNativeEncodingError, .nodeLimit) }
        XCTAssertEqual(encoder.state, old)
    }

    func testSafeIntegerIDBoundaryAllowsLastIDThenFailsWithoutReusingIt() throws {
        var encoder = try EluNativeWireframeEncoder(firstNodeID: EluNativeWireframeEncoder.maximumSafeInteger - 1)
        _ = try encoder.encode([frame(0, nodes: [node(first, .text)])])
        XCTAssertEqual(encoder.state.live[0].id, EluNativeWireframeEncoder.maximumSafeInteger)
        let old = encoder.state
        XCTAssertThrowsError(try encoder.encode([frame(1, nodes: [node(first, .text), node(second, .text)])])) { XCTAssertEqual($0 as? EluNativeEncodingError, .counterExhausted) }
        XCTAssertEqual(encoder.state, old)
    }

    func testExactByteLimitAndFailedLaterFrameLeaveOriginalStateIntact() throws {
        let frames = try [frame(0, nodes: [node(first, .text)]), frame(1, nodes: [node(second, .input(secure: false))])]
        var baseline = try EluNativeWireframeEncoder(); let expected = try baseline.encode(frames)
        var exact = try EluNativeWireframeEncoder(limits: .init(decodedBytes: expected.data.count))
        XCTAssertEqual(try exact.encode(frames), expected)
        var short = try EluNativeWireframeEncoder(limits: .init(decodedBytes: expected.data.count - 1)); let before = short.state
        XCTAssertThrowsError(try short.encode(frames)) { XCTAssertEqual($0 as? EluNativeEncodingError, .byteLimit) }
        XCTAssertEqual(short.state, before)
        let initial = try short.encode([frames[0]])
        XCTAssertEqual(initial.sequence, 0); XCTAssertEqual(short.state.live.first?.id, 10_000_001)
    }

    func testEventAndRepresentationCapsAreAtomic() throws {
        for limits in [try EluNativeWireframeEncoder.Limits(events: 2), try .init(representations: 3)] {
            var encoder = try EluNativeWireframeEncoder(limits: limits); let before = encoder.state
            XCTAssertThrowsError(try encoder.encode([frame(0, nodes: [node(first, .text)]), frame(1, nodes: [node(first, .text)])]))
            XCTAssertEqual(encoder.state, before)
            _ = try encoder.encode([frame(0, nodes: [node(first, .text)])])
        }
    }

    func testTenThousandLiveNodeBoundaryIncludesRoot() throws {
        var encoder = try EluNativeWireframeEncoder()
        let nodes = try (0..<9_999).map { _ in try node(UUID(), .rectangle) }
        let encoded = try encoder.encode([frame(0, nodes: nodes)])
        XCTAssertEqual(encoded.nodeRepresentations, 10_000)
        XCTAssertEqual(try fullLeaves(decode(encoded)[1]).count, 9_999)
        let old = encoder.state
        XCTAssertThrowsError(try encoder.encode([frame(1, nodes: nodes + [node(UUID(), .text)])])) { XCTAssertEqual($0 as? EluNativeEncodingError, .nodeLimit) }
        XCTAssertEqual(encoder.state, old)
    }

    func testTimestampsNotRewrittenAndFailureDoesNotConsumeOrdinal() throws {
        var encoder = try EluNativeWireframeEncoder()
        _ = try encoder.encode([frame(0)])
        let old = encoder.state
        for t in [Int64(0), time - 1, EluNativeWireframeEncoder.maximumSafeInteger + 1] {
            let invalid = EluNativeMaskedSnapshot(ordinal: 1, timestamp: t, viewport: try .init(width: 390, height: 844), nodes: [])
            XCTAssertThrowsError(try encoder.encode([invalid])) { XCTAssertEqual($0 as? EluNativeEncodingError, .invalidTimestamp) }
            XCTAssertEqual(encoder.state, old)
        }
        let next = try encoder.encode([frame(1, timestamp: time + 123)])
        XCTAssertEqual(next.firstTimestamp, time + 123); XCTAssertEqual(next.sequence, 1)
    }

    func testClosedStyleComponentsAndFixedInputTypes() throws {
        let style = try EluNativeStyle(color: .init(red: 255, green: 0, blue: 16),
            backgroundColor: .init(red: 0, green: 20, blue: 30, alpha: 128), fontSize: 12.5, fontFamily: .system)
        let bounds = try EluNativeRect(x: 0, y: 0, width: 20, height: 20)
        let value = EluNativeMaskedNode(identity: first, kind: .input(secure: false), bounds: bounds, clip: bounds, style: style)
        var encoder = try EluNativeWireframeEncoder()
        let leaves = try fullLeaves(decode(encoder.encode([frame(0, nodes: [value])]))[1])
        let actual = try XCTUnwrap(leaves[0]["style"] as? [String: Any])
        XCTAssertEqual(Set(actual.keys), ["color", "backgroundColor", "fontSize", "fontFamily"])
        XCTAssertEqual(actual["color"] as? String, "#ff0010")
        XCTAssertEqual(actual["backgroundColor"] as? String, "#00141e80")
        XCTAssertEqual(leaves[0]["inputType"] as? String, "text")
    }

    func testExactRendererIDBudgetDoesNotReclaimRemovedNodesAndFullResetsIt() throws {
        var encoder = try EluNativeWireframeEncoder()
        let a = try node(first, .text), b = try node(second, .input(secure: true)), c = try node(third, .placeholder)
        _ = try encoder.encode([frame(0, nodes: [a, b])])
        XCTAssertEqual(encoder.state.rendererBudget, 3)
        _ = try encoder.encode([frame(1, nodes: [a, b, c])])
        XCTAssertEqual(encoder.state.rendererBudget, 4)
        _ = try encoder.encode([frame(2, nodes: [b, c])])
        XCTAssertEqual(encoder.state.rendererBudget, 4)
        _ = try encoder.encode([frame(3, nodes: [c, b])])
        XCTAssertEqual(encoder.state.rendererBudget, 3)
    }

    func testSyntheticFixtureExportUsesActualEncoder() throws {
        var encoder = try EluNativeWireframeEncoder()
        let a = try node(first, .text), b = try node(second, .input(secure: true)), c = try node(third, .placeholder)
        let chunks = try [encoder.encode([frame(0, nodes: [a, b])]),
                          encoder.encode([frame(1, nodes: [a, b, c])]),
                          encoder.encode([frame(2, nodes: [node(first, .text, x: 15), b, c])]),
                          encoder.encode([frame(3, nodes: [b, c])])]
        for chunk in chunks { XCTAssertEqual(try EluV1StrictCanonicalJSON.parse(chunk.data).canonicalData, chunk.data) }
        if let directory = ProcessInfo.processInfo.environment["ELU_NATIVE_FIXTURE_DIRECTORY"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            for chunk in chunks { try chunk.data.write(to: root.appendingPathComponent("ios-native-\(chunk.sequence).json"), options: .withoutOverwriting) }
        }
    }

    private func frame(_ ordinal: Int64, timestamp: Int64? = nil, nodes: [EluNativeMaskedNode] = []) -> EluNativeMaskedSnapshot {
        .init(ordinal: ordinal, timestamp: timestamp ?? time, viewport: try! .init(width: 390, height: 844), nodes: nodes)
    }
    private func node(_ identity: UUID, _ kind: EluNativeMaskedKind, x: Double = 10) throws -> EluNativeMaskedNode {
        let bounds = try EluNativeRect(x: x, y: 20, width: 100, height: 30)
        return .init(identity: identity, kind: kind, bounds: bounds, clip: bounds, style: try .init())
    }
    private func decode(_ chunk: EluNativeEncodedChunk) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: chunk.data) as? [[String: Any]])
    }
    private func fullLeaves(_ event: [String: Any]) throws -> [[String: Any]] {
        let data = try XCTUnwrap(event["data"] as? [String: Any])
        let roots = try XCTUnwrap(data["wireframes"] as? [[String: Any]])
        return try XCTUnwrap(roots.first?["childWireframes"] as? [[String: Any]])
    }
}
