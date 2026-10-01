# EluAnalytics for iOS

ELU product intelligence for native iOS apps. Initialize with one site key;
behavior (privacy controls, kill switches, session replay) is managed from your
ELU dashboard and delivered as remote config. Optional native integrations,
including annotated SwiftUI replay, require the explicit setup below.

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

Then add `EluAnalytics` to your target's dependencies. Version 0.2.0 is an
unreleased candidate; install it only after its reviewed release and matching
tag are available at the link above. Use unpublished source as a local Swift
package for development.

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
first identify. By default, `personProfiles` is `.identifiedOnly`: anonymous
captures do not request person-profile processing until an accepted identify,
alias, person-property change, or an event with group membership enables it.
That accepted processing state persists across relaunches until reset.
`ForFlags` context alone never enables it.

```swift
var options = EluSetupOptions()
options.personProfiles = .identifiedOnly // default; also .always or .never
Elu.setup(siteKey: "YOUR_SITE_KEY", options: options)

Elu.reset()                    // logout: new anonymous identity, same device ID
Elu.reset(resetDeviceId: true)  // also rotate the installation's device ID
```

`.always` requests person processing on every eligible event. `.never` suppresses
person processing and ignores identify, alias, and person-property calls; it
still permits group associations and evaluation-only flag context. These modes
do not grant capture permission or override consent. Reset clears user, group,
session, superproperty, flag context, and remembered profile-processing state;
it preserves consent and records already queued under their original identity.
Every new event, including native numeric telemetry, carries SDK-owned
`$device_id`, `$is_identified`, and `$process_person_profile` values. Customer
properties cannot override them, and `$epp` is never sent as an event property.

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
Elu.reset() / Elu.reset(resetDeviceId:)  Elu.captureException(_:properties:)
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

To supply an event time, use
`Elu.capture("Checkout completed", properties: ["amount": 42], timestamp: completedAt)`
with a Foundation `Date`. The timestamp must not precede persisted identity or
session activity; invalid or older times discard the entire event. Events keep
call order, so backdating an event after newer activity does not reorder it.
The overload without `timestamp` uses the runtime clock when it processes the call.

To update a person after an accepted event, use
`Elu.capture("Checkout completed", properties: ["amount": 42], options:
EluCaptureOptions(set: ["plan": "pro"], setOnce: ["firstChannel": "ios"], timestamp: completedAt))`.
`set` replaces existing person values; `setOnce` fills missing values. These maps
are separate from event properties. Rejected events do not apply them, and
`personProfiles: .never` ignores them while retaining otherwise eligible events.
The same ordered call admits the event first, then applies the person change
under the original identity and current consent. It does not reload feature flags.
These are separate durable writes: a crash, storage failure, or superseding
identity/privacy intent can leave the event without its person change. Person
changes use the runtime wall clock, not the event timestamp; a future event time
can make the following person change inadmissible. No automatic backfill occurs.

Pass `EluFeatureFlagOptions` to control one read:

```swift
let options = EluFeatureFlagOptions(sendEvent: false, fresh: true)
let variant = Elu.getFeatureFlag("checkout", options: options)
let result = Elu.getFeatureFlagResult("checkout", options: options)
let enabled = Elu.isFeatureEnabled("checkout", options: options, defaultValue: false)
```

`sendEvent: false` suppresses exposure telemetry without consuming its deduplication
entry. `fresh: true` requires the current evaluation to have been received from
the flag endpoint during this SDK owner's lifetime; it does not fetch flags or
extend expiry. Call `reloadFeatureFlags` to request an evaluation. The options
overload of `isFeatureEnabled` returns `Bool?`: an absent or unavailable flag uses
`defaultValue` (nil when omitted), while a present false value stays false.
Existing overloads retain their defaults: exposure enabled, eligible cached
values allowed, and false for unavailable `isFeatureEnabled` calls.

Read all current flags without exposure telemetry using `Elu.featureFlagSnapshot()`.
It returns nil while unavailable; a valid evaluation may contain no entries.
For load updates, retain a subscription token:

```swift
let subscription = Elu.subscribeToFeatureFlags { snapshot in
    // Main queue. Entries preserve false, variants, numbers and null.
    let checkout = snapshot.entry(forKey: "checkout")
    // snapshot.source is remote, cache or unavailable.
    // snapshot.error reports an actual transport or invalid-response failure.
}
// Later:
subscription.cancel()
```

