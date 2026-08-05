# Simulator upgrade fixture

Raw simulator captures are intentionally not committed. Checked-in manifests
contain only normalized outcomes and a SHA-256 digest.

Use the UIKit and SwiftUI consumer packages as the compile inputs for captures.

The executable `0.1.0`-to-candidate identity and documented session-rotation
harness is described under `UpgradeEvidence/README.md`. It uses one application
bundle and data container for both builds and never emits captured identifiers
to logs.
