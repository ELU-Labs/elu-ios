# EluAnalytics for iOS — runtime contract

This describes the behavior of the iOS SDK and its public `Elu.*` API. See the
[README](README.md) for installation and code examples. Installing the SDK does
not by itself authorize capture; eligible configuration and the consent, privacy,
and runtime checks described here still apply.

## Setup and configuration

Call `Elu.setup(siteKey:)` once at application launch. A second setup call is
ignored. The package supports iOS 13+ and has no external Swift package
dependencies. Optional setup parameters include native performance settings and
a declared self-hosted base (`apiHost`); ELU Cloud uses the default `https://elu.dev`.

The public `apiHost` declaration permits an exactly matching self-hosted config
base: HTTPS with an optional regular path prefix, without explicit port,
credentials, query, fragment or trailing-dot hostname. Empty/dot segments,
encoded separators, whitespace and controls are refused; one trailing slash is
removed. Undeclared bases are refused before runtime setup.
This declaration does not itself authorize configuration or ingestion;
the SDK's endpoint and configuration checks still apply.
The declaration fixes the event, flag and replay API base for this setup;
remote configuration cannot widen it. Each role retains its maintained path beneath the prefix,
and transports refuse redirects. Durable stores are isolated by canonical
self-hosted API base and site key; the existing Cloud storage path is unchanged.

The runtime obtains configuration from `GET /sdk/v2/<siteKey>/config`. An HTTP
success alone does not authorize analytics: the document must pass validation
and its current authority must permit the operation. Configuration has a bounded
validity window checked against wall and continuous clocks. Expiry, withdrawal,
or a failed refresh removes authority; there is no indefinitely valid cached
configuration or fallback runtime. Accepted configuration changes apply
through the current authority gates, without a blanket next-launch delay.

Remote policy, local consent, region restrictions, identity, and lifecycle gates
all apply. The EU restriction uses the documented timezone heuristic and fails
closed. Config requests may continue while analytics is blocked so the site can
recover. Blocking collection does not mean no SDK state is stored locally.

Calls while setup or configuration is pending may enter a bounded in-memory
buffer of 100 calls; once it is full, later calls are discarded and the earlier
ones kept. These calls are not yet durable records. Disabled or denied collection
does not authorize sending that buffer. Each return to the foreground fetches
configuration again. Calls made until that configuration is validated,
including the automatic application-opened event, are held by the same rules
and run in call order once it is; a failed fetch keeps them held until a later
fetch succeeds. A held call keeps the time it was made. An event without an
explicit time is recorded at that time, or at the latest recorded identity,
session, or consent change when that change is later.

## Identity, properties, flags, and screens

Call `Elu.identify` after login or session restoration using the app's stable
internal user ID, and `Elu.reset()` on logout. The SDK does not infer identity.
Reset creates a new anonymous identity, clears group associations, super
properties, flag context, session, and remembered profile-processing state, and
preserves both the independent device ID and consent choice.
`Elu.reset(resetDeviceId: true)` also rotates that device ID. Already admitted records retain
their original identity; they are not relabeled as the next user.

`EluSetupOptions.personProfiles` defaults to `.identifiedOnly`. Accepted person
mutations enable processing; accepted events also retain a processing decision
based on identified/group context or the `.always` option. These changes commit
with the event or mutation, so rejected writes do not promote the state.
`.never` blocks identify, alias, and person-property changes before any local
update and forces event profile processing off. Flag evaluation context
alone cannot promote processing. New events,
including numeric HTTP/performance/OS summaries, receive authoritative device,
identified, and profile-processing properties; this adds no historical identity
attribution, super properties, or groups to OS summaries.

The `Elu` API exposes events, aliases, groups, person and super properties,
first-write properties, and feature flags. `registerOnce` preserves existing
values unless they equal its supplied default sentinel. Flag results are bound
to the current evaluation context; unavailable flags do not imply a successful
evaluation. `ForFlags` setters and resets change evaluation context only, without
sending person or group property updates. The README lists the public methods.