Dropping the token also cancels. A callback already admitted may finish; queued
callbacks recheck cancellation and the original identity/configuration. Legacy
`onFeatureFlagsLoaded` remains available. Snapshot values are immutable historical
data, not permission for future reads. `flagsJSON` and `payloadsJSON` contain the
complete canonical objects, including exact Unicode keys and explicit nulls.
Startup cache alone is not an error; a failed refresh may return still-valid
cached values with an error. An unavailable callback carries no flags or response
metadata, and the synchronous getter stays nil. Neither surface emits exposures.

Exposure events (`$feature_flag_called`) are deduplicated durably by anonymous
visitor, flag key, and typed value. Relaunch, identify, consent changes, and
configuration renewal retain that history; either reset variant clears it.
Only an accepted event consumes an entry. After 4,096 distinct entries, new
exposure telemetry is suppressed until reset; flag evaluation and getters keep
working. Existing owned stores start with an empty exposure history on upgrade.

Exposure properties include the validated `$feature_flag_request_id` and
`$feature_flag_evaluated_at` (Unix milliseconds), including when an evaluation
comes from the retained cache. No customer bootstrap is accepted: compatibility
fields `$feature_flag_bootstrapped_response` and
`$feature_flag_bootstrapped_payload` are null. `$used_bootstrap_value` is true
for a retained evaluation before a remote response has been observed for that
current logical evaluation; it does not indicate customer-supplied bootstrap.
Active apps refresh configuration within five minutes, and each successful
refresh reevaluates flags even if configuration bytes are unchanged. Suspension,
network failures, and expired authority still suppress unavailable results;
refresh never extends the signed configuration's original expiry.

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

Choose analytics storage before setup:

```swift
var options = EluSetupOptions()
options.persistence = .memory // Default is .persistent.
Elu.setup(siteKey: "YOUR_SITE_KEY", options: options)
```

Memory mode uses in-memory SQLite for identity, device/session IDs, properties,
events, flags, replay, and diagnostic/exposure metadata. It writes no analytics
database or temporary analytics cache. That state is lost when this SDK owner
closes or the application process ends, so queued events cannot retry on a later
launch and flags must be fetched again. A new owner starts a new anonymous
visitor and first-capture history. This is a native process lifetime, not browser
tab/session storage.

Explicit consent is retained separately in a small consent-only file in both
modes; reset does not remove it. Both modes use the same exclusive installation
lease and site/API-base namespace. Switching to memory leaves an existing
analytics store untouched and does not import or delete it. On return to
persistent mode, a consent reconciliation transaction retires its old session,
queued replay and diagnostic continuity, even if a memory opt-out/opt-in cycle
ends with the same consent Boolean. Flags require a current evaluation context.
As with ordinary opt-out, previously admitted analytics events, device/person
identity and exposure history remain; eligible analytics backlog may resume.
An older store without an explicit consent record cannot prove an opt-in from
`optedOut == false`: memory startup records denial without reading that store.
That denial applies in either mode until your application explicitly calls
`optIn()` or `optOut()`. A fresh installation keeps the existing default consent
behavior.

A pending consent write is treated as denial on restart. Storage or queue
failure stops the current owner and retains its lease; if storage rejects every
restrictive write, the SDK cannot promise that intent survives process death.

The facade accepts calls before setup, while config is loading, and when
analytics is disabled without throwing errors into application code.
When analytics is disabled or a device is EU-blocked, `Elu.*` event calls are
no-ops and no analytics events or replay leave the device. ELU config checks
continue so a re-enabled site can recover.


### Capture rate limiting

The default site/API-base token bucket allows 10 events per second with a burst
of 100. Configure it before setup without changing existing initializer forms:

```swift
var options = EluSetupOptions()
options.rateLimiting = EluRateLimitingOptions(eventsPerSecond: 5, eventsBurstLimit: 25)
Elu.setup(siteKey: "<SITE_KEY>", options: options)
```

Positive finite fractional rates are supported; invalid values use defaults and
burst is clamped to at least the rate. Captures, screens, manual exceptions,
accepted lifecycle calls, flag exposures and native numeric telemetry share the
bucket. Identity/group/property mutations and replay chunks do not consume it.
Duplicate flag exposures are rejected before a token is taken. Current consent
and configuration are required; rate limiting never grants capture permission.

