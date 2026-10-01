#!/usr/bin/env python3
"""Require observed owned-runtime requests before release qualification.

This is a completeness check for generated evidence, not engine readback or
customer-player certification. The separate network scanner enforces all host
and identifier restrictions and the final Lab gate verifies persisted rendering.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from urllib.parse import urlsplit

METHODS = {"config": "GET", "capture": "POST", "flags": "POST", "replay": "POST"}
NATIVE_CHANNELS = {"config-v2", "config-v3", "capture", "flags", "replay-v2", "replay-v3"}
CONFIG_PATH = re.compile(r"/sdk/(v2|v3)/elu_pk_(?:live|test)_[A-Za-z0-9]{22,64}/config")


def validate(data: object, *, profile: str = "legacy") -> list[str]:
    if profile not in {"legacy", "current-native"}:
        return ["unknown runtime network evidence profile"]
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
        channel = scenario
        if profile == "current-native":
            if parts.query or any(ord(character) <= 32 or ord(character) == 127 for character in url):
                errors.append(f"runtime request {index} requires the fixed query-free SDK endpoint")
                continue
            if scenario == "config":
                match = CONFIG_PATH.fullmatch(parts.path)
                if parts.hostname != "elu.dev" or match is None:
                    errors.append(f"runtime request {index} requires an original cloud config-v2 or config-v3 request")
                    continue
                channel = "config-" + match.group(1)
            else:
                paths = {"capture": "/v1/events", "flags": "/v1/flags"}
                allowed = {paths[scenario]} if scenario in paths else {"/v2/replay", "/v3/replay"}
                if parts.hostname != "ingest.elu.dev" or parts.path not in allowed:
                    errors.append(f"runtime request {index} requires the fixed cloud {scenario} endpoint")
                    continue
                if scenario == "replay":
                    channel = "replay-" + parts.path.split("/")[1]
        if scenario == "replay":
            body = request.get("requestBody")
            chunk = body.get("chunk") if isinstance(body, dict) else None
            raster = profile == "current-native" and channel == "replay-v3"
            version = 3 if raster else 2
            codecs = {"elu-native-raster-v1"} if raster else ({"elu-native-wireframe-v1", "elu-native-wireframe-v2"}
                if profile == "current-native" else {"elu-native-wireframe-v1"})
            if (parts.hostname != "ingest.elu.dev" or parts.port not in (None, 443)
                    or parts.path != f"/v{version}/replay" or parts.query
                    or not isinstance(body, dict) or type(body.get("schemaVersion")) is not int or body["schemaVersion"] != version
                    or not isinstance(chunk, dict) or type(chunk.get("schemaVersion")) is not int or chunk["schemaVersion"] != version
                    or not isinstance(chunk.get("codec"), str) or chunk["codec"] not in codecs
                    or chunk.get("compression") != "gzip"
                    or not isinstance(chunk.get("payload"), str) or not chunk["payload"]):
                errors.append(f"runtime request {index} must contain an observed native v{version} replay request")
                continue
        observed.add(channel)
    required = NATIVE_CHANNELS if profile == "current-native" else METHODS.keys()
    for scenario in sorted(required - observed):
        errors.append(f"runtime network evidence is missing observed {scenario} requests")
    return errors


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--profile", choices=["legacy", "current-native"], default="legacy")
    args = parser.parse_args()
    try:
        errors = validate(json.loads(args.evidence.read_text()), profile=args.profile)
    except (OSError, ValueError) as error:
        errors = [f"runtime network evidence cannot be read: {error}"]
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"generated iOS runtime network evidence includes required {args.profile} channels")


if __name__ == "__main__":
    main()
