#if canImport(UIKit)
import Foundation
import UIKit
import WebKit

/// These are local strengthening annotations, never a remote rule interpreter or
/// capture permission. Actual source/profile/session authority belongs to the owner.
@MainActor
struct EluUIKitReplayRestriction {
    enum Action { case mask, block }
    weak var view: UIView?
    let action: Action
    init(view: UIView, action: Action) { self.view = view; self.action = action }
}

enum EluUIKitReplayCollectionError: Error, Equatable {
    case withdrawn
    case unresolvedBlockRule
    case invalidRoot
    case unsupportedGeometry
    case treeLimit
    case identityCollision
}

private final class EluUIKitCollectionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func withdraw() { lock.lock(); active = false; lock.unlock() }
    func current() -> Bool { lock.lock(); defer { lock.unlock() }; return active }
    func commit(_ apply: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }; apply(); return true
    }
}

/// A synchronous main-thread collector of policy-filtered geometry and native text.
/// Input values, images, web views, and opaque drawing never enter snapshots.
@MainActor
final class EluUIKitReplayCollector {
    private struct Projection {
        weak var view: UIView?
        let identity: UUID
    }
    private struct Visit {
        let view: UIView
        let depth: Int
        let inheritedClip: CGRect
        let masked: Bool
        let blocked: Bool
    }
    private nonisolated let fence = EluUIKitCollectionFence()
    private let identity: () -> UUID
    private let maximumViews: Int
    private let maximumDepth: Int
    private let maximumLifetimeIdentities: Int
    private var projections: [ObjectIdentifier: Projection] = [:]
    private var issued: Set<UUID> = []

    init(maximumViews: Int = 9_999, maximumDepth: Int = 64,
         maximumLifetimeIdentities: Int = 99_999, identity: @escaping () -> UUID = { UUID() }) throws {
        guard (1 ... 9_999).contains(maximumViews), (1 ... 64).contains(maximumDepth),
              (maximumViews ... 99_999).contains(maximumLifetimeIdentities)
        else { throw EluUIKitReplayCollectionError.treeLimit }
        self.maximumViews = maximumViews; self.maximumDepth = maximumDepth
        self.maximumLifetimeIdentities = maximumLifetimeIdentities; self.identity = identity
    }

    /// Immediate local cancellation; no main-queue wait or lock across UIKit work.
    nonisolated func withdraw() { fence.withdraw() }

