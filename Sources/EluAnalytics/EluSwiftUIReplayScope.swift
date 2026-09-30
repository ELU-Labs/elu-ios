#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Explicit privacy declarations for one original mounted SwiftUI root.
///
/// This surface does not enable recording. The declared-region capture policy
/// and transport are not installed in the runtime yet. Every input and private
/// or unsupported painted region must be declared and wrapped before display.
/// Native `privacySensitive()` and arbitrary inputs are not discovered.
///
/// Keep one scope for the lifetime of the root. Its required identifiers cannot
/// be retired by removing a view. Missing, duplicate or stale bindings reject
/// the complete frame. Invalid declarations also leave capture unavailable.
@MainActor
public final class EluSwiftUIReplayScope: ObservableObject {
    let registry: EluSwiftUIReplayRegistry

    /// Identifiers are local binding keys, never replay content. At most 64
    /// distinct, nonempty identifiers of at most 128 UTF-8 bytes are supported.
    public init(requiredRegions: Set<String>) {
        registry = EluSwiftUIReplayRegistry(requiredRegions: requiredRegions)
    }
}

public extension View {
    /// Declares the original area to capture; never constructs a second graph.
    /// Do not apply effects or private overlays outside the registered wrappers.
    @MainActor
    func eluReplayRoot(_ scope: EluSwiftUIReplayScope) -> some View {
        clipped().background(EluSwiftUIReplayMarker(scope: scope, region: nil)
            .allowsHitTesting(false).accessibility(hidden: true))
    }

    /// Removes all paint within this declared region from retained replay.
    /// Unlike readable wireframe masking, this raster wrapper erases the whole
    /// region. Put effects/overlays inside the wrapper so its clip contains them.
    @MainActor
    func eluMask(_ scope: EluSwiftUIReplayScope, region: String) -> some View {
        clipped().background(EluSwiftUIReplayMarker(scope: scope, region: region)
            .allowsHitTesting(false).accessibility(hidden: true))
    }

    /// Excludes the declared region's paint with the same fixed placeholder as
    /// `eluMask`. Unregistered content is not automatically classified as safe.
    @MainActor
    func eluBlock(_ scope: EluSwiftUIReplayScope, region: String) -> some View {
        clipped().background(EluSwiftUIReplayMarker(scope: scope, region: region)
            .allowsHitTesting(false).accessibility(hidden: true))
    }
}

@MainActor
private struct EluSwiftUIReplayMarker: UIViewRepresentable {
    let scope: EluSwiftUIReplayScope
    let region: String?

    func makeUIView(context: Context) -> EluSwiftUIReplayMarkerView {
        EluSwiftUIReplayMarkerView(region: region, registry: scope.registry)
    }

    func updateUIView(_ view: EluSwiftUIReplayMarkerView, context: Context) {
        // SwiftUI can reuse a representable when its inputs change. The old
        // binding must be invalidated even if the final rectangle is identical.
        view.bind(region: region, registry: scope.registry)
    }

    static func dismantleUIView(_ view: EluSwiftUIReplayMarkerView, coordinator: ()) {
        view.unbind()
    }
}
#endif
