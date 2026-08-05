# iOS upgrade compatibility

`0.1.0/dependency-resolutions.json` records what is known about the source
version's dependency resolution. The source tag contains a version range and
no resolved lockfile. The `3.69.0` revision in the inventory is one dated,
provenanced observation, not a claim that every historical consumer selected
that revision. Its annotated tag-object revision and peeled source revision
are recorded separately.

`0.1.0/manifest.json` is a checked-in evidence template, not a completed test
result. A verified generated manifest must include
the candidate revision, the source build's exact dependency version and source
revision, and either the candidate's exact resolution or a digest proving the
dependency is absent from its archived resolved graph. Verified validation
inspects that graph and the raw network captures rather than trusting the
manifest booleans. It also records exact Xcode and iOS versions, the fixed
bundle id, the raw archive digest, and successful identity, session-rotation,
and application-container checks.

## Simulator harness

The harness is a UIKit application hosting a SwiftUI view. The runner:

1. materializes the immutable `0.1.0` source and clean candidate revision with
   `git archive`;
2. builds both applications before starting the continuity clock;
3. installs the source under `dev.elu.sdk-upgrade-evidence`, establishes a
   generated identity, and captures a source marker;
4. installs the already-built candidate over the existing application, without
   an uninstall;
5. compares the public distinct-id result and confirms that both network
   captures contain a session id with the documented source-to-candidate
   rotation; and
6. writes a normalized manifest plus a SHA-256 digest.

The generated identity and session values appear only in the raw archive. The
runner stores failure diagnostics there as well, prints only normalized
status, and refuses an output directory inside the repository. Marker-shaped
payloads count only when captured on the source SDK's exact telemetry route,
`POST /batch`; other methods, paths, and query-bearing variants are ignored by
both the runner and the independent archive validator.

Before SDK setup, the simulator harness makes one anonymous, cache-bypassed
HTTPS request to `github.com/favicon.ico`. This bounded preflight establishes
the simulator's default network route before the source SDK evaluates network
reachability. It uses an ephemeral session and runs before an evidence identity
is created, so it carries no SDK identity or captured event data. The evidence
server remains loopback-only, and the exact `POST /batch` checks remain the
authoritative proof.

The `0.1.0` dependency starts a session during every SDK setup. A process
replacement therefore rotates the session id; exact session-id equality is not
a valid upgrade expectation for this source version. The harness requires the
identity to remain equal while both session ids are present and different.

The executable scripts expose their prerequisites and command-line options via
`--help`. Generated captures must remain outside the repository and must not be
printed to logs.
