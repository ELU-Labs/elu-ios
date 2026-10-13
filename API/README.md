# Public API ledger

The public API of `EluAnalytics` is the exact symbol list in
`Baselines/current/public-symbols.json`. `scripts/verify-symbol-graph.py` fails
if a listed symbol is missing or an unlisted public symbol appears, so every new
public API needs an entry in that file.

Run the check against an iOS build so UIKit-only mask/block APIs are included:

```sh
python3 scripts/verify-symbol-graph.py /path/to/ios-symbol-graphs
```

`scripts/verify-baseline.py` checks that every declaration in
`Baselines/current/public-api.txt` is still in `Sources/EluAnalytics/Elu.swift`.

`package-metadata.json` records the package manifest SHA-256, product, targets,
linker settings and empty dependency set. Check them against the manifest with:

```sh
mkdir -p .build
swift package dump-package > .build/package.json
python3 scripts/verify-package-surface.py --mode strict .build/package.json
```
