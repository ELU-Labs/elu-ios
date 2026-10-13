#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCANNER = ROOT / "scripts" / "identifier-scan.py"
SPEC = importlib.util.spec_from_file_location("identifier_scan", SCANNER)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

# A made-up identifier. The real list is stored only as digests in the scanner.
TOKEN = "zylophant"


class IdentifierScanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.directory.name)
        self.identifiers = self.root / "identifiers.json"
        self.identifiers.write_text(
            json.dumps({"schemaVersion": 1, "identifiers": [MODULE.entry_for(TOKEN)]}),
            encoding="utf-8",
        )
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()

    def tearDown(self) -> None:
        self.directory.cleanup()

    def scan(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCANNER), "--skip-source", "--identifiers", str(self.identifiers), *arguments],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_builtin_list_is_digest_only_and_well_formed(self) -> None:
        identifiers = MODULE.parse_identifiers(MODULE.FORBIDDEN)
        self.assertTrue(identifiers)
        for entry in MODULE.FORBIDDEN:
            self.assertEqual(set(entry), {"length", "prefilter", "sha256"})

    def test_entry_is_independent_of_case_and_separators(self) -> None:
        expected = MODULE.entry_for(TOKEN)
        for variant in ("ZYLOPHANT", "Zylo-Phant", "zylo_phant", "zylo phant", "z.y.l.o.p.h.a.n.t"):
            self.assertEqual(MODULE.entry_for(variant), expected, variant)
        self.assertNotIn(TOKEN, json.dumps(expected))

    def test_entry_rejects_short_or_non_alphanumeric_identifiers(self) -> None:
        for value in ("abc", "zyloéphant"):
            with self.assertRaises(ValueError):
                MODULE.entry_for(value)

    def test_plain_split_and_recased_forms_are_rejected(self) -> None:
        forms = {
            "plain.txt": TOKEN.encode(),
            "upper.txt": TOKEN.upper().encode(),
            "hyphen.txt": b"zylo-phant",
            "spaced.txt": b"Zylo Phant",
            "concatenated.swift": b'let name = "zylo" + "phant"',
            "embedded.swift": b"import ZylophantKit",
            "utf16.txt": TOKEN.encode("utf-16-le"),
        }
        for name, data in forms.items():
            (self.inputs / name).write_bytes(data)
        (self.inputs / "clean.txt").write_text("zylo and phantom are different words", encoding="utf-8")

        result = self.scan("--input", str(self.inputs))

        self.assertNotEqual(result.returncode, 0)
        for name in forms:
            self.assertIn(name, result.stdout)
        self.assertNotIn("clean.txt", result.stdout)

    def test_clean_input_passes(self) -> None:
        (self.inputs / "Module.swiftinterface").write_text("public enum Elu {}", encoding="utf-8")

        result = self.scan("--input", str(self.inputs))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("generated/artifact inputs: clean", result.stdout)

    def test_license_files_are_not_exempt(self) -> None:
        (self.inputs / "LICENSE").write_text(TOKEN, encoding="utf-8")

        result = self.scan("--input", str(self.inputs))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LICENSE", result.stdout)

    def test_interface_and_archive_contents_are_rejected(self) -> None:
        (self.inputs / "Module.swiftinterface").write_text(TOKEN, encoding="utf-8")
        with zipfile.ZipFile(self.inputs / "symbols.zip", "w") as archive:
            archive.writestr("Symbols.json", TOKEN)
        tar_bytes = io.BytesIO()
        with tarfile.open(fileobj=tar_bytes, mode="w:gz") as archive:
            data = TOKEN.encode()
            info = tarfile.TarInfo("Products/Runtime.swift")
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        (self.inputs / "products.tar.gz").write_bytes(tar_bytes.getvalue())

        result = self.scan("--input", str(self.inputs))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Module.swiftinterface", result.stdout)
        self.assertIn("Symbols.json", result.stdout)
        self.assertIn("Runtime.swift", result.stdout)

    def test_forbidden_names_are_rejected_and_redacted(self) -> None:
        with zipfile.ZipFile(self.inputs / "Zylo-Phant-symbols.zip", "w") as archive:
            archive.writestr("clean.json", "{}")

        result = self.scan("--input", str(self.inputs))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("[forbidden]-symbols.zip", result.stdout)
        self.assertNotIn("zylo", result.stdout.casefold())

    def test_nested_archives_are_scanned(self) -> None:
        inner = self.root / "inner.zip"
        with zipfile.ZipFile(inner, "w") as archive:
            archive.writestr("Runtime.swift", TOKEN)
        outer = self.inputs / "outer.zip"
        with zipfile.ZipFile(outer, "w") as archive:
            archive.writestr("LICENSE", inner.read_bytes())

        result = self.scan("--input", str(outer))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outer.zip!/LICENSE!/Runtime.swift", result.stdout)

    def test_report_mode_lists_matches_without_failing(self) -> None:
        (self.inputs / "notes.txt").write_text(TOKEN, encoding="utf-8")

        result = self.scan("--mode", "report", "--input", str(self.inputs))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("notes.txt", result.stdout)

    def test_missing_input_fails(self) -> None:
        result = self.scan("--input", str(self.root / "missing"))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("scan input does not exist", result.stderr)

    def test_malformed_identifier_list_fails_closed(self) -> None:
        for identifiers in (
            [],
            [{"length": 9, "prefilter": "01", "sha256": "0" * 64}],
            [{"length": 9, "prefilter": "010101010", "sha256": "not-a-digest"}],
            [{**MODULE.entry_for(TOKEN), "token": TOKEN}],
        ):
            self.identifiers.write_text(json.dumps({"schemaVersion": 1, "identifiers": identifiers}), encoding="utf-8")

            result = self.scan("--input", str(self.inputs))

            self.assertEqual(result.returncode, 2, identifiers)
            self.assertIn("invalid identifier list", result.stderr)

    def test_entry_for_prints_a_digest_entry(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCANNER), "--entry-for", "Zylo-Phant"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), MODULE.entry_for(TOKEN))


if __name__ == "__main__":
    unittest.main()
