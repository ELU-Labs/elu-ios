import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("symbol_guard", ROOT / "scripts/verify-symbol-graph.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SymbolGraphTests(unittest.TestCase):
    def check_graph(self, names):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "EluAnalytics.symbols.json"
            path.write_text(json.dumps({"module": {"name": "EluAnalytics"},
                "symbols": [{"pathComponents": name.split(".")} for name in names]}))
            with patch("sys.argv", ["verify-symbol-graph", str(path)]), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                return MODULE.main()

    def test_reviewed_union_passes(self):
        _, names = MODULE.expected_symbols()
        self.assertEqual(self.check_graph(names), 0)

    def test_removing_original_api_is_rejected(self):
        _, names = MODULE.expected_symbols()
        self.assertEqual(self.check_graph(names - {"EluSetupOptions.init(configHost:)"}), 1)

    def test_removing_addition_or_exposing_unreviewed_api_is_rejected(self):
        _, names = MODULE.expected_symbols()
        self.assertEqual(self.check_graph(names - {"Elu.optOut()"}), 1)
        self.assertEqual(self.check_graph(names | {"Elu.uncheckedCapture()"}), 1)

    def test_additive_ledger_cannot_replace_baseline(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "additions.json"
            data = json.loads(MODULE.ADDITIONS.read_text())
            data["symbols"].append({"name": "Elu", "kind": "enum"})
            path.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                MODULE.expected_symbols(additions=path)


if __name__ == "__main__":
    unittest.main()
