# EluAnalytics for iOS — runtime contract

This describes the ELU-owned iOS runtime and public `Elu.*` API. See the
[README](README.md) for installation and code examples. Customer support applies
to the exact artifacts in a reviewed release after its required checks pass;
source implementation alone does not establish package or service qualification.

## Setup and configuration

Call `Elu.setup(siteKey:)` once at application launch. A second setup call is
ignored. The package supports iOS 13+ and has no external Swift package
dependencies. Optional setup parameters include native performance settings and
an approved development config host; production uses the default `https://elu.dev`.

The public `apiHost` declaration permits an exactly matching self-hosted config
base: HTTPS with an optional regular path prefix, without explicit port,
credentials, query, fragment or trailing-dot hostname. Empty/dot segments,
encoded separators, whitespace and controls are refused; one trailing slash is
removed. Undeclared bases are refused before runtime setup.
This declaration does not itself authorize configuration or ingestion;
the owned runtime's endpoint and configuration authority checks still apply.
The declaration fixes the event, flag and replay API base for this setup;
remote configuration cannot widen it. Each role retains its maintained path beneath the prefix,
and transports refuse redirects. Durable stores are isolated by canonical
self-hosted API base and site key; the existing Cloud storage path is unchanged.

The runtime obtains configuration from `GET /sdk/v2/<siteKey>/config`. An HTTP
success alone does not authorize analytics: the document must pass validation
and its current authority must permit the operation. Configuration has a bounded
validity window checked against wall and continuous clocks. Expiry, withdrawal,
or a failed refresh removes authority; there is no indefinitely valid cached
configuration or legacy runtime fallback. Accepted configuration changes apply
through the current authority gates, without a blanket next-launch delay.

Remote policy, local consent, region restrictions, identity, and lifecycle gates
all apply. The EU restriction uses the documented timezone heuristic and fails
closed. Config requests may continue while analytics is blocked so the site can
recover. Blocking collection does not mean no SDK state is stored locally.

Calls while setup or configuration is pending may enter a bounded in-memory
buffer; these calls are not yet durable records. Disabled or denied collection
does not authorize sending that buffer.

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
`.never` blocks identify, alias, and person-property changes before optimistic
facade updates and forces event profile processing off. Evaluation-only flag
context and customer `$epp` properties cannot promote processing. New events,
including numeric HTTP/performance/OS summaries, receive authoritative device,
identified, and profile-processing properties; this adds no historical identity
attribution, customer superproperties, or groups to OS summaries.

The facade exposes events, aliases, groups, person and super properties,
first-write properties, and feature flags. `registerOnce` preserves existing
values unless they equal its supplied default sentinel. Flag results are bound
to the current evaluation context; unavailable flags do not imply a successful
evaluation. `ForFlags` setters and resets change evaluation context only, without
sending person or group property updates. The README lists the public methods.

Exposure deduplication is durable for the anonymous visitor/key/typed value and
commits in the same transaction as the accepted exposure event. Identify,
relaunch and config renewal retain it; reset clears it. A full 4,096-entry ledger
suppresses only new exposure telemetry, with no eviction or getter restriction.
Request/evaluation metadata retains the original evaluation provenance. Native
bootstrap values are unsupported; the compatibility `used` field distinguishes
retained cache before a remote evaluation, with both bootstrap values null.
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
even if consent is later granted. Opt-out removes queued replay; previously
admitted analytics events remain paused subject to later eligible delivery.

With the default `.persistent` option, admitted records use a site-scoped owned
SQLite store and survive ordinary process termination. `.memory` uses the same
SQL schema and transactions entirely in memory, including flags, replay,
independent device identity, diagnostics and exposure history. These analytics
states do not survive owner closure or process exit; no temporary analytics
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

