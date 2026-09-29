#if canImport(UIKit)
import UIKit
import XCTest
@testable import EluAnalytics

/// Real windows/hierarchy and detached callback facts. These do not fabricate
/// UITouch or qualify actual UIKit gesture dispatch; that remains a hosted UI gate.
@MainActor
final class EluReplayWindowTests: XCTestCase {
    private var window: EluReplayWindow!
    private var root: UIView!
    private var collector: EluUIKitReplayCollector!
    private var wall: Int64 = 1_000
    private var live = true

    override func setUp() {
        super.setUp()
        window = EluReplayWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let controller = UIViewController()
        root = UIView(frame: window.bounds); controller.view = root
        window.rootViewController = controller; window.isHidden = false
        collector = try! EluUIKitReplayCollector(); live = true; wall = 1_000
        settle()
    }
    override func tearDown() {
        collector.withdraw(); window.isHidden = true
        collector = nil; root = nil; window = nil
        super.tearDown()
    }
    private func settle() { window.layoutIfNeeded(); root.layoutIfNeeded(); CATransaction.flush() }
    private func frame(_ ordinal: Int64) throws -> (EluNativeMaskedSnapshot, EluUIKitReplayInteractionProjection) {
        let snapshot = try collector.collect(root: root, ordinal: ordinal, timestamp: wall,
            hasUnresolvedConfiguredBlockRules: false, profile: .sensitiveMask(),
            retainInteractionProjection: true, isCurrent: { self.live })
        return (snapshot, try XCTUnwrap(EluUIKitReplayInteractionProjection(collector: collector, snapshot: snapshot)))
    }
    private func observer(_ projection: EluUIKitReplayInteractionProjection,
                          _ mailbox: EluNativeReplayInteractionMailbox) -> EluUIKitReplayTouchObserver {
        .init(projection: projection, mailbox: mailbox, isCurrent: { self.live },
            sample: { .init(timestamp: self.wall, continuous: UInt64(self.wall) * 1_000_000) }, continuous: { 0 })
    }
    private func fact(_ phase: EluUIKitReplayTouchFact.Phase, _ finger: NSObject, y: CGFloat = 50) -> EluUIKitReplayTouchFact {
        let lifted = phase == .ended || phase == .cancelled
        return .init(phase: phase, identity: ObjectIdentifier(finger), location: CGPoint(x: 50, y: y),
            liveDirectTouches: lifted ? 0 : 1, allTouchesLifted: lifted)
    }

    func testWindowKeepsOriginalObserverAndDoesNotAdoptForeignWindow() async throws {
        let safe = UIView(frame: CGRect(x: 10, y: 10, width: 100, height: 100)); root.addSubview(safe); settle()
        let (_, projection) = try frame(0), mailbox = EluNativeReplayInteractionMailbox()
        let original = observer(projection, mailbox), replacement = observer(projection, EluNativeReplayInteractionMailbox())
        let other = EluReplayWindow(frame: window.frame)
        XCTAssertFalse(other.installReplayObserver(original))
        XCTAssertTrue(window.installReplayObserver(original))
        XCTAssertFalse(window.installReplayObserver(replacement))
        window.sendEvent(UIEvent()) // Real public dispatch of an event without fabricated touches.
        XCTAssertNil(root.gestureRecognizers)
        await window.closeReplayObserver(replacement)
        XCTAssertFalse(window.installReplayObserver(replacement), "Closing a foreign observer must not displace the original")
        await window.closeReplayObserver(original)
        XCTAssertFalse(window.installReplayObserver(original), "A withdrawn observer cannot be reinstalled")
        let fresh = observer(projection, EluNativeReplayInteractionMailbox())
        XCTAssertTrue(window.installReplayObserver(fresh))
        await window.closeReplayObserver(fresh)
    }

