# SDK development status

This branch is an implementation checkpoint, not a released SDK.

Local focused runtime, facade, consent, and native performance tests pass. The
provider boundary and additive API guards pass; the iOS symbol graph preserves
all 25 original public symbols and includes 28 explicit additions. The legacy
reader remains subject to migration qualification and a pinned source boundary.

The current source passed 689 local iOS 18.3 simulator tests, including UIKit
privacy and readable system secondary text. This is simulator source evidence,
not physical-device or final-distribution qualification.
Exact distribution installation, supported upgrades, Lab engine readback,
customer-player rendering, and resource overhead remain release gates.

Replay currently covers supported UIKit wireframes and complete visible
single-line native text under authorizing policy. SwiftUI content remains
opaque. An embedded UIKit text bridge cannot safely infer an ancestor SwiftUI
`.privacySensitive()` setting through public APIs, so it does not bypass the
opaque host. Automatic SwiftUI replay and automatic fatal-crash reporting are
unsupported. Performance samples report process memory and completed native
main-thread stalls, not browser metrics or full application launch time.

Continue implementation in the dedicated SDK review branch. Build and test the final package from that branch before publishing a release.

Keep generated packages, device data, credentials and test-run evidence out of commits. Continue changes on this branch in its own checkout, with one owner for shared files. Historical test results do not certify changed artifacts.
