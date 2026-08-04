# SDK ownership foundations

This branch establishes Phase 0/1 evidence and gates around the historical
`0.1.0` facade. It does not import or replace the runtime and does not freeze a
mobile transport, replay codec, or persistence schema ahead of the browser v1
contract.

## What is enforced now

- The immutable tag, source archive, manifest, public facade, and public symbol
  inventory are checksummed under `Baselines/0.1.0`.
- The exact temporary parity dependency is pinned and checked against the legal
  provenance inventory; the current parsed package metadata is checked against
  `Baselines/phase-1-wrapper/package-metadata.json`.
- Golden observable-behavior fixtures cover identity, reset, groups, flags,
  lifecycle, events, replay, privacy, persistence, and network routing.
- UIKit and SwiftUI consumer targets compile representative customer calls.
- Swift tests cover schema versions, URL encoding, activation policy, FIFO
  buffering, EU defaults, replay markers, facade concurrency, and callback
  ordering.
- The source scanner runs in debt-baseline mode: existing wrapper debt may
  shrink but cannot grow or move to a new path.

The strict scanner is already implemented for tracked source, file names,
Swift interfaces, symbol graphs, binaries, source archives, XCArchives, SBOMs,
and network traces. It intentionally fails on the current wrapper. Only exact
`LICENSE` and `THIRD_PARTY_NOTICES` artifacts are allowlisted. The ownership
release must run strict mode with zero findings; report/baseline mode is not a
release waiver.

Archive inspection recurses through four nested archive layers; deeper nesting
is itself a strict-gate failure rather than an unscanned exception.

## Local validation limitation

This workstation has Command Line Tools but not full Xcode or an iOS SDK. Its
Swift 6.2 compiler also does not match the installed macOS SDK interfaces, so
only manifest evaluation and Swift parser checks are runnable locally. The
simulator tests, consumer builds, generated interface, symbol graph, and
archive inspection run on the `macos-15` CI worker with full Xcode.

## Commands

```sh
python3 scripts/verify-baseline.py
python3 scripts/zero-brand-scan.py --mode baseline
python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
```

After `swift package resolve`, verify the exact Phase 1 graph with:

```sh
python3 scripts/verify-dependencies.py --mode baseline
```

The final, non-publishing release gate is:

```sh
scripts/release-preflight.sh <exact-semver-tag> <network-trace.json>
```

It requires a clean checkout at the exact tag, an owned dependency graph,
simulator and consumer builds, API/symbol parity, an archive, SBOM, checksums,
provenance, legal payload, captured build logs, and strict
source/artifact/network scans. The trace must contain the real release
candidate's observed SDK requests normalized to
`release/network-trace.schema.json`; an empty trace is rejected. The exact tag
must carry a valid Git or SSH signature. The preflight never publishes, moves
a tag, or deploys.

Release evidence includes an explicit checksum inventory for every artifact
input. Files use SHA-256; directories use the documented path-bound
`sha256-tree-v1` digest so an XCArchive can be verified without repackaging it.
The source ZIP is produced by `git archive` from the reviewed commit/tag, so
ignored build caches and dependency checkouts cannot enter the release.
