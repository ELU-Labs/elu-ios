#if canImport(UIKit)
import UIKit
import WebKit
import XCTest
@testable import EluAnalytics

private final class GetterLabel: UILabel {
    var reads = 0
    override var text: String? { get { reads += 1; return super.text } set { super.text = newValue } }
    override var attributedText: NSAttributedString? { get { reads += 1; return super.attributedText } set { super.attributedText = newValue } }
}
private final class GetterField: UITextField {
    var reads = 0
    override var text: String? { get { reads += 1; return super.text } set { super.text = newValue } }
    override var attributedText: NSAttributedString? { get { reads += 1; return super.attributedText } set { super.attributedText = newValue } }
}
private final class GetterTextView: UITextView {
    var reads = 0
    override var text: String! { get { reads += 1; return super.text } set { super.text = newValue } }
    override var attributedText: NSAttributedString! { get { reads += 1; return super.attributedText } set { super.attributedText = newValue } }
}
private final class GetterImage: UIImageView {
    var reads = 0
    override var image: UIImage? { get { reads += 1; return super.image } set { super.image = newValue } }
    override var subviews: [UIView] { reads += 1; return super.subviews }
}
private final class GetterWebView: WKWebView {
    var reads = 0
    override var url: URL? { reads += 1; return super.url }
    override var subviews: [UIView] { reads += 1; return super.subviews }
}
private final class OpaqueView: UIView {
    var reads = 0
    override var subviews: [UIView] { reads += 1; return super.subviews }
}

private final class WeakViewBox {
    weak var view: UIView?
    init(_ view: UIView) { self.view = view }
}