Explicit consent has a separate bounded pending/settled record under the same
canonical site/API-base lease in both modes. Only a settled explicit choice can
establish a grant across modes; pending choices deny. Existing denied persistent
state can establish denial, but its false bit does not prove explicit opt-in.
Memory startup with an older analytics store and no explicit choice is denied
until a public consent call settles. Old analytics bytes remain untouched while
memory mode runs. Returning to persistent mode transactionally retires dormant
session/replay/diagnostic coverage and invalidates flag context before admitting
work, even if the final consent Boolean matches. Existing analytics backlog,
device/person identity and exposure history follow ordinary opt-out retention.
The consent-only reconciliation bit advances only after that SQL barrier settles.
Storage/ambiguous consent failure denies this owner and retains its original
lease. Durable intent through process death cannot be guaranteed when storage
rejects all restrictive writes. Reset never erases this consent record.

## Replay and privacy

Replay uses bounded UIKit wireframes, not screenshots. The binary supports
`elu-native-wireframe-v1` with gzip and `protocol-generation-v1`; current server
qualification and configuration must authorize that exact support. Sampling,
session budgets, lifecycle, identity, consent, and local privacy still apply.
When optional configuration-v2 `replayAudience` is `"new-devices"`, replay is
limited to the installation's first successfully committed capture session.
The history is durable even when no replay started, survives identity and
consent changes, and cannot advance on a rolled-back capture. Older stores
without complete history fail closed for this replay restriction only.
Absent this field, all devices remain eligible subject to the ordinary gates.

Public `startSessionRecording`, `stopSessionRecording` and
`sessionRecordingStarted` control only the original runtime's local intake.
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
original physical capture and durable accounting settle. Each replacement uses a
new replay ID, preserving the analytics session's sample and budget history and
v1's fixed viewport per stream. No unsealed boundary frame is carried forward.
Only the collector's closed `unsupportedGeometry` error retries the same capture;
privacy, source, encoding and storage failures are not geometry retries. At most
one cancellable root-only observer waits for an available foreground root under
an original, unexpired authorization; it performs no text collection, SQL polling
or configuration renewal. Local control generations fence late restart. Snapshot
changes do not represent native touch/scroll events, and engine/player continuity
across replay IDs requires separate qualification.

The blanket profile masks text. When current policy authorizes ordinary text,
supported fully visible `UILabel` and `UIButton` text can remain
readable when its full layout fits, including multiline and wrapped text.
Standard table and collection views expose only visible standard cells through
their public content views, with all actual ancestor restrictions retained.
Truncated text, unsupported attributed
content, attachments, links, transparent text, and custom subclasses remain
masked or opaque. All input values, including `UITextField` and `UITextView`,
stay hidden. Images, web views, custom drawing, and SwiftUI content use
content-free placeholders. SwiftUI replay is not supported.

Apply `Elu.maskView` or `Elu.blockView` on the main thread before presenting
private UIKit content. Masking hides subtree text; blocking excludes content
and descendants, allowing only a content-free bounds placeholder. These
restrictions last for the view's lifetime and cannot weaken remote policy.
Unresolved native blocking rules disable replay. Ordinary analytics properties
and manually reported errors are not automatically redacted by replay masking;
applications must choose appropriate values to send.

## Instrumented customer networking

`EluURLSession` explicitly wraps a customer-supplied Foundation session. It never
replaces delegates, swizzles other clients, or changes customer request behavior
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

The whole OS interval must be covered by one durable consent/identity epoch.
Every consent action, identity change, observed terminal capture/privacy denial,
explicit shutdown, changed local diagnostics options, or clock regression
closes that coverage. Ordinary config refresh/expiry, suspension, and process
restart do not close it. Current authority and an existing live receipt session
are required at enqueue; summaries are passive and inherit no groups or super
properties. Historical interval fields distinguish the OS report from receipt
context. Unknown history and duplicate, malformed, or oversized reports are
omitted. Dedupe metadata and its event commit atomically. Restrictive closure
writes get one retry only after known rollback. If storage still fails or commit
is ambiguous, shutdown records an unresolved diagnostics settlement and retains
the original installation lease until process exit; another live owner cannot
reuse it. No cross-process persistence guarantee is made for an intent when
storage rejects every write. See the README for installation, availability, and
attribution limits.

