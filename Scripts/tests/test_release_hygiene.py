"""Static release-hygiene audit for the protected release path (issue #7).

These tests are pure-file checks that run in every CI lane (including the
Linux helper-test phase wired into Scripts/ci.sh). They prove *repository
posture only*: they cannot prove a signed archive, a successful upload, or
Apple processing — those remain separate native/account gates.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
RELEASE_SH = REPO_ROOT / "Scripts" / "release.sh"
RELEASE_YML = REPO_ROOT / ".github" / "workflows" / "release.yml"

SECRET_NAMES = ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "ASC_TEAM_ID")


def _read(path: Path) -> str:
    assert path.is_file(), f"expected release artifact missing: {path}"
    return path.read_text(encoding="utf-8")


class ReleaseScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = _read(RELEASE_SH)

    def test_no_removed_altool_usage(self):
        # altool was removed in Xcode 26; the pinned toolchain (26.0.1)
        # cannot provide it. Any invocation makes the upload gate fail the
        # moment an owner enables it. Scan code lines only (prose comments
        # about the removal are fine and encouraged).
        code = "\n".join(
            line for line in self.script.splitlines()
            if not line.lstrip().startswith("#")
        )
        self.assertNotIn("altool", code)

    def test_upload_uses_xcodebuild_upload_destination(self):
        self.assertIn("'destination': 'upload'", self.script)
        self.assertIn("UPLOAD_TO_TESTFLIGHT", self.script)

    def test_api_key_temp_dir_is_private_and_cleaned(self):
        # Key must land in a mktemp directory guarded by an EXIT trap.
        self.assertIn("mktemp -d", self.script)
        self.assertRegex(self.script, r"trap '[^']*rm -rf \"\$key_dir\"' EXIT")
        # Private umask so the temp key file is never group/world readable.
        self.assertIn("umask 077", self.script)

    def test_p8_secret_is_unset_after_key_file_write(self):
        # After writing the key file the raw PEM must leave the environment
        # so child toolchains (xcodebuild) cannot inherit it.
        write = self.script.index('$key_file"')
        unset = self.script.index("unset ASC_KEY_P8")
        self.assertGreater(unset, write)
        self.assertLess(unset, self.script.index("xcodebuild -project"))

    def test_never_prints_secret_values(self):
        # echo of a secret expansion is forbidden anywhere.
        for name in SECRET_NAMES:
            for pattern in (rf"echo[^\n]*\$\{{{name}}}", rf"echo[^\n]*\${name}\b"):
                self.assertIsNone(re.search(pattern, self.script),
                                  f"release.sh appears to print ${name}")
        # The one sanctioned printf must write the private key directly to
        # the temp key file (a file sink, not a terminal/log sink).
        printfs = [m.group(0) for m in re.finditer(r"printf[^\n]*", self.script)
                   if "ASC_KEY_P8" in m.group(0)]
        self.assertEqual(len(printfs), 1)
        self.assertRegex(printfs[0], r'> "\$key_file"$')
        # No xtrace: `set -x` would echo every secret-bearing command.
        self.assertNotIn("set -x", self.script)


class ReleaseWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.yml = _read(RELEASE_YML)

    def test_manual_dispatch_only(self):
        # The release workflow must never fire on push/pull_request: secrets
        # must stay unreachable from PRs and forks.
        self.assertNotIn("pull_request", self.yml)
        self.assertIsNotNone(
            re.search(r"^on:\s*\n\s*workflow_dispatch:", self.yml, re.M))

    def test_no_write_permissions_declared(self):
        top = self.yml.split("jobs:", 1)[0]
        self.assertNotIn("write", top)
        self.assertNotIn("contents: write", self.yml)

    def test_signing_job_uses_protected_environment(self):
        self.assertIn("environment: testflight", self.yml)

    def test_secrets_reach_only_the_environment_job(self):
        # Every `secrets.` reference must appear after the environment
        # declaration in the archive job (the verify-gate never sees them).
        jobs = self.yml.split("jobs:", 1)[1]
        env_job = jobs.split("environment: testflight", 1)
        self.assertEqual(len(env_job), 2, "no job declares the testflight environment")
        before_env, after_env = env_job
        self.assertNotIn("secrets.", before_env,
                         "secrets referenced before the protected environment job")
        for name in SECRET_NAMES:
            self.assertIn(f"secrets.{name}", after_env)

    def test_upload_input_defaults_to_false(self):
        self.assertRegex(
            self.yml,
            r"upload_to_testflight:[\s\S]*?default:\s*false",
        )

    def test_provenance_artifact_retained(self):
        self.assertIn("provenance.json", self.yml)


if __name__ == "__main__":
    unittest.main()