@MainActor
final class EluUIKitReplayCollectorTests: XCTestCase {
    private var window: UIWindow!
    private var root: UIView!
    override func setUp() {
        super.setUp()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        root = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        controller.view.addSubview(root)
        settle()
    }
    override func tearDown() {
        window.isHidden = true; root = nil; window = nil
        super.tearDown()
    }
    private func settle() {
        window.layoutIfNeeded(); root.layoutIfNeeded()
        CATransaction.flush()
    }
    private func collect(_ collector: EluUIKitReplayCollector, ordinal: Int64 = 0,
                         rules: [EluUIKitReplayRestriction] = [], current: () -> Bool = { true }) throws -> EluNativeMaskedSnapshot {
        try collector.collect(root: root, ordinal: ordinal, timestamp: 1_700_000_000_123 + ordinal,
                              hasUnresolvedConfiguredBlockRules: false, restrictions: rules, isCurrent: current)
    }
    private func error(_ expected: EluUIKitReplayCollectionError, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual($0 as? EluUIKitReplayCollectionError, expected) }
    }

    func testSensitiveProfileDoesNotReadAttributedTransparentOrClippedUnderlyingText() throws {
        let attributed = UILabel(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        attributed.attributedText = NSAttributedString(string: "PRIVATE_ATTRIBUTED", attributes: [.foregroundColor: UIColor.clear])
        let transparent = UILabel(frame: CGRect(x: 0, y: 25, width: 100, height: 20))
        transparent.text = "PRIVATE_TRANSPARENT"; transparent.textColor = .clear
        let clipped = UILabel(frame: CGRect(x: -100, y: 50, width: 100, height: 20))
        clipped.text = "PRIVATE_OFFSCREEN"
        root.addSubview(attributed); root.addSubview(transparent); root.addSubview(clipped); settle()
        let collector = try EluUIKitReplayCollector()
        let frame = try collector.collect(root: root, ordinal: 0, timestamp: 100,
            hasUnresolvedConfiguredBlockRules: false, profile: .sensitiveMask(), isCurrent: { true })
        XCTAssertFalse(frame.nodes.contains { if case .ordinaryText = $0.kind { return true }; return false })
    }

    func testSensitiveButtonUsesRenderedTitleAndMasksAttributedPrivateTitle() throws {
        let ordinary = UIButton(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        ordinary.setTitle("Continue checkout", for: .normal)
        let privateButton = UIButton(frame: CGRect(x: 0, y: 50, width: 200, height: 40))
        privateButton.setTitle("HIDDEN_UNDERLYING_TITLE", for: .normal)
        privateButton.setAttributedTitle(NSAttributedString(string: "PRIVATE_TITLE", attributes: [.foregroundColor: UIColor.clear]), for: .normal)
        root.addSubview(ordinary); root.addSubview(privateButton); settle()
        let snapshot = try EluUIKitReplayCollector().collect(root: root, ordinal: 0, timestamp: 100,
            hasUnresolvedConfiguredBlockRules: false, profile: .sensitiveMask(), isCurrent: { true })
        var encoder = try EluNativeWireframeEncoder()
        let text = String(decoding: try encoder.encode([snapshot]).data, as: UTF8.self)
        XCTAssertTrue(text.contains("Continue checkout"))
        XCTAssertFalse(text.contains("PRIVATE_TITLE"))
        XCTAssertFalse(text.contains("HIDDEN_UNDERLYING_TITLE"))
    }

    func testSensitiveProfileMasksTruncatedSuffixAndHiddenButtonLabel() throws {
        let truncated = UILabel(frame: CGRect(x: 0, y: 0, width: 50, height: 30))
        truncated.text = "Visible prefix with PRIVATE_UNRENDERED_SUFFIX"
        truncated.numberOfLines = 1; truncated.lineBreakMode = .byTruncatingTail
        let hiddenButton = UIButton(frame: CGRect(x: 0, y: 40, width: 250, height: 40))
        hiddenButton.setTitle("PRIVATE_BUTTON_LABEL", for: .normal)
        root.addSubview(truncated); root.addSubview(hiddenButton); settle()
        hiddenButton.titleLabel?.alpha = 0
        let snapshot = try EluUIKitReplayCollector().collect(root: root, ordinal: 0, timestamp: 100,
            hasUnresolvedConfiguredBlockRules: false, profile: .sensitiveMask(), isCurrent: { true })
        var encoder = try EluNativeWireframeEncoder()
        let text = String(decoding: try encoder.encode([snapshot]).data, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE_UNRENDERED_SUFFIX"))
        XCTAssertFalse(text.contains("PRIVATE_BUTTON_LABEL"))
    }

    func testSensitiveProfileReadsCompleteIntrinsicSizeLabel() throws {
        let label = UILabel()
        label.text = "Ordinary native text"; label.textColor = .black
        label.frame = CGRect(origin: .zero, size: label.intrinsicContentSize)
        root.addSubview(label); settle()
        let snapshot = try EluUIKitReplayCollector().collect(root: root, ordinal: 0, timestamp: 100,
            hasUnresolvedConfiguredBlockRules: false, profile: .sensitiveMask(), isCurrent: { true })
        XCTAssertTrue(snapshot.nodes.contains { $0.kind == .ordinaryText("Ordinary native text") })
    }

    func testSensitiveProfileReadsSystemSecondaryTextButMasksFaintGlyphColors() throws {
        window.overrideUserInterfaceStyle = .light
        let cases: [(String, UIColor, Bool, Bool)] = [
            ("Secondary native text", .secondaryLabel, false, true),
            ("Half opacity glyphs", UIColor.black.withAlphaComponent(0.5), true, true),
            ("PRIVATE_FAINT", UIColor.black.withAlphaComponent(0.49), false, false),
            ("PRIVATE_FAINT_RUN", UIColor.black.withAlphaComponent(0.49), true, false),
            ("PRIVATE_CLEAR", .clear, false, false),
            ("PRIVATE_CLEAR_RUN", .clear, true, false)
        ]
        for (index, item) in cases.enumerated() {
            let label = UILabel(frame: CGRect(x: 0, y: index * 40, width: 280, height: 30))
            if item.2 {
                label.attributedText = NSAttributedString(string: item.0, attributes: [.foregroundColor: item.1])
            } else {
                label.text = item.0; label.textColor = item.1
            }
            root.addSubview(label)
        }
        settle()
        let secondary = try XCTUnwrap(root.subviews.first as? UILabel)
        let alpha = secondary.textColor.resolvedColor(with: secondary.traitCollection).cgColor.alpha
        XCTAssertGreaterThanOrEqual(alpha, 0.5)
        XCTAssertLessThan(alpha, 1, "The regression must exercise UIKit's translucent system text")
        let snapshot = try EluUIKitReplayCollector().collect(root: root, ordinal: 0, timestamp: 100,
            hasUnresolvedConfiguredBlockRules: false, profile: .sensitiveMask(), isCurrent: { true })
        var encoder = try EluNativeWireframeEncoder()
        let text = String(decoding: try encoder.encode([snapshot]).data, as: UTF8.self)
        for item in cases { XCTAssertEqual(text.contains(item.0), item.3, item.0) }
    }

    func testSensitiveProfilePreservesOrdinaryTextAndRejectsPrivateSubtreesBeforeReading() throws {
        let ordinary = UILabel(frame: CGRect(x: 0, y: 0, width: 250, height: 30))
        ordinary.text = "Welcome to ELU"
        let privateContainer = UIView(frame: CGRect(x: 0, y: 40, width: 250, height: 40))
        let privateLabel = GetterLabel(frame: privateContainer.bounds)
        privateLabel.text = "PRIVATE_PROFILE_TEXT"
        privateContainer.addSubview(privateLabel)
        Elu.maskView(privateContainer)
        let blocked = OpaqueView(frame: CGRect(x: 0, y: 90, width: 250, height: 50))
        let blockedLabel = UILabel(frame: blocked.bounds)
        blockedLabel.text = "BLOCKED_CONTENT"
        blocked.addSubview(blockedLabel)
        Elu.blockView(blocked)
        let input = GetterField(frame: CGRect(x: 0, y: 150, width: 250, height: 30))
        input.text = "PRIVATE_INPUT_VALUE"
        root.addSubview(ordinary); root.addSubview(privateContainer); root.addSubview(blocked); root.addSubview(input)
        settle()
        privateLabel.reads = 0; input.reads = 0; blocked.reads = 0
        let collector = try EluUIKitReplayCollector()
        let initial = try collector.collect(root: root, ordinal: 0, timestamp: 1_700_000_000_123,
            hasUnresolvedConfiguredBlockRules: false, profile: .sensitiveMask(), isCurrent: { true })
        XCTAssertEqual(privateLabel.reads, 0)
        XCTAssertEqual(input.reads, 0)
        XCTAssertEqual(blocked.reads, 0)
        var encoder = try EluNativeWireframeEncoder()
        let initialBytes = try encoder.encode([initial]).data
        let initialText = String(decoding: initialBytes, as: UTF8.self)
        XCTAssertTrue(initialText.contains("Welcome to ELU"))
        for secret in ["PRIVATE_PROFILE_TEXT", "BLOCKED_CONTENT", "PRIVATE_INPUT_VALUE"] {
            XCTAssertFalse(initialText.contains(secret))
        }
        ordinary.text = "Order confirmed"
        let inserted = UILabel(frame: CGRect(x: 0, y: 190, width: 250, height: 30))
        inserted.text = "Continue shopping"; root.addSubview(inserted); settle()
        let next = try collector.collect(root: root, ordinal: 1, timestamp: 1_700_000_000_124,
            hasUnresolvedConfiguredBlockRules: false, profile: .sensitiveMask(), isCurrent: { true })
        let changed = String(decoding: try encoder.encode([next]).data, as: UTF8.self)
        XCTAssertTrue(changed.contains("Order confirmed"))
        XCTAssertTrue(changed.contains("Continue shopping"))
        XCTAssertFalse(changed.contains("Welcome to ELU"))
    }

    func testMaskAboveCollectionRootRemainsHiddenAndBlockCannotBeWeakened() throws {
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: 200, height: 30))
        label.text = "ANCESTOR_PRIVATE"; root.addSubview(label); settle()
        Elu.maskView(try XCTUnwrap(root.superview))
        let masked = try EluUIKitReplayCollector().collect(root: root, ordinal: 0, timestamp: 1_700_000_000_123,
            hasUnresolvedConfiguredBlockRules: false, profile: .sensitiveMask(), isCurrent: { true })
        var encoder = try EluNativeWireframeEncoder()
        XCTAssertFalse(String(decoding: try encoder.encode([masked]).data, as: UTF8.self).contains("ANCESTOR_PRIVATE"))
        Elu.blockView(root)
        Elu.maskView(root)
        XCTAssertEqual(root.eluReplayRestriction, .block, "mask cannot weaken a prior block")
    }

    private func export(_ stream: String, _ values: [(EluNativeEncodedChunk, [EluNativeMaskedSnapshot])]) throws {
        guard ProcessInfo.processInfo.environment["ELU_UIKIT_FIXTURE_EXPORT"] == "1" else { return }
        guard ["secure", "clip", "scroll", "paint"].contains(stream), values.count <= 2 else { throw EluNativeEncodingError.invalidLimits }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("replay-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        for (index, value) in values.enumerated() {
            let (chunk, frames) = value
            guard chunk.data.count <= 65_536, !frames.isEmpty, frames.count <= 2 else { throw EluNativeEncodingError.byteLimit }
            let name = "\(stream)-\(index).json"
            // Exact bytes from the production N1 encoder. JSONL is a later renderer input at the root.
            try chunk.data.write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
            records.append(["file": name, "sha256": EluV1StrictCanonicalJSON.hash(chunk.data), "bytes": chunk.data.count,
                "sequence": chunk.sequence, "firstTimestamp": chunk.firstTimestamp, "lastTimestamp": chunk.lastTimestamp,
                "frames": frames.map { ["ordinal": $0.ordinal, "timestamp": $0.timestamp] }])
        }
        let manifest: [String: Any] = ["source": "actual synchronous UIKit collector then frozen N1 encoder", "stream": stream,
            "chunks": records, "payloadReserialized": false, "authorityOrCodecActivated": false]
        let metadata = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
        guard metadata.count <= 8_192 else { throw EluNativeEncodingError.byteLimit }
        try metadata.write(to: directory.appendingPathComponent("\(stream)-manifest.json"), options: .withoutOverwriting)
    }

    func testSecureAndOrdinaryContentGettersAreNeverRead() throws {
        let label = GetterLabel(frame: CGRect(x: 0, y: 0, width: 80, height: 20))
        let field = GetterField(frame: CGRect(x: 0, y: 30, width: 80, height: 20))
        let secure = GetterField(frame: CGRect(x: 0, y: 60, width: 80, height: 20))
        let text = GetterTextView(frame: CGRect(x: 0, y: 90, width: 80, height: 30))
        label.text = "PRIVATE_LABEL"; field.text = "PRIVATE_FIELD"
        secure.isSecureTextEntry = true; secure.text = "PRIVATE_SECRET"; text.text = "PRIVATE_TEXT"
        [label, field, secure, text].forEach { root.addSubview($0) }
        settle()
        label.reads = 0; field.reads = 0; secure.reads = 0; text.reads = 0
        let snapshot = try collect(EluUIKitReplayCollector())
        XCTAssertEqual([label.reads, field.reads, secure.reads, text.reads], [0, 0, 0, 0])
        XCTAssertEqual(snapshot.nodes.map(\.kind), [.rectangle, .text, .input(secure: false), .input(secure: true), .input(secure: false)])
        var encoder = try EluNativeWireframeEncoder()
        let chunk = try encoder.encode([snapshot])
        let output = String(decoding: chunk.data, as: UTF8.self)
        try export("secure", [(chunk, [snapshot])])
        XCTAssertFalse(output.contains("PRIVATE_")); XCTAssertTrue(output.contains("[masked]"))
        XCTAssertTrue(output.contains("password"))
    }

    func testOpaqueImageAndWebSubtreesAreNotInspected() throws {
        let image = GetterImage(frame: CGRect(x: 0, y: 0, width: 80, height: 30))
        let web = GetterWebView(frame: CGRect(x: 0, y: 40, width: 80, height: 30))
        let custom = OpaqueView(frame: CGRect(x: 0, y: 80, width: 80, height: 30))
        let hiddenText = GetterLabel(); hiddenText.text = "PRIVATE_CHILD"; custom.addSubview(hiddenText)
        [image, web, custom].forEach { root.addSubview($0) }
        settle(); image.reads = 0; web.reads = 0; custom.reads = 0; hiddenText.reads = 0
        let snapshot = try collect(EluUIKitReplayCollector())
        XCTAssertEqual([image.reads, web.reads, custom.reads, hiddenText.reads], [0, 0, 0, 0])
        XCTAssertEqual(snapshot.nodes.map(\.kind), [.rectangle, .placeholder, .placeholder, .placeholder])
        XCTAssertEqual(snapshot.nodes[1].style.color?.wireValue, "#ffffff")
        var encoder = try EluNativeWireframeEncoder()
        let output = String(decoding: try encoder.encode([snapshot]).data, as: UTF8.self)
        XCTAssertTrue(output.contains("Content hidden")); XCTAssertFalse(output.contains("PRIVATE_CHILD"))
    }

    func testBlockSuppressesDescendantsAndUnknownConfiguredRulesDeny() throws {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 50))
        let label = GetterLabel(frame: parent.bounds); label.text = "PRIVATE_BLOCK"; parent.addSubview(label); root.addSubview(parent)
        settle(); label.reads = 0
        let collector = try EluUIKitReplayCollector()
        let snapshot = try collect(collector, rules: [.init(view: parent, action: .block)])
        XCTAssertEqual(label.reads, 0); XCTAssertEqual(snapshot.nodes.map(\.kind), [.rectangle, .placeholder])
        error(.unresolvedBlockRule) {
            _ = try collector.collect(root: root, ordinal: 1, timestamp: 123,
                                      hasUnresolvedConfiguredBlockRules: true, isCurrent: { true })
        }
        XCTAssertEqual(label.reads, 0)
        let blockedRoot = try collect(collector, ordinal: 1, rules: [.init(view: root.superview!, action: .block)])
        XCTAssertEqual(blockedRoot.nodes.map(\.kind), [.placeholder])
    }

    func testNonclippingOverflowAndActualAncestorClip() throws {
        let parent = UIView(frame: CGRect(x: 20, y: 20, width: 40, height: 40))
        let child = UILabel(frame: CGRect(x: 30, y: 5, width: 50, height: 20))
        parent.addSubview(child); root.addSubview(parent); settle()
        let collector = try EluUIKitReplayCollector()
        let overflow = try collect(collector)
        XCTAssertEqual(overflow.nodes[2].bounds, try .init(x: 50, y: 25, width: 50, height: 20))
        XCTAssertEqual(overflow.nodes[2].clip, overflow.nodes[2].bounds)
        parent.clipsToBounds = true
        let clipped = try collect(collector, ordinal: 1)
        XCTAssertEqual(clipped.nodes[2].clip, try .init(x: 50, y: 25, width: 10, height: 20))
        XCTAssertEqual(clipped.nodes[2].identity, overflow.nodes[2].identity)
        var encoder = try EluNativeWireframeEncoder()
        let first = try encoder.encode([overflow]); let second = try encoder.encode([clipped])
        try export("clip", [(first, [overflow]), (second, [clipped])])
    }

    func testScrollUsesAbsoluteGeometryAndReplacementRetainsIDs() throws {
        let scroll = UIScrollView(frame: CGRect(x: 10, y: 20, width: 100, height: 80))
        scroll.contentSize = CGSize(width: 100, height: 300)
        let label = UILabel(frame: CGRect(x: 5, y: 50, width: 50, height: 30))
        scroll.addSubview(label); root.addSubview(scroll); settle()
        let collector = try EluUIKitReplayCollector()
        let first = try collect(collector)
        scroll.contentOffset = CGPoint(x: 0, y: 60)
        let second = try collect(collector, ordinal: 1)
        let firstLabel = try XCTUnwrap(first.nodes.first(where: { $0.kind == .text }))
        let secondLabel = try XCTUnwrap(second.nodes.first(where: { $0.kind == .text }))
        XCTAssertEqual(secondLabel.identity, firstLabel.identity)
        XCTAssertEqual(secondLabel.bounds.y, 10); XCTAssertEqual(secondLabel.clip.y, 20); XCTAssertEqual(secondLabel.clip.height, 20)
        var encoder = try EluNativeWireframeEncoder()
        let initial = try encoder.encode([first]); let chunk = try encoder.encode([second])
        try export("scroll", [(initial, [first]), (chunk, [second])])
        let events = try XCTUnwrap(JSONSerialization.jsonObject(with: chunk.data) as? [[String: Any]])
        XCTAssertEqual(events[0]["type"] as? Int, 2)
    }

    func testHiddenRemovalAndWeakIdentityNeverRetainOrReuse() throws {
        // First prove this fixture releases UIKit's own transient retention.
        let baseline = autoreleasepool { () -> WeakViewBox in
            let label = UILabel(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
            root.addSubview(label); settle()
            let reference = WeakViewBox(label)
            label.removeFromSuperview(); settle()
            return reference
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertNil(baseline.view, "UIKit baseline must release before attributing retention to the collector")
        let collector = try EluUIKitReplayCollector()
        let retainedProjection = try autoreleasepool { () throws -> WeakViewBox in
            let child = UILabel(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
            root.addSubview(child); settle()
            let first = try collect(collector)
            child.isHidden = true
            XCTAssertEqual(try collect(collector, ordinal: 1).nodes.count, 1)
            child.isHidden = false
            let third = try collect(collector, ordinal: 2)
            XCTAssertNotEqual(third.nodes[1].identity, first.nodes[1].identity)
            let reference = WeakViewBox(child)
            child.removeFromSuperview(); settle()
            return reference
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        // The collector remains alive and still has its last projection entry;
        // no subsequent collect is allowed to purge it before this assertion.
        XCTAssertNil(retainedProjection.view)
        XCTAssertEqual(try collect(collector, ordinal: 3).nodes.count, 1)
    }

    func testWithdrawalIsImmediateAndFailedCollectionDoesNotPublishIdentities() throws {
        let child = UILabel(frame: CGRect(x: 0, y: 0, width: 20, height: 20)); root.addSubview(child); settle()
        let repeated = UUID(); var generated = 0
        let collector = try EluUIKitReplayCollector(identity: { generated += 1; return generated == 1 || generated == 3 ? repeated : UUID() })
        var calls = 0
        error(.withdrawn) { _ = try collect(collector, current: { calls += 1; return calls < 5 }) }
        // A rejected collection has no committed projection; repeating its first UUID remains legal.
        generated = 2
        _ = try collect(collector)
        collector.withdraw()
        error(.withdrawn) { _ = try collect(collector, ordinal: 1) }
    }

    func testWithdrawInsideCurrentCallbackCannotCommit() throws {
        let collector = try EluUIKitReplayCollector()
        error(.withdrawn) { _ = try collect(collector, current: { collector.withdraw(); return true }) }
        error(.withdrawn) { _ = try collect(collector) }
    }

    func testDepthViewAndLifetimeLimitsAreBounded() throws {
        let parent = UIView(frame: root.bounds); let child = UIView(frame: root.bounds)
        parent.addSubview(child); root.addSubview(parent); settle()
        error(.treeLimit) { _ = try collect(EluUIKitReplayCollector(maximumViews: 2)) }
        error(.treeLimit) { _ = try collect(EluUIKitReplayCollector(maximumDepth: 2)) }
        parent.removeFromSuperview()
        let collector = try EluUIKitReplayCollector(maximumViews: 1, maximumLifetimeIdentities: 1)
        _ = try collect(collector)
        let alternate = UIView(frame: root.frame); root.superview!.addSubview(alternate)
        error(.treeLimit) { _ = try collector.collect(root: alternate, ordinal: 1, timestamp: 123, hasUnresolvedConfiguredBlockRules: false, isCurrent: { true }) }
    }

    func testDuplicateGeneratedIdentityDeniesAtomically() throws {
        root.addSubview(UILabel(frame: root.bounds)); settle()
        let duplicate = UUID(); let collector = try EluUIKitReplayCollector(identity: { duplicate })
        error(.identityCollision) { _ = try collect(collector) }
        root.subviews.forEach { $0.removeFromSuperview() }
        XCTAssertEqual(try collect(collector).nodes.count, 1)
    }

    func testFractionalViewportDetachedRootAndUnsupportedGeometryDeny() throws {
        let collector = try EluUIKitReplayCollector()
        root.bounds.size.width = 300.5
        XCTAssertThrowsError(try collect(collector)) { XCTAssertEqual($0 as? EluNativeEncodingError, .invalidViewport) }
        root.bounds.size.width = 300
        root.transform = CGAffineTransform(rotationAngle: 0.1)
        error(.unsupportedGeometry) { _ = try collect(collector) }
        root.transform = .identity; root.layer.zPosition = 1
        error(.unsupportedGeometry) { _ = try collect(collector) }
        root.layer.zPosition = 0; root.layer.mask = CALayer()
        error(.unsupportedGeometry) { _ = try collect(collector) }
        root.layer.mask = nil; root.removeFromSuperview()
        error(.invalidRoot) { _ = try collect(collector) }
    }

    func testLateRootVisibilityAndDirectLayerOpacityDeny() throws {
        var mutate = false
        let collector = try EluUIKitReplayCollector(identity: { mutate = true; return UUID() })
        error(.invalidRoot) {
            _ = try collect(collector, current: { if mutate { self.root.isHidden = true }; return true })
        }
        root.isHidden = false; root.layer.opacity = 0.5
        // UIKit reflects direct root-layer opacity through root.alpha.
        error(.invalidRoot) { _ = try collect(EluUIKitReplayCollector()) }
        root.layer.opacity = 1
        let translucent = UIView(frame: root.bounds); translucent.layer.opacity = 0.5
        root.addSubview(translucent)
        error(.unsupportedGeometry) { _ = try collect(EluUIKitReplayCollector()) }
        translucent.removeFromSuperview(); mutate = false
        let alphaCollector = try EluUIKitReplayCollector(identity: { mutate = true; return UUID() })
        error(.invalidRoot) {
            _ = try collect(alphaCollector, current: { if mutate { self.root.alpha = 0.5 }; return true })
        }
    }

    func testImmutableOriginalTimestampAndPaintOrder() throws {
        let a = UILabel(frame: CGRect(x: 20, y: 30, width: 40, height: 20))
        let b = UILabel(frame: CGRect(x: 25, y: 35, width: 40, height: 20))
        root.addSubview(a); root.addSubview(b); settle()
        let collector = try EluUIKitReplayCollector()
        let first = try collect(collector)
        root.bringSubviewToFront(a)
        let second = try collect(collector, ordinal: 1)
        XCTAssertEqual(first.timestamp, 1_700_000_000_123); XCTAssertEqual(first.ordinal, 0)
        XCTAssertEqual(first.nodes[1].bounds.x, 20)
        XCTAssertEqual(second.nodes[1].identity, first.nodes[2].identity)
        XCTAssertEqual(second.nodes[2].identity, first.nodes[1].identity)
        var encoder = try EluNativeWireframeEncoder()
        let initial = try encoder.encode([first]); let reordered = try encoder.encode([second])
        try export("paint", [(initial, [first]), (reordered, [second])])
    }
}
#endif
