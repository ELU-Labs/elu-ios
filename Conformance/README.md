# Conformance foundations

`Baselines/0.1.0/behavior.json` records observable behavior of the wrapper tag.
It deliberately does not define the future event/replay wire envelope,
ingestion routing, or persistence schema. Those fields are marked provisional
until the browser SDK publishes the shared v1 contract.

Validate every checked-in baseline with:

```sh
python3 Conformance/validate-baselines.py
```

Future simulator and physical-device captures should add evidence references
to the existing case IDs rather than silently changing their expectations.