    func testLawfulScrollRetainsContactAndOrdersOldPointsBeforeFreshGeometry() throws {
        let scroll = UIScrollView(frame: root.bounds)
        scroll.showsVerticalScrollIndicator = false; scroll.showsHorizontalScrollIndicator = false
        scroll.contentSize = CGSize(width: 320, height: 900)
        let safe = UIView(frame: CGRect(x: 10, y: 0, width: 100, height: 300))
        scroll.addSubview(safe); root.addSubview(scroll); settle()
        let (initial, firstProjection) = try frame(0)
        let originalChildren = scroll.subviews.prefix(17).map(ObjectIdentifier.init)
        let originalWitness = try XCTUnwrap(collector.collectedInteractionProjection(for: initial))
        var encoder = try EluNativeWireframeV2Encoder(profile: .sensitiveMask())
        _ = try encoder.encode([.geometry(initial, continuous: 1_000_000_000)])
        let mailbox = EluNativeReplayInteractionMailbox(), value = observer(firstProjection, mailbox), finger = NSObject()
        var deliveries = 0
        wall = 1_100
        value.observeForTesting(fact(.began, finger), originalView: safe) { deliveries += 1 }
        wall = 1_200
        value.observeForTesting(fact(.moved, finger), originalView: safe) {
            deliveries += 1; scroll.contentOffset.y = 20
        }
        let old = try XCTUnwrap(value.drainCurrent(),
            "Old points after original scroll delivery;" + ReplayScrollFixtureDiagnostics.describe(
                root: root, scroll: scroll, target: safe, originalChildren: originalChildren) +
            ";strictWitnessCurrent=\(originalWitness.isCurrent(deadline: 100, now: { 0 }))" +
            ";geometryWitnessCurrent=\(originalWitness.isCurrent(deadline: 100, now: { 0 }, allowingGeometry: true))" +
            ";currentGeometryAvailable=\(originalWitness.currentGeometry(deadline: 100, now: { 0 }) != nil)" +
            ";currentPointAvailable=\(firstProjection.point(location: CGPoint(x: 50, y: 50),
                time: .init(timestamp: wall, continuous: UInt64(wall) * 1_000_000), deadline: 100, now: { 0 }) != nil)" +
            ";observerOrdinalAvailable=\(value.originalProjectionOrdinal != nil);contactActive=\(value.contactIsActive)")
        XCTAssertEqual(old.count, 2)
        XCTAssertTrue(value.contactIsActive)
        XCTAssertEqual(scroll.contentOffset.y, 20)
        wall = 1_400
        let (next, nextProjection) = try frame(1)
        XCTAssertNotEqual(initial.nodes.map(\.bounds), next.nodes.map(\.bounds))
        let terminal = try XCTUnwrap(value.handoff(nextProjection, at: .init(timestamp: wall, continuous: 1_400_000_000)))
        XCTAssertTrue(terminal.isEmpty, "A lawful same-identity scroll must not become cancel-only geometry")
        _ = try encoder.encode(old.map(EluNativeReplayRecord.interaction) + [.geometry(next, continuous: 1_400_000_000)])
        wall = 1_500
        value.observeForTesting(fact(.moved, finger, y: 60), originalView: safe) { deliveries += 1 }
        wall = 1_600
        value.observeForTesting(fact(.ended, finger, y: 60), originalView: safe) { deliveries += 1 }
        let suffix = try XCTUnwrap(value.drainCurrent())
        XCTAssertEqual(suffix.flatMap(\.points).map(\.geometryOrdinal), [1, 1])
        _ = try encoder.encode(suffix.map(EluNativeReplayRecord.interaction))
        XCTAssertEqual(deliveries, 4); XCTAssertFalse(value.contactIsActive)
        value.stop()
    }

    func testHandoffCancelsRemovedTargetAtGeometryClockAndSuppressesThroughLift() throws {
        let safe = UILabel(frame: CGRect(x: 10, y: 10, width: 160, height: 50)); safe.text = "Readable"
        root.addSubview(safe); settle()
        let (initial, projection) = try frame(0)
        var encoder = try EluNativeWireframeV2Encoder(profile: .sensitiveMask())
        _ = try encoder.encode([.geometry(initial, continuous: 1_000_000_000)])
        let mailbox = EluNativeReplayInteractionMailbox(), value = observer(projection, mailbox), finger = NSObject()
        wall = 1_100; value.observeForTesting(fact(.began, finger, y: 30), originalView: safe) {}
        let old = try XCTUnwrap(value.drainCurrent())
        safe.text = EluNativeWireframeEncoder.mask; settle(); wall = 1_400
        let (next, nextProjection) = try frame(1)
        wall = 1_401 // A later callback sample must not put cancel after the following geometry.
        let cancelled = try XCTUnwrap(value.handoff(nextProjection, at: .init(timestamp: 1_400, continuous: 1_400_000_000)))
        XCTAssertEqual(cancelled, [.cancel(.init(timestamp: 1_400, continuous: 1_400_000_000))])
        _ = try encoder.encode((old + cancelled).map(EluNativeReplayRecord.interaction) + [.geometry(next, continuous: 1_400_000_000)])
        wall = 1_500; value.observeForTesting(fact(.moved, finger), originalView: safe) {}
        XCTAssertEqual(try XCTUnwrap(value.drainCurrent()), [])
        wall = 1_600; value.observeForTesting(fact(.ended, finger), originalView: safe) {}
        XCTAssertFalse(value.contactIsActive); value.stop()
    }

    func testCurrentAndOrderedClipsBothRequiredWithoutAdvancingCollectorIdentity() throws {
        let safe = UIView(frame: CGRect(x: 10, y: 10, width: 100, height: 100)); root.addSubview(safe); settle()
        let (initial, projection) = try frame(0), time = EluNativeInteractionTime(timestamp: 1_100, continuous: 1_100_000_000)
        let before = try XCTUnwrap(projection.point(location: CGPoint(x: 50, y: 50), time: time, deadline: 100, now: { 0 }))
        safe.frame.origin.x = 30
        let withinBoth = try XCTUnwrap(projection.point(location: CGPoint(x: 50, y: 50), time: time, deadline: 100, now: { 0 }))
        XCTAssertEqual(before, withinBoth)
        XCTAssertNil(projection.point(location: CGPoint(x: 20, y: 50), time: time, deadline: 100, now: { 0 }))
        XCTAssertNil(projection.point(location: CGPoint(x: 120, y: 50), time: time, deadline: 100, now: { 0 }))
        XCTAssertNotNil(collector.collectedInteractionProjection(for: initial), "Queries must retain original identity and ordinal")
        live = false; collector.withdraw()
        XCTAssertNil(projection.point(location: CGPoint(x: 50, y: 50), time: time, deadline: 100, now: { 0 }))
    }
}