A token is taken before canonical event validation, enrichment or queue admission
and is not refunded if those later steps reject the event. Customer `Any`/`Error`
values are converted to bounded JSON before crossing into the runtime. On the
first limited call after accepted calls,
the SDK attempts one `$$client_ingestion_warning` through normal event authority
and storage, bypassing only its own limiter. Consecutive drops do not repeat it;
warning delivery is not guaranteed if consent, configuration or storage rejects it.
A customer event with that name still consumes a token. Warnings triggered by
passive native telemetry retain its existing-session requirement and do not
extend user-activity time.

Customer event filtering is selected once at setup:

```swift
var options = EluSetupOptions()
options.propertyDenylist = ["email", "internalNotes"]
options.beforeSend = { event in
    guard event.event != "Sensitive screen" else { return nil }
    var event = event
    event.properties.removeValue(forKey: "phone")
    event.set?.removeValue(forKey: "phone")
    return event
}
Elu.setup(siteKey: "YOUR_SITE_KEY", options: options)
```

The denylist removes exact top-level names after super properties and event
properties are merged. The hook then receives a detached `EluEvent` and may
replace it or return `nil`; it can deliberately re-add a denylisted property.
A thrown error, invalid value, oversized replacement or changed capture authority
drops the event without sending the unfiltered original. Callbacks are synchronous:
return promptly and do not wait for SDK work, perform networking, or access UIKit.
Runtime identity/session/version fields remain protected. Existing native event
name, timestamp and passive-session constraints still apply to replacements.

Manual capture uses the hook's `set` and `setOnce`, including maps introduced by
the hook, only after the original event is accepted. These remain separate
ordered writes and use the person mutator's wall clock. No extra flag reload is
scheduled. A dropped flag event does not consume its durable exposure marker.
Filtering covers manual events, screens, exceptions and automatic native event
producers; replay frames are governed by their separate privacy rules.

This unreleased slice does not yet apply property hooks to identify, alias, or
standalone person/group mutations. Hook-introduced person maps on automatic
events are refused with the event, rather than silently ignored. Those paths
remain required follow-on parity work before complete hook support is claimed.

Persistent mode keeps bucket state across restarts, identify, reset (including
device reset), and consent changes. Memory mode discards the bucket with the
analytics connection and does not change a dormant persistent bucket. Wall-clock
regression creates token debt; forward refill stops at the burst limit. Startup
refills/checks the bucket without consuming a token or repeating an existing
limited-state warning. Known storage read/write failures use an in-process
fallback as in the browser; a later readable durable bucket takes precedence.
An ambiguous SQL commit stops the owner instead of continuing with fresh state.

## Remote-controlled vs baked-in

Controlled from the ELU dashboard without an app update. Changes apply after
the SDK accepts the refreshed configuration. A previously accepted
configuration can authorize work only within its validity window:

- Analytics on/off (kill switch)
- EU visitor blocking (`blockEu` — on by default, timezone heuristic,
  fail-closed: blocked devices send no analytics events or replay)
- Feature flag evaluation

Replay privacy, sampling, and per-session limits are implemented in the owned
runtime. The binary supports the exact tuples `elu-native-wireframe-v1` / gzip /
`protocol-generation-v1` and `elu-native-wireframe-v2` / gzip /
`protocol-generation-v2`; current server qualification must advertise the selected
tuple before configuration can authorize capture. Local consent, region,
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
placeholders in this automatic wireframe mode. Annotated SwiftUI capture is a
separate opt-in candidate described below.

Apply additional restrictions on the main thread before content is presented:

```swift
Elu.maskView(profileContainer) // Masks text throughout the subtree.
Elu.blockView(paymentContainer) // Excludes content and descendants.
```

Restrictions last for the view's lifetime and cannot weaken remote policy.
Unknown native blocking rules disable replay. Exact-artifact local simulator,
engine, player and privacy qualification remain required before release.

### Annotated SwiftUI replay (unreleased candidate)

The candidate can capture the original displayed SwiftUI root, including its
current state and scroll position, using explicit privacy declarations. It is
not automatic input discovery. Select it before the first setup call:

```swift
var options = EluSetupOptions()
options.declaredRegionReplayEnabled = true // default: false
Elu.setup(siteKey: "YOUR_SITE_KEY", options: options)
```

Keep one scope for the original root's entire lifetime. This iOS 14+ example
uses `StateObject`; an iOS 13 host must retain the same scope itself.

