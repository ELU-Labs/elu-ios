# SDK development status

This branch is an implementation checkpoint, not a released SDK.

The clean candidate retired the unused preview import path under the dated
[storage compatibility decision](storage-compatibility.md). Its current source
at `3f5c2c6` passed all 691 local iOS 18.3.1 simulator tests and all 145 then-current
release-script tests. The subsequent 0.2.0 archive from `2c7f6ad` passed 643 host
Swift tests, strict package/API/artifact checks, generic iOS builds, and UIKit
and SwiftUI consumer compilation. Its application-bundled privacy manifest was
verified in the Lab UIKit fixture. Those source commits distinguish implementation
qualification from later metadata/documentation and boundary-guard changes; they
do not certify physical devices, installation, engine readback, or deployment.
Immutable baseline definitions and strict scanning policy remain unchanged.

Exact distribution installation, supported owned upgrades, Lab engine readback,
customer-player rendering, physical-device checks, and resource overhead remain
release gates. The iOS symbol graph preserves all 25 original public symbols
and includes 28 explicit additions; this source API check is separate from
runtime and package qualification.

The owned composition selects the exact implemented native codec, gzip, and
protocol generation. This is binary support, not release qualification. Current
server qualification/configuration and local privacy gates must authorize capture.

Replay currently covers supported UIKit wireframes and complete visible
single-line native text under authorizing policy. SwiftUI content remains
opaque. An embedded UIKit text bridge cannot safely infer an ancestor SwiftUI
`.privacySensitive()` setting through public APIs, so it does not bypass the
opaque host. Automatic SwiftUI replay and automatic fatal-crash reporting are
unsupported. Performance samples report process memory and completed native
main-thread stalls, not browser metrics or full application launch time.

Continue implementation in the dedicated SDK review branch. Build and test the final package from that branch before publishing a release.

Keep generated packages, device data, credentials and test-run evidence out of commits. Continue changes on this branch in its own checkout, with one owner for shared files. Historical test results do not certify changed artifacts.
