# Simulator evidence fixture

Do not store raw simulator captures in this directory. Captures referenced by
conformance case IDs must remain in external operator custody; checked-in
manifests carry only normalized outcomes and a SHA-256 digest.

Use the UIKit and SwiftUI consumer packages as the compile inputs for captures.

The executable `0.1.0`-to-candidate identity and documented session-rotation
harness is described under `UpgradeEvidence/README.md`. It uses one application
bundle and data container for both builds and never emits captured identifiers
to CI logs.
