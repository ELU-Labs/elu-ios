# Conformance fixtures

`Baselines/0.1.0/behavior.json` records observable behavior of the `0.1.0`
package. It deliberately does not define event or replay wire envelopes,
ingestion routing, or persistence formats.

Validate every checked-in baseline with:

```sh
python3 Conformance/validate-baselines.py
```

Validate the frozen config and replay contracts with:

```sh
python3 Conformance/validate-v1-config.py
python3 Conformance/validate-v1-queue.py
python3 Conformance/validate-v1-flags.py
python3 Conformance/validate-v2-replay.py
```

Simulator and physical-device captures add evidence references to the existing
case IDs rather than silently changing their expectations.
