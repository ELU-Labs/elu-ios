#if canImport(UIKit)
import UIKit
import XCTest
@testable import EluAnalytics

/// These test the synchronous wrapper, not genuine touch delivery. Actual
/// UIWindow dispatch/gestures require the separately scheduled hosted UI lane.
@MainActor
final class EluUIKitReplayTouchObserverTests: XCTestCase {
    private var window: UIWindow!
    private var root: UIView!
    private var collector: EluUIKitReplayCollector!
    private var projection: EluUIKitReplayInteractionProjection!
    private var mailbox: EluNativeReplayInteractionMailbox!
    private var current = true

    override func setUp() {
        super.setUp()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let controller = UIViewController(); window.rootViewController = controller; window.isHidden = false
        root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480)); controller.view.addSubview(root)
        window.layoutIfNeeded(); root.layoutIfNeeded(); CATransaction.flush()
        collector = try! EluUIKitReplayCollector()
        let snapshot = try! collector.collect(root: root, ordinal: 0, timestamp: 1_000,
            hasUnresolvedConfiguredBlockRules: false, profile: .sensitiveMask(),
            retainInteractionProjection: true, isCurrent: { true })
        projection = EluUIKitReplayInteractionProjection(collector: collector, snapshot: snapshot)
        mailbox = EluNativeReplayInteractionMailbox(); current = true
    }
    override func tearDown() {
        collector.withdraw(); collector = nil; projection = nil
        window.isHidden = true; root = nil; window = nil; mailbox = nil
        super.tearDown()
    }
    private func observer() -> EluUIKitReplayTouchObserver {
        .init(projection: projection, mailbox: mailbox, isCurrent: { self.current },
            sample: { .init(timestamp: 1_000, continuous: 1_000_000_000) }, continuous: { 0 })
    }

    func testOriginalDeliveryOnceOnUnobservedClosedAndWithdrawnPaths() {
        let value = observer(), event = UIEvent()
        var deliveries = 0
        value.observe(event) { deliveries += 1 }
        value.stop()
        value.observe(event) { deliveries += 1 }
        value.withdraw()
        value.observe(event) { deliveries += 1 }
        XCTAssertEqual(deliveries, 3)
        XCTAssertEqual(mailbox.drain(), [])
        XCTAssertNil(root.gestureRecognizers)
    }

    func testNestedOriginalDeliveryIsSynchronousAndNeverObservedTwice() {
        let value = observer(), event = UIEvent()
        var order: [Int] = []
        value.observe(event) {
            order.append(1)
            value.observe(event) { order.append(2) }
            order.append(3)
        }
        XCTAssertEqual(order, [1, 2, 3])
        XCTAssertEqual(mailbox.drain(), [])
    }

    func testWithdrawalDuringOriginalDeliveryDropsPreviouslyPendingValues() {
        let value = observer(), event = UIEvent()
        let point = EluNativeInteractionPoint(identity: UUID(), geometryOrdinal: 0,
            time: .init(timestamp: 900, continuous: 1), x: 0, y: 0)
        XCTAssertEqual(mailbox.offer(.start(point)), .retained)
        var deliveries = 0
        value.observe(event) { deliveries += 1; self.current = false }
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(mailbox.drain(), [])
    }

    func testReversedWorkClockWithdrawsMailboxButStillDeliversOnce() {
        var reads = 0
        let value = EluUIKitReplayTouchObserver(projection: projection, mailbox: mailbox,
            isCurrent: { true }, sample: { self.time() }, continuous: {
                reads += 1; return reads == 1 ? 100 : 99
            })
        var deliveries = 0
        value.observe(UIEvent()) { deliveries += 1 }
        XCTAssertEqual(deliveries, 1)
        let point = EluNativeInteractionPoint(identity: UUID(), geometryOrdinal: 0,
            time: time(), x: 0, y: 0)
        XCTAssertEqual(mailbox.offer(.start(point)), .refused)
        value.observe(UIEvent()) { deliveries += 1 }
        XCTAssertEqual(deliveries, 2)
    }

    private func time() -> EluNativeInteractionTime {
        .init(timestamp: 1_000, continuous: 1_000_000_000)
    }

    private func refreshProjection() throws {
        window.layoutIfNeeded(); root.layoutIfNeeded(); CATransaction.flush()
        let snapshot = try collector.collect(root: root, ordinal: 0, timestamp: 1_000,
            hasUnresolvedConfiguredBlockRules: false, profile: .sensitiveMask(),
            retainInteractionProjection: true, isCurrent: { true })
        projection = try XCTUnwrap(EluUIKitReplayInteractionProjection(collector: collector, snapshot: snapshot))
    }
    private func fact(_ phase: EluUIKitReplayTouchFact.Phase, finger: NSObject,
                      x: CGFloat = 20, lifted: Bool = false) -> EluUIKitReplayTouchFact {
        .init(phase: phase, identity: ObjectIdentifier(finger), location: CGPoint(x: x, y: 20),
            liveDirectTouches: lifted ? 0 : 1, allTouchesLifted: lifted)
    }
    private func kinds(_ values: [EluNativeInteraction]) -> [String] {
        values.map { value in
            switch value { case .start: return "start"; case .moves: return "moves"; case .end: return "end"; case .cancel: return "cancel" }
        }
    }

    func testThrottledMoveCrossingPrivateLeafCancelsAndIgnoresThroughLift() throws {
        for mode in ["blocked", "input", "opaque"] {
            root.subviews.forEach { $0.removeFromSuperview() }
            let safe = UIView(frame: CGRect(x: 10, y: 10, width: 90, height: 90))
            let unsafe: UIView
            if mode == "input" { unsafe = UITextField() }
            else if mode == "opaque" { unsafe = UIImageView() }
            else { unsafe = UIView(); Elu.blockView(unsafe) }
            // This fixture deliberately confines the private test region. An
            // unclipped opaque subtree vetoes its full ancestor paint footprint.
            unsafe.clipsToBounds = true
            unsafe.frame = CGRect(x: 120, y: 10, width: 90, height: 90)
            root.addSubview(safe); root.addSubview(unsafe); try refreshProjection()
            mailbox = EluNativeReplayInteractionMailbox()
            var wall: Int64 = 1_000
            let finger = NSObject()
            let value = EluUIKitReplayTouchObserver(projection: projection, mailbox: mailbox,
                isCurrent: { true }, sample: { .init(timestamp: wall, continuous: UInt64(wall) * 1_000_000) }, continuous: { 0 })
            var deliveries = 0
            value.observeForTesting(fact(.began, finger: finger), originalView: safe) { deliveries += 1 }
            wall = 1_100
            value.observeForTesting(fact(.moved, finger: finger), originalView: safe) { deliveries += 1 }
            wall = 1_150 // Below the retention interval, but privacy is mandatory.
            value.observeForTesting(fact(.moved, finger: finger, x: 140), originalView: safe) { deliveries += 1 }
            wall = 1_200
            value.observeForTesting(fact(.moved, finger: finger), originalView: safe) { deliveries += 1 }
            wall = 1_250
            value.observeForTesting(fact(.ended, finger: finger, lifted: true), originalView: safe) { deliveries += 1 }
            let first = mailbox.drain()
            XCTAssertEqual(kinds(first), ["start", "moves", "cancel"], mode)
            XCTAssertEqual(first.last, .cancel(.init(timestamp: 1_150, continuous: 1_150_000_000)), mode)
            XCTAssertEqual(deliveries, 5, mode)
            wall = 1_300
            value.observeForTesting(fact(.began, finger: finger), originalView: safe) { deliveries += 1 }
            XCTAssertEqual(kinds(mailbox.drain()), ["start"], "Only a new physical gesture may resume")
            value.stop()
        }
    }

    func testThrottledMoveRechecksRealHierarchyAfterOriginalDelivery() throws {
        let safe = UIView(frame: CGRect(x: 10, y: 10, width: 90, height: 90))
        root.addSubview(safe); try refreshProjection()
        var wall: Int64 = 1_000
        let finger = NSObject()
        let value = EluUIKitReplayTouchObserver(projection: projection, mailbox: mailbox,
            isCurrent: { true }, sample: { .init(timestamp: wall, continuous: UInt64(wall) * 1_000_000) }, continuous: { 0 })
        value.observeForTesting(fact(.began, finger: finger), originalView: safe) {}
        wall = 1_100; value.observeForTesting(fact(.moved, finger: finger), originalView: safe) {}
        wall = 1_150
        value.observeForTesting(fact(.moved, finger: finger), originalView: safe) {
            let opaque = UIImageView(frame: safe.frame); self.root.addSubview(opaque)
        }
        XCTAssertEqual(kinds(mailbox.drain()), ["start", "moves", "cancel"])
        wall = 1_200; value.observeForTesting(fact(.moved, finger: finger), originalView: safe) {}
        XCTAssertEqual(mailbox.drain(), [])
    }

    func testThrottledLawfulMoveSkipsOnlyRetention() throws {
        let safe = UIView(frame: CGRect(x: 10, y: 10, width: 90, height: 90))
        root.addSubview(safe); try refreshProjection()
        var wall: Int64 = 1_000
        let finger = NSObject()
        let value = EluUIKitReplayTouchObserver(projection: projection, mailbox: mailbox,
            isCurrent: { true }, sample: { .init(timestamp: wall, continuous: UInt64(wall) * 1_000_000) }, continuous: { 0 })
        value.observeForTesting(fact(.began, finger: finger), originalView: safe) {}
        for next in [Int64(1_100), 1_150, 1_200] {
            wall = next; value.observeForTesting(fact(.moved, finger: finger), originalView: safe) {}
        }
        wall = 1_250; value.observeForTesting(fact(.ended, finger: finger, lifted: true), originalView: safe) {}
        let values = mailbox.drain()
        XCTAssertEqual(kinds(values), ["start", "moves", "end"])
        guard case let .moves(points) = values[1] else { return XCTFail("retained moves") }
        XCTAssertEqual(points.map { $0.time.timestamp }, [1_100, 1_200])
    }

    func testThrottledMoveWorkExhaustionCancelsAndPreservesOriginalDelivery() throws {
        let safe = UIView(frame: CGRect(x: 10, y: 10, width: 90, height: 90))
        root.addSubview(safe); try refreshProjection()
        var wall: Int64 = 1_000, ticks: UInt64 = 0
        var expensive = false, deliveries = 0
        let finger = NSObject()
        let value = EluUIKitReplayTouchObserver(projection: projection, mailbox: mailbox,
            isCurrent: { true }, sample: { .init(timestamp: wall, continuous: UInt64(wall) * 1_000_000) },
            continuous: { if expensive { ticks += 1_000_000 }; return ticks })
        value.observeForTesting(fact(.began, finger: finger), originalView: safe) { deliveries += 1 }
        wall = 1_100
        value.observeForTesting(fact(.moved, finger: finger), originalView: safe) { deliveries += 1 }
        wall = 1_150; expensive = true
        value.observeForTesting(fact(.moved, finger: finger), originalView: safe) { deliveries += 1 }
        expensive = false
        XCTAssertEqual(kinds(mailbox.drain()), ["start", "moves", "cancel"])
        wall = 1_200
        value.observeForTesting(fact(.moved, finger: finger), originalView: safe) { deliveries += 1 }
        XCTAssertEqual(mailbox.drain(), [])
        XCTAssertEqual(deliveries, 4)
    }

    func testOriginalApplicationDeliveryTimeDoesNotSpendObservationBudget() throws {
        let safe = UIView(frame: CGRect(x: 10, y: 10, width: 90, height: 90))
        root.addSubview(safe); try refreshProjection()
        var ticks: UInt64 = 0, wall: Int64 = 1_000
        let finger = NSObject()
        let value = EluUIKitReplayTouchObserver(projection: projection, mailbox: mailbox,
            isCurrent: { true }, sample: { .init(timestamp: wall, continuous: UInt64(wall) * 1_000_000) },
            continuous: { ticks += 100; return ticks })
        value.observeForTesting(fact(.began, finger: finger), originalView: safe) { ticks += 50_000_000 }
        wall = 1_100
        value.observeForTesting(fact(.ended, finger: finger, lifted: true), originalView: safe) { ticks += 50_000_000 }
        XCTAssertEqual(kinds(mailbox.drain()), ["start", "end"])
    }

    func testRollingBudgetDoesNotRefillAtFixedWindowBoundary() {
        var budget = EluUIKitReplayTouchWorkBudget()
        XCTAssertEqual(budget.allowance(at: 0), 2_000_000)
        for index in 0 ..< 20 {
            let began = UInt64(900 + index) * 1_000_000
            XCTAssertTrue(budget.charge(from: began, through: began + 1_000_000))
        }
        XCTAssertEqual(budget.allowance(at: 1_001_000_000), 0)
        XCTAssertEqual(budget.allowance(at: 1_900_999_999), 0)
        XCTAssertEqual(budget.allowance(at: 1_901_000_000), 1_000_000)
        XCTAssertEqual(budget.allowance(at: 1_902_000_000), 2_000_000)
    }

    func testRollingBudgetBoundedLedgerMergesConservativelyAndRejectsReversal() {
        var budget = EluUIKitReplayTouchWorkBudget()
        for index in 0 ..< 200 {
            let began = UInt64(index) * 100_000
            XCTAssertTrue(budget.charge(from: began, through: began + 100_000))
        }
        // The oldest73 charges coalesce at the latest end rather than refill
        // early. Entry storage remains bounded while timing stays restrictive.
        XCTAssertEqual(budget.allowance(at: 1_000_100_000), 0)
        XCTAssertEqual(budget.allowance(at: 1_007_300_000), 2_000_000)
        XCTAssertNil(budget.allowance(at: 1_007_299_999))
        XCTAssertNil(budget.allowance(at: 2_000_000_000))
        var backwards = EluUIKitReplayTouchWorkBudget()
        XCTAssertFalse(backwards.charge(from: 100, through: 99))
        XCTAssertNil(backwards.allowance(at: 200))
    }

    func testReentrantStopDoesNotSkipOriginalDeliveryOrInstallRecognizer() {
        let value = observer(), event = UIEvent()
        let tap = UITapGestureRecognizer()
        root.addGestureRecognizer(tap)
        var deliveries = 0
        value.observe(event) { value.stop(); deliveries += 1 }
        value.observe(event) { deliveries += 1 }
        XCTAssertEqual(deliveries, 2)
        XCTAssertEqual(root.gestureRecognizers?.count, 1)
        XCTAssertTrue(root.gestureRecognizers?.first === tap)
    }
}
#endif
