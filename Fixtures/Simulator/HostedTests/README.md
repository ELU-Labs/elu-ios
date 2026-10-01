# Native unit-test host

UIKit presentation and application-window discovery require a real application
host. This project runs the unchanged package test sources inside `EluTestHost`;
the host does not initialize the SDK or create a competing test window.

After adding a file under `Tests/EluAnalyticsTests`, run
`python3 scripts/verify-hosted-test-project.py --update` from the repository root
and review the project diff. CI verifies exact source membership before running
the full suite. Package, consumer, API and storage-upgrade checks remain separate.
