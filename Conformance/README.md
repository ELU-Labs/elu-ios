# Conformance fixtures

`V1/` and `V2/` hold the wire contract fixtures, schemas and test vectors that
the SDK is tested against. They do not change when the SDK changes; the Swift
tests and the validators below read them as they are.

Validate the config, queue, feature-flag and replay contracts with:

```sh
python3 Conformance/validate-v1-config.py
python3 Conformance/validate-v1-queue.py
python3 Conformance/validate-v1-flags.py
python3 Conformance/validate-v2-replay.py
```