```swift
@MainActor
struct RecordedRoot: View {
    @StateObject private var replay = EluSwiftUIReplayScope(
        requiredRegions: ["inputs", "private-card"])
    @State private var name = ""
    @State private var password = ""
    @State private var notes = ""

    var body: some View {
        VStack {
            Text("Public content")
            VStack {
                TextField("Name", text: $name)
                SecureField("Password", text: $password)
                TextEditor(text: $notes).frame(height: 80)
            }
            .eluMask(replay, region: "inputs")
            Text("Private card")
                .eluBlock(replay, region: "private-card")
        }
        .eluReplayRoot(replay)
    }
}
```

Declare and wrap every input, private image/content and unsupported drawing
before display, including overlays and effects inside each wrapper's clip.
Both wrappers erase their entire region in retained output. Standard SwiftUI
inputs and `.privacySensitive()` are not discovered automatically; unannotated
content may be visible. Keep required wrappers mounted around conditional
content. Removing a view or releasing its scope does not erase the original
host's required intent. Missing, duplicate, stale or ambiguous bindings reject
the whole frame. Geometry/source changes revoke the old capture. Rejected owned
buffers are cleared; candidates that fail validation are never persisted or uploaded.

The option selects one original `/sdk/v3/<siteKey>/config` source and its same
runtime/queue. It creates no grant and makes no fallback v2 fetch. The embedded
v2 configuration still governs ordinary analytics and automatic UIKit replay;
raster additionally requires an explicit compatible declared-region policy,
current consent, identity, sampling and budget. The candidate is limited to the
supported ELU issuer/replay endpoint pair; arbitrary self-hosted raster origins
or prefixes are not supported. Leaving the option false preserves v2 setup.

Capture uses one eligible original window/root, at most one frame per second,
with bounded image dimensions and request size. It adds no SwiftUI interaction
markers or automatic screen tracking; continue explicit `Elu.screen` calls.
The API remains an unreleased candidate pending exact package, engine, privacy
and customer-player qualification. The compiled consumer example and isolated
rendering checks are not release approval.

### Local replay controls

After `Elu.setup`, use the same calls from UIKit or SwiftUI application code:

```swift
Elu.stopSessionRecording()
Elu.startSessionRecording()
let isRecording = Elu.sessionRecordingStarted()
```

Stop synchronously freezes new collection. The original capture then settles
asynchronously and may seal its already captured prefix only while the original
source, identity, consent and privacy remain valid. A first chunk below the
configured minimum observed duration is discarded. Previously sealed chunks
retain their ordinary delivery/retry permission; this call neither waits for
server acknowledgement nor acts as opt-out.

Start clears only this runtime's local stop and reevaluates every normal replay
gate, including configuration, sampling, audience, budget and a supported visible
root under the selected replay mode. It cannot force recording. Status is true only for the installed,
current collector; it is false during setup, draining, local stop or withdrawal.
Calls before setup are no-ops. The local choice lasts for this runtime and does
not persist across launches; use `optOut()` for persistent consent withdrawal.
There are no URL/event/linked-flag or sampling override arguments. These controls
do not opt into annotated SwiftUI replay, add touch/gesture recording or track
screens automatically.

A visible root replacement or a viewport change ends the original capture before
starting a new replay ID under the same analytics session, sample decision and
remaining budget. Unsealed boundary frames are discarded. Transient unsupported
geometry is retried at the existing capture cadence without retaining failed
frames. A missing or presented root is observed without reading view text; recovery
stops on local stop, withdrawal or expiry and never renews configuration itself.
In automatic wireframe mode, opaque framework/custom content remains opaque. Scroll and navigation can change
visual snapshots; they do not produce touch or scroll interaction markers. Ordered
multi-stream viewport changes and player forward/backward seeking still require
end-to-end qualification; source recovery alone is not that evidence.

### Explicit UIKit interaction bridge (candidate)

The source candidate adds `EluReplayWindow` for applications that own their UIKit
window creation. Replace the existing `UIWindow` constructor in the scene
delegate, preserving the same root controller, stored window and key-window
setup. Do not create a second window:

```swift
let window = EluReplayWindow(windowScene: windowScene)
window.rootViewController = AppViewController()
self.window = window
window.makeKeyAndVisible()
```

For an application that already creates its window without scenes, the equivalent
constructor is `EluReplayWindow(frame: UIScreen.main.bounds)`; keep that
application's existing root, window ownership and presentation code. Both
construction paths run on the main actor and are included in the UIKit consumer
compile fixture.

