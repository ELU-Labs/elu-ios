# EluAnalytics for iOS

ELU product intelligence for native iOS apps. One site key, no other
configuration — behavior (privacy controls, kill switches, session replay)
is managed from your ELU dashboard and delivered as remote config.

This package uses the ELU-owned analytics runtime and has no external Swift
package dependencies. Customer installation and support apply to the exact
version and artifacts listed in a reviewed [GitHub release](https://github.com/ELU-Labs/elu-ios/releases)
after its required release checks have passed. A source checkout alone does not
establish release qualification. Application code uses `Elu.*` with an ELU site key.

- Swift Package, iOS 13+
- Events, identity, feature flags, screen tracking, and lifecycle events
- Remote configuration controls whether analytics may run
- Bounded UIKit replay, gated by current server qualification, configuration,
  and on-device privacy, with package and service qualification required for release

## Install (Swift Package Manager)

In Xcode: **File → Add Package Dependencies…** and enter the package URL, or
add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ELU-Labs/elu-ios.git", exact: "0.2.0"),
]
```

Then add `EluAnalytics` to your target's dependencies. Install version 0.2.0 only
when its reviewed release and matching tag are available at the link above.
Use unpublished source as a local Swift package for development.

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
the behavior below.

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

The owned runtime uses separate storage. The unused 0.1.0 release is not a
supported persisted-data import source: version 0.2.0 starts a fresh owned
installation and leaves its old files untouched. Unpublished preview databases
with import receipts are refused without deleting their database, WAL, or SHM
files. Existing supported owned-store schemas retain identity, consent, queued
records, and their ordinary schema upgrades. See [storage compatibility](docs/storage-compatibility.md).

## Screen tracking and SwiftUI

The owned runtime records application lifecycle events automatically. Call
`Elu.screen(...)` when a logical screen appears in both UIKit and SwiftUI;
the SDK does not intercept view controller methods. For SwiftUI:

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
Elu.getGroups() / Elu.resetGroups()
Elu.resetPersonPropertiesForFlags()      Elu.resetGroupPropertiesForFlags(_:)
```

`registerOnce` preserves existing properties unless they equal the supplied
default (the default sentinel is `"None"`). `getFeatureFlagResult` returns one
current snapshot with `key`, `enabled`, `variant`, and JSON-compatible `payload`;
nil means the flag is missing or unavailable.

The `identify(_:userProperties:userPropertiesOnce:)` and
`setPersonProperties(_:propertiesOnce:)` overloads can set first-write person
properties. The `ForFlags` setters and resets change only this device's flag
evaluation context; they do not send person or group property updates. Pass a
group type to reset that group's flag context, or omit it to reset all group
flag context. `resetGroups()` clears group associations and their flag context.
`getGroups()` returns the settled associations, or an empty dictionary while a
context change is pending or collection is opted out.

Call `Elu.optOut()` to persist consent withdrawal. Reset/logout preserves that
choice. Call `Elu.optIn()` to restore collection subject to current remote
policy; `Elu.optIn(captureEventName: nil)` suppresses the default `$opt_in` event.
The latest valid choice made before setup is retained in memory, then saved
before configuration or lifecycle work can authorize collection. It becomes
durable when the runtime opens; a process ending before setup cannot persist it.
The opt-in event is one normal capture attempt and is discarded if configuration
is not eligible then; it is not backfilled later. Event calls made while opted
out are discarded, and queued replay is removed.

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
runtime. The binary supports `elu-native-wireframe-v1` with gzip and
`protocol-generation-v1`; current server qualification must advertise that exact
support before configuration can authorize capture. Local consent, region,
identity, lifecycle, masking, and budget gates also apply. Optional
`replayAudience: "new-devices"` restricts replay to this installation's first
successfully captured session, even if that session was not recorded. Restart,
identify, reset, or consent changes do not make a later session eligible.
Ordinary events remain available under their own consent and config rules.
Existing stores with unknown capture history do not qualify for this restricted
audience; see [storage compatibility](docs/storage-compatibility.md). Source support does
not establish package, engine readback, or customer-player qualification.

Baked into the binary (changes require an SDK update):

