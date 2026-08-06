# EluAnalytics for iOS

ELU product intelligence for native iOS apps. One site key, no other
configuration — behavior (privacy controls, kill switches, session replay)
is managed from your ELU dashboard and delivered as remote config.

ELU Analytics 0.1.0 exposes an ELU-owned API and currently uses PostHog's
native runtime for managed capture and ingest. You do not need a PostHog
account or key; application code should call only `Elu.*`.
This provider-backed disclosure and dependency are temporary; both must be
absent from a standalone ELU runtime release.

- Swift Package, iOS 13+
- Session replay, screen tracking, lifecycle events out of the box
- All privacy controls act on-device at capture time: masked or blocked
  content never leaves the phone

## Install (Swift Package Manager)

In Xcode: **File → Add Package Dependencies…** and enter the package URL, or
add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ELU-Labs/elu-ios.git", exact: "0.1.0"),
]
```

Then add `EluAnalytics` to your target's dependencies.

## Setup

Call once, as early as possible:

```swift
import UIKit
import EluAnalytics

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Elu.setup(siteKey: "YOUR_SITE_KEY")
        return true
    }
}
```

SwiftUI `App` lifecycle:

```swift
import SwiftUI
import EluAnalytics

@main
struct MyApp: App {
    init() {
        Elu.setup(siteKey: "YOUR_SITE_KEY")
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

That's it. Events are captured with `Elu.capture(...)`; everything else
(replay, screen views, lifecycle events) is automatic per your dashboard
settings.

On the very first launch of a fresh install the SDK fetches its config
before initializing — calls made in that window are buffered in memory and
sent once config arrives (session replay starts from the next launch).

## Identity: you own it

ELU never auto-identifies users. Link activity to your user ids explicitly —
exactly like the web snippet:

```swift
// After YOUR login / session restore succeeds:
Elu.identify("user-123", userProperties: ["plan": "pro"])

// On logout:
Elu.reset()
```

Do not identify with emails or other PII as the id; use your stable internal
user id. Before `identify`, activity is tracked anonymously and linked on the
first identify.

## Screen tracking and SwiftUI

UIKit view controllers are tracked automatically (`$screen` on
`viewDidAppear`). **SwiftUI navigation does not go through view controllers**,
so call `Elu.screen(...)` manually when a logical screen appears:

```swift
struct CheckoutView: View {
    var body: some View {
        content
            .onAppear { Elu.screen("Checkout") }
    }
}
```

Screen names feed ELU's journey analysis — instrument every screen you care
about.

## API surface

```swift
Elu.setup(siteKey:)                      Elu.capture(_:properties:)
Elu.identify(_:userProperties:)          Elu.screen(_:properties:)
Elu.reset()                              Elu.captureException(_:properties:)
Elu.alias(_:)                            Elu.register(_:) / Elu.unregister(_:)
Elu.distinctId()                         Elu.group(_:key:properties:)
Elu.setPersonProperties(_:)              Elu.flush()

Elu.getFeatureFlag(_:)                   Elu.isFeatureEnabled(_:)
Elu.getFeatureFlagPayload(_:)            Elu.reloadFeatureFlags(_:)
Elu.onFeatureFlagsLoaded(_:)             Elu.setPersonPropertiesForFlags(_:)
Elu.setGroupPropertiesForFlags(_:properties:)
```

Every method is safe to call at any time — before setup, while config is
loading, or when analytics is disabled — it never throws and never blocks.
When analytics is disabled or a device is EU-blocked, `Elu.*` event calls are
no-ops and no analytics events or replay leave the device. ELU config checks
continue so a re-enabled site can recover.

## Remote-controlled vs baked-in

Controlled from the ELU dashboard without an app update. Changes apply after
the next successful eligible config refresh; a fetch failure keeps the last
known safe config until the device can refresh again:

- Analytics on/off (kill switch)
- EU visitor blocking (`blockEu` — on by default, timezone heuristic,
  fail-closed: blocked devices send no analytics events or replay)
- Replay text/input masking, image masking
- Replay for new users only; per-session replay minute budget
- Replay sampling and minimum duration (project settings)

Baked into the binary (changes require an SDK update):

- Screen tracking and application lifecycle events: on
- Session replay screenshot mode: on (required by ELU's analysis pipeline)
- Element-interaction autocapture, surveys, push auto-capture: off
- The facade surface itself (`elu_facade_version` super property tells ELU
  what each installed binary can do)

Tightening a privacy setting takes effect immediately for live sessions
(replay stops rather than continue with looser masking); loosening applies
from the next app launch.

## Dev/staging

```swift
Elu.setup(siteKey: "YOUR_SITE_KEY",
          options: EluSetupOptions(configHost: URL(string: "https://staging.elu.dev")!))
```

Production apps should always use the default host.