`EluFeatureFlagOptions` controls individual value/result/enabled reads. Disabling
`sendEvent` does not consume an exposure entry. Requiring `fresh` refuses a cache
restored from another SDK instance until the current logical evaluation has a remote
response; all original identity, consent, configuration and expiry gates still
apply. Fresh reads do not start a request. The options-enabled Boolean overload
returns nil for missing/unavailable values unless a default is supplied, and never
replaces an evaluated false value with that default. Existing overloads keep their
behavior.

Exposure deduplication is durable for the anonymous visitor/key/typed value and
commits in the same transaction as the accepted exposure event. Identify,
relaunch and config renewal retain it; reset clears it. A full 4,096-entry ledger
suppresses only new exposure telemetry, with no eviction or getter restriction.
Request/evaluation metadata retains the original evaluation provenance.
The SDK accepts no bootstrap flag values, so `$feature_flag_bootstrapped_response`
and `$feature_flag_bootstrapped_payload` are null; `$used_bootstrap_value` is true
when the value came from the retained cache before the current evaluation has a
remote response.
Foreground config refresh is capped at 300 seconds; an unchanged successful
response also requests flag evaluation without replacing source authority or
extending its expiry.

Application lifecycle events are automatic when collection is eligible.
Logical screens require explicit `Elu.screen(...)` calls in both UIKit and
SwiftUI. Element-interaction autocapture, surveys, and push auto-capture are not
provided.

## Consent and durable delivery

`Elu.optOut()` persists withdrawal and stops collection and delivery. Reset,
relaunch, or a remote re-enable does not clear that choice. `Elu.optIn()` restores
collection only when current policy also permits it. Its default `$opt_in` event
is one ordinary capture attempt, not an event backfilled after configuration
becomes eligible; pass `captureEventName: nil` to suppress it.

The latest valid consent choice made before setup is retained in memory and
saved before configuration or lifecycle work can authorize collection. It is
durable only once the runtime opens; ending the process before setup cannot
persist it. Event, screen, and exception calls made during denial are discarded
even if consent is later granted. While configuration is pending, including the
fetch after a return to the foreground, every other call made during denial is
discarded as well, except `reset()` and `reset(resetDeviceId:)`; a later grant
does not release it. Opt-out also discards calls made before it that are still
waiting for configuration, with the same exception. A reset made before or
during an opt-out still applies once configuration arrives: it collects nothing
and preserves the consent choice. Opt-out removes queued replay; previously
admitted analytics events remain paused subject to later eligible delivery.

With the default `.persistent` option, admitted records use a site-scoped
SQLite store and survive ordinary process termination. `.memory` uses the same
SQL schema and transactions entirely in memory, including flags, replay,
independent device identity, diagnostics and exposure history. These analytics
states do not survive SDK shutdown or process exit; no temporary analytics
database or old-store import participates. Event and replay admission share record and logical-byte
limits; current remote `queueBytes` also limits admission without requiring
replay initialization. A lower limit preserves existing backlog but rejects
new records that exceed it. Logical queue limits are not a physical SQLite,
WAL, or filesystem disk ceiling. Privacy changes can remove replay that no
longer meets policy.

`Elu.flush()` requests a delivery attempt. It does not await acknowledgment or
guarantee delivery before termination. Unacknowledged durable events may retry
on a later eligible launch; lost acknowledgments do not justify treating a
request as delivered. Offline storage does not bypass current configuration,
consent, or privacy authority.

For a `429` or `5xx` response, the SDK retries the unchanged request with
backoff, whatever the response body. When the body is ELU's error object, its
`Retry-After` is honoured (up to one day for replay), and a `429` pauses that
upload endpoint. For any other body, one valid `Retry-After` is honoured up to
five minutes, and a missing, repeated or invalid one is ignored. After a
temporary failure, replay uploads wait up to a minute before the next recording
is tried. `401` and `403` stop delivery of that request. In annotated SwiftUI
replay, a validated `409` conflict or `413` size refusal stops that recording
permanently. Other unexpected responses, including a wireframe `409`, hold a
replay chunk: the same bytes are offered again after one hour to one day, until
the chunk expires seven days after capture. While the first undelivered chunk
of a recording is held or refused, new chunks for that recording are not stored,
and a new recording starts only once the configuration is refreshed, the
identity or analytics session changes, or the app is opened again.

