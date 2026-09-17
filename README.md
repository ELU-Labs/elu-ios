# EluAnalytics for iOS

ELU product intelligence for native iOS apps. One site key, no other
configuration — behavior (privacy controls, kill switches, session replay)
is managed from your ELU dashboard and delivered as remote config.

This source checkout uses the ELU-owned analytics runtime and has no external
Swift package dependencies. Its standalone release is still undergoing
qualification. The published 0.1.0 release uses the previous runtime; changing
this checkout does not change that release. Application code continues to use
`Elu.*` with an ELU site key.

- Swift Package, iOS 13+
- Events, identity, feature flags, screen tracking, and lifecycle events
- Remote configuration controls whether analytics may run
- Standalone session replay remains disabled until capture, masking, stored
  readback, and final device qualification pass

## Install (Swift Package Manager)

In Xcode: **File → Add Package Dependencies…** and enter the package URL, or
add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ELU-Labs/elu-ios.git", exact: "0.1.0"),
]
```

Then add `EluAnalytics` to your target's dependencies. The version above refers
to the previous published release. For development against this unreleased
checkout, add it as a local Swift package instead; a qualified standalone
version has not yet been published.

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

Use `Elu.capture(...)` for custom events. Screen and lifecycle tracking follow
the behavior below. The standalone replay implementation is not yet enabled
for customer use.

The SDK fetches an eligible configuration before sending analytics. Calls made
while setup or configuration is pending are subject to the SDK's bounded
buffering and privacy rules. A missing, disabled, expired, or ineligible
configuration does not grant permission to send.

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

The owned runtime uses separate storage. Installing it alone does not import
the previous runtime's identity. Identity continuity is part of the migration
qualification required before a standalone rollout.

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

The facade accepts calls before setup, while config is loading, and when
analytics is disabled without throwing errors into application code.
When analytics is disabled or a device is EU-blocked, `Elu.*` event calls are
no-ops and no analytics events or replay leave the device. ELU config checks
continue so a re-enabled site can recover.

## Remote-controlled vs baked-in

Controlled from the ELU dashboard without an app update. Changes apply after
the SDK accepts the refreshed configuration. A previously accepted
configuration can authorize work only within its validity window:

- Analytics on/off (kill switch)
- EU visitor blocking (`blockEu` — on by default, timezone heuristic,
  fail-closed: blocked devices send no analytics events or replay)
- Feature flag evaluation

Replay privacy, sampling, and per-session limits are implemented in the owned
runtime but remain subject to the replay qualification gate. They do not
enable capture in this checkout.

Baked into the binary (changes require an SDK update):

- Screen tracking and application lifecycle events: on
- Standalone replay: not enabled pending qualification
- Element-interaction autocapture, surveys, push auto-capture: off
- The facade surface itself (`elu_facade_version` super property tells ELU
  what each installed binary can do)

## Dev/staging

```swift
Elu.setup(siteKey: "YOUR_SITE_KEY",
          options: EluSetupOptions(configHost: URL(string: "https://staging.elu.dev")!))
```

Production apps should always use the default host.

## SDK development

[SDK development status](docs/sdk-development-status.md) tracks validation gaps and related work.
