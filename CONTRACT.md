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
Reset creates a new anonymous identity, clears group associations and super
properties, and preserves the consent choice. Already admitted records retain
their original identity; they are not relabeled as the next user.

The facade exposes events, aliases, groups, person and super properties,
first-write properties, and feature flags. `registerOnce` preserves existing
values unless they equal its supplied default sentinel. Flag results are bound
to the current evaluation context; unavailable flags do not imply a successful
evaluation. `ForFlags` setters and resets change evaluation context only, without
sending person or group property updates. The README lists the public methods.

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

Admitted records use a site-scoped owned SQLite store and survive ordinary
process termination. Event and replay admission share record and logical-byte
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

## Replay and privacy

Replay uses bounded UIKit wireframes, not screenshots. The binary supports
`elu-native-wireframe-v1` with gzip and `protocol-generation-v1`; current server
qualification and configuration must authorize that exact support. Sampling,
session budgets, lifecycle, identity, consent, and local privacy still apply.

The blanket profile masks text. When current policy authorizes ordinary text,
supported fully visible, single-line `UILabel` and `UIButton` text can remain
readable if it fits without wrapping or truncation. Unsupported attributed
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

## Exceptions and native performance

`Elu.captureException` records errors explicitly supplied by the app, including
bounded cause chains. Automatic fatal-crash reporting is not provided.

Native performance sampling is disabled by default. Enable it through
`EluPerformanceOptions` at setup; server policy must also permit the selected
measurements. Foreground samples report process physical memory footprint and
completed main-thread response stalls above the configured threshold. Missing
memory readings are omitted. Consent, identity, configuration, and lifecycle
changes discard pending samples. See the README for option ranges and examples.
These measurements do not supply browser DOM metrics, Web Vitals, JavaScript
heap size, browser long tasks, or full application launch time.

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
