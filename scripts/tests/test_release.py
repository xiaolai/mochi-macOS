import importlib.util
import json
import plistlib
import re
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
            with self.assertRaisesRegex(RuntimeError,"submission ID.*exit 1.*transport error"):
                release.notarize(artifact,"profile",run=run,sleep=lambda _:None)
            self.assertEqual(len(calls),3)

    def test_polling_failure_reports_notarytool_stderr(self):
        with tempfile.TemporaryDirectory() as d:
            artifact=Path(d)/"app.zip"; artifact.write_bytes(b"artifact")
            calls=[]
            run=self.runner([(0,{"id":"s"})] + [(1,b"")] * 3,calls)
            with self.assertRaisesRegex(RuntimeError,"rerun to resume s.*transport error"):
                release.notarize(artifact,"profile",run=run,sleep=lambda _:None)

    def test_version_file_is_the_single_validated_source(self):
        self.assertEqual(release.read_version("MOCHI_VERSION=0.4.0\nMOCHI_BUILD=28\n"),("0.4.0","28"))
        for text in ("MOCHI_VERSION=0.4\nMOCHI_BUILD=28","MOCHI_VERSION=0.4.0\nMOCHI_BUILD=0","MOCHI_VERSION=0.4.0","MOCHI_VERSION=0.4.0\nMOCHI_BUILD=28\nOTHER=1",
                     "MOCHI_VERSION=0.4.0\nMOCHI_BUILD=28\nMOCHI_BUILD=29","MOCHI_VERSION=0.4.0; rm -rf /\nMOCHI_BUILD=28"):
            with self.assertRaises(ValueError): release.read_version(text)
        repository=(Path(__file__).parents[2]/"VERSION").read_text()
        version, build = release.read_version(repository)
        self.assertRegex(version,r"^[0-9]+\.[0-9]+\.[0-9]+$"); self.assertGreater(int(build),0)

    def test_changed_artifact_does_not_reuse_old_submission(self):
        with tempfile.TemporaryDirectory() as d:
            artifact=Path(d)/"app.zip"; artifact.write_bytes(b"new")
            artifact.with_suffix(".zip.notary.json").write_text(json.dumps({"sha256":"old","id":"old"}))
            calls=[]
            release.notarize(artifact,"profile",run=self.runner([(0,{"id":"new"}),(0,{"status":"Accepted"})],calls),sleep=lambda _:None)
            self.assertTrue(any("submit" in c for c in calls))

    def test_metadata_rejects_wrong_version_build_and_identity(self):
        info={"CFBundleShortVersionString":"0.3.0","CFBundleVersion":"27","CFBundleIdentifier":"com.lixiaolai.mochi-macos","LSMinimumSystemVersion":"14.0","MochiSingleInstanceProtocol":True}
        release.validate_metadata(info,"0.3.0","27")
        previous=dict(info); previous["CFBundleIdentifier"]="com.xiaolai.mochi-macos"
        with self.assertRaises(ValueError): release.validate_metadata(previous,"0.3.0","27")
        cross_user=dict(info); cross_user["LSMultipleInstancesProhibited"]=True
        with self.assertRaises(ValueError): release.validate_metadata(cross_user,"0.3.0","27")
        for key in info:
            broken=dict(info); broken[key]="wrong"
            with self.assertRaises(ValueError): release.validate_metadata(broken,"0.3.0","27")

    def test_cask_requires_real_hash_version_and_explicit_tap_name(self):
        template='cask "mochi" do\n  version "@VERSION@"\n  sha256 "@SHA256@"\nend'
        with self.assertRaises(ValueError): release.render_cask(template,"bad","0.4.0")
        with self.assertRaises(ValueError): release.render_cask(template,"a"*64,"latest")
        with self.assertRaises(ValueError): release.render_cask('sha256 "@SHA256@"',"a"*64,"0.4.0")
        text=release.render_cask(template,"a"*64,"0.4.0")
        self.assertNotIn("@SHA256@",text); self.assertNotIn("@VERSION@",text)
        self.assertIn('version "0.4.0"',text); self.assertIn('cask "mochi"',text)

    def test_template_does_not_conflict_with_its_own_caskroom_token(self):
        template=(Path(__file__).parents[1]/"distribution/mochi.rb.in").read_text()
        self.assertIn('cask "mochi" do',template)
        self.assertIn('version "@VERSION@"',template)
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

    def test_distribution_gate_rejects_every_development_flag_the_app_names(self):
        # DevelopmentLaunch.Flag names each development flag once; a new flag must not ship unnoticed.
        source = (Path(__file__).parents[2] / "Sources/MochiApp/MochiApp.swift").read_text()
        flags = re.findall(r'^\s*case \w+ = "(--[a-z-]+)"$', source, re.MULTILINE)
        self.assertIn("--preview", flags)
        self.assertIn("--barge-in", flags)
        for flag in flags:
            with self.assertRaises(ValueError, msg=flag): release.validate_distribution_symbols(flag, "normal")

    def test_distribution_gate_rejects_probes_and_provider_symbols(self):
        release.validate_distribution_symbols("normal app", "normal helper")
        for probe in ("--tools-probe", "--smoke-test", "--tray-smoke-test", "--single-instance-smoke-test", "MOCHI_INSTANCE_EVENTS_DIR", "MOCHI_INSTANCE_TEST_ID", "--preview", "native-smoke", "mochi-instance-", "MOCHI_E2E_LIBRARY_ROOT", "mochi.e2e.command", "SingleInstanceE2E", "--probe", "--import-environment", "AutomationSmokeClient", "SmokePlaybackPlayer", "ComposerGeometryProbe", "mochi-composer-geometry-probe", "ClickProbe", "mochi-phrase-chip-probe", "--hands-free-smoke-test", "--barge-in", "RecordedStreamFeeder"):
            with self.assertRaises(ValueError): release.validate_distribution_symbols(probe,"normal")
        for symbol in ("Credentials", "RealtimeService", "VoiceRenderer", "codexToken"):
            with self.assertRaises(ValueError): release.validate_distribution_symbols("normal",symbol)
        for symbol in ("AutomationSmokeClient", "SmokePlaybackPlayer", "toolsProbe", "smokeTray", "smokeHandsFree", "smokeBargeIn"):
            with self.assertRaises(ValueError): release.validate_distribution_symbols("normal","normal",symbol)
        calls=[]
        def run(args, **kwargs):
            calls.append(args); self.assertTrue(kwargs["check"])
            return subprocess.CompletedProcess(args,0,"normal","")
        release.check_distribution("app","helper",run=run)
        self.assertEqual(calls,[["strings","app"],["nm","app"],["nm","helper"]])

    def test_distribution_gate_rejects_retired_providers(self):
        for retired in ("api.elevenlabs.io", "ELEVENLABS_API_KEY", "ElevenLabsSpeech", "ElevenLabsCredential"):
            with self.assertRaises(ValueError): release.validate_distribution_symbols(retired,"normal","normal")
            with self.assertRaises(ValueError): release.validate_distribution_symbols("normal","normal",retired)
            with self.assertRaises(ValueError): release.validate_distribution_symbols("normal",retired,"normal")

    def test_the_api_key_gate_is_on_mochis_own_sources(self):
        # The shared sign-in package ships the name to strip it from Codex's environment and to refuse an API-key
        # sign-in; only Mochi's sources could add a fallback.
        release.validate_distribution_symbols("OPENAI_API_KEY","normal","OPENAI_API_KEY")
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder)/"Fallback.swift"
            source.write_text('let key = environment["OPENAI_API_KEY"]\n')
            with self.assertRaises(ValueError): release.validate_sources(folder)
            source.write_text('let key = "codex"\n')
            release.validate_sources(folder)
        with tempfile.TemporaryDirectory() as empty:
            with self.assertRaises(ValueError): release.validate_sources(empty)
        release.validate_sources()
