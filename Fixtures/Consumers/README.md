# Consumer compile fixtures

These targets compile the `0.1.0` facade from representative UIKit and SwiftUI
call sites. They do not contact a backend or define automatic SwiftUI screen
semantics. CI builds both for an iOS Simulator destination.

They are intentionally libraries rather than runnable sample apps so package
resolution and source compatibility can be checked without signing.
