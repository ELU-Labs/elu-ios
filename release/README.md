# Local release evidence

Run `scripts/release-preflight.sh <exact-semver-tag> <network-trace.json>` only
with the reviewed, trusted signed tag and an observed trace from the exact
candidate. The preflight validates the tag before building and never publishes.

The trace uses `network-trace.schema.json`, sets `evidenceKind` to
`ios-runtime-network-capture` and `runtimeEvidence` to `true`, and includes all
required scenarios. Config, capture, flags, and native replay must have observed
requests with their actual HTTP methods. Native replay must include its JSON
request body from `POST https://ingest.elu.dev/v2/replay`, with the native codec
and gzip payload. Do not substitute generated fixtures or a declared scenario
for an observed request. Keep credentials and customer data in private evidence.
The completeness validator does not prove engine readback or customer-player
rendering; those remain mandatory Lab gates.

CI and local preflight create archives with `scripts/create-source-archive.py`.
The helper resolves a tag or ref to its exact commit and always uses the
`elu-ios-source/` prefix. With the same toolchain, a commit produces the same ZIP bytes whether
selected by HEAD or an annotated release tag, so Lab can bind the original
archive SHA-256 before tag publication. Build manifests record the full source
commit, source archive hash, package version, and actual bundled resources.
