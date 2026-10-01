# Consumer compile fixtures

These targets compile the supported facade from representative UIKit and SwiftUI
call sites. The UIKit target also checks the explicit `EluReplayWindow`
scene-window constructor and alternative frame constructor. The scene example
replaces an application's existing window construction and preserves its root,
stored window and key-window setup; it does not add a second window. The frame
example returns an unshown alternative window. Neither constructor grants replay
authority or changes the production v1-only capability advertisement.

The fixtures do not execute backend requests or define automatic SwiftUI screen
semantics. CI builds both for an iOS Simulator destination; compilation does not
qualify UIKit touch dispatch, scrolling or customer-player behavior.

They are intentionally libraries rather than runnable sample apps so package
resolution and source compatibility can be checked without signing.
