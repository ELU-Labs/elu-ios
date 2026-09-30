# SDK development status

Implementation evidence is separate from published release status. Consult the
[reviewed releases](https://github.com/ELU-Labs/elu-ios/releases) for customer
artifacts, and the [README](../README.md) for the current public API and limits.

The current source includes durable analytics and consent, independent device
identity and person-profile modes, prefixed HTTPS self-hosting, durable flag
exposures, memory-only analytics persistence with separate explicit consent, and
a site/API-base capture token bucket. The persistent default and owned-store
upgrade rules remain in force; the unused 0.1.0 preview import is intentionally
absent under the [storage compatibility decision](storage-compatibility.md).

Replay projects bounded UIKit wireframes with complete visible multiline label
and button text when privacy policy permits. Standard table/collection cells
use public visible-cell/content-view traversal and retain actual ancestor
restrictions. Input values, custom drawing and unknown content remain masked or
opaque. The default automatic wireframe mode keeps SwiftUI trees opaque: public
UIKit bridging cannot prove all SwiftUI inputs or `.privacySensitive()` ancestors. Public local replay
start/stop/status controls preserve full authority gates, first-chunk minimums,
original capture settlement and sealed delivery. They add no automatic screens
or browser trigger overrides. A separate candidate v2 path now joins the original
capture run to an explicit `EluReplayWindow` only after a known initial SQLite
commit. Current privacy plus ordered clip/identity checks bound a primary-finger
stream and lawful geometry handoffs. The local runtime supports exact v1 and v2
tuples under the original server configuration; the engine's default policy is
unchanged. Actual dispatch, useful-scroll, resource and player qualification
remain separate gates, including a fresh artifact built from this source.

The separate annotated SwiftUI candidate now has a default-false setup option,
`declaredRegionReplayEnabled`. The original setup copies it once and selects
native-v3 configuration plus implementation support together; it neither grants
permission nor starts a second source/queue. A stable `EluSwiftUIReplayScope` and
explicit mask/block wrappers are required for every input/private region.
Declared intent survives marker removal; ambiguous or stale geometry rejects
the frame before retention. This mode preserves original rendered state and
scroll, but does not discover inputs or native `.privacySensitive()` markings,
and adds no SwiftUI interaction markers. General self-hosted raster endpoints
are unsupported. See the README for the exact customer obligations.

Candidate `0a0c438` passed all three jobs in [hosted CI run
36721141678](https://github.com/ELU-Labs/elu-ios/actions/runs/36721141678):
1,132 Swift tests, 97 owned-store upgrade tests and 186 release-tool controls,
with no failures. Public API verification found 99 symbols; UIKit and SwiftUI
consumer builds, source archive generation and artifact scans passed. This
includes the corrected lost-ACK and root-source fixtures and the public
declared-region setup option. The tested archive belongs to PR merge `c71640e9`;
its packaged file contents and executable modes match reviewed `0a0c438`.
These are source-validation results, not installed-package or release
qualification; version 0.2.0 remains an unreleased candidate.

Customer request metrics require the explicit `EluURLSession` wrapper; URLs,
headers and bodies are omitted. Opt-in native performance includes process
memory, completed main-thread stalls and CADisplayLink callback cadence, not
Web Vitals or measured rendering completion. Separately opted-in MetricKit
summaries are delayed numeric OS diagnostics/launch histograms with interval
continuity checks. They are not synchronous crash reporting, raw crash stacks,
exact crash-session attribution or guaranteed simulator delivery. Manual
`captureException` and explicit `screen` remain supported.

Historical counts must remain attached to their exact source/artifacts. For
example, candidate `7703b10` completed 793 hosted simulator cases before later
prefix, identity, flag, persistence, limiter and replay-control changes. Those
results cannot certify this source. The `5703d373` CI run executed 842 cases
with two memory-fixture failures; the corrected successor `a21a6001` then hit a
separate limiter-test compilation error before native tests. Both failures and
the isolated test corrections are retained. Later `35afe9c` CI executed 954 cases with one real modal-host readiness failure
and two opaque-counter fixture failures; baseline and owned-upgrade gates passed.
The actual hosted-target/counter successor `1f8e705` then passed all three CI jobs,
including hosted tests, consumers/API/artifact checks and owned upgrades. That
result predates later capture/window, raster and bootstrap changes; no current
success is inferred from that historical run or API-ledger additions.

Exact distribution installation, owned upgrades, real Lab engine readback,
customer-player rendering, privacy/fault cohorts and bounded resource checks
remain release gates. Final qualification on a local simulator using the exact
artifacts is still pending; hosted CI does not replace it. Physical-device
behavior, performance and OS diagnostic availability remain unverified. A source
or consumer compile is not final artifact or end-to-end qualification. Keep
private artifacts, logs, device data, credentials and provenance receipts out
of public source commits.

The per-report MetricKit path is a separately opted-in no-stack implementation:
iOS 14 Mach/signal fields, optional iOS 17 Objective-C details under another local
permission, a current empty-suppression exception grant, and independent durable
local interval consent. Native control-plane grant emission is still unavailable;
manual exception capture and numeric diagnostic opt-in do not activate it.
Report, queue, migration and close controls are included in the passing hosted
Swift suites above. Those controls do not demonstrate actual OS report delivery,
crash-stack mapping, global Swift error interception, full browser
suppression/override parity or final artifact qualification. See README and
CONTRACT for receipt-time attribution and downgrade limits.
