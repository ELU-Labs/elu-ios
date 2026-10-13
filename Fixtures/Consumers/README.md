# Consumer compile fixtures

Compile-only UIKit and SwiftUI consumers that CI builds to check that the public
API is usable from app code. The UIKit target also compiles both
`EluReplayWindow` constructors.

They are intentionally libraries rather than runnable sample apps so package
resolution and source compatibility can be checked without signing.