    func collect(root: UIView, ordinal: Int64, timestamp: Int64,
                 hasUnresolvedConfiguredBlockRules: Bool,
                 restrictions: [EluUIKitReplayRestriction] = [],
                 profile: EluNativeMaskingProfile = .blanketMask(),
                 isCurrent: () -> Bool) throws -> EluNativeMaskedSnapshot {
        let viewPrivacyRevision = EluNativeViewPrivacy.shared.snapshot()
        func check() throws {
            guard EluNativeViewPrivacy.shared.isCurrent(viewPrivacyRevision), fence.current(), isCurrent(), fence.current() else { throw EluUIKitReplayCollectionError.withdrawn }
        }
        try check()
        guard !hasUnresolvedConfiguredBlockRules else { throw EluUIKitReplayCollectionError.unresolvedBlockRule }
        guard restrictions.count <= 128 else { throw EluUIKitReplayCollectionError.treeLimit }
        guard ordinal >= 0, ordinal < EluNativeWireframeEncoder.maximumSafeInteger,
              (1 ... EluNativeWireframeEncoder.maximumSafeInteger).contains(timestamp)
        else { throw EluNativeEncodingError.invalidTimestamp }
        guard let window = root.window, !window.isHidden, window.alpha == 1,
              !root.isHidden, root.alpha == 1 else { throw EluUIKitReplayCollectionError.invalidRoot }
        let rootBounds = root.bounds
        let viewport = try EluNativeViewport(width: Double(rootBounds.width), height: Double(rootBounds.height))
        let viewportRect = CGRect(x: 0, y: 0, width: viewport.width, height: viewport.height)
        var inheritedClip = viewportRect, rootBlocked = false, rootMasked = !profile.allowsOrdinaryText
        var ancestor = root.superview, ancestorCount = 0
        while let current = ancestor {
            try check(); ancestorCount += 1
            guard ancestorCount <= maximumDepth else { throw EluUIKitReplayCollectionError.treeLimit }
            guard !current.isHidden, current.alpha == 1 else { throw EluUIKitReplayCollectionError.invalidRoot }
            try validateGeometry(current)
            if current.eluReplayRestriction == .block || restrictions.contains(where: { $0.view === current && $0.action == .block }) { rootBlocked = true }
            if current.eluReplayRestriction == .mask || restrictions.contains(where: { $0.view === current && $0.action == .mask }) { rootMasked = true }
            if current === window || current.clipsToBounds || current.layer.masksToBounds || current is UIScrollView {
                let bounds = current.convert(current.bounds, to: root).offsetBy(dx: -rootBounds.minX, dy: -rootBounds.minY)
                _ = try rect(bounds)
                inheritedClip = intersection(bounds, inheritedClip, viewport: viewportRect)
            }
            ancestor = current.superview
        }
        var stack = [Visit(view: root, depth: 1, inheritedClip: inheritedClip, masked: rootMasked, blocked: rootBlocked)]
        var nodes: [EluNativeMaskedNode] = [], nextProjections: [ObjectIdentifier: Projection] = [:]
        var nextIssued = issued, visited = 0
        while let visit = stack.popLast() {
            try check()
            visited += 1
            guard visited <= maximumViews, visit.depth <= maximumDepth else { throw EluUIKitReplayCollectionError.treeLimit }
            let view = visit.view
            if view.isHidden || view.alpha == 0 { continue }
            guard view.window === root.window, view.alpha.isFinite else { throw EluUIKitReplayCollectionError.invalidRoot }
            let layer = view.layer
            try validateGeometry(view)
            let converted = view.convert(view.bounds, to: root)
                .offsetBy(dx: -rootBounds.minX, dy: -rootBounds.minY)
            let bounds = try rect(converted)
            let visible = intersection(converted, visit.inheritedClip, viewport: viewportRect)
            var blocked = visit.blocked || view.eluReplayRestriction == .block
            var masked = visit.masked || view.eluReplayRestriction == .mask
            for restriction in restrictions where restriction.view === view {
                switch restriction.action { case .block: blocked = true; case .mask: masked = true }
            }
            let kind: EluNativeMaskedKind
            let traversable: Bool
            if blocked || view.alpha != 1 {
                kind = .placeholder; traversable = false
            } else if view is UIImageView || view is WKWebView {
                kind = .placeholder; traversable = false
            } else if let field = view as? UITextField {
                // Deliberately before any value access; no branch reads a value.
                kind = .input(secure: field.isSecureTextEntry); traversable = false
            } else if let text = view as? UITextView {
                kind = .input(secure: text.isSecureTextEntry); traversable = false
            } else if let label = view as? UILabel {
                // Subclasses can expose custom-sensitive state through getters.
                // Only exact system controls are eligible for ordinary text.
                kind = !masked && type(of: label) == UILabel.self && visible == converted
                    && hasVisiblePlainText(label)
                    ? ordinaryText(label.text ?? "") : .text
                traversable = false
            } else if let button = view as? UIButton, type(of: button) == UIButton.self {
                // Read the actually rendered label, never a stale underlying
                // plain title overridden by an attributed/configured title.
                let titleLabel = button.titleLabel
                kind = !masked && visible == converted
                    && titleLabel.map({ !$0.isHidden && hasVisiblePlainText($0) }) == true
                    ? ordinaryText(titleLabel?.text ?? "") : .text
                traversable = false
            } else if type(of: view) == UIView.self || type(of: view) == UIWindow.self
                        || type(of: view) == UIStackView.self || type(of: view) == UIScrollView.self {
                kind = .rectangle; traversable = true
            } else {
                // Unknown/custom-drawn/SwiftUI/video/map controls are opaque.
                kind = .placeholder; traversable = false
            }
            let key = ObjectIdentifier(view)
            let projection: Projection
            if let existing = projections[key], existing.view === view { projection = existing }
            else {
                guard nextIssued.count < maximumLifetimeIdentities else { throw EluUIKitReplayCollectionError.treeLimit }
                let value = identity()
                guard nextIssued.insert(value).inserted else { throw EluUIKitReplayCollectionError.identityCollision }
                projection = Projection(view: view, identity: value)
            }
            guard nextProjections.updateValue(projection, forKey: key) == nil else { throw EluUIKitReplayCollectionError.invalidRoot }
            // No attributed strings, accessibility, image/URL/layer contents,
            // descriptions, screenshots, or pixel access enter the snapshot.
            let style = try EluNativeStyle(color: kind == .placeholder ? .init(red: 255, green: 255, blue: 255) : nil)
            nodes.append(.init(identity: projection.identity, kind: kind, bounds: bounds, clip: try rect(visible), style: style))
            if traversable {
                var clip = visit.inheritedClip
                if view.clipsToBounds || layer.masksToBounds || view is UIScrollView {
                    clip = intersection(converted, clip, viewport: viewportRect)
                }
                let children = view.subviews
                guard children.count <= maximumViews - visited - stack.count else { throw EluUIKitReplayCollectionError.treeLimit }
                for child in children.reversed() { stack.append(Visit(view: child, depth: visit.depth + 1, inheritedClip: clip, masked: masked, blocked: false)) }
            }
        }
        try check()
        guard root.window === window, root.bounds == rootBounds, !root.isHidden, root.alpha == 1,
              !window.isHidden, window.alpha == 1 else { throw EluUIKitReplayCollectionError.invalidRoot }
        let result = EluNativeMaskedSnapshot(ordinal: ordinal, timestamp: timestamp, viewport: viewport, nodes: nodes)
        guard fence.commit({ projections = nextProjections; issued = nextIssued }) else { throw EluUIKitReplayCollectionError.withdrawn }
        return result
    }

