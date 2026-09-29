#if canImport(UIKit)
import UIKit
import XCTest
@testable import EluAnalytics

@MainActor
private final class InteractionOpaqueView: UIView {
    var childReads = 0
    override var subviews: [UIView] { childReads += 1; return super.subviews }
}
@MainActor
private final class InteractionPrivateField: UITextField {
    var valueReads = 0
    override var text: String? {
        get { valueReads += 1; return super.text }
        set { super.text = newValue }
    }
}

@MainActor
final class EluUIKitReplayInteractionProjectionTests: XCTestCase {
    private var window: UIWindow!
    private var root: UIView!
    private var collector: EluUIKitReplayCollector!
    private let time = EluNativeInteractionTime(timestamp: 1_000, continuous: 1_000_000_000)

    override func setUp() {
        super.setUp()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let controller = UIViewController()
        window.rootViewController = controller; window.isHidden = false
        root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        controller.view.addSubview(root)
        collector = try! EluUIKitReplayCollector()
        settle()
    }
    override func tearDown() {
        collector.withdraw(); collector = nil
        window.isHidden = true; root = nil; window = nil
        super.tearDown()
    }
    private func settle() { window.layoutIfNeeded(); root.layoutIfNeeded(); CATransaction.flush() }
    private func view(_ frame: CGRect = CGRect(x: 10, y: 10, width: 100, height: 100)) -> UIView {
        let child = UIView(frame: frame); root.addSubview(child); settle(); return child
    }
    private func projection(_ ordinal: Int64 = 0, retained: Bool = true) throws -> EluUIKitReplayInteractionProjection? {
        let snapshot = try collector.collect(root: root, ordinal: ordinal, timestamp: 1_000 + ordinal * 200,
            hasUnresolvedConfiguredBlockRules: false, profile: .sensitiveMask(),
            retainInteractionProjection: retained, isCurrent: { true })
        return EluUIKitReplayInteractionProjection(collector: collector, snapshot: snapshot)
    }
    private func point(_ value: EluUIKitReplayInteractionProjection, _ p: CGPoint = CGPoint(x: 20, y: 20)) -> EluNativeInteractionPoint? {
        value.point(location: p, time: time, deadline: 100, now: { 0 })
    }

    func testOriginalCollectorOrdinalAndPositiveClipOnly() throws {
        _ = view()
        let original = try XCTUnwrap(projection())
        let first = try XCTUnwrap(point(original))
        XCTAssertEqual(first.geometryOrdinal, 0)
        XCTAssertEqual(first.x, 20)
        XCTAssertNil(point(original, CGPoint(x: 200, y: 200))) // no root/viewport fallback
        XCTAssertNil(point(original, CGPoint(x: -1, y: 20)))
        XCTAssertNil(point(original, CGPoint(x: 320, y: 20)))
        XCTAssertNil(original.point(location: CGPoint(x: 20, y: 20), time: time, deadline: 1, now: { 2 }))
        _ = try projection(1)
        XCTAssertNil(point(original))
    }

    func testUIKitBoundsCoordinatesNormalizeToSerializedViewport() throws {
        root.bounds.origin = CGPoint(x: 40, y: 60)
        _ = view(CGRect(x: 50, y: 70, width: 100, height: 100))
        let original = try XCTUnwrap(projection())
        let value = try XCTUnwrap(point(original, CGPoint(x: 60, y: 80)))
        XCTAssertEqual(value.x, 20); XCTAssertEqual(value.y, 20)
        XCTAssertNil(point(original, CGPoint(x: 20, y: 20)))
    }

    func testOrdinaryCollectionDoesNotCreateInteractionWitness() throws {
        _ = view()
        XCTAssertNil(try projection(retained: false))
    }

