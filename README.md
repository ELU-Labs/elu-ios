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

The owned runtime records application lifecycle events automatically. Call
`Elu.screen(...)` when a logical screen appears in both UIKit and SwiftUI;
this candidate does not intercept view controller methods. For SwiftUI:

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
Elu.registerOnce(_:defaultValue:)        Elu.getFeatureFlagResult(_:)
Elu.optOut() / Elu.optIn()               Elu.isOptedOut()
Elu.distinctId()                         Elu.group(_:key:properties:)
Elu.setPersonProperties(_:)              Elu.flush()

Elu.getFeatureFlag(_:)                   Elu.isFeatureEnabled(_:)
Elu.getFeatureFlagPayload(_:)            Elu.reloadFeatureFlags(_:)
Elu.onFeatureFlagsLoaded(_:)             Elu.setPersonPropertiesForFlags(_:)
Elu.setGroupPropertiesForFlags(_:properties:)
```

`registerOnce` preserves existing properties unless they equal the supplied
default (the default sentinel is `"None"`). `getFeatureFlagResult` returns one
current snapshot with `key`, `enabled`, `variant`, and JSON-compatible `payload`;
nil means the flag is missing or unavailable.

Call `Elu.optOut()` to persist consent withdrawal. Reset/logout preserves that
choice. Call `Elu.optIn()` to restore collection subject to current remote
policy; `Elu.optIn(captureEventName: nil)` suppresses the default `$opt_in` event.
Consent set before setup takes effect when the runtime opens. Event calls made
while opted out are discarded, and queued replay is removed.

`flush()` requests a delivery attempt; it does not wait for acknowledgment or
guarantee a send before termination. Unacknowledged durable events remain for a
later eligible launch.

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

- Application lifecycle events: on; screen names: explicit `Elu.screen` calls
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

## Replay coverage in the candidate

The unpublished candidate supports bounded UIKit wireframes. When policy allows
ordinary text, supported fully visible `UILabel` and `UIButton` text remains
readable. Transparent text, attachments, links, unsupported attributed content,
and custom subclasses remain masked or opaque. All input values, including `UITextField` and `UITextView`, remain hidden. Images, web
views, custom drawing, and SwiftUI content are represented by content-free
placeholders. SwiftUI replay is not supported by this candidate.

Apply additional restrictions on the main thread before content is presented:

```swift
Elu.maskView(profileContainer) // Masks text throughout the subtree.
Elu.blockView(paymentContainer) // Excludes content and descendants.
```

Restrictions last for the view's lifetime and cannot weaken remote policy.
Unknown native blocking rules disable replay. Replay remains subject to engine,
player, privacy, and device qualification before release.

`captureException` records errors explicitly supplied by your app. Automatic
fatal-crash capture and native performance monitoring are not currently supplied.
Browser DOM, Web Vitals, and browser long-task APIs do not apply to native apps.

## SDK development

[SDK development status](docs/sdk-development-status.md) tracks validation gaps and related work.