This is an explicit window choice; the SDK does not replace existing windows,
add gesture recognizers, swizzle methods or adopt custom `UIWindow` subclasses.
The final window forwards the original `sendEvent` synchronously exactly once.
SwiftUI-owned windows and other hosts without this integration are unsupported
for interaction observation. Existing v1 wireframes do not require this window.

The local runtime supports both exact native tuples; this does not enable the
engine's default replay policy or certify either end-to-end path. The window alone
cannot enable v2, consent, recording or a public capability override. The
v2 path requires the exact locally supported tuple and original
configuration, then a known durable initial-frame commit satisfying the minimum
duration before observing coordinates. This source integration and authored tests
are not a released or end-to-end-qualified interaction feature.

The bounded primary direct-finger stream records start, at most ten movement
samples per second, and end/cancel; it does not infer clicks, recognize gestures,
or render multiple finger trails. Geometry samples at most five times per second
during contact or public scroll dragging/deceleration and once per second while
idle. Activity alone grants no point retention. Each point must be lawful in both
the current privacy hierarchy and the last ordered serialized clip/identity.
Pending old points precede fresh geometry; a continuing lawful identity can then
use the new geometry. Private/opaque crossing, unsafe clipping, changed text or
uncertain hierarchy cancels coordinates through physical lift. Opaque paint may
veto its full unclipped ancestor extent; coordinates are not clamped or assigned
a fallback target. Actual UIKit gesture delivery, useful scrolling, resource cost
and customer-player rendering remain part of the required exact-artifact local
simulator qualification. Hosted CI does not replace that gate.

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
responsiveness permission (`capturePerformance.long_tasks`). Numeric collection
reads no stack trees, raw OS payloads, exception messages, file paths, or process metadata.

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

### Individual delayed crash reports

The separate `crashReports` option adds a bounded per-report `$exception` path
for actual iOS 14+ MetricKit Mach exception/signal values. `enabled` is its parent
gate. Both report options default to `false`; enabling numeric summaries does
not grant permission to read report details:

```swift
options.diagnostics = EluDiagnosticsOptions(
    enabled: true,
    crashReports: true,
    crashReportDetails: false
)
```

This path also needs a current server `captureExceptions` grant with exactly an
empty `suppressionRules` array. Missing/false grants and any nonempty policy deny
automatic reports. This first native option is an opt-in with no local authority
override; it does not implement the browser's tri-state override. Native
control-plane grant emission is not activated by this SDK change. The option
alone cannot activate reporting under today's default server configuration.

On iOS 17+, setting `crashReportDetails: true` additionally permits the OS's
Objective-C exception name, class and composed reason, when available. These
strings can contain application data. Retained strings are limited to 256, 256
and 1,024 Unicode scalars, respectively, and each detached report to 16 KiB. These
are output bounds, not guarantees about OS getter allocation or duration. The
SDK never reads MetricKit JSON/dictionary representations, call-stack trees,
addresses, process metadata or raw reports. Missing data is marked unavailable;
there is no global interception of Swift thrown errors, Swift fatal errors or
native signals, and no promise of every crash or immediate delivery.

Reports require their own continuous local consent/identity epoch covering the
whole OS interval. Earlier numeric-only consent cannot authorize them. The
original persisted report epoch is copied under the current identity/source
fence; the OS interval is validated against it before any optional reason/name
getter runs. Current general and exception permission is rechecked when
acquiring and committing a report. This is deliberately receipt-time remote permission: it does **not**
assert that the same remote grant was valid throughout the historical interval.
Explicit report/detail withdrawal closes its epoch; routine remote expiry alone
does not reconstruct or extend local consent. The existing active receipt
session is used passively, with no new session, idle extension, groups or super
properties. `occurredAt` is receipt time; the interval properties and
`$native_crash_exact_time_available: false` explicitly avoid a fabricated crash
timestamp or historical session.

At most four crash reports in one OS callback are accepted for projection; an
oversized whole callback is rejected before detail reads. One original intake
slot remains occupied through projection and the serial SQL writes; shutdown
joins it. Report content plus occurrence number within the bounded identical
content group is deduplicated atomically with each event. This is not an OS
unique crash ID: identical reports in overlapping/subset callbacks may be
conservatively omitted. Up to 32 receipts at the latest OS interval end are
retained; older ends and new receipts after saturation are omitted. No event or
receipt is consumed by known rollback. Unknown commit retains the original lease.
Actual OS delivery is optional and cannot be forced by simulator fixtures.

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