    func testInputAndOpaqueOverlayVetoWithoutPrivateReads() throws {
        _ = view()
        let field = InteractionPrivateField(frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        root.addSubview(field); settle()
        XCTAssertNil(point(try XCTUnwrap(projection())))
        XCTAssertEqual(field.valueReads, 0)
        field.removeFromSuperview()
        let opaque = InteractionOpaqueView(frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        root.addSubview(opaque); settle()
        // UIKit setup/layout may inspect this test view. Measure only the SDK
        // collection and subsequent no-content projection proof below.
        opaque.childReads = 0
        let opaqueProjection = try XCTUnwrap(projection(1))
        XCTAssertEqual(opaque.childReads, 0, "Collection must not open opaque children")
        XCTAssertNil(point(opaqueProjection))
        XCTAssertEqual(opaque.childReads, 0, "Point validation must not open opaque children")
    }

    func testUnclippedCustomOverflowVetoesLawfulSiblingWithoutOpeningPrivateChildren() throws {
        let safe = view()
        let opaque = InteractionOpaqueView(frame: CGRect(x: 200, y: 10, width: 40, height: 40))
        let privateChild = InteractionPrivateField(frame: CGRect(x: -190, y: 0, width: 100, height: 40))
        opaque.addSubview(privateChild); root.addSubview(opaque); settle()
        opaque.childReads = 0; privateChild.valueReads = 0
        let ordinary = try collector.collect(root: root, ordinal: 0, timestamp: 1_000,
            hasUnresolvedConfiguredBlockRules: false, profile: .sensitiveMask(), isCurrent: { true })
        let retained = try collector.collect(root: root, ordinal: 0, timestamp: 1_000,
            hasUnresolvedConfiguredBlockRules: false, profile: .sensitiveMask(),
            retainInteractionProjection: true, isCurrent: { true })
        XCTAssertEqual(ordinary, retained, "Interaction privacy does not change serialized v1 geometry")
        let original = try XCTUnwrap(EluUIKitReplayInteractionProjection(collector: collector, snapshot: retained))
        XCTAssertNil(point(original)) // Private child can paint beyond its opaque parent's bounds.
        root.bringSubviewToFront(safe)
        XCTAssertNil(point(try XCTUnwrap(projection(1))), "A foreground rectangle does not prove opaque coverage")
        XCTAssertEqual(opaque.childReads, 0); XCTAssertEqual(privateChild.valueReads, 0)
        opaque.clipsToBounds = true
        let confined = try XCTUnwrap(projection(2))
        XCTAssertNotNil(point(confined))
        XCTAssertNil(point(confined, CGPoint(x: 210, y: 20)))
        XCTAssertEqual(opaque.childReads, 0); XCTAssertEqual(privateChild.valueReads, 0)
    }

    func testBlockedOverflowUsesActualLayerClipAndNeverReadsBlockedChildren() throws {
        _ = view()
        let blocked = InteractionOpaqueView(frame: CGRect(x: 200, y: 10, width: 40, height: 40))
        let child = InteractionPrivateField(frame: CGRect(x: -190, y: 0, width: 100, height: 40))
        blocked.addSubview(child); Elu.blockView(blocked); root.addSubview(blocked); settle()
        blocked.childReads = 0; child.valueReads = 0
        XCTAssertNil(point(try XCTUnwrap(projection())))
        blocked.layer.masksToBounds = true
        let confined = try XCTUnwrap(projection(1))
        XCTAssertNotNil(point(confined))
        XCTAssertNil(point(confined, CGPoint(x: 210, y: 20)))
        XCTAssertEqual(blocked.childReads, 0); XCTAssertEqual(child.valueReads, 0)
        blocked.layer.masksToBounds = false
        XCTAssertNil(point(confined), "Removing the actual clipping boundary invalidates the original proof")
    }

    func testPrivatePaintUsesEffectiveClippedAncestorAndNotScrollClassAssumption() throws {
        _ = view(CGRect(x: 200, y: 10, width: 100, height: 100))
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        scroll.clipsToBounds = false; scroll.layer.masksToBounds = false
        scroll.showsVerticalScrollIndicator = false; scroll.showsHorizontalScrollIndicator = false
        let opaque = InteractionOpaqueView(frame: CGRect(x: 120, y: 10, width: 20, height: 30))
        let child = InteractionPrivateField(frame: CGRect(x: 80, y: 0, width: 100, height: 30))
        opaque.addSubview(child); scroll.addSubview(opaque); root.addSubview(scroll); settle()
        opaque.childReads = 0; child.valueReads = 0
        XCTAssertNil(point(try XCTUnwrap(projection()), CGPoint(x: 210, y: 20)))
        scroll.clipsToBounds = true
        let confined = try XCTUnwrap(projection(1))
        XCTAssertNotNil(point(confined, CGPoint(x: 210, y: 20)))
        XCTAssertNil(point(confined, CGPoint(x: 20, y: 20)), "Unknown paint remains private throughout its actual ancestor clip")
        XCTAssertEqual(opaque.childReads, 0); XCTAssertEqual(child.valueReads, 0)
    }

    func testAddedReorderedOrNewlyVisibleOverlayRefusesOldProjection() throws {
        let child = view()
        let first = try XCTUnwrap(projection())
        let overlay = UIView(frame: child.frame); overlay.isUserInteractionEnabled = false
        root.addSubview(overlay)
        XCTAssertNil(point(first))
        let second = try XCTUnwrap(projection(1))
        root.sendSubviewToBack(overlay)
        XCTAssertNil(point(second))
        overlay.isHidden = true
        let third = try XCTUnwrap(projection(2))
        XCTAssertNotNil(point(third))
        overlay.isHidden = false
        XCTAssertNil(point(third))
    }

    func testFreshPrivacyScrollGeometryAndDetachRefuse() throws {
        let child = view()
        var original = try XCTUnwrap(projection())
        child.center.x += 1
        XCTAssertNil(point(original))
        original = try XCTUnwrap(projection(1))
        Elu.maskView(child)
        XCTAssertNil(point(original))
        let masked = try XCTUnwrap(projection(2))
        XCTAssertNil(point(masked))
        child.removeFromSuperview()
        XCTAssertNil(point(masked))
    }

    func testFractionalClipNeverClampsIntoPrivateBoundary() throws {
        _ = view(CGRect(x: 10.5, y: 10.5, width: 50, height: 50))
        let original = try XCTUnwrap(projection())
        XCTAssertNil(point(original, CGPoint(x: 10.75, y: 10.75)))
        XCTAssertNotNil(point(original, CGPoint(x: 11, y: 11)))
    }

    func testQuantizedPointCannotCrossFractionalPrivatePaintBoundary() throws {
        _ = view()
        let blocked = UIView(frame: CGRect(x: 10, y: 10, width: 10.5, height: 10.5))
        blocked.clipsToBounds = true; Elu.blockView(blocked); root.addSubview(blocked); settle()
        let original = try XCTUnwrap(projection())
        for location in [CGPoint(x: 20.75, y: 15), CGPoint(x: 15, y: 20.75), CGPoint(x: 20.75, y: 20.75)] {
            XCTAssertNil(point(original, location), "Emitted floor coordinate would fall inside private paint")
        }
        for location in [CGPoint(x: 21, y: 15), CGPoint(x: 15, y: 21), CGPoint(x: 21, y: 21)] {
            let admitted = try XCTUnwrap(point(original, location))
            XCTAssertEqual(admitted.x, Int64(location.x)); XCTAssertEqual(admitted.y, Int64(location.y))
        }
    }

    func testChangedReadableTextOrOutsideRootOverlayRefuses() throws {
        let label = UILabel(frame: CGRect(x: 10, y: 10, width: 200, height: 30))
        label.text = "Ordinary label"; label.textColor = .black
        root.addSubview(label); settle()
        let original = try XCTUnwrap(projection())
        XCTAssertNotNil(point(original))
        label.text = "Changed label"
        XCTAssertNil(point(original))
        let next = try XCTUnwrap(projection(1))
        let outside = UIView(frame: root.frame)
        root.superview?.addSubview(outside)
        XCTAssertNil(point(next))
        let obscured = try XCTUnwrap(projection(2))
        XCTAssertNil(point(obscured))
    }

    func testPreexistingUnserializedCellOverlayCannotSupplyTouchTarget() throws {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.frame = CGRect(x: 10, y: 10, width: 200, height: 60)
        root.addSubview(cell)
        let ordinary = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        cell.contentView.addSubview(ordinary)
        let overlay = InteractionOpaqueView(frame: cell.bounds)
        cell.addSubview(overlay); settle()
        overlay.childReads = 0 // Exclude the preceding real UIKit layout only.
        let original = try XCTUnwrap(projection())
        XCTAssertEqual(overlay.childReads, 0, "Collection must not open the opaque overlay")
        XCTAssertNil(point(original))
        XCTAssertEqual(overlay.childReads, 0, "Point validation must not open the opaque overlay")
    }

    func testWithdrawnCollectorAndForeignSnapshotCannotSupplyWitness() throws {
        _ = view()
        let original = try XCTUnwrap(projection())
        let foreign = try EluUIKitReplayCollector()
        let snapshot = try foreign.collect(root: root, ordinal: 0, timestamp: 1_000,
            hasUnresolvedConfiguredBlockRules: false, profile: .sensitiveMask(),
            retainInteractionProjection: true, isCurrent: { true })
        XCTAssertNil(EluUIKitReplayInteractionProjection(collector: collector, snapshot: snapshot))
        collector.withdraw()
        XCTAssertNil(point(original))
    }
}
#endif
