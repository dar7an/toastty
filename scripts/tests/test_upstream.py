import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("upstream", Path(__file__).resolve().parents[1] / "upstream.py")
upstream = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upstream)


class UpstreamTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Toastty Tests")
        self.git("config", "user.email", "tests@example.invalid")
        self.write("build.zig.zon", '.{ .minimum_zig_version = "0.16.0" }')
        self.base = self.commit("src/terminal.zig", "original", "Initial engine")
        self.git("update-ref", "refs/remotes/origin/main", self.base)
        self.data = dict(repository="ghostty-org/ghostty", branch="main", commit=self.base, zig_version="0.16.0")
        self.write("upstream.json", json.dumps(self.data))

    def git(self, *args):
        return upstream.git(self.root, *args)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, name, text, message):
        self.write(name, text)
        self.git("add", ".")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def test_manifest_rejects_ambiguous_pins_and_toolchain_drift(self):
        self.assertEqual(upstream.manifest(self.root), self.data)
        for change in [dict(commit="main"), dict(repository="another/repository"),
                       dict(zig_version="master"), dict(zig_version="0.17.0")]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.write("upstream.json", json.dumps(self.data | change))
                upstream.manifest(self.root)

    def test_claimed_base_must_be_in_fork_history(self):
        candidate = self.commit("src/terminal.zig", "new upstream", "Upstream change")
        self.git("checkout", "-qb", "fork", self.base)
        self.commit("macos/UI.swift", "fork UI", "Toastty interface")
        upstream.check_history(self.root, self.data)
        with self.assertRaises(subprocess.CalledProcessError):
            upstream.check_history(self.root, self.data | dict(commit=candidate))

    def test_pr_and_new_branch_check_all_commits(self):
        self.commit("src/terminal.zig", "updated", "Engine change")
        self.commit("docs/readme.md", "docs", "Docs-only final commit")
        self.assertTrue(upstream.ci_scope(self.root, "pull_request", {"pull_request": {"base": {"sha": self.base}}}))
        self.assertTrue(upstream.ci_scope(self.root, "push", {"before": "0" * 40}))

    def test_push_scope_and_manual_override(self):
        previous = self.commit("src/terminal.zig", "updated", "Engine change")
        self.commit("macos/UI.swift", "UI only", "Interface change")
        self.assertFalse(upstream.ci_scope(self.root, "push", {"before": previous}))
        self.assertTrue(upstream.ci_scope(self.root, "workflow_dispatch", {}))
        with self.assertRaises(ValueError):
            upstream.ci_scope(self.root, "unknown", {})

    def test_ui_only_pr_and_new_branch_skip_engine_suites(self):
        previous = self.commit("upstream.json", json.dumps(self.data), "Record adopted engine")
        self.git("update-ref", "refs/remotes/origin/main", previous)
        self.commit("macos/UI.swift", "UI only", "Interface change")
        self.assertFalse(upstream.ci_scope(self.root, "pull_request", {"pull_request": {"base": {"sha": previous}}}))
        self.assertFalse(upstream.ci_scope(self.root, "push", {"before": "0" * 40}))

    def test_missing_comparison_base_runs_every_suite(self):
        self.assertTrue(upstream.ci_scope(self.root, "push", {"before": "a" * 40}))
        self.git("update-ref", "-d", "refs/remotes/origin/main")
        self.assertTrue(upstream.ci_scope(self.root, "push", {"before": "0" * 40}))

    def test_deletion_and_rename_out_of_engine_still_trigger_tests(self):
        self.git("mv", "src/terminal.zig", "terminal.txt")
        self.git("commit", "-qm", "Move engine source")
        self.assertTrue(upstream.ci_scope(self.root, "push", {"before": self.base}))

    def test_upgrade_infrastructure_triggers_engine_tests(self):
        for path in ["upstream.json", "scripts/test-engine.sh", ".github/workflows/ci.yml",
                     "pkg/dependency/build.zig.zon", "include/ghostty.h", "test/fixture.txt"]:
            with self.subTest(path=path):
                self.assertTrue(upstream.engine_changes({path}))
        self.assertFalse(upstream.engine_changes({"docs/usage.md", "macos/Sources/UI.swift"}))

    def test_report_uses_complete_counts_and_identifies_overlap(self):
        candidate = self.commit("src/terminal.zig", "upstream", "Upstream [link](https://example.invalid)")
        self.git("checkout", "-qb", "fork", self.base)
        self.commit("src/terminal.zig", "Toastty patch", "Fork engine change")
        report = upstream.render_report(self.root, self.data, candidate)
        self.assertIn("**1 commits**", report)
        self.assertIn("- src/terminal.zig", report)
        self.assertIn(candidate, report)
        self.assertIn(r"Upstream \[link\]\(https://example.invalid\)", report)
        self.assertNotIn("Not a forward update", report)
        # An older/divergent candidate must not be described as an upgrade.
        report = upstream.render_report(self.root, self.data | dict(commit=candidate), self.base)
        self.assertIn("Not a forward update", report)

    def test_report_marks_current_base_and_commit_sample(self):
        self.assertIn("already at the adopted base", upstream.render_report(self.root, self.data, self.base))
        for index in range(26):
            candidate = self.commit("src/terminal.zig", str(index), "Engine change " + str(index))
        report = upstream.render_report(self.root, self.data, candidate)
        self.assertIn("**26 commits**", report)
        self.assertIn("latest 25 of 26 commits", report)


if __name__ == "__main__":
    unittest.main()