Explicit consent has a separate bounded pending/settled record under the same
canonical site/API-base namespace in both modes. Only a settled explicit choice can
establish a grant across modes; pending choices deny. Existing denied persistent
state can establish denial, but its false bit does not prove explicit opt-in.
Memory startup with an older analytics store and no explicit choice is denied
until a public consent call settles. Old analytics bytes remain untouched while
memory mode runs. Returning to persistent mode transactionally retires dormant
session/replay/diagnostic coverage and invalidates flag context before admitting
work, even if the final consent Boolean matches. Existing analytics backlog,
device/person identity and exposure history follow ordinary opt-out retention.
The consent-only reconciliation bit advances only after that SQL barrier settles.
Storage/ambiguous consent failure denies this SDK instance and keeps other SDK
instances in this app from opening the same store until the app restarts. Durable intent through process death cannot be guaranteed when storage
rejects all restrictive writes. Reset never erases this consent record.

## Replay and privacy

The default automatic replay mode uses bounded UIKit wireframes. The SDK
supports `elu-native-wireframe-v1` and `elu-native-wireframe-v2` with gzip
(`protocol-generation-v1` and `protocol-generation-v2` respectively); the server
configuration must select one of them before capture starts. Sampling,
session budgets, lifecycle, identity, consent, and local privacy still apply.
When optional configuration-v2 `replayAudience` is `"new-devices"`, replay is
limited to the installation's first successfully committed capture session.
The history is durable even when no replay started, survives identity and
consent changes, and cannot advance on a rolled-back capture. Older stores
without complete history fail closed for this replay restriction only.
Absent this field, all devices remain eligible subject to the ordinary gates.

Public `startSessionRecording`, `stopSessionRecording` and
`sessionRecordingStarted` control only the current SDK instance's local intake.
Stop freezes collection synchronously, then settles capture accounting and seals
only an already captured, still-authorized prefix. It does not bypass the first
chunk's minimum or discard previously sealed delivery. Privacy/consent/source
withdrawal still discards unauthorized unsealed values. Start clears local stop
and reevaluates all existing gates without overriding sampling, audience or
budget. Status requires the installed current collector, not a desired option.
Calls before setup are no-ops; local stop is not persisted. Browser URL/event/
linked-flag override modes are not implemented, and the controls do not add
native touch/gesture or automatic-screen capture.

Safe root replacement and viewport changes recover automatically only after the
previous capture and its durable accounting settle. Each replacement uses a
new replay ID, preserving the analytics session's sample and budget history and
v1's fixed viewport per stream. No unsealed boundary frame is carried forward.
Only the collector's closed `unsupportedGeometry` error retries the same capture;
privacy, source, encoding and storage failures are not geometry retries. At most
one cancellable root-only observer waits for an available foreground root under
the same unexpired authorization; it performs no text collection, SQL polling
or configuration renewal. A pending restart is ignored once a later local start
or stop supersedes it. Snapshot changes do not represent native touch or scroll events.

When the app is ended, killed or updated and opened again inside the same
analytics session, the new process starts a new replay ID under that session's
original sample decision, first start and remaining budget; it never continues an
earlier replay ID. The time the app was closed is charged to the budget by the
device wall clock, which must not read earlier than the last recorded replay time;
otherwise replay stays off for the rest of that session. Sealed chunks from the
earlier process keep their delivery permission, and unsealed frames are discarded.
Local stop does not carry over to the next launch; it must be requested again after
setup, and opt-out is the persistent control.

The blanket profile masks text. When current policy authorizes ordinary text,
supported fully visible `UILabel` and `UIButton` text can remain
readable when its full layout fits, including multiline and wrapped text.
Standard table and collection views expose only visible standard cells through
their public content views, with all actual ancestor restrictions retained.
Truncated text, unsupported attributed
content, attachments, links, transparent text, and custom subclasses remain
masked or opaque. All input values, including `UITextField` and `UITextView`,
stay hidden. Images, web views, custom drawing, and SwiftUI content use
content-free placeholders in this automatic wireframe mode.

