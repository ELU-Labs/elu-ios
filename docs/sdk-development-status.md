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
opaque. SwiftUI trees remain opaque: public UIKit bridging cannot prove all
SwiftUI visibility or `.privacySensitive()` ancestors. Public local replay
start/stop/status controls preserve full authority gates, first-chunk minimums,
original capture settlement and sealed delivery. They add no touch/gesture
protocol, automatic screens or browser trigger overrides.

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
the isolated test corrections are retained. Current replay-control source and
its new tests require compilation and native execution; no success is inferred
from source review or API-ledger additions.

Exact distribution installation, owned upgrades, real Lab engine readback,
customer-player rendering, privacy/fault cohorts and bounded resource checks
remain release gates. Physical devices are deferred by the owner for this
release effort; simulator qualification cannot establish real-device resource
costs or OS diagnostic availability. A source or consumer compile is not final
artifact or end-to-end qualification. Keep private artifacts, logs, device data,
credentials and provenance receipts out of public source commits.
