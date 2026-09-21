# Public API additions

`Baselines/0.1.0/public-symbols.json` remains the immutable source API baseline.
`public-symbol-additions.json` lists the additive APIs in the native runtime
candidate. The symbol graph check requires their exact union: removing an old
API, removing an addition, or exposing an unreviewed API fails the check.

Run the check against an iOS build so UIKit-only mask/block APIs are included:

```sh
python3 scripts/verify-symbol-graph.py /path/to/ios-symbol-graphs
```

This is a source API check, not proof of binary compatibility, supported
upgrades, package qualification, or customer readiness. The release checks and
Lab clean-install and supported owned-store upgrade tests remain required.

`package-metadata.json` records the current owned package's exact manifest
digest, product, targets, linker settings, and empty dependency set for strict
release checks. The historical package-validation ledger describes the prior
provider-backed wrapper and remains unchanged for baseline checks. Both modes
reject manifest tampering; the current package does not reuse a historical
manifest digest or dependency claim.

The boundary check forbids the retired preview startup/import surfaces and
requires the exact owned bootstrap factory. The strict source and artifact
scanner remains unchanged and permits identifiers only in approved legal
notices. Historical manifests, source archives, and original public API
baselines remain immutable; they do not promise persisted-data import support.
