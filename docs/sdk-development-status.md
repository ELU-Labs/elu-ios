# SDK development status

This branch is an implementation checkpoint, not a released SDK.

Fresh boundary checks fail on the legacy startup reader and exact bootstrap binding. The guard unit suite ran 49 tests with 3 failures. Full current iOS component qualification remains incomplete; the latest attempt stopped before device acquisition. Review these failures before merge.

Implementation belongs in this repository; cross-platform acceptance belongs in [elu-sdk-lab](https://github.com/ELU-Labs/elu-sdk-lab). See the [SDK coordination guide](https://github.com/ELU-Labs/ELU/blob/docs/sdk-release-handoff/docs/sdk-ownership/README.md) for related branches and integration order.

Keep generated packages, device data, credentials and test-run evidence out of commits. Continue changes on this branch in its own checkout, with one owner for shared files. Historical test results do not certify changed artifacts.
