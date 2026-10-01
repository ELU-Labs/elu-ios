# Local release evidence

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
