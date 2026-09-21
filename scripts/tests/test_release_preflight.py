from __future__ import annotations

import importlib.util
import os
import pathlib
import subprocess
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("source_archive", ROOT / "scripts/create-source-archive.py")
assert SPEC and SPEC.loader
ARCHIVE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ARCHIVE)


class ReleasePreflightTests(unittest.TestCase):
    def test_tag_and_commit_have_identical_distribution_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
            def git(*args: str) -> str:
                return subprocess.check_output(["git", *args], cwd=root, env=env, text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "--quiet")
            git("config", "user.name", "Release Test")
            git("config", "user.email", "release-test@example.invalid")
            (root / "Package.swift").write_text("// immutable source fixture\n")
            git("add", "Package.swift")
            git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Fixture source")
            commit = git("rev-parse", "HEAD")
            git("-c", "tag.gpgsign=false", "tag", "-a", "0.2.0", "-m", "Separate annotated tag metadata")
            first, second = root / "head.zip", root / "tag.zip"
            head = ARCHIVE.create_archive(root, "HEAD", first)
            tag = ARCHIVE.create_archive(root, "0.2.0", second)
            self.assertEqual(head, tag)
            self.assertEqual(commit, tag["sourceCommit"])
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with zipfile.ZipFile(first) as archive:
                self.assertEqual(["elu-ios-source/", "elu-ios-source/Package.swift"], archive.namelist())
                self.assertEqual(commit, archive.comment.decode())

    def test_preflight_requires_native_evidence_and_frozen_v2_contract(self) -> None:
        text = (ROOT / "scripts/release-preflight.sh").read_text()
        tag = text.index('python3 scripts/verify-release-tag.py "$release_tag"')
        evidence = text.index('python3 scripts/validate-runtime-network-evidence.py "$network_trace"')
        build = text.index("run_logged simulator-tests")
        self.assertLess(tag, evidence)
        self.assertLess(evidence, build)
        self.assertLess(text.index("python3 Conformance/validate-v2-replay.py"), build)
        self.assertNotIn("if ", text[tag:evidence])
        self.assertIn('run_logged source-archive python3 scripts/create-source-archive.py', text)
        self.assertIn('--ref "$release_tag"', text)
        self.assertNotIn("git archive", text)
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("python3 scripts/create-source-archive.py", ci)
        self.assertNotIn("git archive", ci)


if __name__ == "__main__":
    unittest.main()
