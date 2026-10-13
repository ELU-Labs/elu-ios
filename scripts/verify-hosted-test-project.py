#!/usr/bin/env python3
"""Keep the application-hosted suite bound to every current package test source."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / "Fixtures/Simulator/HostedTests"
PROJECT = HOST / "EluHostedTests.xcodeproj/project.pbxproj"
TEST_GROUP = "A0928195822C53907FA0C692"
TEST_PHASE = "97650F5118D743D06D3E9A72"


def read_project() -> dict:
    return json.loads(subprocess.check_output(
        ["plutil", "-convert", "json", "-o", "-", str(PROJECT)]
    ))["objects"]


def source_names(objects: dict) -> list[str]:
    return [objects[objects[key]["fileRef"]]["path"]
            for key in objects[TEST_PHASE]["files"]]


def update_missing_sources(expected: list[str]) -> None:
    """Add new test files; removal or changed project wiring needs explicit review."""
    objects = read_project()
    actual = source_names(objects)
    if len(actual) != len(set(actual)) or set(actual) - set(expected):
        raise ValueError("duplicate or removed test sources require project review")
    text = PROJECT.read_text()
    group = f"\t\t{TEST_GROUP} /* EluAnalyticsTests */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
    phase = f"\t\t{TEST_PHASE} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n"
    for name in sorted(set(expected) - set(actual)):
        ref = hashlib.sha256(("file:" + name).encode()).hexdigest()[:24].upper()
        build = hashlib.sha256(("build:" + name).encode()).hexdigest()[:24].upper()
        if ref in objects or build in objects or text.count(group) != 1 or text.count(phase) != 1:
            raise ValueError("test source identifiers or project sections conflict")
        text = text.replace("/* Begin PBXBuildFile section */\n",
            "/* Begin PBXBuildFile section */\n" +
            f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n")
        text = text.replace("/* Begin PBXFileReference section */\n",
            "/* Begin PBXFileReference section */\n" +
            f'\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n')
        text = text.replace(group, group + f"\t\t\t\t{ref} /* {name} */,\n")
        text = text.replace(phase, phase + f"\t\t\t\t{build} /* {name} in Sources */,\n")
    PROJECT.write_text(text)


def verify(objects: dict, expected: list[str]) -> None:
    actual = source_names(objects)
    if sorted(actual) != expected:
        raise ValueError("hosted test membership differs; run this script with --update and review")
    group = objects[TEST_GROUP]
    if group["path"] != "../../../Tests/EluAnalyticsTests" or group["sourceTree"] != "<group>":
        raise ValueError("hosted tests must use the original repository test sources")
    source_refs = [objects[key]["fileRef"] for key in objects[TEST_PHASE]["files"]]
    if sorted(group["children"]) != sorted(source_refs):
        raise ValueError("test group and compiled source membership differ")
    for key in source_refs:
        ref = objects[key]
        if ref["sourceTree"] != "<group>" or Path(ref["path"]).name != ref["path"]:
            raise ValueError("foreign test source reference")
    packages = [obj for obj in objects.values() if obj.get("isa") == "XCLocalSwiftPackageReference"]
    if len(packages) != 1 or packages[0]["relativePath"] != "../../..":
        raise ValueError("hosted tests must link the original local package")
    target, = [obj for obj in objects.values()
               if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "EluAnalyticsTests"]
    phases = [key for key in target["buildPhases"] if objects[key]["isa"] == "PBXSourcesBuildPhase"]
    if phases != [TEST_PHASE]:
        raise ValueError("unexpected test source build phase")
    for key in objects[target["buildConfigurationList"]]["buildConfigurations"]:
        settings = objects[key]["buildSettings"]
        if settings.get("TEST_HOST") != "$(BUILT_PRODUCTS_DIR)/EluTestHost.app/EluTestHost" or settings.get("BUNDLE_LOADER") != "$(TEST_HOST)":
            raise ValueError("tests require the actual application host")
    if any(obj.get("isa") == "PBXShellScriptBuildPhase" or "EXCLUDED_SOURCE_FILE_NAMES" in obj.get("buildSettings", {}) for obj in objects.values()):
        raise ValueError("test sources cannot be substituted or excluded")
    scheme = ET.parse(HOST / "EluHostedTests.xcodeproj/xcshareddata/xcschemes/EluHostedTests.xcscheme").getroot()
    testable, = scheme.findall("./TestAction/Testables/TestableReference")
    if testable.get("skipped") != "NO" or testable.findall(".//SkippedTests") or testable.findall(".//SelectedTests"):
        raise ValueError("the full native suite must run without test exclusions")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", action="store_true", help="add new test source references before review")
    args = parser.parse_args()
    expected = sorted(path.name for path in (ROOT / "Tests/EluAnalyticsTests").glob("*.swift"))
    if args.update:
        update_missing_sources(expected)
    verify(read_project(), expected)
    print(f"Hosted application suite includes all {len(expected)} package test sources")


if __name__ == "__main__":
    main()