- Application lifecycle events: on; screen names: explicit `Elu.screen` calls
- Native replay formats and the supported UIKit view coverage described below
- Element-interaction autocapture, surveys, push auto-capture: off
- The facade surface itself (`elu_facade_version` super property tells ELU
  what each installed binary can do)

## Dev/staging

```swift
Elu.setup(siteKey: "YOUR_SITE_KEY",
          options: EluSetupOptions(configHost: URL(string: "https://staging.elu.dev")!))
```

ELU Cloud apps use the default host. A self-hosted instance can include a path prefix:

```swift
let instance = URL(string: "https://analytics.example.com/elu")!
Elu.setup(siteKey: "YOUR_SITE_KEY",
          options: EluSetupOptions(configHost: instance, apiHost: instance))
```

Both self-hosted base URLs must match exactly and use HTTPS without an explicit
port, credentials, query, fragment or trailing-dot hostname. One trailing slash
is removed. Prefixes cannot contain empty or dot segments, encoded separators,
whitespace or control characters. The instance serves the owned
`/sdk/v2/<siteKey>/config`, `/v1/events`, `/v1/flags` and `/v2/replay` contracts
beneath that prefix: the example uses `/elu/v1/events`. Returned endpoints must
use the declared base and each maintained role path; redirects are refused.
Declaring a base does not bypass configuration, consent or delivery authorization.

Each canonical self-hosted API base has separate durable identity, consent,
feature flags and queued events/replay. Changing servers or prefixes starts a
separate installation; returning to the same normalized base reopens its own store.
Cloud installations keep their existing storage. SDK config/API requests are
excluded from the optional customer URLSession metrics, including redirects
into either configured host. Self-hosted service compatibility still requires
its own end-to-end verification.

## UIKit replay coverage

The SDK supports bounded UIKit wireframes. When policy allows
ordinary text, supported fully visible `UILabel` and `UIButton` text remains
readable when its complete layout fits, including multiline and wrapped labels.
Standard `UITableView` and `UICollectionView` instances project visible standard
cells through their public `contentView`; offscreen cells are excluded and actual
ancestor mask, block, visibility and clipping restrictions still apply. Transparent or truncated text, attachments, links, unsupported attributed content,
and custom subclasses remain masked or opaque. All input values, including `UITextField` and `UITextView`, remain hidden. Images, web
views, custom drawing, and SwiftUI content are represented by content-free
placeholders. SwiftUI replay is not supported.

Apply additional restrictions on the main thread before content is presented:

```swift
Elu.maskView(profileContainer) // Masks text throughout the subtree.
Elu.blockView(paymentContainer) // Excludes content and descendants.
```

Restrictions last for the view's lifetime and cannot weaken remote policy.
Unknown native blocking rules disable replay. Replay remains subject to engine,
player, privacy, and device qualification before release.

`captureException` records errors explicitly supplied by your app, including
bounded cause chains. It does not install a synchronous fatal-crash handler.
Optional delayed numeric OS diagnostics are described below.
Browser DOM, Web Vitals, and browser long-task APIs do not apply to native apps.

## Customer networking

Instrument requests explicitly with the session your app already owns:

```swift
let instrumented = EluURLSession(session: customerSession)
// iOS 13+: starts immediately; the returned Foundation task can be cancelled.
let task = instrumented.perform(request) { data, response, error in
    // Handle the original Foundation result on its normal completion queue.
}
// iOS 15+: preserves Foundation async cancellation and task-delegate behavior.
let (data, response) = try await instrumented.data(for: request)
```

The wrapper preserves the supplied session, delegates, request and response. It
does not intercept other clients or initialize ELU. Requests still run when
analytics is unavailable or consent is denied. Only eligible instrumented
foreground requests produce `$network_request`, with `$network_method`,
`$network_status_code`, `$network_response_time_ms`, `$network_initiator`
(`urlsession`), and `$network_failed`. HTTP error status alone is not a transport
failure. Elapsed time ends when Foundation completes the data request, including
body receipt; it is not a server-only timing measurement.

No URL, path, query, fragment, headers, bodies, response content, or error text is
recorded. Custom HTTP methods become `UNKNOWN`; SDK origins and successful
redirects to them are excluded. There are at most 200 eligible observation
attempts per process across all wrappers, including observations later discarded.
Consent, identity, context, session, foreground or configuration changes discard in-flight
telemetry. A completion does not prolong an existing session's idle timeout.
Current general analytics permission is required; the replay `captureNetwork`
setting does not grant this separate, explicitly installed analytics collector.