## Storage upgrades and release evidence

Supported owned-store schemas preserve identity, consent, queued records, and
ordinary schema upgrades. Version 0.2.0 does not import persisted data from the
unused 0.1.0 runtime and leaves its files untouched. Unsupported transition or
unknown schemas fail closed without destructive recovery. Reset does not grant
permission to erase an unsupported store. Exact supported schema and owned-file
import boundaries are documented in [storage compatibility](docs/storage-compatibility.md).

The bundled privacy manifest describes the SDK's data categories and API use;
review the complete app's disclosures as explained in the README. Release
qualification separately requires exact distribution checks, supported upgrades,
device testing, Lab engine readback and customer-player rendering, privacy and
resource measurements. Compilation or stored replay bytes alone are not those
checks.


Capture admission uses `EluRateLimitingOptions` (default 10/second, burst 100),
scoped to the site and canonical API base. The independently persisted bucket
survives identity/reset/consent changes; `.memory` retains it only for that SQL
connection. Consent/configuration and duplicate-exposure checks precede debit;
canonical event validation, enrichment and quota follow it without refunds.
Identity mutations/replay chunks are exempt. One ordinary authorized
`$$client_ingestion_warning` is attempted on transition into limiting, bypassing
only the limiter; customer events cannot request that bypass. Warnings from
passive native telemetry cannot create or extend its existing session. Constructor checks
consume no token, backward wall time accrues debt, and ambiguous SQL commits
stop the owner. Bounded native JSON conversion precedes actor admission; there
are no native customer capture hooks. See README for persistence fallback and
warning omission behavior.


The internal candidate v2 sealing path accepts only the closed tuples
`elu-native-wireframe-v1` / `gzip` / `protocol-generation-v1` and
`elu-native-wireframe-v2` / `gzip` / `protocol-generation-v2`, intersected with
local proof and the original configuration. Mixed codec advertisements cannot
cross generations. The production runtime still installs only v1. The internal
v2 capture branch reuses the original enrollment, physical use and accounting;
it installs an observer only on an explicit `EluReplayWindow`, after its exact
minimum-qualified initial append is known committed. Neither constructing that
window nor the internal observer advertises v2 or grants authority. Generic replay
append refuses either native codec without the original physical admission. The
original serial run adopts its candidate encoder only after a known queue commit, preserving
the exact prepared bytes for retries. Movement envelopes begin at the earliest
logical sample, even when the first outer event uses the last sample timestamp.
Original identity, privacy, source, budget, physical settlement, and ambiguous
commit quarantine continue to apply. No database schema changes are needed.

The explicit final `EluReplayWindow` forwards each original event synchronously
once and participates in no gesture-recognizer dependencies. The original run
retains its installed observer until synchronous delivery and detachment are
joined, before physical/accounting settlement. Local stop freezes intake and
may retain an already lawful tail under unchanged authority; restrictive source,
privacy or identity withdrawal discards unsealed values. Ambiguous storage keeps
the original request/lease quarantined.

Current geometry queries reuse the collector's original UUIDs and ordinal,
read no private child contents or text, and never allocate a wire ID. The encoder
alone maps a detached point to its exact ordered node/positive clip. Both actual
and floored coordinates must also pass the current hierarchy/privacy paint veto.
Old points, any required coordinate-free cancel and new geometry stay ordered in
one serial buffer. A still-lawful target survives a geometry handoff; failure
suppresses coordinates through lift. Callbacks retain one bounded mailbox with a
reserved terminal slot, no per-event tasks, and the existing 2ms callback/20ms
rolling-second SDK-work budget excluding original host dispatch. Geometry uses
at most 5Hz during physical contact or public drag/deceleration and 1Hz idle;
movement retention is capped at 10Hz. These are maxima, not coverage promises.
The current source remains unqualified for actual UIKit dispatch/scroll cost and
player interaction/seek behavior until the original hosted Lab path executes.