    private func hasVisiblePlainText(_ label: UILabel) -> Bool {
        guard !label.isHidden, label.alpha == 1, (try? validateGeometry(label)) != nil else { return false }
        let color = label.isHighlighted ? (label.highlightedTextColor ?? label.textColor) : label.textColor
        guard let color else { return false }
        // UIKit secondary text uses translucent glyph color on an opaque view.
        // Keep faint/transparent glyphs private while admitting standard labels.
        guard color.resolvedColor(with: label.traitCollection).cgColor.alpha >= 0.5 else { return false }
        // UILabel synthesizes attributedText even for .text assignments. Admit
        // only its ordinary presentation attributes; links, attachments, stroke,
        // custom attributes and transparent runs stay masked as one unit.
        guard let attributed = label.attributedText else { return label.text?.isEmpty ?? true }
        guard attributed.length <= 4_096 else { return false }
        // A fully visible view can still truncate its underlying string. Keep
        // the first text profile conservative: only complete single-line text
        // that fits without wrapping or ellipsis may be serialized.
        guard attributed.string.rangeOfCharacter(from: .newlines) == nil else { return false }
        let fullSize = attributed.size()
        guard fullSize.width.isFinite, fullSize.height.isFinite,
              fullSize.width <= label.bounds.width,
              fullSize.height <= label.bounds.height else { return false }
        let allowed: Set<NSAttributedString.Key> = [.font, .foregroundColor, .paragraphStyle, .shadow]
        var visible = true
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, _, stop in
            if !Set(attributes.keys).isSubset(of: allowed) { visible = false }
            if let raw = attributes[.foregroundColor] {
                guard let color = raw as? UIColor,
                      color.resolvedColor(with: label.traitCollection).cgColor.alpha >= 0.5 else {
                    visible = false; stop.pointee = true; return
                }
            }
            if let raw = attributes[.font], (raw as? UIFont).map({ $0.pointSize.isFinite && $0.pointSize > 0 }) != true {
                visible = false
            }
            if let raw = attributes[.paragraphStyle] {
                guard let paragraph = raw as? NSParagraphStyle,
                      paragraph.firstLineHeadIndent == 0, paragraph.headIndent == 0, paragraph.tailIndent == 0,
                      paragraph.minimumLineHeight == 0, paragraph.maximumLineHeight == 0,
                      paragraph.lineHeightMultiple == 0 else { visible = false; stop.pointee = true; return }
            }
            if !visible { stop.pointee = true }
        }
        return visible
    }

    private func ordinaryText(_ text: String) -> EluNativeMaskedKind {
        // Refuse oversized content as one unit rather than retaining a prefix.
        text.utf8.count <= 4_096 ? .ordinaryText(text) : .placeholder
    }

    private func validateGeometry(_ view: UIView) throws {
        let layer = view.layer
        guard view.transform.isIdentity, CATransform3DIsIdentity(layer.transform),
              CATransform3DIsIdentity(layer.sublayerTransform), layer.zPosition == 0, layer.opacity == 1,
              layer.mask == nil, (layer.animationKeys()?.isEmpty ?? true),
              !(layer.masksToBounds && layer.cornerRadius != 0)
        else { throw EluUIKitReplayCollectionError.unsupportedGeometry }
        if let scroll = view as? UIScrollView, scroll.zoomScale != 1 { throw EluUIKitReplayCollectionError.unsupportedGeometry }
    }

    private func rect(_ value: CGRect) throws -> EluNativeRect {
        try .init(x: Double(value.origin.x), y: Double(value.origin.y), width: Double(value.width), height: Double(value.height))
    }
    private func intersection(_ bounds: CGRect, _ inherited: CGRect, viewport: CGRect) -> CGRect {
        let value = bounds.intersection(inherited).intersection(viewport)
        if !value.isNull && !value.isInfinite { return value }
        return CGRect(x: min(viewport.maxX, max(0, bounds.minX)),
                      y: min(viewport.maxY, max(0, bounds.minY)), width: 0, height: 0)
    }
}
#endif