## Native performance

Native performance sampling is disabled by default. To opt in:

```swift
var performance = EluPerformanceOptions(enabled: true,
    sampleIntervalMilliseconds: 30_000,
    mainThreadStallThresholdMilliseconds: 250)
performance.frameCadence = true // Optional display-link callback intervals.
Elu.setup(siteKey: "YOUR_SITE_KEY", options: EluSetupOptions(performance: performance))
```

Server policy must also enable these measurements. While the app is foregrounded,
`$performance_sample` contains process physical memory footprint and completed
main-thread response stalls above the configured threshold. These are native
measurements, not JavaScript heap size or browser long tasks. A stall is counted
after the main thread recovers; no stack traces, messages, URLs, or view content
are collected. Unavailable memory readings are omitted.

With `frameCadence` enabled and server responsiveness policy permitting it,
foreground samples also include display-link callback count, interval count,
mean and maximum interval, and the count of intervals of at least 50 milliseconds.
These `$display_link_*` fields measure callback cadence; they are not rendered
frame counts, dropped frames, or Web Vitals. The observer does not change the
app's preferred frame rate. Missing, invalid or oversized windows are omitted.

Consent, identity, configuration, and lifecycle changes discard pending samples.
Intervals must be 5,000–2,147,483,647 milliseconds; the effective interval is the
slower of local and server settings. Stall thresholds must be 100–60,000
milliseconds. Invalid options disable sampling. This does not measure full app
launch time or automatically report fatal crashes.

## Delayed OS diagnostics and launch summaries

MetricKit collection is separately disabled by default:

```swift
var options = EluSetupOptions()
options.diagnostics = EluDiagnosticsOptions(enabled: true, launchSummaries: true)
Elu.setup(siteKey: "YOUR_SITE_KEY", options: options)
```

On iOS 14 and later, eligible `$native_diagnostic` events contain numeric crash,
hang, and CPU diagnostic counts and duration totals. With `launchSummaries`
enabled, `$native_launch` contains available launch/resume histogram counts and
lower/upper duration bounds from iOS 13 onward, plus numeric launch diagnostic
durations on iOS 16 onward. Launch summaries also require the current server
responsiveness permission (`capturePerformance.long_tasks`). No stack trees,
raw OS payloads, exception messages, file paths, or process metadata are read.

These are delayed, OS-scheduled interval summaries. They do not guarantee every
crash is reported or describe an individual launch when only histogram bounds
are available. The full OS interval must fit inside one persisted consent and
identity interval. First installation, an account switch, consent action,
observed capture denial, explicit SDK shutdown, changed diagnostics options, or
an invalid clock can make a report ineligible. Routine config expiry, refresh,
backgrounding, and process restart preserve known continuity; current capture
permission is still required when a report arrives. Disabling collection does
not later import reports from the disabled interval.

An accepted summary uses an existing live session at receipt time, without
creating a session, extending its idle timer, or copying groups and registered
properties. `$diagnostic_interval_start` and `$diagnostic_interval_end` identify
the historical OS interval; the receipt session is not an assertion that the
crash or launch happened in that session. Reports with uncertain ownership,
unavailable OS data, malformed values, excessive size, or duplicate intervals
are omitted. Typical use requires the app to receive an OS report after a full
eligible interval; this collector is not a live crash-stack reporter.

## SDK development

[SDK development status](docs/sdk-development-status.md) tracks validation gaps and related work.

## App privacy manifest

The package includes `PrivacyInfo.xcprivacy`. It declares the SDK's linked
analytics, manual exception, native performance/diagnostic data, and ordinary
replay text, with tracking disabled. Performance and OS diagnostics remain disabled by default;
replay still requires eligible privacy authority, and masked inputs and blocked
content are excluded. Elapsed-time clocks are used for in-app timers and duration
measurements; raw system boot time is not sent. Review your app's complete data
practices when preparing its App Store privacy disclosures.

The categories and elapsed-time reason follow Apple's
[data-type definitions](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype)
and [required API reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons).
