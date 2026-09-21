# SDK development status

This branch is an implementation checkpoint, not a released SDK.

The clean candidate retired the unused preview import path under the dated
[storage compatibility decision](storage-compatibility.md). Its current source
passed all 691 local iOS 18.3.1 simulator tests and all 145 release-script tests.
Immutable baseline verification passes, and the strict tracked-source scanner
reports zero findings without changing its policy. These checks do not certify
physical devices or the final distribution and service deployment.

Exact distribution installation, supported owned upgrades, Lab engine readback,
customer-player rendering, physical-device checks, and resource overhead remain
release gates. The iOS symbol graph preserves all 25 original public symbols
and includes 28 explicit additions; this source API check is separate from
runtime and package qualification.

Replay currently covers supported UIKit wireframes and complete visible
single-line native text under authorizing policy. SwiftUI content remains
opaque. An embedded UIKit text bridge cannot safely infer an ancestor SwiftUI
`.privacySensitive()` setting through public APIs, so it does not bypass the
opaque host. Automatic SwiftUI replay and automatic fatal-crash reporting are
unsupported. Performance samples report process memory and completed native
main-thread stalls, not browser metrics or full application launch time.

Continue implementation in the dedicated SDK review branch. Build and test the final package from that branch before publishing a release.

Keep generated packages, device data, credentials and test-run evidence out of commits. Continue changes on this branch in its own checkout, with one owner for shared files. Historical test results do not certify changed artifacts.
