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
        info={"CFBundleShortVersionString":"0.2.0","CFBundleVersion":"25","CFBundleIdentifier":"com.lixiaolai.mochi-macos","LSMinimumSystemVersion":"14.0"}
        release.validate_metadata(info,"0.2.0","25")
        previous=dict(info); previous["CFBundleIdentifier"]="com.xiaolai.mochi-macos"
        with self.assertRaises(ValueError): release.validate_metadata(previous,"0.2.0","25")
        for key in info:
            broken=dict(info); broken[key]="wrong"
            with self.assertRaises(ValueError): release.validate_metadata(broken,"0.2.0","25")

    def test_cask_requires_real_hash_and_explicit_tap_name(self):
        with self.assertRaises(ValueError): release.render_cask('sha256 "@SHA256@"',"bad")
        text=release.render_cask('cask "mochi" do\n  sha256 "@SHA256@"\nend',"a"*64)
        self.assertNotIn("@SHA256@",text)
        self.assertIn('cask "mochi"',text)

    def test_template_does_not_conflict_with_its_own_caskroom_token(self):
        template=(Path(__file__).parents[1]/"distribution/mochi.rb.in").read_text()
        self.assertIn('cask "mochi" do',template)
        self.assertNotIn('conflicts_with cask:',template)

    def test_helper_requires_architecture_runtime_identity_and_timestamp(self):
        signature="Authority=Developer ID Application: Example (ABC123)\nTimestamp=Oct 9, 2026\nTeamIdentifier=ABC123\nCodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+2 location=embedded\n"
        release.validate_binary_signature("arm64\n", signature)
        for architectures in ("x86_64", "arm64 x86_64", ""):
            with self.assertRaises(ValueError): release.validate_binary_signature(architectures, signature)
        for fragment in ("Authority=Developer ID Application: Example (ABC123)\n", "Timestamp=Oct 9, 2026\n", "TeamIdentifier=ABC123\n", "CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+2 location=embedded\n"):
            with self.assertRaises(ValueError): release.validate_binary_signature("arm64", signature.replace(fragment,""))
        with self.assertRaises(ValueError): release.validate_binary_signature("arm64", signature.replace("ABC123\n", "not set\n"))

    def test_binary_check_runs_strict_verification_and_checks_both_outputs(self):
        signature="Authority=Developer ID Application: Example (ABC123)\nTimestamp=Oct 9\nTeamIdentifier=ABC123\nCodeDirectory v=20500 flags=0x10000(runtime)\n"
        calls=[]
        def run(args, **kwargs):
            calls.append(args); self.assertTrue(kwargs["check"])
            return subprocess.CompletedProcess(args,0,"arm64" if args[0]=="lipo" else "",signature if "-d" in args else "")
        for path in ("app", "helper"):
            release.check_binary(path,run=run)
        self.assertEqual(calls,[["codesign","--verify","--strict","app"],["lipo","-archs","app"],["codesign","-d","--verbose=4","app"],["codesign","--verify","--strict","helper"],["lipo","-archs","helper"],["codesign","-d","--verbose=4","helper"]])
        def failing(args, **kwargs): raise subprocess.CalledProcessError(1,args)
        with self.assertRaises(subprocess.CalledProcessError): release.check_binary("bad",run=failing)

    def test_distribution_gate_rejects_probes_and_provider_symbols(self):
        release.validate_distribution_symbols("normal app", "normal helper")
        for probe in ("--tools-probe", "--smoke-test", "--tray-smoke-test", "--probe", "--import-environment", "AutomationSmokeClient", "SmokePlaybackPlayer"):
            with self.assertRaises(ValueError): release.validate_distribution_symbols(probe,"normal")
        for symbol in ("Credentials", "RealtimeService", "VoiceRenderer", "codexToken"):
            with self.assertRaises(ValueError): release.validate_distribution_symbols("normal",symbol)
        for symbol in ("AutomationSmokeClient", "SmokePlaybackPlayer", "toolsProbe", "smokeTray"):
            with self.assertRaises(ValueError): release.validate_distribution_symbols("normal","normal",symbol)
        calls=[]
        def run(args, **kwargs):
            calls.append(args); self.assertTrue(kwargs["check"])
            return subprocess.CompletedProcess(args,0,"normal","")
        release.check_distribution("app","helper",run=run)
        self.assertEqual(calls,[["strings","app"],["nm","app"],["nm","helper"]])

    def test_distribution_gate_rejects_retired_voice_providers(self):
        for retired in ("api.elevenlabs.io", "ElevenLabsVoices", "VoiceRenderer", "VoiceSetupModel", "ELEVENLABS_API_KEY", "OPENAI_API_KEY"):
            with self.assertRaises(ValueError): release.validate_distribution_symbols(retired,"normal","normal")
            with self.assertRaises(ValueError): release.validate_distribution_symbols("normal","normal",retired)
