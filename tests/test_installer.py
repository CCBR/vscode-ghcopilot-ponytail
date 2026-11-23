import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "install_ponytail.sh"
SKILLS = ("ponytail", "ponytail-audit", "ponytail-debt", "ponytail-gain",
          "ponytail-help", "ponytail-review")


def git(*args, cwd):
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, text=True, capture_output=True
    ).stdout.strip()


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.source = self.root / "upstream"
        self.source.mkdir()
        git("init", "-q", cwd=self.source)
        git("config", "user.email", "test@example.invalid", cwd=self.source)
        git("config", "user.name", "Test", cwd=self.source)
        for name in SKILLS:
            path = self.source / "skills" / name
            path.mkdir(parents=True)
            (path / "SKILL.md").write_text(f"---\nname: {name}\n---\nversion one\n")
        git("add", ".", cwd=self.source)
        git("commit", "-qm", "first", cwd=self.source)
        git("tag", "v5.3.3", cwd=self.source)
        (self.source / "skills" / "ponytail" / "SKILL.md").write_text(
            "---\nname: ponytail\n---\nversion two\n"
        )
        git("add", ".", cwd=self.source)
        git("commit", "-qm", "second", cwd=self.source)
        git("tag", "v5.4.0", cwd=self.source)
        self.project = self.root / "project"
        self.project.mkdir()
        git("init", "-q", cwd=self.project)
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.home), CCBR_PONYTAIL_REPO_URL=str(self.source))
        self.install_root = self.home / ".claude"
        self.checkout = self.install_root / "repos" / "ponytail"
        self.skills = self.install_root / "skills"

    def run_installer(self, *args, ok=True, cwd=None):
        result = subprocess.run(
            ["bash", str(SCRIPT), *args], cwd=cwd or self.project,
            env=self.env, text=True, capture_output=True
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_install_all_skills_and_idempotent_status_verify(self):
        self.run_installer()
        for name in SKILLS:
            self.assertTrue((self.skills / name).is_symlink())
            self.assertTrue((self.skills / name / "SKILL.md").is_file())
        self.assertFalse((self.project / "AGENTS.md").exists())
        self.run_installer()
        self.assertIn("v5.3.3", self.run_installer("--status").stdout)
        self.run_installer("--verify")

    def test_upgrade_rollback_and_invalid_tag_preserve_checkout(self):
        self.run_installer()
        self.run_installer("--version", "v5.4.0")
        self.assertIn("version two", (self.skills / "ponytail" / "SKILL.md").read_text())
        self.run_installer("--version", "v5.3.3")
        self.run_installer("--version", "v999", ok=False)
        self.assertEqual(git("describe", "--tags", "--exact-match", cwd=self.checkout), "v5.3.3")

    def test_conflict_prevents_checkout_and_preserves_existing_file(self):
        self.skills.mkdir(parents=True)
        target = self.skills / "ponytail"
        target.write_text("mine")
        self.run_installer(ok=False)
        self.assertEqual(target.read_text(), "mine")
        self.assertFalse(self.checkout.exists())

    def test_modified_managed_link_is_never_replaced_or_deleted(self):
        self.run_installer()
        target = self.skills / "ponytail"
        target.unlink()
        target.symlink_to(self.root)
        self.run_installer("--version", "v5.4.0", ok=False)
        self.assertEqual(target.readlink(), self.root)
        self.assertEqual(git("describe", "--tags", "--exact-match", cwd=self.checkout), "v5.3.3")
        self.run_installer("--verify", ok=False)

    def test_dirty_and_wrong_origin_checkouts_are_rejected(self):
        self.run_installer()
        (self.checkout / "skills" / "ponytail" / "SKILL.md").write_text("local edits")
        self.run_installer("--version", "v5.4.0", ok=False)
        git("checkout", "--", "skills/ponytail/SKILL.md", cwd=self.checkout)
        git("remote", "set-url", "origin", str(self.root / "other"), cwd=self.checkout)
        self.run_installer(ok=False)
        self.run_installer("--verify", ok=False)

    def test_obsolete_managed_links_removed_but_unrelated_preserved(self):
        self.run_installer()
        extra = self.skills / "mine"
        extra.mkdir()
        git("rm", "-rq", "skills/ponytail-debt", cwd=self.source)
        git("commit", "-qm", "remove debt", cwd=self.source)
        git("tag", "v6.0.0", cwd=self.source)
        self.run_installer("--version", "v6.0.0")
        self.assertFalse((self.skills / "ponytail-debt").exists())
        self.assertTrue(extra.is_dir())

    def test_optional_policy_preserves_other_text_and_rejects_bad_markers(self):
        agents = self.project / "AGENTS.md"
        agents.write_text("# Existing guidance\n\nKeep this.\n")
        self.run_installer("--agents-policy")
        first = agents.read_text()
        self.assertIn("Keep this.", first)
        self.assertIn("CCBR-PONYTAIL-START", first)
        self.run_installer("--agents-policy")
        self.assertEqual(agents.read_text(), first)
        agents.write_text(first + "\n<!-- CCBR-PONYTAIL-START -->\n")
        before = agents.read_text()
        self.run_installer("--agents-policy", ok=False)
        self.assertEqual(agents.read_text(), before)

    def test_read_only_commands_and_version_listing(self):
        self.run_installer("--verify", ok=False)
        self.assertFalse(self.install_root.exists())
        versions = self.run_installer("--list-versions").stdout
        self.assertIn("v5.3.3", versions)
        self.assertIn("v5.4.0", versions)
        self.assertFalse(self.install_root.exists())

    def test_verify_detects_manifest_missing_an_installed_skill(self):
        self.run_installer()
        manifest = self.install_root / ".ccbr-ponytail-managed"
        manifest.write_text(manifest.read_text().replace("ponytail-review\n", ""))
        self.run_installer("--verify", ok=False)

    def test_policy_refresh_preserves_text_after_block_and_permissions(self):
        agents = self.project / "AGENTS.md"
        agents.write_text("# Existing guidance\n")
        agents.chmod(0o644)
        self.run_installer("--agents-policy")
        agents.write_text(agents.read_text() + "\n# Other guidance\n")
        self.run_installer("--agents-policy")
        self.assertTrue(agents.read_text().endswith("\n# Other guidance\n"))
        self.assertEqual(agents.stat().st_mode & 0o777, 0o644)


if __name__ == "__main__":
    unittest.main()
