#!/usr/bin/env python3
"""Require observed owned-runtime requests before release qualification.

This is a completeness check for generated evidence, not engine readback or
customer-player certification. The separate network scanner enforces all host
and identifier restrictions and the final Lab gate verifies persisted rendering.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from urllib.parse import urlsplit

METHODS = {"config": "GET", "capture": "POST", "flags": "POST", "replay": "POST"}


def validate(data: object) -> list[str]:
    if not isinstance(data, dict):
        return ["runtime network evidence must be an object"]
    errors = []
    if data.get("schemaVersion") != 1 or data.get("evidenceKind") != "ios-runtime-network-capture" or data.get("runtimeEvidence") is not True:
        errors.append("generated iOS runtime network evidence must use schemaVersion 1, evidenceKind ios-runtime-network-capture and runtimeEvidence=true")
    requests = data.get("requests")
    if not isinstance(requests, list) or not requests:
        return errors + ["runtime network evidence must contain observed SDK requests"]
    observed = set()
    for index, request in enumerate(requests):
        if not isinstance(request, dict):
            errors.append(f"runtime request {index} must be an object")
            continue
        scenario = request.get("scenario")
        if not isinstance(scenario, str) or scenario not in METHODS:
            continue  # The full trace also includes reset/lifecycle/offline cases.
        if request.get("method") != METHODS[scenario]:
            errors.append(f"runtime request {index} requires {METHODS[scenario]} for {scenario}")
            continue
        url = request.get("url")
        try:
            parts = urlsplit(url) if isinstance(url, str) else None
            valid = (parts is not None and parts.scheme == "https" and parts.hostname
                     and parts.username is None and parts.password is None and not parts.fragment
                     and parts.port in (None, 443))
        except ValueError:
            valid = False
        if not valid:
            errors.append(f"runtime request {index} must have an absolute HTTPS URL")
            continue
        if scenario == "replay":
            body = request.get("requestBody")
            chunk = body.get("chunk") if isinstance(body, dict) else None
            if (parts.hostname != "ingest.elu.dev" or parts.port not in (None, 443)
                    or parts.path != "/v2/replay" or parts.query
                    or not isinstance(body, dict) or body.get("schemaVersion") != 2
                    or not isinstance(chunk, dict) or chunk.get("schemaVersion") != 2
                    or chunk.get("codec") != "elu-native-wireframe-v1"
                    or chunk.get("compression") != "gzip"
                    or not isinstance(chunk.get("payload"), str) or not chunk["payload"]):
                errors.append(f"runtime request {index} must contain an observed native v2 replay request")
                continue
        observed.add(scenario)
    for scenario in sorted(METHODS.keys() - observed):
        errors.append(f"runtime network evidence is missing observed {scenario} requests")
    return errors


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    try:
        errors = validate(json.loads(args.evidence.read_text()))
    except (OSError, ValueError) as error:
        errors = [f"runtime network evidence cannot be read: {error}"]
    if errors:
        raise SystemExit("\n".join(errors))
    print("generated iOS runtime network evidence includes config, capture, flags and native replay")


if __name__ == "__main__":
    main()
