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

fileprivate typealias EluUIKitReplayInteractionCheck = @MainActor (UInt64, () -> UInt64) -> Bool

/// Minted only by a successful original collection. UIKit references and the
/// no-content freshness checks never leave MainActor. This is a projection,
/// not proof of a durable initial chunk or permission to install an observer.
@MainActor
final class EluUIKitReplayCollectedProjection {
    let snapshot: EluNativeMaskedSnapshot
    let eligible: Set<UUID>
    /// Private/unknown paint may extend past serialized bounds. These vetoes
    /// are interaction-only and never change the wire geometry or inspect content.
    let paintVetoes: [UUID: EluNativeRect]
    weak var root: UIView?
    weak var window: UIWindow?
    fileprivate let checks: [EluUIKitReplayInteractionCheck]
    fileprivate let currentGeometryChecks: [EluUIKitReplayInteractionCheck]
    fileprivate let scrollActivity: [@MainActor () -> Bool]
    fileprivate let profile: EluNativeMaskingProfile
    fileprivate let restrictions: [EluUIKitReplayRestriction]
    fileprivate let privacyRevision: UUID
    fileprivate let generation: UUID
    fileprivate weak var collector: EluUIKitReplayCollector?
    fileprivate init(snapshot: EluNativeMaskedSnapshot, eligible: Set<UUID>, paintVetoes: [UUID: EluNativeRect], root: UIView,
                     window: UIWindow, checks: [EluUIKitReplayInteractionCheck],
                     currentGeometryChecks: [EluUIKitReplayInteractionCheck], scrollActivity: [@MainActor () -> Bool], profile: EluNativeMaskingProfile,
                     restrictions: [EluUIKitReplayRestriction], privacyRevision: UUID,
                     generation: UUID, collector: EluUIKitReplayCollector) {
        self.snapshot = snapshot; self.eligible = eligible; self.root = root; self.window = window
        self.paintVetoes = paintVetoes
        self.checks = checks; self.currentGeometryChecks = currentGeometryChecks; self.scrollActivity = scrollActivity
        self.profile = profile; self.restrictions = restrictions; self.privacyRevision = privacyRevision; self.generation = generation
        self.collector = collector
    }
    var privacyIsCurrent: Bool { EluNativeViewPrivacy.shared.isCurrent(privacyRevision) }
    // Activity selects a bounded sampling interval only. It never proves point
    // privacy, authorizes retention, or reads text/children. Weak original views
    // cover public drag/deceleration after the physical finger lifts.
    var hasActiveScroll: Bool {
        guard collector?.ownsInteractionProjection(self) == true, privacyIsCurrent else { return false }
        return scrollActivity.contains { $0() }
    }
    func currentGeometry(deadline: UInt64, now: () -> UInt64) -> (EluNativeMaskedSnapshot, [UUID: EluNativeRect])? {
        collector?.currentInteractionGeometry(self, deadline: deadline, now: now)
    }

