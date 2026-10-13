#if canImport(UIKit)
import UIKit
import ObjectiveC

private var eluReplayPrivacyKey: UInt8 = 0

extension Elu {
    /// Hide text in this view and its descendants before replay serialization.
    /// This restriction lasts for the view's lifetime and cannot loosen remote policy.
    @MainActor
    public static func maskView(_ view: UIView) {
        guard view.eluReplayRestriction == nil else { return }
        view.eluReplayRestriction = .mask
        EluNativeViewPrivacy.shared.strengthen()
    }

    /// Exclude this view's content and descendants from replay collection.
    /// Only a content-free placeholder for its bounds may be recorded.
    @MainActor
    public static func blockView(_ view: UIView) {
        guard view.eluReplayRestriction != .block else { return }
        view.eluReplayRestriction = .block
        EluNativeViewPrivacy.shared.strengthen()
    }
}

extension UIView {
    @MainActor
    var eluReplayRestriction: EluUIKitReplayRestriction.Action? {
        get {
            guard let value = objc_getAssociatedObject(self, &eluReplayPrivacyKey) as? NSNumber else { return nil }
            return value.intValue == 2 ? .block : .mask
        }
        set {
            let value = newValue.map { NSNumber(value: $0 == .block ? 2 : 1) }
            objc_setAssociatedObject(self, &eluReplayPrivacyKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
#endif
