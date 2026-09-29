#if canImport(UIKit)
import UIKit

/// An explicit UIKit event bridge for native replay. Constructing this window
/// grants no collection permission and does not enable a replay codec.
///
/// Use this window only where the application owns its UIKit window creation.
/// The SDK observes an authorized primary touch while preserving synchronous
/// UIKit dispatch. SwiftUI-owned windows and custom UIWindow subclasses are not
/// installed automatically.
@MainActor
public final class EluReplayWindow: UIWindow {
    private var replayObserver: EluUIKitReplayTouchObserver?
    private var replayDeliveryDepth = 0
    private var pendingReplayDetach: (EluUIKitReplayTouchObserver, CheckedContinuation<Void, Never>)?

    public override func sendEvent(_ event: UIEvent) {
        replayDeliveryDepth += 1
        defer {
            replayDeliveryDepth -= 1
            if replayDeliveryDepth == 0, let (original, settled) = pendingReplayDetach {
                pendingReplayDetach = nil
                removeReplayObserver(original)
                settled.resume()
            }
        }
        if let original = replayObserver {
            original.observe(event) { super.sendEvent(event) }
        } else {
            super.sendEvent(event)
        }
    }

    /// Called only by the original capture run after known initial admission.
    /// No replacement callback, root, or authority can be adopted here.
    func installReplayObserver(_ original: EluUIKitReplayTouchObserver) -> Bool {
        guard replayDeliveryDepth == 0, replayObserver == nil, pendingReplayDetach == nil,
              original.belongs(to: self) else { return false }
        replayObserver = original
        return true
    }

    /// MainActor dispatch is synchronous. A reentrant close retains its original
    /// continuation/observer until the outermost original super delivery returns.
    /// The capture run must await this before physical/accounting settlement.
    func closeReplayObserver(_ original: EluUIKitReplayTouchObserver) async {
        original.withdraw()
        if replayDeliveryDepth == 0 { removeReplayObserver(original); return }
        await withCheckedContinuation { continuation in
            precondition(pendingReplayDetach == nil, "One original capture owner closes its observer")
            pendingReplayDetach = (original, continuation)
        }
    }

    private func removeReplayObserver(_ original: EluUIKitReplayTouchObserver) {
        if replayObserver === original { replayObserver = nil }
        original.withdraw()
    }
}
#endif
