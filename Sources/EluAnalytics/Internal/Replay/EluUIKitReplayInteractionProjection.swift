#if canImport(UIKit)
import Foundation
import UIKit

/// A MainActor-only view of one original collector result. This never chooses
/// wire IDs: detached UUID/ordinal values must still pass the v2 encoder's exact
/// serialized live-node and positive-clip checks. It grants no capture authority.
@MainActor
final class EluUIKitReplayInteractionProjection {
    private let original: EluUIKitReplayCollectedProjection
    var ordinal: Int64 { original.snapshot.ordinal }
    var privacyIsCurrent: Bool { original.privacyIsCurrent }
    var window: UIWindow? { original.window }
    var root: UIView? { original.root }

    init?(collector: EluUIKitReplayCollector, snapshot: EluNativeMaskedSnapshot) {
        guard let original = collector.collectedInteractionProjection(for: snapshot) else { return nil }
        self.original = original
    }

    func containsEligibleIdentity(_ identity: UUID) -> Bool {
        original.eligible.contains(identity) && original.snapshot.nodes.contains {
            $0.identity == identity && $0.clip.width > 0 && $0.clip.height > 0
        }
    }

    func isCurrent(deadline: UInt64, now: () -> UInt64) -> Bool {
        original.isCurrent(deadline: deadline, now: now)
    }

    /// Copies no content and never calls hitTest/pointInside. The frontmost
    /// serialized leaf covering the point either proves lawful or vetoes it;
    /// an input/opaque/masked leaf cannot fall back to a parent or viewport ID.
    func point(location: CGPoint, time: EluNativeInteractionTime,
               deadline: UInt64, now: () -> UInt64) -> EluNativeInteractionPoint? {
        guard location.x.isFinite, location.y.isFinite,
              isCurrent(deadline: deadline, now: now) else { return nil }
        guard let root = original.root else { return nil }
        // UIKit locations use the root's bounds coordinate system; the
        // serialized viewport starts at zero, including scrolled bounds.
        let location = CGPoint(x: location.x - root.bounds.minX, y: location.y - root.bounds.minY)
        let frame = original.snapshot
        guard location.x >= 0, location.y >= 0,
              location.x < CGFloat(frame.viewport.width), location.y < CGFloat(frame.viewport.height) else { return nil }
        let x = Int64(location.x.rounded(.down)), y = Int64(location.y.rounded(.down))
        // A lawful leaf does not prove opaque coverage of private paint beneath
        // it. Veto every overlapping private/unknown paint footprint first,
        // regardless of hit testing or a nominal foreground rectangle.
        for clip in original.paintVetoes.values {
            guard now() <= deadline else { return nil }
            guard clip.width > 0, clip.height > 0 else { continue }
            let actualInside = Double(location.x) >= clip.x && Double(location.y) >= clip.y &&
                Double(location.x) < clip.x + clip.width && Double(location.y) < clip.y + clip.height
            let emittedInside = Double(x) >= clip.x && Double(y) >= clip.y &&
                Double(x) < clip.x + clip.width && Double(y) < clip.y + clip.height
            // Quantization must not move a lawful fractional point into private
            // paint. Never clamp it back or substitute another target.
            if actualInside || emittedInside { return nil }
        }
        for node in frame.nodes.reversed() {
            guard now() <= deadline else { return nil }
            let clip = node.clip
            guard clip.width > 0, clip.height > 0,
                  Double(location.x) >= clip.x, Double(location.y) >= clip.y,
                  Double(location.x) < clip.x + clip.width, Double(location.y) < clip.y + clip.height else { continue }
            guard original.eligible.contains(node.identity),
                  Double(x) >= clip.x, Double(y) >= clip.y,
                  Double(x) < clip.x + clip.width, Double(y) < clip.y + clip.height,
                  isCurrent(deadline: deadline, now: now) else { return nil }
            return .init(identity: node.identity, geometryOrdinal: frame.ordinal, time: time, x: x, y: y)
        }
        return nil
    }
}
#endif
