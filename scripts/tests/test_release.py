import importlib.util
import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("release_support", Path(__file__).parents[1] / "release_support.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

class ReleaseTests(unittest.TestCase):
    def runner(self, responses, calls):
        def run(args, **kwargs):
            calls.append(args)
            code, payload = responses.pop(0)
            data = plistlib.dumps(payload) if isinstance(payload, dict) else payload
            return subprocess.CompletedProcess(args, code, data, b"transport error" if code else b"")
        return run

    def test_poll_failure_never_resubmits_and_resume_keeps_id(self):
        with tempfile.TemporaryDirectory() as d:
            artifact = Path(d) / "app.zip"; artifact.write_bytes(b"artifact")
            calls = []
            run = self.runner([(0, {"id":"submission-1"}), (1,b""), (0,{"status":"Accepted"})], calls)
            self.assertEqual(release.notarize(artifact,"profile",run=run,sleep=lambda _:None),"submission-1")
            self.assertEqual(sum("submit" in c for c in calls),1)
            calls.clear()
            run = self.runner([(0,{"status":"Accepted"})],calls)
            release.notarize(artifact,"profile",run=run,sleep=lambda _:None)
            self.assertFalse(any("submit" in c for c in calls))

    def test_rejection_stops_polling_and_fetches_log(self):
        with tempfile.TemporaryDirectory() as d:
            artifact=Path(d)/"app.zip"; artifact.write_bytes(b"artifact")
            calls=[]
            run=self.runner([(0,{"id":"bad"}),(1,{"status":"Invalid"}),(0,b"rejected file")],calls)
            with self.assertRaisesRegex(RuntimeError,"Invalid"):
                release.notarize(artifact,"profile",run=run,sleep=lambda _:self.fail("must not retry rejection"))
            self.assertEqual(sum("wait" in c for c in calls),1)
            self.assertTrue(any("log" in c for c in calls))

    def test_missing_id_is_bounded_and_cannot_reach_polling(self):
        with tempfile.TemporaryDirectory() as d:
            artifact=Path(d)/"app.zip"; artifact.write_bytes(b"artifact")
            calls=[]
            run=self.runner([(1,b"")] * 3,calls)
            with self.assertRaisesRegex(RuntimeError,"submission ID"):
                release.notarize(artifact,"profile",run=run,sleep=lambda _:None)
            self.assertEqual(len(calls),3)

    def test_changed_artifact_does_not_reuse_old_submission(self):
        with tempfile.TemporaryDirectory() as d:
            artifact=Path(d)/"app.zip"; artifact.write_bytes(b"new")
            artifact.with_suffix(".zip.notary.json").write_text(json.dumps({"sha256":"old","id":"old"}))
            calls=[]
            release.notarize(artifact,"profile",run=self.runner([(0,{"id":"new"}),(0,{"status":"Accepted"})],calls),sleep=lambda _:None)
            self.assertTrue(any("submit" in c for c in calls))

    def test_metadata_rejects_wrong_version_build_and_identity(self):
        info={"CFBundleShortVersionString":"0.1.2","CFBundleVersion":"24","CFBundleIdentifier":"com.lixiaolai.mochi-macos","LSMinimumSystemVersion":"14.0"}
        release.validate_metadata(info,"0.1.2","24")
        previous=dict(info); previous["CFBundleIdentifier"]="com.xiaolai.mochi-macos"
        with self.assertRaises(ValueError): release.validate_metadata(previous,"0.1.2","24")
        for key in info:
            broken=dict(info); broken[key]="wrong"
            with self.assertRaises(ValueError): release.validate_metadata(broken,"0.1.2","24")

    def test_cask_requires_real_hash_and_explicit_tap_name(self):
        with self.assertRaises(ValueError): release.render_cask('sha256 "@SHA256@"',"bad")
        text=release.render_cask('cask "mochi" do\n  sha256 "@SHA256@"\nend',"a"*64)
        self.assertNotIn("@SHA256@",text)
        self.assertIn('cask "mochi"',text)

    def test_template_does_not_conflict_with_its_own_caskroom_token(self):
        template=(Path(__file__).parents[2]/"dev-docs/distribution/mochi.rb.in").read_text()
        self.assertIn('cask "mochi" do',template)
        self.assertNotIn('conflicts_with cask:',template)
