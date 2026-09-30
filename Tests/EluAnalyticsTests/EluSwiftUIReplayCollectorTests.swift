#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
import zlib
@testable import EluAnalytics

@MainActor
final class EluSwiftUIReplayCollectorTests: XCTestCase {
    func testRequiredIntentSurvivesMissingRemovedAndDuplicateMarkers() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.privateMarker.removeFromSuperview()
        XCTAssertEqual(fixture.registry.requiredRegions, ["private"])
        assertFailure(.missingRegion) { _ = try fixture.registry.plan() }
        fixture.parent.addSubview(fixture.privateMarker)
        _ = try fixture.registry.plan()
        let duplicate = fixture.marker(region: "private", frame: fixture.privateMarker.frame)
        assertFailure(.duplicateRegion) { _ = try fixture.registry.plan() }
        duplicate.removeFromSuperview()
        _ = try fixture.registry.plan()
    }

    func testInvalidDeclarationsAndUnknownBindingsDoNotBecomeEmptyPrivacy() throws {
        for declarations: Set<String> in [[""], [String(repeating: "x", count: 129)], Set((0..<65).map(String.init))] {
            let registry = EluSwiftUIReplayRegistry(requiredRegions: declarations)
            assertFailure(.invalidDeclaration) { _ = try registry.plan() }
        }
        let fixture = try Fixture(); defer { fixture.close() }
        let extra = fixture.marker(region: "not-declared", frame: .init(x: 2, y: 2, width: 5, height: 5))
        assertFailure(.invalidDeclaration) { _ = try fixture.registry.plan() }
        extra.removeFromSuperview()
        _ = try fixture.registry.plan()
    }

    func testOriginalPlanRejectsResizeReparentAndGeometryRoundTrip() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let original = try fixture.registry.plan(), frame = fixture.privateMarker.frame
        fixture.privateMarker.frame.origin.x += 1
        fixture.privateMarker.frame = frame
        assertFailure(.staleGeometry) { try fixture.registry.validate(original) }
        let next = try fixture.registry.plan()
        let alternate = UIView(frame: fixture.parent.bounds); fixture.parent.addSubview(alternate)
        alternate.addSubview(fixture.privateMarker)
        assertFailure(.staleGeometry) { try fixture.registry.validate(next) }
        fixture.parent.addSubview(fixture.privateMarker)
        _ = try fixture.registry.plan()
    }

    func testScopeReplacementCannotReuseOldFrameOrWithdrawRequiredIntent() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let frame = try fixture.capture()
        let replacement = EluSwiftUIReplayRegistry(requiredRegions: ["private"])
        fixture.privateMarker.bind(region: "private", registry: replacement)
        assertFailure(.missingRegion) { _ = try fixture.registry.plan() }
        assertFailure(.staleGeometry) { _ = try frame.encodePNG() }
        XCTAssertEqual(fixture.registry.requiredRegions, ["private"])
        fixture.privateMarker.bind(region: "private", registry: fixture.registry)
        _ = try fixture.registry.plan()
    }

    func testFractionalOverlappingMasksProduceOpaqueUnionAndMetadataFreePNG() throws {
        let fixture = try Fixture(regions: ["private", "overlap"]); defer { fixture.close() }
        let overlap = fixture.marker(region: "overlap", frame: .init(x: 20.75, y: 5.75, width: 20.5, height: 20.5))
        defer { overlap.removeFromSuperview() }
        let plan = try fixture.registry.plan()
        XCTAssertTrue(plan.masks.allSatisfy { $0.minX == floor($0.minX) && $0.maxX == ceil($0.maxX) })
        XCTAssertFalse(plan.masks[0].intersection(plan.masks[1]).isEmpty)
        let bytes = try fixture.capture().encodePNG()
        let decoded = try decode(bytes)
        XCTAssertEqual(decoded.kinds, ["IHDR", "sRGB", "IDAT", "IEND"])
        XCTAssertEqual(decoded.width, 64); XCTAssertEqual(decoded.height, 64)
        for y in 0..<64 { for x in 0..<64 {
            let masked = plan.masks.contains { $0.contains(CGPoint(x: CGFloat(x), y: CGFloat(y))) }
            let index = y * (64 * 4 + 1) + 1 + x * 4
            XCTAssertEqual(Array(decoded.rows[index..<(index + 4)]), masked ? [73, 83, 93, 255] : [255, 0, 0, 255])
        } }
    }

    func testDefaultDrawUsesTheOriginalMountedWindowAndRedactsBeforeEncoding() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.parent.backgroundColor = .red
        let privatePaint = UIView(frame: fixture.privateMarker.frame)
        privatePaint.backgroundColor = .green; fixture.parent.addSubview(privatePaint)
        fixture.window.layoutIfNeeded(); CATransaction.flush()
        // Actual default drawHierarchy, no alternate graph or injected draw.
        let frame = try fixture.registry.capture(deadline: 1, clock: { 0 })
        let decoded = try decode(frame.encodePNG())
        let publicIndex = 2 * (64 * 4 + 1) + 1 + 2 * 4
        let privateIndex = 15 * (64 * 4 + 1) + 1 + 15 * 4
        XCTAssertEqual(Array(decoded.rows[publicIndex..<(publicIndex + 4)]), [255, 0, 0, 255])
        XCTAssertEqual(Array(decoded.rows[privateIndex..<(privateIndex + 4)]), [73, 83, 93, 255])
        XCTAssertTrue(privatePaint.superview === fixture.parent)
    }

    func testDefaultDrawIncorporatesImmediatePaintAndPrivateRegionMovement() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.parent.backgroundColor = .red
        let privatePaint = UIView(frame: fixture.privateMarker.frame)
        privatePaint.backgroundColor = .green; fixture.parent.addSubview(privatePaint)
        fixture.window.layoutIfNeeded(); CATransaction.flush()
        // A controlled clock isolates rendering/current geometry. This does not
        // qualify the production 50ms deadline or UIKit's synchronous draw time.
        let first = try fixture.registry.capture(deadline: 1, clock: { 0 }).encodePNG()
        let original = try decode(first)
        let publicIndex = 2 * (64 * 4 + 1) + 1 + 2 * 4
        let oldPrivateIndex = 15 * (64 * 4 + 1) + 1 + 15 * 4
        XCTAssertEqual(Array(original.rows[publicIndex..<(publicIndex + 4)]), [255, 0, 0, 255])
        XCTAssertEqual(Array(original.rows[oldPrivateIndex..<(oldPrivateIndex + 4)]), [73, 83, 93, 255])

        // No render-loop wait or snapshot warm-up: current declared geometry
        // and actual original-view paint must agree in the next default draw.
        fixture.parent.backgroundColor = .blue
        fixture.privateMarker.frame.origin = CGPoint(x: 40.25, y: 40.25)
        privatePaint.frame = fixture.privateMarker.frame
        let second = try fixture.registry.capture(deadline: 3, clock: { 2 }).encodePNG()
        let updated = try decode(second)
        let newPrivateIndex = 45 * (64 * 4 + 1) + 1 + 45 * 4
        XCTAssertEqual(Array(updated.rows[publicIndex..<(publicIndex + 4)]), [0, 0, 255, 255])
        XCTAssertEqual(Array(updated.rows[oldPrivateIndex..<(oldPrivateIndex + 4)]), [0, 0, 255, 255])
        XCTAssertEqual(Array(updated.rows[newPrivateIndex..<(newPrivateIndex + 4)]), [73, 83, 93, 255])
        XCTAssertTrue(privatePaint.window === fixture.window)
    }

    func testFinalRedactionDoesNotDependOnDestinationClipAndRootNeverRoundsOutward() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.root.frame.size = CGSize(width: 63.75, height: 63.5)
        let frame = try fixture.registry.capture(deadline: 1, clock: { 0 }, draw: { _, _, context in
            // Synthetic renderer that ignores the clip by writing the owned
            // context directly. Retained-output masks must still be applied.
            guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
            for offset in stride(from: 0, to: context.bytesPerRow * context.height, by: 4) {
                data[offset] = 0; data[offset + 1] = 255; data[offset + 2] = 0; data[offset + 3] = 255
            }
            return true
        })
        let decoded = try decode(frame.encodePNG())
        XCTAssertEqual(decoded.width, 63); XCTAssertEqual(decoded.height, 63)
        let publicIndex = 2 * (63 * 4 + 1) + 1 + 2 * 4
        let privateIndex = 15 * (63 * 4 + 1) + 1 + 15 * 4
        XCTAssertEqual(Array(decoded.rows[publicIndex..<(publicIndex + 4)]), [0, 255, 0, 255])
        XCTAssertEqual(Array(decoded.rows[privateIndex..<(privateIndex + 4)]), [73, 83, 93, 255])
    }

    func testNonopaqueDrawIsRejectedAndCleared() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var cleared = false
        assertFailure(.invalidPixels) {
            _ = try fixture.registry.capture(deadline: 1, clock: { 0 }, draw: { _, _, context in
                context.data?.assumingMemoryBound(to: UInt8.self)[3] = 0
                return true
            }, onDiscard: { count, zero in cleared = count == 16_384 && zero })
        }
        XCTAssertTrue(cleared)
    }

    func testDrawReturnMutationsClearOriginalAllocationBeforeAnyFrameEscapes() throws {
        for mutation in 0..<5 {
            let fixture = try Fixture(); defer { fixture.close() }
            let original = fixture.privateMarker.frame
            let alternate = UIView(frame: fixture.parent.bounds); fixture.parent.addSubview(alternate)
            var draws = 0, cleared = 0, allZero = false
            XCTAssertThrowsError(try fixture.registry.capture(deadline: 1, clock: { 0 }, draw: { _, _, context in
                draws += 1; context.setFillColor(UIColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                switch mutation {
                case 0: fixture.privateMarker.removeFromSuperview()
                case 1: alternate.addSubview(fixture.privateMarker)
                case 2: fixture.privateMarker.frame.size.width += 1
                case 3:
                    fixture.privateMarker.frame.origin.x += 1; fixture.privateMarker.frame = original
                default: fixture.privateMarker.unbind()
                }
                return true
            }, onDiscard: { count, zero in cleared = count; allZero = zero })) {
                XCTAssertEqual($0 as? EluSwiftUIReplayFailure, .staleGeometry)
            }
            XCTAssertEqual(draws, 1); XCTAssertEqual(cleared, 64 * 64 * 4); XCTAssertTrue(allZero)
            // The callback mutates mounted public geometry at the synchronous
            // draw boundary, not a claim about incidental UIKit scheduling.
        }
    }

    func testIncompleteDrawAndDeadlineClearOriginalStorage() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var cleared = 0, zero = false, now = 0.0
        assertFailure(.incompleteDraw) {
            _ = try fixture.registry.capture(deadline: 1, clock: { now }, draw: { _, _, _ in false },
                onDiscard: { cleared = $0; zero = $1 })
        }
        XCTAssertEqual(cleared, 16_384); XCTAssertTrue(zero)
        now = 2; cleared = 0; zero = false
        assertFailure(.deadline) {
            _ = try fixture.registry.capture(deadline: 3, clock: { now }, draw: { _, _, _ in now = 2.051; return true },
                onDiscard: { cleared = $0; zero = $1 })
        }
        XCTAssertEqual(cleared, 16_384); XCTAssertTrue(zero)
    }

    func testOneOriginalCandidateAndOneHertzCadenceAreNotBypassedByReentry() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var reentry: EluSwiftUIReplayFailure?
        let frame = try fixture.registry.capture(deadline: 1, clock: { 0 }, draw: { _, _, _ in
            do { _ = try fixture.capture() } catch { reentry = error as? EluSwiftUIReplayFailure }
            return true
        })
        XCTAssertEqual(reentry, .busy)
        assertFailure(.busy) { _ = try fixture.capture(at: 2) }
        frame.close()
        assertFailure(.cadence) { _ = try fixture.capture(at: 0.999) }
        let next = try fixture.capture(at: 1); next.close()
        assertFailure(.cadence) { _ = try fixture.capture(at: 0.5) }
    }

    func testOffscreenRequiredRegionRemainsRequiredAndHasNoViewportPixels() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.privateMarker.frame.origin.y = 100
        let plan = try fixture.registry.plan()
        XCTAssertTrue(plan.masks.isEmpty); XCTAssertEqual(plan.witnesses.count, 2)
        _ = try fixture.capture().encodePNG()
        fixture.privateMarker.removeFromSuperview()
        assertFailure(.missingRegion) { _ = try fixture.registry.plan() }
    }

    func testOriginalScrollChangesFreshGeometryButInvalidatesPinnedGeometry() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let scroll = UIScrollView(frame: fixture.parent.bounds)
        scroll.contentInsetAdjustmentBehavior = .never; scroll.contentSize = CGSize(width: 64, height: 200)
        fixture.parent.addSubview(scroll); scroll.addSubview(fixture.privateMarker)
        let original = try fixture.registry.plan()
        scroll.contentOffset = CGPoint(x: 0, y: 4)
        assertFailure(.staleGeometry) { try fixture.registry.validate(original) }
        let current = try fixture.registry.plan()
        XCTAssertEqual(current.witnesses[1].rect.minY, original.witnesses[1].rect.minY - 4)
        XCTAssertTrue(current.window === original.window)
        _ = try fixture.capture().encodePNG()
    }

    func testTransformsAnimationsAndDeepHierarchyRefuseBeforeDraw() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.privateMarker.transform = CGAffineTransform(rotationAngle: 0.1)
        assertFailure(.invalidGeometry) { _ = try fixture.registry.plan() }
        fixture.privateMarker.transform = .identity
        let animation = CABasicAnimation(keyPath: "opacity"); animation.duration = 10
        fixture.privateMarker.layer.add(animation, forKey: "synthetic")
        assertFailure(.invalidGeometry) { _ = try fixture.registry.plan() }
        fixture.privateMarker.layer.removeAllAnimations()
        var parent = fixture.parent
        for _ in 0..<65 { let child = UIView(frame: parent.bounds); parent.addSubview(child); parent = child }
        parent.addSubview(fixture.privateMarker)
        assertFailure(.invalidGeometry) { _ = try fixture.registry.plan() }
    }

    func testOneShotFrameCannotEncodeAgainAndScopeDeathRevokesCandidate() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let frame = try fixture.capture()
        _ = try frame.encodePNG()
        assertFailure(.staleGeometry) { _ = try frame.encodePNG() }
        var registry: EluSwiftUIReplayRegistry? = EluSwiftUIReplayRegistry(requiredRegions: [])
        let root = EluSwiftUIReplayMarkerView(region: nil, registry: registry!)
        root.frame = CGRect(x: 0, y: 0, width: 16, height: 16); fixture.parent.addSubview(root)
        let orphan = try registry!.capture(deadline: 1, clock: { 0 }, draw: { _, _, _ in true })
        registry = nil
        assertFailure(.staleGeometry) { _ = try orphan.encodePNG() }
    }

    func testPNGRejectsNonopaqueOversizedAndIncompressiblePixels() throws {
        var transparent = [UInt8](repeating: 0, count: 4)
        assertFailure(.invalidPixels) { _ = try transparent.withUnsafeBytes { try EluSwiftUIReplayPNG.encode(width: 1, height: 1, rgba: $0) } }
        transparent[3] = 255
        assertFailure(.invalidPixels) { _ = try transparent.withUnsafeBytes { try EluSwiftUIReplayPNG.encode(width: 2049, height: 1, rgba: $0) } }
        var pixels = [UInt8](repeating: 255, count: 1024 * 1024 * 4), state: UInt32 = 0x98178623
        for index in pixels.indices where index % 4 != 3 {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            pixels[index] = UInt8(truncatingIfNeeded: state)
        }
        assertFailure(.pngLimit) { _ = try pixels.withUnsafeBytes { try EluSwiftUIReplayPNG.encode(width: 1024, height: 1024, rgba: $0) } }
    }

    func testPublicModifiersCompileWithoutExposingBitmapOrEnablingRuntime() {
        let scope = EluSwiftUIReplayScope(requiredRegions: ["input", "private"])
        _ = VStack {
            TextField("Input", text: .constant("synthetic")).eluMask(scope, region: "input")
            Text("Private").eluBlock(scope, region: "private")
        }.eluReplayRoot(scope)
        XCTAssertEqual(scope.registry.requiredRegions, ["input", "private"])
        assertFailure(.missingRegion) { _ = try scope.registry.plan() }
    }

    private func assertFailure(_ expected: EluSwiftUIReplayFailure, file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? EluSwiftUIReplayFailure, expected, file: file, line: line)
        }
    }

    private struct Decoded {
        let width: Int, height: Int
        let kinds: [String]
        let rows: [UInt8]
    }
    /// Independently inspect emitted chunk grammar, CRCs and exact zlib extent.
    private func decode(_ data: Data) throws -> Decoded {
        let bytes = Array(data)
        XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        func integer(_ offset: Int) -> Int { bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) } }
        var cursor = 8, kinds: [String] = [], compressed: [UInt8] = [], width = 0, height = 0
        while cursor < bytes.count {
            let count = integer(cursor), begin = cursor + 8, end = begin + count
            guard count >= 0, end + 4 <= bytes.count else { throw EluSwiftUIReplayFailure.pngEncoding }
            let kind = String(decoding: bytes[(cursor + 4)..<begin], as: UTF8.self); kinds.append(kind)
            let actual = bytes.withUnsafeBufferPointer { crc32(0, $0.baseAddress!.advanced(by: cursor + 4), uInt(count + 4)) }
            XCTAssertEqual(UInt32(actual), UInt32(integer(end)))
            switch kind {
            case "IHDR":
                width = integer(begin); height = integer(begin + 4)
                XCTAssertEqual(Array(bytes[(begin + 8)..<end]), [8, 6, 0, 0, 0])
            case "sRGB": XCTAssertEqual(Array(bytes[begin..<end]), [0])
            case "IDAT": compressed.append(contentsOf: bytes[begin..<end])
            case "IEND": XCTAssertEqual(count, 0); XCTAssertEqual(end + 4, bytes.count)
            default: XCTFail("Unexpected metadata chunk")
            }
            cursor = end + 4
        }
        var rows = [UInt8](repeating: 0, count: (width * 4 + 1) * height)
        var stream = z_stream()
        XCTAssertEqual(inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { inflateEnd(&stream) }
        let result = compressed.withUnsafeMutableBufferPointer { input in
            rows.withUnsafeMutableBufferPointer { output in
                stream.next_in = input.baseAddress; stream.avail_in = uInt(input.count)
                stream.next_out = output.baseAddress; stream.avail_out = uInt(output.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        XCTAssertEqual(result, Z_STREAM_END); XCTAssertEqual(stream.avail_in, 0); XCTAssertEqual(stream.avail_out, 0)
        for row in 0..<height { XCTAssertEqual(rows[row * (width * 4 + 1)], 0) }
        return Decoded(width: width, height: height, kinds: kinds, rows: rows)
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow, previous: UIViewController?
        let parent: UIView
        let registry: EluSwiftUIReplayRegistry
        let root: EluSwiftUIReplayMarkerView, privateMarker: EluSwiftUIReplayMarkerView
        init(regions: Set<String> = ["private"]) throws {
            window = try EluUIKitTestHost.window(); previous = window.rootViewController
            let controller = UIViewController(); window.rootViewController = controller
            controller.loadViewIfNeeded(); controller.view.frame = window.bounds
            parent = UIView(frame: CGRect(x: 0, y: 0, width: 64, height: 64)); controller.view.addSubview(parent)
            registry = EluSwiftUIReplayRegistry(requiredRegions: regions)
            root = EluSwiftUIReplayMarkerView(region: nil, registry: registry); root.frame = parent.bounds
            privateMarker = EluSwiftUIReplayMarkerView(region: "private", registry: registry)
            privateMarker.frame = CGRect(x: 10.25, y: 10.25, width: 20.5, height: 20.5)
            parent.addSubview(root); parent.addSubview(privateMarker)
            window.makeKeyAndVisible(); window.layoutIfNeeded(); parent.layoutIfNeeded(); CATransaction.flush()
        }
        func marker(region: String?, frame: CGRect) -> EluSwiftUIReplayMarkerView {
            let marker = EluSwiftUIReplayMarkerView(region: region, registry: registry)
            marker.frame = frame; parent.addSubview(marker); return marker
        }
        func capture(at time: TimeInterval = 0) throws -> EluSwiftUIReplayFrame {
            try registry.capture(deadline: time + 1, clock: { time }, draw: { _, _, context in
                context.setFillColor(UIColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64)); return true
            })
        }
        func close() { window.rootViewController = previous }
    }
}
#endif