    func isCurrent(deadline: UInt64, now: () -> UInt64, allowingGeometry: Bool = false) -> Bool {
        guard let collector, collector.ownsInteractionProjection(self), now() <= deadline,
              EluNativeViewPrivacy.shared.isCurrent(privacyRevision), root != nil, window != nil else { return false }
        for check in (allowingGeometry ? currentGeometryChecks : checks) {
            guard now() <= deadline, check(deadline, now) else { return false }
        }
        return now() <= deadline && collector.ownsInteractionProjection(self)
            && EluNativeViewPrivacy.shared.isCurrent(privacyRevision)
    }
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
        let interactionInheritedClip: CGRect
        let masked: Bool
        let blocked: Bool
        var projectedParent: UIView? = nil
        var systemCellContent = false
    }
    private nonisolated let fence = EluUIKitCollectionFence()
    private let identity: () -> UUID
    private let maximumViews: Int
    private let maximumDepth: Int
    private let maximumLifetimeIdentities: Int
    private var projections: [ObjectIdentifier: Projection] = [:]
    private var issued: Set<UUID> = []
    private var interactionProjection: EluUIKitReplayCollectedProjection?
    private var interactionGeneration = UUID()

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
                 retainInteractionProjection: Bool = false,
                 isCurrent: () -> Bool) throws -> EluNativeMaskedSnapshot {
        try collectOriginal(root: root, ordinal: ordinal, timestamp: timestamp,
            hasUnresolvedConfiguredBlockRules: hasUnresolvedConfiguredBlockRules, restrictions: restrictions,
            profile: profile, retainInteractionProjection: retainInteractionProjection, query: nil, isCurrent: isCurrent)
    }

    private func collectOriginal(root: UIView, ordinal: Int64, timestamp: Int64,
                 hasUnresolvedConfiguredBlockRules: Bool, restrictions: [EluUIKitReplayRestriction],
                 profile: EluNativeMaskingProfile, retainInteractionProjection: Bool,
                 query: EluUIKitReplayCollectedProjection?, queryDeadline: UInt64 = .max, queryNow: () -> UInt64 = { 0 },
                 queryPaint: (([UUID: EluNativeRect]) -> Void)? = nil,
                 isCurrent: () -> Bool) throws -> EluNativeMaskedSnapshot {
        // Any new geometry collection invalidates the prior point witness. A
        // read-only current-geometry query retains the original ordinal/identity
        // and never grants a new projection or allocates an identity.
        if query == nil && (retainInteractionProjection || interactionProjection != nil) {
            interactionGeneration = UUID(); interactionProjection = nil
        }
        let viewPrivacyRevision = EluNativeViewPrivacy.shared.snapshot()
        let queryNodes = query.map { Dictionary(uniqueKeysWithValues: $0.snapshot.nodes.map { ($0.identity, $0.kind) }) }
        var interactionChecks: [EluUIKitReplayInteractionCheck] = []
        var currentGeometryChecks: [EluUIKitReplayInteractionCheck] = []
        var scrollActivity: [@MainActor () -> Bool] = []
        var interactionEligible: Set<UUID> = []
        var interactionPaintVetoes: [UUID: EluNativeRect] = [:]
        var interactionOverflow = false
        func addInteractionCheck(_ value: @escaping EluUIKitReplayInteractionCheck) {
            guard retainInteractionProjection else { return }
            guard interactionChecks.count < maximumViews * 3 + maximumDepth * 2 else {
                interactionOverflow = true; return
            }
            interactionChecks.append(value); currentGeometryChecks.append(value)
        }
        func remember(_ view: UIView) {
            if retainInteractionProjection {
                if let scroll = view as? UIScrollView, scrollActivity.count < maximumViews + maximumDepth {
                    scrollActivity.append { [weak scroll] in scroll.map { $0.isDragging || $0.isDecelerating } ?? false }
                }
                addInteractionCheck(interactionCheck(view))
                if !interactionOverflow { currentGeometryChecks[currentGeometryChecks.count - 1] = interactionCheck(view, allowingGeometry: true) }
            }
        }
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
        remember(window)
        let rootBounds = root.bounds
        let viewport = try EluNativeViewport(width: Double(rootBounds.width), height: Double(rootBounds.height))
        let viewportRect = CGRect(x: 0, y: 0, width: viewport.width, height: viewport.height)
        var inheritedClip = viewportRect, rootBlocked = false, rootMasked = !profile.allowsOrdinaryText
        var interactionInheritedClip = viewportRect
        var ancestor = root.superview, ancestorCount = 0
        var interactionBranch = root
        while let current = ancestor {
            try check(); ancestorCount += 1
            remember(current)
            if retainInteractionProjection {
                addInteractionCheck(interactionAncestorCheck(current, branch: interactionBranch, root: root))
                interactionBranch = current
            }
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
            if retainInteractionProjection, current === window || current.clipsToBounds || current.layer.masksToBounds {
                let bounds = current.convert(current.bounds, to: root).offsetBy(dx: -rootBounds.minX, dy: -rootBounds.minY)
                interactionInheritedClip = intersection(bounds, interactionInheritedClip, viewport: viewportRect)
            }
            ancestor = current.superview
        }
        var stack = [Visit(view: root, depth: 1, inheritedClip: inheritedClip,
            interactionInheritedClip: interactionInheritedClip, masked: rootMasked, blocked: rootBlocked)]
        var nodes: [EluNativeMaskedNode] = [], nextProjections: [ObjectIdentifier: Projection] = [:]
        var nextIssued = issued, visited = 0
        while let visit = stack.popLast() {
            try check()
            visited += 1
            guard visited <= maximumViews, visit.depth <= maximumDepth else { throw EluUIKitReplayCollectionError.treeLimit }
            let view = visit.view
            remember(view)
            var inheritedClip = visit.inheritedClip
            var interactionInheritedClip = visit.interactionInheritedClip
            var blocked = visit.blocked
            var masked = visit.masked
            // visibleCells is a public projection through UIKit's implementation
            // wrappers. Every actual skipped ancestor still strengthens privacy.
            var skipped = view.superview, skippedCount = 0, skippedHidden = false
            if let projectedParent = visit.projectedParent {
                while let current = skipped, current !== projectedParent {
                    try check(); skippedCount += 1
                    remember(current)
                    if retainInteractionProjection { addInteractionCheck(interactionChildrenCheck(current)) }
                    guard skippedCount + visit.depth <= maximumDepth else { throw EluUIKitReplayCollectionError.treeLimit }
                    guard current.window === window else { throw EluUIKitReplayCollectionError.invalidRoot }
                    if current.isHidden || current.alpha == 0 { skippedHidden = true; break }
                    // A cell reparented under app/custom drawing must not gain
                    // access through visibleCells. UIKit's own implementation
                    // ancestry is recognized by its public owning bundle, never
                    // by private class names or selectors.
                    guard canProjectThroughListAncestor(current) else { skippedHidden = true; break }
                    try validateGeometry(current)
                    blocked = blocked || current.alpha != 1 || current.eluReplayRestriction == .block
                        || restrictions.contains { $0.view === current && $0.action == .block }
                    masked = masked || current.eluReplayRestriction == .mask
                        || restrictions.contains { $0.view === current && $0.action == .mask }
                    if current.clipsToBounds || current.layer.masksToBounds || current is UIScrollView {
                        let clip = current.convert(current.bounds, to: root).offsetBy(dx: -rootBounds.minX, dy: -rootBounds.minY)
                        _ = try rect(clip)
                        inheritedClip = intersection(clip, inheritedClip, viewport: viewportRect)
                    }
                    if retainInteractionProjection, current.clipsToBounds || current.layer.masksToBounds {
                        let clip = current.convert(current.bounds, to: root).offsetBy(dx: -rootBounds.minX, dy: -rootBounds.minY)
                        interactionInheritedClip = intersection(clip, interactionInheritedClip, viewport: viewportRect)
                    }
                    skipped = current.superview
                }
                if skippedHidden { continue }
                guard skipped === projectedParent else { throw EluUIKitReplayCollectionError.invalidRoot }
            }
            if view.isHidden || view.alpha == 0 { continue }
            guard view.window === root.window, view.alpha.isFinite else { throw EluUIKitReplayCollectionError.invalidRoot }
            let layer = view.layer
            try validateGeometry(view)
            let converted = view.convert(view.bounds, to: root)
                .offsetBy(dx: -rootBounds.minX, dy: -rootBounds.minY)
            let bounds = try rect(converted)
            let visible = intersection(converted, inheritedClip, viewport: viewportRect)
            blocked = blocked || view.eluReplayRestriction == .block
            masked = masked || view.eluReplayRestriction == .mask
            for restriction in restrictions where restriction.view === view {
                switch restriction.action { case .block: blocked = true; case .mask: masked = true }
            }
            let kind: EluNativeMaskedKind
            let traversable: Bool
            var projectedChildren: [UIView]? = nil
            var childrenAreCellContent = false
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
                if let query {
                    kind = !masked && visible == converted ? queryKind(view, original: query, nodes: queryNodes ?? [:]) : .text
                } else {
                    kind = !masked && type(of: label) == UILabel.self && visible == converted
                        && hasVisiblePlainText(label) ? ordinaryText(label.text ?? "") : .text
                }
                traversable = false
            } else if let button = view as? UIButton, type(of: button) == UIButton.self {
                // Read the actually rendered label, never a stale underlying
                // plain title overridden by an attributed/configured title.
                let titleLabel = button.titleLabel
                if let query {
                    kind = !masked && visible == converted ? queryKind(view, original: query, nodes: queryNodes ?? [:]) : .text
                } else {
                kind = !masked && visible == converted
                    && titleLabel.map({ label in
                        label.eluReplayRestriction == nil
                            && !restrictions.contains { $0.view === label }
                            && button.bounds.contains(label.convert(label.bounds, to: button))
                            && hasVisiblePlainText(label)
                    }) == true
                    ? ordinaryText(titleLabel?.text ?? "") : .text
                }
                traversable = false
            } else if let table = view as? UITableView, type(of: table) == UITableView.self {
                kind = .rectangle; traversable = true; projectedChildren = table.visibleCells
            } else if let collection = view as? UICollectionView, type(of: collection) == UICollectionView.self {
                kind = .rectangle; traversable = true; projectedChildren = collection.visibleCells
            } else if let cell = view as? UITableViewCell, type(of: cell) == UITableViewCell.self {
                kind = .rectangle; traversable = true; projectedChildren = [cell.contentView]; childrenAreCellContent = true
            } else if let cell = view as? UICollectionViewCell, type(of: cell) == UICollectionViewCell.self {
                kind = .rectangle; traversable = true; projectedChildren = [cell.contentView]; childrenAreCellContent = true
            } else if type(of: view) == UIView.self || type(of: view) == UIWindow.self
                        || type(of: view) == UIStackView.self || type(of: view) == UIScrollView.self
                        || visit.systemCellContent {
                kind = .rectangle; traversable = true
            } else {
                // Unknown/custom-drawn/SwiftUI/video/map controls are opaque.
                kind = .placeholder; traversable = false
            }
            let key = ObjectIdentifier(view)
            let projection: Projection
            if let existing = projections[key], existing.view === view { projection = existing }
            else {
                guard query == nil else { throw EluUIKitReplayCollectionError.withdrawn }
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
            if retainInteractionProjection, view !== root, !masked, !blocked, view.alpha == 1,
               visible.width > 0, visible.height > 0 {
                switch kind {
                case .rectangle: interactionEligible.insert(projection.identity)
                case let .ordinaryText(value) where value != EluNativeWireframeEncoder.mask:
                    interactionEligible.insert(projection.identity)
                    if let label = view as? UILabel, type(of: label) == UILabel.self {
                        addInteractionCheck(interactionTextIdentityCheck(label))
                    }
                default: break
                }
            }
            if retainInteractionProjection {
                let privatePaint: Bool
                switch kind {
                case .rectangle: privatePaint = masked || blocked
                case .ordinaryText: privatePaint = !interactionEligible.contains(projection.identity)
                default: privatePaint = true
                }
                if privatePaint {
                    // Do not open private/opaque children to guess their drawing
                    // extent. Only an actual clipping boundary confines paint.
                    // UIScrollView type alone is not such a boundary when the
                    // customer has disabled its clipping flags.
                    let confined = view.clipsToBounds || layer.masksToBounds
                    let veto = confined
                        ? intersection(converted, interactionInheritedClip, viewport: viewportRect)
                        : interactionInheritedClip
                    interactionPaintVetoes[projection.identity] = try rect(veto)
                }
            }
            // Buttons are one wire leaf. A later added/removed/reordered internal
            // overlay or changed title restriction cannot inherit that leaf ID.
            if retainInteractionProjection, let button = view as? UIButton, type(of: button) == UIButton.self {
                addInteractionCheck(interactionChildrenCheck(button))
                weak var title = button.titleLabel
                addInteractionCheck { [weak button] _, _ in button?.titleLabel === title }
                if let label = button.titleLabel {
                    addInteractionCheck(interactionAncestorCheck(button, branch: label, root: button))
                    remember(label)
                    addInteractionCheck(interactionTextIdentityCheck(label))
                }
            }
            if traversable {
                var clip = inheritedClip
                var interactionClip = interactionInheritedClip
                if view.clipsToBounds || layer.masksToBounds || view is UIScrollView {
                    clip = intersection(converted, clip, viewport: viewportRect)
                }
                if retainInteractionProjection, view.clipsToBounds || layer.masksToBounds {
                    interactionClip = intersection(converted, interactionClip, viewport: viewportRect)
                }
                let children = projectedChildren ?? view.subviews
                if retainInteractionProjection {
                    // Capture actual container order as well as the visible-cell
                    // projection. Unknown/custom subtrees remain unopened.
                    addInteractionCheck(interactionChildrenCheck(view))
                    if let projectedChildren {
                        // visibleCells/contentView may skip preexisting UIKit
                        // wrappers or overlays. Until their actual paint order
                        // is represented, they cannot supply touch provenance.
                        let serialized = projectedChildren.map(EluUIKitWeakInteractionView.init)
                        addInteractionCheck { [weak view] deadline, now in
                            guard let view else { return false }
                            return Self.sameInteractionViews(view.subviews, serialized, deadline: deadline, now: now)
                        }
                    }
                    if let table = view as? UITableView, type(of: table) == UITableView.self {
                        let original = table.visibleCells.map(EluUIKitWeakInteractionView.init)
                        addInteractionCheck { [weak table] deadline, now in
                            guard let table else { return false }
                            return Self.sameInteractionViews(table.visibleCells, original, deadline: deadline, now: now)
                        }
                    } else if let collection = view as? UICollectionView, type(of: collection) == UICollectionView.self {
                        let original = collection.visibleCells.map(EluUIKitWeakInteractionView.init)
                        addInteractionCheck { [weak collection] deadline, now in
                            guard let collection else { return false }
                            return Self.sameInteractionViews(collection.visibleCells, original, deadline: deadline, now: now)
                        }
                    }
                }
                guard children.count <= maximumViews - visited - stack.count else { throw EluUIKitReplayCollectionError.treeLimit }
                for child in children.reversed() {
                    stack.append(Visit(view: child, depth: visit.depth + skippedCount + 1, inheritedClip: clip,
                        interactionInheritedClip: interactionClip,
                        masked: masked, blocked: false, projectedParent: view, systemCellContent: childrenAreCellContent))
                }
            }
        }
        try check()
        guard root.window === window, root.bounds == rootBounds, !root.isHidden, root.alpha == 1,
              !window.isHidden, window.alpha == 1 else { throw EluUIKitReplayCollectionError.invalidRoot }
        let result = EluNativeMaskedSnapshot(ordinal: ordinal, timestamp: timestamp, viewport: viewport, nodes: nodes)
        if let query {
            guard ownsInteractionProjection(query), isCurrent() else {
                throw EluUIKitReplayCollectionError.withdrawn
            }
            guard !interactionOverflow else { throw EluUIKitReplayCollectionError.treeLimit }
            for check in interactionChecks {
                guard queryNow() <= queryDeadline, check(queryDeadline, queryNow) else { throw EluUIKitReplayCollectionError.withdrawn }
            }
            guard isCurrent() else { throw EluUIKitReplayCollectionError.withdrawn }
            queryPaint?(interactionPaintVetoes)
            return result
        }
        guard fence.commit({
            projections = nextProjections; issued = nextIssued
            if retainInteractionProjection, !interactionOverflow {
                interactionProjection = EluUIKitReplayCollectedProjection(snapshot: result,
                    eligible: interactionEligible, paintVetoes: interactionPaintVetoes,
                    root: root, window: window, checks: interactionChecks, currentGeometryChecks: currentGeometryChecks, scrollActivity: scrollActivity,
                    profile: profile, restrictions: restrictions, privacyRevision: viewPrivacyRevision, generation: interactionGeneration, collector: self)
            }
        }) else { throw EluUIKitReplayCollectionError.withdrawn }
        return result
    }


    /// Reuses the exact collection traversal in a no-content/no-new-ID mode.
    /// The result is descriptive current geometry; it never advances an ordinal,
    /// changes the original projection, or supplies permission to serialize it.
    fileprivate func currentInteractionGeometry(_ original: EluUIKitReplayCollectedProjection,
        deadline: UInt64, now: () -> UInt64) -> (EluNativeMaskedSnapshot, [UUID: EluNativeRect])? {
        guard original.isCurrent(deadline: deadline, now: now, allowingGeometry: true), let root = original.root else { return nil }
        var paint: [UUID: EluNativeRect] = [:]
        do {
            let frame = try collectOriginal(root: root, ordinal: original.snapshot.ordinal,
                timestamp: original.snapshot.timestamp, hasUnresolvedConfiguredBlockRules: false,
                restrictions: original.restrictions, profile: original.profile, retainInteractionProjection: true,
                query: original, queryDeadline: deadline, queryNow: now, queryPaint: { paint = $0 },
                isCurrent: { now() <= deadline && self.ownsInteractionProjection(original) && original.privacyIsCurrent })
            guard original.isCurrent(deadline: deadline, now: now, allowingGeometry: true) else { return nil }
            return (frame, paint)
        } catch { return nil }
    }

    private func queryKind(_ view: UIView, original: EluUIKitReplayCollectedProjection,
                           nodes: [UUID: EluNativeMaskedKind]) -> EluNativeMaskedKind {
        guard let prior = projections[ObjectIdentifier(view)], prior.view === view,
              original.eligible.contains(prior.identity),
              let kind = nodes[prior.identity] else { return .text }
        return kind
    }

    /// Only the exact last successful snapshot can recover its original witness.
    /// Copying snapshot values cannot invent a collector generation or view ID.
    func collectedInteractionProjection(for snapshot: EluNativeMaskedSnapshot) -> EluUIKitReplayCollectedProjection? {
        guard let value = interactionProjection, value.snapshot == snapshot,
              ownsInteractionProjection(value) else { return nil }
        return value
    }

    fileprivate func ownsInteractionProjection(_ value: EluUIKitReplayCollectedProjection) -> Bool {
        fence.current() && interactionProjection === value && value.collector === self
            && interactionGeneration == value.generation
    }

    private final class EluUIKitWeakInteractionView {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }
    private static func sameInteractionViews(_ current: [UIView], _ original: [EluUIKitWeakInteractionView],
                                             deadline: UInt64, now: () -> UInt64) -> Bool {
        guard current.count == original.count else { return false }
        for (view, old) in zip(current, original) {
            guard now() <= deadline, view === old.view else { return false }
        }
        return now() <= deadline
    }
    private func interactionChildrenCheck(_ view: UIView) -> EluUIKitReplayInteractionCheck {
        let current = view.subviews
        guard current.count <= maximumViews else { return { _, _ in false } }
        let children = current.map(EluUIKitWeakInteractionView.init)
        return { [weak view] deadline, now in
            guard let view else { return false }
            return Self.sameInteractionViews(view.subviews, children, deadline: deadline, now: now)
        }
    }

    private func interactionAncestorCheck(_ parent: UIView, branch: UIView, root: UIView) -> EluUIKitReplayInteractionCheck {
        let order = interactionChildrenCheck(parent)
        return { [weak parent, weak branch, weak root] deadline, now in
            guard let parent, let branch, root != nil, order(deadline, now) else { return false }
            for sibling in parent.subviews where sibling !== branch {
                guard now() <= deadline else { return false }
                // Outside-root/one-leaf content has no serialized target or
                // trustworthy draw extent. Even a hit-test-transparent sibling
                // cannot inherit this branch's interaction witness.
                guard sibling.isHidden || sibling.alpha == 0 else { return false }
            }
            return now() <= deadline
        }
    }

    private func interactionTextIdentityCheck(_ label: UILabel) -> EluUIKitReplayInteractionCheck {
        // UILabel copy-owns this immutable backing value. No text/attributes are
        // read here: a changed or released value refuses the old readable ID.
        weak var originalText = label.attributedText
        weak var originalFont = label.font
        let alignment = label.textAlignment, lineBreak = label.lineBreakMode, lines = label.numberOfLines
        let shrink = label.adjustsFontSizeToFitWidth, tighten = label.allowsDefaultTighteningForTruncation
        let size = label.bounds.size
        let highlighted = label.isHighlighted
        let color = highlighted ? (label.highlightedTextColor ?? label.textColor) : label.textColor
        let alpha = color?.resolvedColor(with: label.traitCollection).cgColor.alpha
        return { [weak label] _, _ in
            guard let label, let originalText, originalFont != nil,
                  label.attributedText === originalText, label.font === originalFont, label.bounds.size == size,
                  label.textAlignment == alignment, label.lineBreakMode == lineBreak,
                  label.numberOfLines == lines, label.adjustsFontSizeToFitWidth == shrink,
                  label.allowsDefaultTighteningForTruncation == tighten, label.isHighlighted == highlighted else { return false }
            let current = highlighted ? (label.highlightedTextColor ?? label.textColor) : label.textColor
            return current?.resolvedColor(with: label.traitCollection).cgColor.alpha == alpha
        }
    }

    /// This base stamp reads geometry, hierarchy and explicit restrictions only.
    /// It invokes no text/input/image/accessibility getter or hitTest callback.
    private func interactionCheck(_ view: UIView, allowingGeometry: Bool = false) -> EluUIKitReplayInteractionCheck {
        weak var originalParent = view.superview
        weak var originalWindow = view.window
        let hadParent = view.superview != nil, hadWindow = view.window != nil
        let bounds = view.bounds, center = view.center, transform = view.transform
        let hidden = view.isHidden, alpha = view.alpha, clips = view.clipsToBounds
        let restriction = view.eluReplayRestriction
        let layer = view.layer
        let layerTransform = layer.transform, sublayerTransform = layer.sublayerTransform
        let z = layer.zPosition, opacity = layer.opacity, masks = layer.masksToBounds
        let radius = layer.cornerRadius, hadMask = layer.mask != nil
        let animationKeys = layer.animationKeys() ?? []
        let zoom = (view as? UIScrollView)?.zoomScale
        let offset = (view as? UIScrollView)?.contentOffset
        return { [weak view] _, _ in
            guard let view, (!hadParent || originalParent != nil), (!hadWindow || originalWindow != nil),
                  view.superview === originalParent, view.window === originalWindow,
                  (allowingGeometry || view.bounds == bounds && view.center == center), view.transform == transform,
                  view.isHidden == hidden, view.alpha == alpha, view.clipsToBounds == clips,
                  view.eluReplayRestriction == restriction else { return false }
            let current = view.layer
            return CATransform3DEqualToTransform(current.transform, layerTransform)
                && CATransform3DEqualToTransform(current.sublayerTransform, sublayerTransform)
                && current.zPosition == z && current.opacity == opacity && current.masksToBounds == masks
                && current.cornerRadius == radius && (current.mask != nil) == hadMask
                && (current.animationKeys() ?? []) == animationKeys
                && (view as? UIScrollView)?.zoomScale == zoom && (allowingGeometry || (view as? UIScrollView)?.contentOffset == offset)
        }
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
        return visible && allTextFits(attributed, in: label)
    }

    /// UILabel may truncate inside a fully visible view. A bounded public
    /// TextKit layout must account for every character and glyph without a
    /// clipped or truncated line before the original string can leave UIKit.
    private func allTextFits(_ attributed: NSAttributedString, in label: UILabel) -> Bool {
        guard !label.adjustsFontSizeToFitWidth, !label.allowsDefaultTighteningForTruncation,
              label.bounds.width > 0, label.bounds.height > 0, let font = label.font else { return false }
        if attributed.length == 0 { return true }
        let storage = NSTextStorage(attributedString: attributed)
        let range = NSRange(location: 0, length: storage.length)
        attributed.enumerateAttributes(in: range) { attributes, run, _ in
            if attributes[.font] == nil { storage.addAttribute(.font, value: font, range: run) }
            if attributes[.paragraphStyle] == nil {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = label.textAlignment; paragraph.lineBreakMode = label.lineBreakMode
                storage.addAttribute(.paragraphStyle, value: paragraph, range: run)
            }
        }
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: label.bounds.size)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = label.numberOfLines
        container.lineBreakMode = label.lineBreakMode
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(for: container)
        guard glyphs.location == 0, glyphs.length == manager.numberOfGlyphs,
              manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil) == range else { return false }
        let available = CGRect(origin: .zero, size: label.bounds.size)
        var complete = true
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, line, stop in
            if !available.contains(used) || manager.truncatedGlyphRange(inLineFragmentForGlyphAt: line.location).location != NSNotFound {
                complete = false; stop.pointee = true
            }
        }
        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
        return complete && available.contains(bounds)
    }

    private func ordinaryText(_ text: String) -> EluNativeMaskedKind {
        // Refuse oversized content as one unit rather than retaining a prefix.
        text.utf8.count <= 4_096 ? .ordinaryText(text) : .placeholder
    }

    private func canProjectThroughListAncestor(_ view: UIView) -> Bool {
        if type(of: view) == UIView.self || type(of: view) == UIStackView.self
            || type(of: view) == UIScrollView.self { return true }
        if view is UIControl || view is UILabel || view is UITextView || view is UIImageView
            || view is WKWebView || view is UIVisualEffectView { return false }
        return Bundle(for: type(of: view)).bundleURL == Bundle(for: UIView.self).bundleURL
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