/// Failure-only diagnostics shared by the two real-scroll fixtures. No text,
/// class names, view identifiers or child content is emitted. Identity values
/// stay local solely to compare the original ordered direct children.
@MainActor
enum ReplayScrollFixtureDiagnostics {
    static func describe(root: UIView, scroll: UIScrollView, target: UIView,
                         originalChildren: [ObjectIdentifier]) -> String {
        let children = scroll.subviews
        let sameOrder = children.count == originalChildren.count && children.count <= 16 &&
            zip(children, originalChildren).allSatisfy { ObjectIdentifier($0.0) == $0.1 }
        var facts = [
            "rootAttached=\(root.window != nil)", "scrollParentOriginal=\(scroll.superview === root)",
            "targetParentOriginal=\(target.superview === scroll)", "sameWindow=\(scroll.window === root.window && target.window === root.window)",
            "originalChildren=\(min(originalChildren.count, 17))", "currentChildren=\(min(children.count, 17))",
            "sameOrderedChildren=\(sameOrder)", "targetInChildren=\(children.prefix(16).contains { $0 === target })",
            "offsetX=\(number(scroll.contentOffset.x))", "offsetY=\(number(scroll.contentOffset.y))",
            "zoomIsOne=\(scroll.zoomScale == 1)", "dragging=\(scroll.isDragging)", "decelerating=\(scroll.isDecelerating)"
        ]
        facts += viewFacts("root", root) + viewFacts("scroll", scroll) + viewFacts("target", target)
        for (index, child) in children.prefix(16).enumerated() { facts += viewFacts("child\(index)", child) }
        return facts.joined(separator: ";")
    }

    private static func number(_ value: CGFloat) -> Double {
        value.isFinite ? Double(max(-100_000, min(value, 100_000))) : 0
    }

    private static func viewFacts(_ prefix: String, _ view: UIView) -> [String] {
        let layer = view.layer
        return [
            "\(prefix)Hidden=\(view.isHidden)", "\(prefix)AlphaOne=\(view.alpha == 1)", "\(prefix)AlphaZero=\(view.alpha == 0)",
            "\(prefix)TransformIdentity=\(view.transform.isIdentity)", "\(prefix)LayerTransformIdentity=\(CATransform3DIsIdentity(layer.transform))",
            "\(prefix)SublayerTransformIdentity=\(CATransform3DIsIdentity(layer.sublayerTransform))",
            "\(prefix)ZZero=\(layer.zPosition == 0)", "\(prefix)OpacityOne=\(layer.opacity == 1)",
            "\(prefix)HasMask=\(layer.mask != nil)", "\(prefix)AnimationCount=\(min(layer.animationKeys()?.count ?? 0, 17))",
            "\(prefix)Clips=\(view.clipsToBounds)", "\(prefix)Masks=\(layer.masksToBounds)", "\(prefix)CornerZero=\(layer.cornerRadius == 0)",
            "\(prefix)Restricted=\(view.eluReplayRestriction != nil)", "\(prefix)BoundsX=\(number(view.bounds.minX))",
            "\(prefix)BoundsY=\(number(view.bounds.minY))", "\(prefix)Width=\(number(view.bounds.width))", "\(prefix)Height=\(number(view.bounds.height))"
        ]
    }
}
#endif
