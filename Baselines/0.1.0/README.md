# 0.1.0 compatibility snapshot

This directory freezes the public package and API surface at tag `0.1.0`
(`5825dfb4ca9cd1d104d0a07e33d0394128750391`).

The behavior fixtures under `Conformance/Baselines/0.1.0` describe observable
facade semantics only. Event and replay envelopes, ingestion endpoints, and
persistence formats are outside this snapshot.

Generate the tag's verification archive with:

```sh
git archive --format=tar 0.1.0 > git-archive-without-prefix.tar
```

Then compare it with `SHA256SUMS`. The archive is intentionally generated on
demand rather than committed.
