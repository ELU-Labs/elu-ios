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

/// A synchronous main-thread collector of blanket-masked geometry. It never
/// installs observers, reads values, captures pixels, or authorizes queue admission.
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
                 isCurrent: () -> Bool) throws -> EluNativeMaskedSnapshot {
        func check() throws {
            guard fence.current(), isCurrent(), fence.current() else { throw EluUIKitReplayCollectionError.withdrawn }
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
        var inheritedClip = viewportRect, rootBlocked = false
        var ancestor = root.superview, ancestorCount = 0
        while let current = ancestor {
            try check(); ancestorCount += 1
            guard ancestorCount <= maximumDepth else { throw EluUIKitReplayCollectionError.treeLimit }
            guard !current.isHidden, current.alpha == 1 else { throw EluUIKitReplayCollectionError.invalidRoot }
            try validateGeometry(current)
            if restrictions.contains(where: { $0.view === current && $0.action == .block }) { rootBlocked = true }
            if current === window || current.clipsToBounds || current.layer.masksToBounds || current is UIScrollView {
                let bounds = current.convert(current.bounds, to: root).offsetBy(dx: -rootBounds.minX, dy: -rootBounds.minY)
                _ = try rect(bounds)
                inheritedClip = intersection(bounds, inheritedClip, viewport: viewportRect)
            }
            ancestor = current.superview
        }
        var stack = [Visit(view: root, depth: 1, inheritedClip: inheritedClip, masked: true, blocked: rootBlocked)]
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
            var blocked = visit.blocked, masked = visit.masked
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
            } else if view is UILabel {
                kind = .text; traversable = false
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
            let visible = intersection(converted, visit.inheritedClip, viewport: viewportRect)
            // Scalar shape only. No text/attributedText/accessibility/title/font,
            // image/URL/layer contents, description, screenshot or pixel access.
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
