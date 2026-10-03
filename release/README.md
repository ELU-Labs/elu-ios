# Local release evidence

## Evaluation exception: 0.2.0-beta.1 only

The repository owner approved a non-production evaluation release of
`0.2.0-beta.1`. This exception defers the remaining installed-SDK Lab,
public-origin network, engine readback, replay/player, privacy and performance
qualification for this version only. It does not certify those behaviors or
apply to `0.2.0`, another prerelease, or a production deployment. Evaluate only
with synthetic data in a test app. Customer installation availability and native
capture activation remain off until separately qualified and approved.

Before publishing this beta:

1. Review its pull request and pass every required check on the exact beta
   source commit. Follow the separate authorization requirement for merging.
   All existing hosted CI jobs remain required, including Swift tests, UIKit
   and SwiftUI consumer builds, API/dependency checks, source/artifact scans,
   and owned-store compatibility tests. Lightweight local checks alone do not
   replace these jobs.
2. Retain the successful run's original `ios-tested-source` artifact and Swift
   test results. Verify the source ZIP's SHA-256, embedded commit and release
   manifest against that run's exact source commit and package version
   `0.2.0-beta.1`. Do not relabel the earlier `0.2.0` archive or substitute a
   merge commit's archive because its tree happens to match.
3. From a clean checkout of that reviewed commit, create an annotated OpenPGP
   tag named `0.2.0-beta.1` with a genuine `Reviewed-by:` trailer. Record the
   source commit and source archive SHA-256 in its signed message. The owner
   must explicitly trust the signing fingerprint. Run the unchanged
   `scripts/verify-release-tag.py 0.2.0-beta.1` with
   `ELU_TRUSTED_RELEASE_SIGNING_FINGERPRINTS` configured. Retain the verified
   tag object identity; a beta label does not waive signing or review.
4. Run the existing strict artifact scan on the retained source ZIP. Publish
   only the verified tag object and that ZIP. Mark the GitHub release as a
   **prerelease**, do not mark it latest, and disclose the deferred checks in
   its notes. Keep private traces, credentials and internal evidence private.
5. Verify the remote tag target and published asset digest against the retained
   identities. Record publication separately from activation and production
   qualification; neither activation nor qualification follows from this beta.

The full `release-preflight.sh` below is intentionally unchanged. This beta
uses the bounded exception above instead of claiming that an unrun full
preflight passed. No synthetic network fixture may be presented as observed
runtime evidence. A stable release still requires the complete procedure and
Lab qualification below.

## Full release qualification

Run `scripts/release-preflight.sh <exact-semver-tag> <network-trace.json>` only
with the reviewed, trusted signed tag and an observed trace from the exact
candidate. The preflight validates the tag before building and never publishes.

The trace uses `network-trace.schema.json`, sets `evidenceKind` to
`ios-runtime-network-capture` and `runtimeEvidence` to `true`, and includes all
required scenarios. Config, capture, flags, and native replay must have observed
requests with their actual HTTP methods. Current preflight selects
`--profile current-native`: both `GET https://elu.dev/sdk/v2/{siteKey}/config`
and `/sdk/v3/{siteKey}/config`, plus `POST https://ingest.elu.dev/v1/events`,
`/v1/flags`, `/v2/replay` and `/v3/replay` must have been observed. Configuration
requests retain scenario `config`; both replay formats retain scenario `replay`.
Replay requests include their original JSON bodies: schema 2 with a native
wireframe codec or schema 3 with `elu-native-raster-v1`, using gzip. Paths are
exact, without queries or custom origins. The default legacy validator mode
remains available for historical traces but cannot satisfy current preflight.
Do not substitute generated fixtures or a declared scenario
for an observed request. Keep credentials and customer data in private evidence.
The completeness validator does not prove engine readback or customer-player
rendering; those remain mandatory Lab gates.

CI and local preflight create archives with `scripts/create-source-archive.py`.
The helper resolves a tag or ref to its exact commit and always uses the
`elu-ios-source/` prefix. With the same toolchain, a commit produces the same ZIP bytes whether
selected by HEAD or an annotated release tag, so Lab can bind the original
archive SHA-256 before tag publication. Build manifests record the full source
commit, source archive hash, package version, and actual bundled resources.