The separate [annotated SwiftUI replay](README.md#annotated-swiftui-replay-preview)
mode is in preview and not available for any project yet. It requires
`declaredRegionReplayEnabled = true` (configuration then comes from
`GET /sdk/v3/<siteKey>/config`, with no fallback), a retained
`EluSwiftUIReplayScope`, and a privacy declaration for every input and private
region. It does not find inputs or `.privacySensitive()` content automatically,
so unannotated content may be visible. Server permission, consent and privacy
checks still apply. Self-hosted instances do not support this mode.

Apply `Elu.maskView` or `Elu.blockView` on the main thread before presenting
private UIKit content. Masking hides subtree text; blocking excludes content
and descendants, allowing only a content-free bounds placeholder. These
restrictions last for the view's lifetime and cannot weaken remote policy.
Unresolved native blocking rules disable replay. Ordinary analytics properties
and manually reported errors are not automatically redacted by replay masking;
applications must choose appropriate values to send.

## Network requests

`EluURLSession` explicitly wraps a Foundation session your app supplies. It never
replaces delegates, swizzles other clients, or changes your app's request behavior
when telemetry is denied. The completion API supports iOS 13; Foundation async
requests support iOS 15 and later. It reports only method, status, data-request
completion duration, native initiator and transport-failure Boolean. URLs,
headers, bodies and error text are excluded; SDK origins are excluded.

At most 200 eligible observation attempts are admitted per process across all
wrappers. The app must remain foregrounded. The original identity, context,
session, consent and config authority
must still match at durable enqueue. Existing session activity is preserved;
when no session exists, the first accepted completion can atomically start one
and claim the same first-capture history used by replay audience selection.
Instrumentation requires current general capture permission, independently of
the replay request-detail setting. The README documents installation and limits.

## Exceptions and native performance

`Elu.captureException` records errors explicitly supplied by the app, including
bounded cause chains. It does not install a synchronous fatal-crash handler.

Native performance sampling is disabled by default. Enable it through
`EluPerformanceOptions` at setup; server policy must also permit the selected
measurements. Foreground samples report process physical memory footprint and
completed main-thread response stalls above the configured threshold. Missing
memory readings are omitted. Consent, identity, configuration, and lifecycle
changes discard pending samples. See the README for option ranges and examples.
The separately enabled `frameCadence` option observes public display-link
callbacks under the same responsiveness grant. It reports bounded callback
interval summaries, without inspecting rendered content or changing the app's
frame rate. It does not claim rendered or dropped frame counts.
These measurements do not supply browser DOM metrics, Web Vitals, JavaScript
heap size, browser long tasks, or full application launch time.

`EluDiagnosticsOptions` separately enables delayed numeric MetricKit summaries.
It defaults off. iOS 14+ crash/hang/CPU diagnostic counts and durations use
`$native_diagnostic`; optional iOS 13+ launch/resume histogram bounds and iOS 16+
launch diagnostic durations use `$native_launch`. Launch collection additionally
requires current server responsiveness permission. No raw payloads, stacks,
messages, paths, or metadata are collected. OS availability and scheduling do
not guarantee delivery or coverage of every fatal crash.

The whole OS interval must be covered by one durable consent/identity period.
Every consent action, identity change, observed terminal capture/privacy denial,
explicit shutdown, changed local diagnostics options, or clock regression
closes that coverage. Ordinary config refresh/expiry, suspension, and process
restart do not close it. Current authority and an existing live receipt session
are required at enqueue; summaries are passive and inherit no groups or super
properties. Historical interval fields distinguish the OS report from receipt
context. Unknown history and duplicate, malformed, or oversized reports are
omitted. Dedupe metadata and its event commit atomically. Restrictive closure
writes get one retry only after known rollback. If storage still fails or commit
is ambiguous, shutdown records an unresolved diagnostics settlement and keeps
other SDK instances in this app from opening the same store until the app
restarts. No cross-process persistence guarantee is made for an intent when
storage rejects every write. See the README for installation, availability, and
attribution limits.

### Opt-in MetricKit crash reports (preview)

Individual crash reports are in preview and are not yet available for ELU Cloud
projects. ELU Cloud does not yet send the permission they need, so turning the
option on sends nothing today. They are separate from numeric diagnostics and
need `diagnostics.enabled`, `crashReports`, unchanged consent and identity for the
whole period the OS report covers, and a current server `captureExceptions`
permission with no suppression rules. Unknown `captureExceptions` keys or values
make the configuration invalid. There is no local override.

On iOS 14+ a report carries the Mach exception and signal. On iOS 17+,
`crashReportDetails` also allows the Objective-C exception name, class and reason
(up to 256, 256 and 1,024 characters). The SDK never reads stack traces,
addresses, process metadata or raw OS payloads. Each report is at most 16 KiB, at
most four are accepted per OS delivery, and one is processed at a time.

Each report becomes an `$exception` event at the time it arrives, with
`$diagnostic_interval_start`, `$diagnostic_interval_end` and
`$native_crash_exact_time_available: false`. It does not start or extend a
session and carries no groups or super properties. Duplicates are dropped. The OS
decides whether and when it delivers reports.

The first time crash reports are enabled, the SDK upgrades the local database to
a newer layout. Numeric-only diagnostics keep the existing layout and metadata
bytes, and the metadata table stays capped at 8 KiB. A database upgraded for
crash reports cannot be opened for writing by older SDK versions that predate
that layout: they refuse it before writing, so downgrading after enabling crash
reports is not supported.

## Storage upgrades and privacy manifest

Supported store schemas from earlier SDK versions upgrade in place and preserve
identity, consent and queued records. Unsupported or unknown schemas fail closed
without destructive recovery: the SDK leaves the database, WAL and SHM files
untouched. Reset does not grant permission to erase an unsupported store.

The bundled privacy manifest describes the SDK's data categories and API use;
review the complete app's disclosures as explained in the README.

## Capture rate limiting

Capture admission uses `EluRateLimitingOptions` (default 10/second, burst 100),
scoped to the site and canonical API base. The independently persisted bucket
survives identity/reset/consent changes; `.memory` retains it only for that SQL
connection. Consent/configuration and duplicate-exposure checks precede debit;
canonical event validation, enrichment and quota follow it without refunds.
Identity mutations/replay chunks are exempt. One ordinary authorized
`$$client_ingestion_warning` is attempted on transition into limiting, bypassing
only the limiter; app events cannot request that bypass. Warnings from
passive native telemetry cannot create or extend its existing session. Constructor checks
consume no token, backward wall time accrues debt, and ambiguous SQL commits
stop the SDK instance. Your values are converted to bounded JSON before
admission. See README for persistence fallback and warning omission behavior.

## UIKit touch recording (preview)

Touch recording through `EluReplayWindow` is in preview and is not yet available
for ELU Cloud projects, so recordings do not include touches yet. Replay supports
two formats, `elu-native-wireframe-v1` and `elu-native-wireframe-v2` (both gzip,
with `protocol-generation-v1` and `protocol-generation-v2`). The server
configuration picks one, and the SDK never mixes them. Only
`elu-native-wireframe-v2` carries touches, and only from an `EluReplayWindow`
after the recording's first frame is stored. Creating the window does not pick a
format or grant permission. Both formats follow the same consent, identity,
privacy, sampling, budget and storage rules.

`EluReplayWindow` passes every event to UIKit synchronously, exactly once, and
adds no gesture recognizers. A touch point is recorded only over content the
current privacy rules allow. Crossing masked, blocked or uncertain content stops
coordinates until the finger lifts. Stopping recording, or a privacy, consent or
identity change, discards touches not yet saved. Touch handling uses at most 2 ms
per event and 20 ms per second. Layout is sampled at most 5 times per second while
touching or scrolling and once per second when idle, with at most 10 movement
samples per second. These are upper limits, not guarantees.
