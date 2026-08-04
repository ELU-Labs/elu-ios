# 0.1.0 wrapper baseline

This directory freezes the public package and API surface at tag `0.1.0`
(`5825dfb4ca9cd1d104d0a07e33d0394128750391`). It is evidence for the
ownership migration, not a new runtime contract.

The behavior fixtures under `Conformance/Baselines/0.1.0` describe observable
facade semantics only. Event/replay envelopes, ingestion endpoints, and the
future ELU persistence schema remain provisional until the browser SDK freezes
the shared v1 contract.

The historical tag is immutable. Generate its rollback archive with:

```sh
git archive --format=tar --prefix=elu-ios-0.1.0/ 0.1.0 > elu-ios-0.1.0.tar
```

Then compare it with `SHA256SUMS`. The archive is intentionally generated on
demand rather than committed.
