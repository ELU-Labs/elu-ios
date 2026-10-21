# EluAnalytics for iOS

ELU product intelligence for native iOS apps. Initialize with one site key;
behavior (privacy controls, kill switches, session replay) is managed from your
ELU dashboard and delivered as remote config. Optional native integrations,
including annotated SwiftUI replay, require the explicit setup below.

This package has no external Swift package dependencies. Install a version listed
on the [GitHub releases page](https://github.com/ELU-Labs/elu-ios/releases), where
each release has its notes. Application code uses `Elu.*` with an ELU site key.

- Swift Package, iOS 13+
- Events, identity, feature flags, screen tracking, and lifecycle events
- Remote configuration controls whether analytics may run
- Bounded UIKit session replay, controlled by remote configuration and on-device
  privacy rules

## Current release: 0.2.3

`0.2.3` is the current release. It fixes two native session replay issues:

- A recording no longer stops uploading when the service, or a proxy in front of
  it, briefly answers with an error page that is not ELU's error format, for
  example during maintenance. Those uploads now retry with backoff, and
  recordings that earlier versions held back on the device upload again within
  a day of the app updating, as long as they are less than seven days old.
- Replay now resumes when the app is relaunched or updated during a session. The
  new launch starts a new recording in the same session, under the same sampling
  decision and the same recording-length limit. A local `stopSessionRecording()`
  still lasts only until the app is relaunched.

It includes analytics, identity, sessions, durable delivery, feature flags, and
automatic device and app context on every event (see
[Identity: you own it](#identity-you-own-it)). Since 0.2.2, a custom `configHost`
must be a self-hosted instance that you also declare as `apiHost` (see
[Self-hosted instances](#self-hosted-instances)); ELU Cloud apps keep the default
host and need no change.

Since 0.2.2, the SDK no longer writes the unused `elu.firstLaunchAt` UserDefaults
key, and its privacy manifest no longer declares UserDefaults access. The privacy
manifest declares file timestamp access (`C617.1`): the SDK checks metadata only on
its own files inside the app container. Your app's aggregated privacy report changes
accordingly.

Native session replay on iOS is in preview. ELU turns it on per project through
the service configuration; the SDK version alone does not enable it. Recordings
follow your project's masking policy: by default readable UIKit text (labels,
buttons) is recorded while text inputs stay masked and images, opaque views and
web views stay blocked; with "mask all text" every text element is masked.
Masked text and input values appear as one `*` per character, so a replay shows
their length but never their content (0.2.3 and earlier show the word
`[masked]` instead). See [UIKit replay coverage](#uikit-replay-coverage).

## Install (Swift Package Manager)

In Xcode, use **File → Add Package Dependencies…**, enter
`https://github.com/ELU-Labs/elu-ios`, choose 0.2.3 or later, and add the
`EluAnalytics` library to your app target. Or add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ELU-Labs/elu-ios.git", from: "0.2.3"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "EluAnalytics", package: "elu-ios"),
        ]
    ),
]
```

Stay on the latest release to receive fixes (see [SECURITY.md](SECURITY.md)).

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
still permits group associations and flag evaluation context. These modes
do not grant capture permission or override consent. Reset clears user, group,
session, superproperty, flag context, and remembered profile-processing state;
it preserves consent and records already queued under their original identity.
Every new event, including native numeric telemetry, carries `$device_id`,
`$is_identified`, and `$process_person_profile` values set by the SDK. Your
properties cannot override them.

New events also carry library, OS, device, and app context read once at setup:
`$lib` (`elu-ios`), `$lib_version`, `$os` and `$os_name`, `$os_version`,
`$device_type`, `$device_model` (a hardware identifier such as `iPhone17,1`),
`$device_manufacturer`, `$is_emulator`, `$app_name`, `$app_version`,
`$app_build`, `$app_namespace` (the bundle identifier), `$screen_width` and
`$screen_height` (portrait points), `$locale`, and `$timezone`. Super properties
and event properties override these values, and `propertyDenylist` or
`beforeSend` can remove them. The SDK reads no advertising or vendor
identifier and no user-assigned device name.

The SDK keeps its data in its own local store. Upgrading to a newer SDK version
keeps identity, consent and queued records. The SDK never deletes or rewrites a
store it cannot open safely, such as one with an unknown schema: it refuses to
open it and leaves the database, WAL and SHM files untouched.

## Screen tracking and SwiftUI

The SDK records application lifecycle events automatically. Call
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
Elu.setup(siteKey:)                      Elu.setup(siteKey:options:)
Elu.capture(_:properties:)               Elu.capture(_:properties:timestamp:)
Elu.capture(_:properties:options:)
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
Elu.featureFlagSnapshot()                Elu.subscribeToFeatureFlags(_:)

Elu.startSessionRecording() / Elu.stopSessionRecording()
Elu.sessionRecordingStarted()
Elu.maskView(_:) / Elu.blockView(_:)
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
the flag endpoint during this SDK instance's lifetime; it does not fetch flags or
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
callbacks recheck cancellation and the original identity/configuration.
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
working. Stores from earlier SDK versions without this history start with an
empty exposure history on upgrade.

Exposure properties include the validated `$feature_flag_request_id` and
`$feature_flag_evaluated_at` (Unix milliseconds), including when an evaluation
comes from the retained cache. The SDK does not accept bootstrap flag values, so
`$feature_flag_bootstrapped_response` and `$feature_flag_bootstrapped_payload` are
null. `$used_bootstrap_value` is true when the value came from the retained cache
before a remote response for the current evaluation. Active apps refresh configuration within five
minutes, and each successful
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
database or temporary analytics cache. That state is lost when this SDK instance
shuts down or the application process ends, so queued events cannot retry on a
later launch and flags must be fetched again. A new instance starts a new anonymous
visitor and first-capture history. This is a native process lifetime, not browser
tab/session storage.

Explicit consent is retained separately in a small consent-only file in both
modes; reset does not remove it. Both modes use the same site/API-base
namespace, and only one SDK instance in the app can use it at a time. Switching to memory leaves an existing
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
failure stops the current SDK instance and keeps other SDK instances in this app
from opening the same store until the app restarts. If storage rejects every
restrictive write, the SDK cannot promise that intent survives process death.

The `Elu` API accepts calls before setup, while config is loading, and when
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
Elu.setup(siteKey: "YOUR_SITE_KEY", options: options)
```

Positive finite fractional rates are supported; invalid values use defaults and
burst is clamped to at least the rate. Captures, screens, manual exceptions,
accepted lifecycle calls, flag exposures and native numeric telemetry share the
bucket. Identity/group/property mutations and replay chunks do not consume it.
Duplicate flag exposures are rejected before a token is taken. Current consent
and configuration are required; rate limiting never grants capture permission.

A token is taken before canonical event validation, enrichment or queue admission
and is not refunded if those later steps reject the event. Your `Any`/`Error`
values are converted to bounded JSON before crossing into the runtime. On the
first limited call after accepted calls,
the SDK attempts one `$$client_ingestion_warning` through normal event authority
and storage, bypassing only its own limiter. Consecutive drops do not repeat it;
warning delivery is not guaranteed if consent, configuration or storage rejects it.
Your own event with that name still consumes a token. Warnings triggered by
passive native telemetry retain its existing-session requirement and do not
extend user-activity time.

Persistent mode keeps bucket state across restarts, identify, reset (including
device reset), and consent changes. Memory mode discards the bucket with the
analytics connection and does not change a dormant persistent bucket. Wall-clock
regression creates token debt; forward refill stops at the burst limit. Startup
refills/checks the bucket without consuming a token or repeating an existing
limited-state warning. Known storage read/write failures use an in-process
fallback as in the browser; a later readable durable bucket takes precedence.
An ambiguous SQL commit stops the SDK instance instead of continuing with fresh state.

### Event filtering

Choose event filtering once at setup:

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

Captures use the hook's `set` and `setOnce`, including maps introduced by
the hook, only after the original event is accepted. These remain separate
ordered writes and use the person mutator's wall clock. No extra flag reload is
scheduled. A dropped flag event does not consume its durable exposure marker.
Filtering covers manual events, screens, exceptions and automatic native event
producers; replay frames are governed by their separate privacy rules.

This also applies to automatic events and the rate-limit warning, while keeping
the original event's typed privacy and session constraints. A later identity,
consent, source or clock refusal can prevent the separate person write without
undoing the accepted event; `personProfiles = .never` still prevents person updates.

Identity and property calls use mutation projections through the same hook:
`$identify` takes `set`/`setOnce`; `$set` takes `properties["$set"]` and
`properties["$set_once"]`; `$groupidentify` takes `properties["$group_set"]`.
`$create_alias` can be dropped. These projections create only the existing typed
mutations, not extra events. Their name, timestamp, user/alias and group targets
cannot be changed. Returning `nil` prevents the mutation; removing all `$set`
maps makes that property update a no-op. The denylist applies to top-level merged
properties, so filter individual person fields inside the relevant maps.
Flag-only local property overrides do not pass through this hook.

## Remote-controlled vs baked-in

Controlled from the ELU dashboard without an app update. Changes apply after
the SDK accepts the refreshed configuration. A previously accepted
configuration can authorize work only within its validity window:

- Analytics on/off (kill switch)
- EU visitor blocking (`blockEu` — on by default, timezone heuristic,
  fail-closed: blocked devices send no analytics events or replay)
- Feature flag evaluation

Replay privacy, sampling, and per-session limits are applied on the device. The
SDK supports two replay formats, `elu-native-wireframe-v1` and
`elu-native-wireframe-v2` (gzip, with `protocol-generation-v1` and
`protocol-generation-v2` respectively); capture starts only after the server
configuration selects one of them. Local consent, region, identity, lifecycle,
masking, and budget rules also apply. Optional
`replayAudience: "new-devices"` restricts replay to this installation's first
successfully captured session, even if that session was not recorded. Restart,
identify, reset, or consent changes do not make a later session eligible.
Ordinary events remain available under their own consent and config rules.
Stores without a known capture history are not eligible for this restricted
audience.

Baked into the binary (changes require an SDK update):

- Application lifecycle events: on; screen names: explicit `Elu.screen` calls
- Native replay formats and the supported UIKit view coverage described below
- Element-interaction autocapture, surveys, push auto-capture: off
- The `Elu` API itself (each event's `$elu_facade_version` property tells ELU
  which API version the app was built with)

## Self-hosted instances

ELU Cloud apps use the default host and need no host options. To use a
self-hosted instance, declare it as both `configHost` and `apiHost`. The base
can include a path prefix:

```swift
let instance = URL(string: "https://analytics.example.com/elu")!
Elu.setup(siteKey: "YOUR_SITE_KEY",
          options: EluSetupOptions(configHost: instance, apiHost: instance))
```

Both self-hosted base URLs must match exactly and use HTTPS without an explicit
port, credentials, query, fragment or trailing-dot hostname. One trailing slash
is removed. Prefixes cannot contain empty or dot segments, encoded separators,
whitespace or control characters. Apart from a local loopback host in debug
builds, any other `configHost` is refused at setup. The instance serves the
`/sdk/v2/<siteKey>/config`, `/v1/events`, `/v1/flags` and `/v2/replay` endpoints
beneath that prefix: the example uses `/elu/v1/events`. Returned endpoints must
use the declared base and the standard paths above; redirects are refused.
Declaring a base does not bypass configuration, consent or delivery authorization.

Each canonical self-hosted API base has separate durable identity, consent,
feature flags and queued events/replay. Changing servers or prefixes starts a
separate installation; returning to the same normalized base reopens its own store.
Cloud installations keep their existing storage. SDK config/API requests are
excluded from the optional `EluURLSession` metrics, including redirects
into either configured host. Test a self-hosted instance end to end before you
ship an app that uses it.

## UIKit replay coverage

The SDK supports bounded UIKit wireframes. When policy allows
ordinary text, supported fully visible `UILabel` and `UIButton` text remains
readable when its complete layout fits, including multiline and wrapped labels.
Standard `UITableView` and `UICollectionView` instances project visible standard
cells through their public `contentView`; offscreen cells are excluded and actual
ancestor mask, block, visibility and clipping restrictions still apply. Transparent or truncated text, attachments, links, unsupported attributed content,
and custom subclasses remain masked or opaque. All input values, including `UITextField`, secure fields and `UITextView`, are always masked. Images, web
views, custom drawing, and SwiftUI content are represented by content-free
placeholders in this automatic wireframe mode. Annotated SwiftUI replay is a
separate opt-in, described below.

Masking keeps the length of the content, the same way web replay does:

- Masked text shows one `*` per character and keeps its spaces and line
  breaks. Truncated or clipped text is masked in full, so the length of the
  hidden part shows, but not its content.
- An input value shows one `*` per character, spaces included. This shows the
  length of what was typed, including passwords, as the device screen does.
- Very long masked text and input values are cut off after about 4,000
  characters.

To draw these shapes, the SDK reads masked text and the length of input values
on the device while it records a frame, including in "mask all text" mode. It
keeps only the `*` version: the original text is never stored, logged or sent.
Blocked views are never read.

Apply additional restrictions on the main thread before content is presented:

```swift
Elu.maskView(profileContainer) // Masks text throughout the subtree.
Elu.blockView(paymentContainer) // Excludes content and descendants.
```

Restrictions last for the view's lifetime and cannot weaken remote policy.
Unknown native blocking rules disable replay.

### Annotated SwiftUI replay (preview)

Annotated SwiftUI replay is in preview and is not available for any project
yet, so it records nothing today. While the option is on, a root marked with
`.eluReplayRoot` is also left out of automatic UIKit replay, so leave the option
off in production apps for now.

This mode captures the displayed SwiftUI root, including its current state and
scroll position, using explicit privacy declarations. It does not discover
inputs automatically. Select it before the first setup call:

```swift
var options = EluSetupOptions()
options.declaredRegionReplayEnabled = true // default: false
Elu.setup(siteKey: "YOUR_SITE_KEY", options: options)
```

Keep one scope for the root view's entire lifetime. This iOS 14+ example
uses `StateObject`; an iOS 13 host must retain the same scope itself.

```swift
@available(iOS 14.0, *)
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
content. Removing a view or releasing its scope does not remove the root's
required regions. Missing, duplicate, stale or ambiguous bindings reject
the whole frame. Geometry or configuration changes end the current capture.
Rejected frames are cleared and are never stored or uploaded.

With this option on, the SDK reads its configuration from
`/sdk/v3/<siteKey>/config` instead of `/sdk/v2/<siteKey>/config`, with no
fallback. Analytics and automatic UIKit replay keep their usual settings. SwiftUI
frames also need your project to allow annotated replay, plus consent, sampling
and budget. When the feature is available, frames will go only to ELU Cloud.
Self-hosted instances do not support this mode, so keep the option off if you
use one. Leaving the option off keeps the default setup.

Capture uses one eligible window and root, at most one frame per second,
with bounded image dimensions and request size. It adds no SwiftUI interaction
markers or automatic screen tracking; continue explicit `Elu.screen` calls.

### Local replay controls

After `Elu.setup`, use the same calls from UIKit or SwiftUI application code:

```swift
Elu.stopSessionRecording()
Elu.startSessionRecording()
let isRecording = Elu.sessionRecordingStarted()
```

Stop synchronously freezes new collection. The current capture then settles
asynchronously and may seal what it has already captured only while its
configuration, identity, consent and privacy remain valid. A first chunk below the
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

A visible root replacement or a viewport change ends the current capture before
starting a new replay ID under the same analytics session, sample decision and
remaining budget. Unsealed boundary frames are discarded. Transient unsupported
geometry is retried at the existing capture cadence without retaining failed
frames. A missing or presented root is observed without reading view text; recovery
stops on local stop, withdrawal or expiry and never renews configuration itself.
In automatic wireframe mode, opaque framework/custom content remains opaque. Scroll and navigation can change
visual snapshots; they do not produce touch or scroll interaction markers.

If the app is closed, ended by the system or updated and then opened again while
its analytics session is still active, replay continues under a new replay ID in
the same session, with the same sample decision and the remaining budget. The time
the app was closed counts toward the session's replay limit. If the device clock
reads earlier than the last recorded replay time, replay stays off for the rest of
that session. A local `stopSessionRecording()` does not carry over to the next launch:
call it again after setup on each launch where recording must stay off, or use
`optOut()` to stop recording persistently.

### UIKit touch recording with EluReplayWindow (preview)

Touch recording is in preview and is not yet available for ELU Cloud projects,
so recordings do not include touches yet. Replay works the same with or without
this window.

`EluReplayWindow` lets applications that create their own UIKit window record
touches with replay. Replace the existing `UIWindow` constructor in the scene
delegate, keeping the same root controller, stored window and key-window
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
constructors run on the main actor.

This is an explicit window choice; the SDK does not replace existing windows,
add gesture recognizers, swizzle methods or adopt custom `UIWindow` subclasses.
The window forwards each `sendEvent` call synchronously, exactly once.
SwiftUI-owned windows and other windows without this integration do not record
touches. Automatic `elu-native-wireframe-v1` replay does not need this window.

Touches are recorded only in the `elu-native-wireframe-v2` format, after the
server configuration selects it and the recording's first frame has been stored
with at least the minimum duration. The window alone cannot turn on that
format, consent or recording.

The SDK records one primary finger: its start, at most ten movement samples per
second, and its end or cancellation. It does not infer taps, recognize gestures,
or draw multiple finger trails. View geometry is sampled at most five times per
second during contact or while a scroll view is dragging or decelerating, and
once per second while idle. Each recorded point must be visible under both the
current privacy rules and the last recorded layout. Crossing private or opaque
content, unsafe clipping, changed text or an uncertain view hierarchy stops
coordinate recording until the finger lifts. Coordinates are never clamped or
assigned to a different view.

## Network requests (EluURLSession)

Instrument requests explicitly with the session your app already owns:

```swift
let instrumented = EluURLSession(session: appSession)
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

`Elu.captureException` records errors your app passes to it, including their
cause chains. The SDK does not install a crash handler; MetricKit can report
crashes later, as described below.

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

### Individual delayed crash reports (preview)

Automatic crash reports are in preview and are not yet available for ELU Cloud
projects, so enabling this option does not send reports yet. Use
`Elu.captureException` for errors your app handles.

When available, `crashReports` turns each MetricKit crash report (iOS 14+) into an
`$exception` event with the Mach exception and signal. It needs `enabled: true`,
and both report options default to `false`:

```swift
options.diagnostics = EluDiagnosticsOptions(
    enabled: true,
    crashReports: true,
    crashReportDetails: false
)
```

Reports also need your ELU project to allow exception capture with no
suppression rules. ELU Cloud does not send this permission yet, so the option
alone cannot turn on reporting today.

On iOS 17+, `crashReportDetails: true` also sends the Objective-C exception name,
class and reason when the OS provides them. These can contain app data. They are
cut to 256, 256 and 1,024 characters, and each report is at most 16 KiB. The SDK
never reads stack traces, memory addresses, process details or raw reports, and
it does not catch Swift errors, Swift fatal errors or signals itself.

A report is sent only if consent and the identified user stayed the same for the
whole period the OS report covers, and capture is still allowed when it arrives.
The event uses the time the report arrived, carries the report period in
`$diagnostic_interval_start` and `$diagnostic_interval_end`, and sets
`$native_crash_exact_time_available: false`. It joins the current session without
extending it. The OS decides whether and when it delivers reports, so not every
crash is reported. At most four reports per OS delivery are accepted, and
duplicates are dropped.

## App privacy manifest

The package includes `PrivacyInfo.xcprivacy`. It declares the SDK's linked
analytics, manual exception, native performance/diagnostic data, and ordinary
replay text, with tracking disabled. Performance and OS diagnostics remain disabled by default;
replay still requires eligible privacy authority, masked text and inputs are sent
only as `*` characters, and blocked content is excluded. Elapsed-time clocks are used for in-app timers and duration
measurements; raw system boot time is not sent. File metadata is read only for the
SDK's own files inside the app container, to check its local stores; it is not
sent. Review your app's complete data
practices when preparing its App Store privacy disclosures.

The categories and required-reason entries follow Apple's
[data-type definitions](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype)
and [required API reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons).
