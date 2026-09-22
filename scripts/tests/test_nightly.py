import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("nightly", Path(__file__).resolve().parents[1] / "package-nightly.py")
nightly = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nightly)


class NightlyTests(unittest.TestCase):
    def package(self, **kwargs):
        return nightly.metadata({"CFBundleIdentifier": "com.dar7an.toastty.local"},
                                "18.1", "a" * 40, **kwargs)

    def test_production_identity_and_verification(self):
        info = self.package()
        self.assertEqual(info["CFBundleIdentifier"], "com.dar7an.toastty.nightly")
        self.assertEqual(info["CFBundleVersion"], "18.1")
        self.assertEqual(info["GhosttyCommit"], "a" * 40)
        self.assertEqual(info["SUFeedURL"], nightly.FEED)
        self.assertTrue(info["SURequireSignedFeed"])
        self.assertTrue(info["SUVerifyUpdateBeforeExtraction"])
        self.assertEqual(info["SUSignedFeedFailureExpirationInterval"], 0)
        self.assertNotIn("NSAppTransportSecurity", info)

    def test_local_test_identity_is_separate(self):
        info = self.package(test_feed="http://127.0.0.1:8765/appcast.xml")
        self.assertEqual(info["CFBundleIdentifier"], "com.dar7an.toastty.nightly.test")

    def test_rejects_remote_or_lookalike_test_feeds(self):
        for feed in ["http://example.com/feed", "http://127.0.0.1.example.com/feed"]:
            with self.subTest(feed=feed), self.assertRaises(ValueError):
                self.package(test_feed=feed)

    def test_cannot_package_pinned_build(self):
        with self.assertRaises(ValueError):
            nightly.metadata({"CFBundleIdentifier": "com.dar7an.toastty"}, "18.1", "a" * 40)

    def test_rejects_ambiguous_versions_and_commits(self):
        for build, commit in [("abc", "a" * 40), ("18.0", "a" * 40), ("18.1", "main")]:
            with self.subTest(build=build), self.assertRaises(ValueError):
                nightly.metadata({"CFBundleIdentifier": "com.dar7an.toastty.local"}, build, commit)

    def test_production_cannot_override_key(self):
        with self.assertRaises(ValueError):
            self.package(public_key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")


if __name__ == "__main__":
    unittest.main()
