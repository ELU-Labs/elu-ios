from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE_SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "verify-release-tag.py"


class VerifyReleaseTagTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="elu-ios-tag-test-")
        self.root = pathlib.Path(self.temp.name)
        self.gnupg_temp = tempfile.TemporaryDirectory(prefix="elu-ios-tag-gpg-test-")
        self.gnupg = pathlib.Path(self.gnupg_temp.name)
        self.gnupg.chmod(0o700)
        self.environment = os.environ.copy()
        self.environment["GNUPGHOME"] = str(self.gnupg)

        script = self.root / "scripts" / "verify-release-tag.py"
        script.parent.mkdir(parents=True)
        shutil.copy2(SOURCE_SCRIPT, script)
        version = self.root / "Sources" / "EluAnalytics" / "EluState.swift"
        version.parent.mkdir(parents=True)
        version.write_text(
            'final class EluCore {\n    static let sdkVersion = "1.2.3"\n}\n',
            encoding="utf-8",
        )
        (self.root / "tracked.txt").write_text("reviewed\n", encoding="utf-8")
        self.git("init", "-q")
        self.git("config", "user.email", "release-test@elu.dev")
        self.git("config", "user.name", "ELU Release Test")
        self.git("config", "gpg.format", "openpgp")
        self.git("config", "gpg.program", shutil.which("gpg") or "gpg")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def tearDown(self) -> None:
        self.temp.cleanup()
        self.gnupg_temp.cleanup()

    def git(self, *arguments: str) -> str:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            env=self.environment,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def create_signing_key(self) -> str:
        subprocess.run(
            [
                "gpg",
                "--batch",
                "--pinentry-mode",
                "loopback",
                "--passphrase",
                "",
                "--quick-generate-key",
                "ELU iOS Release Test <release-test@elu.dev>",
                "ed25519",
                "sign",
                "0",
            ],
            env=self.environment,
            check=True,
            capture_output=True,
            text=True,
        )
        listing = subprocess.run(
            ["gpg", "--batch", "--with-colons", "--list-secret-keys"],
            env=self.environment,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        fingerprint = next(
            line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:")
        )
        self.git("config", "user.signingkey", fingerprint)
        return fingerprint

    def signed_tag(self, message: str = "Release 1.2.3\n\nReviewed-by: SDK Owner <owner@elu.dev>") -> str:
        fingerprint = self.create_signing_key()
        self.git("tag", "-s", "1.2.3", "-m", message)
        return fingerprint

    def verify(self, tag: str, trusted: str | None = None) -> subprocess.CompletedProcess[str]:
        environment = self.environment.copy()
        environment.pop("ELU_TRUSTED_RELEASE_SIGNING_FINGERPRINTS", None)
        if trusted is not None:
            environment["ELU_TRUSTED_RELEASE_SIGNING_FINGERPRINTS"] = trusted
        return subprocess.run(
            [sys.executable, "scripts/verify-release-tag.py", tag],
            cwd=self.root,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_accepts_matching_reviewed_tag_signed_by_trusted_key(self) -> None:
        fingerprint = self.signed_tag()

        result = self.verify("1.2.3", trusted=f"{'0' * 40}, {fingerprint.lower()}")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(fingerprint, result.stdout)

    def test_rejects_unsigned_annotated_tag(self) -> None:
        self.git(
            "tag",
            "-a",
            "1.2.3",
            "-m",
            "Release 1.2.3\n\nReviewed-by: SDK Owner <owner@elu.dev>",
        )

        result = self.verify("1.2.3", trusted="0" * 40)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("valid GPG signature", result.stdout + result.stderr)

    def test_repository_gpg_program_cannot_forge_validsig(self) -> None:
        fake_fingerprint = "A" * 40
        fake_gpg = self.root / "fake-gpg"
        fake_gpg.write_text(
            "#!/bin/sh\n"
            f"echo '[GNUPG:] VALIDSIG {fake_fingerprint} 20260804 0 0 4 0 22 8 00 {fake_fingerprint}' >&2\n"
            "exit 0\n",
            encoding="utf-8",
        )
        fake_gpg.chmod(0o755)
        self.git("config", "gpg.program", str(fake_gpg))
        self.git(
            "tag",
            "-a",
            "1.2.3",
            "-m",
            "Release 1.2.3\n\nReviewed-by: SDK Owner <owner@elu.dev>",
        )

        result = self.verify("1.2.3", trusted=fake_fingerprint)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("valid GPG signature", result.stdout + result.stderr)

    def test_rejects_valid_signature_from_untrusted_key(self) -> None:
        self.signed_tag()

        result = self.verify("1.2.3", trusted="0" * 40)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("full signer fingerprint is not trusted", result.stdout + result.stderr)

    def test_rejects_missing_trusted_fingerprint_configuration(self) -> None:
        self.signed_tag()

        result = self.verify("1.2.3")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release signing trust fails closed", result.stdout + result.stderr)

    def test_rejects_short_trusted_key_id(self) -> None:
        self.git(
            "tag",
            "-a",
            "1.2.3",
            "-m",
            "Release 1.2.3\n\nReviewed-by: SDK Owner <owner@elu.dev>",
        )

        result = self.verify("1.2.3", trusted="DEADBEEF")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("full 40- or 64-hex fingerprints only", result.stdout + result.stderr)

    def test_rejects_missing_review_trailer(self) -> None:
        fingerprint = self.signed_tag(message="Release 1.2.3")

        result = self.verify("1.2.3", trusted=fingerprint)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must contain a Reviewed-by: trailer", result.stdout + result.stderr)

    def test_rejects_review_line_outside_the_trailer_block(self) -> None:
        self.git(
            "tag",
            "-a",
            "1.2.3",
            "-m",
            "Reviewed-by: SDK Owner <owner@elu.dev>\n\nRelease narrative, not a trailer.",
        )

        result = self.verify("1.2.3", trusted="0" * 40)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must contain a Reviewed-by: trailer", result.stdout + result.stderr)

    def test_rejects_wrong_version(self) -> None:
        self.git(
            "tag",
            "-a",
            "1.2.4",
            "-m",
            "Release 1.2.4\n\nReviewed-by: SDK Owner <owner@elu.dev>",
        )

        result = self.verify("1.2.4", trusted="0" * 40)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match EluCore.sdkVersion", result.stdout + result.stderr)

    def test_rejects_dirty_tracked_content(self) -> None:
        fingerprint = self.signed_tag()
        (self.root / "tracked.txt").write_text("changed\n", encoding="utf-8")

        result = self.verify("1.2.3", trusted=fingerprint)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("including untracked files", result.stdout + result.stderr)

    def test_rejects_untracked_content(self) -> None:
        fingerprint = self.signed_tag()
        (self.root / "untracked.txt").write_text("not reviewed\n", encoding="utf-8")

        result = self.verify("1.2.3", trusted=fingerprint)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("including untracked files", result.stdout + result.stderr)

    def test_rejects_tag_that_does_not_point_at_head(self) -> None:
        self.git(
            "tag",
            "-a",
            "1.2.3",
            "-m",
            "Release 1.2.3\n\nReviewed-by: SDK Owner <owner@elu.dev>",
        )
        (self.root / "tracked.txt").write_text("next commit\n", encoding="utf-8")
        self.git("add", "tracked.txt")
        self.git("commit", "-qm", "advance")

        result = self.verify("1.2.3", trusted="0" * 40)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not point at the checked-out commit", result.stdout + result.stderr)

    def test_rejects_ref_whose_signed_tag_name_differs(self) -> None:
        fingerprint = self.create_signing_key()
        self.git(
            "tag",
            "-s",
            "other-name",
            "-m",
            "Release 1.2.3\n\nReviewed-by: SDK Owner <owner@elu.dev>",
        )
        self.git("update-ref", "refs/tags/1.2.3", "refs/tags/other-name")

        result = self.verify("1.2.3", trusted=fingerprint)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signed name does not match", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
