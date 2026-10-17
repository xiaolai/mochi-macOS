#!/usr/bin/env python3
"""Small, testable release checks; credentials stay in notarytool's Keychain profile."""
import hashlib
import json
import plistlib
import re
import subprocess
import sys
import time
from pathlib import Path


SOURCES = Path(__file__).resolve().parents[1] / "Sources"
VERSION_PATTERN = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
BUILD_PATTERN = re.compile(r"[1-9][0-9]*")


def read_version(text):
    """Parses the repository VERSION file: exactly MOCHI_VERSION=x.y.z and MOCHI_BUILD=n."""
    values = {}
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        key, separator, value = line.partition("=")
        if not separator or key not in ("MOCHI_VERSION", "MOCHI_BUILD") or key in values:
            raise ValueError(f"VERSION line {number} must be MOCHI_VERSION=x.y.z or MOCHI_BUILD=n, once each")
        values[key] = value.strip()
    version, build = values.get("MOCHI_VERSION", ""), values.get("MOCHI_BUILD", "")
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError("VERSION needs MOCHI_VERSION=x.y.z")
    if not BUILD_PATTERN.fullmatch(build):
        raise ValueError("VERSION needs a positive integer MOCHI_BUILD")
    return version, build


def validate_metadata(info, version, build):
    expected = {"CFBundleShortVersionString":version, "CFBundleVersion":build,
                "CFBundleIdentifier":"com.lixiaolai.mochi-macos", "LSMinimumSystemVersion":"14.0"}
    if info.get("LSMultipleInstancesProhibited"):
        raise ValueError("Single-instance ownership must be per user, not across user sessions")
    if info.get("MochiSingleInstanceProtocol") is not True:
        raise ValueError("Missing single-instance protocol marker")
    if not str(build).isdigit() or int(build) < 1:
        raise ValueError("Build number must be a positive integer")
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"Unexpected {key}: {info.get(key)!r}; expected {value!r}")


def validate_binary_signature(architectures, signature):
    if architectures.strip() != "arm64":
        raise ValueError("Unexpected executable architecture")
    for pattern in (r"^Authority=Developer ID Application:", r"^Timestamp=.+", r"^TeamIdentifier=(?!not set).+", r"^CodeDirectory .*flags=.*runtime"):
        if not re.search(pattern, signature, re.MULTILINE):
            raise ValueError("Executable needs timestamped Developer ID signing with hardened runtime")


def check_binary(path, *, run=subprocess.run):
    run(["codesign", "--verify", "--strict", path], check=True, capture_output=True)
    architectures = run(["lipo", "-archs", path], check=True, capture_output=True, text=True).stdout
    signature = run(["codesign", "-d", "--verbose=4", path], check=True, capture_output=True, text=True).stderr
    validate_binary_signature(architectures, signature)


def validate_distribution_symbols(app_strings, helper_symbols, app_symbols=""):
    for probe in ("--tools-probe", "--smoke-test", "--tray-smoke-test", "--single-instance-smoke-test", "MOCHI_INSTANCE_EVENTS_DIR", "MOCHI_INSTANCE_TEST_ID", "--preview", "native-smoke", "mochi-instance-", "MOCHI_E2E_LIBRARY_ROOT", "mochi.e2e.command", "SingleInstanceE2E", "--probe", "--import-environment", "AutomationSmokeClient", "SmokePlaybackPlayer", "ComposerGeometryProbe", "mochi-composer-geometry-probe", "ClickProbe", "mochi-phrase-chip-probe", "--hands-free-smoke-test", "RecordedStreamFeeder"):
        if probe in app_strings:
            raise ValueError("Development probes cannot ship in the distribution app")
    for symbol in ("AutomationSmokeClient", "SmokePlaybackPlayer", "toolsProbe", "smokeTray", "smokeHandsFree", "smokeBargeIn"):
        if symbol in app_symbols:
            raise ValueError("Development probe symbols cannot ship in the distribution app")
    for retired in ("api.elevenlabs.io", "ELEVENLABS_API_KEY", "ElevenLabs"):
        if retired in app_strings or retired in app_symbols or retired in helper_symbols:
            raise ValueError("The retired ElevenLabs provider cannot ship")
    for symbol in ("Credentials", "RealtimeService", "VoiceRenderer", "codexToken"):
        if symbol in helper_symbols:
            raise ValueError("Provider and credential code cannot ship in the MCP helper")


def validate_sources(sources=SOURCES):
    """Mochi has no API-key path. The shared sign-in package names OPENAI_API_KEY in the binary, to remove it from
    Codex's environment and to refuse an API-key sign-in, so the gate is on Mochi's own sources, which are where a
    fallback would have to be written."""
    files = sorted(Path(sources).rglob("*.swift"))
    if not files:
        raise ValueError(f"No Swift sources under {sources}")
    for path in files:
        if "OPENAI_API_KEY" in path.read_text(encoding="utf-8"):
            raise ValueError(f"OpenAI API-key fallback cannot ship: {path}")


def validate_build_paths(strings_by_binary):
    """The resource bundle has to be found inside the app. SwiftPM's older resource accessor looked beside the
    executable and then fell back to the absolute .build path it was compiled in: the bundle the app ships in
    Contents/Resources is never found, so the app works on the Mac that built it and crashes everywhere else."""
    for name, text in strings_by_binary.items():
        for marker in ("/.build/", "could not load resource bundle"):
            if marker in text:
                raise ValueError(f"{name} looks up resources through the build folder ({marker!r}); it cannot ship")


def check_distribution(app, helper, *, run=subprocess.run, sources=SOURCES):
    app_strings = run(["strings", app], check=True, capture_output=True, text=True).stdout
    app_symbols = run(["nm", app], check=True, capture_output=True, text=True).stdout
    helper_symbols = run(["nm", helper], check=True, capture_output=True, text=True).stdout
    helper_strings = run(["strings", helper], check=True, capture_output=True, text=True).stdout
    validate_distribution_symbols(app_strings, helper_symbols, app_symbols)
    validate_build_paths({app: app_strings, helper: helper_strings})
    validate_sources(sources)


def release_commit(version, *, run=subprocess.run):
    """The commit being released. The build reads the working tree, so it has to be exactly HEAD: no changed and no
    untracked files, which the bundle could otherwise pick up. A v<version> tag, if one exists, has to name HEAD."""
    def git(*args, check=True):
        return run(["git", *args], capture_output=True, text=True, check=check)
    status = git("status", "--porcelain", "--untracked-files=all").stdout
    if status.strip():
        raise ValueError("Release only from a clean checkout; commit or remove:\n" + status.rstrip())
    head = git("rev-parse", "--verify", "HEAD^{commit}").stdout.strip()
    tag = git("rev-parse", "-q", "--verify", f"refs/tags/v{version}^{{commit}}", check=False)
    if tag.returncode == 0 and tag.stdout.strip() != head:
        raise ValueError(f"Tag v{version} names {tag.stdout.strip()[:12]}, not HEAD {head[:12]}")
    return head


def dmg_commit_record(dmg):
    return Path(str(dmg) + ".commit")


def record_dmg_commit(dmg, commit):
    """Records the commit a DMG was built from, beside it, so a resumed run can tell whether it still matches."""
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError(f"Not a commit: {commit!r}")
    dmg_commit_record(dmg).write_text(commit + "\n")


def check_dmg_commit(dmg, commit):
    record = dmg_commit_record(dmg)
    if not record.exists():
        raise ValueError(f"{Path(dmg).name} has no recorded commit; move it aside and rebuild")
    built = record.read_text().strip()
    if built != commit:
        raise ValueError(f"{Path(dmg).name} was built from {built[:12]}, not HEAD {commit[:12]}; move it aside and rebuild")


def render_cask(template, digest, version):
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("A real lowercase SHA-256 is required")
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError("A release version x.y.z is required")
    if "@SHA256@" not in template or "@VERSION@" not in template:
        raise ValueError("The cask template needs @SHA256@ and @VERSION@ placeholders")
    return template.replace("@SHA256@", digest).replace("@VERSION@", version)


def notarize(artifact, profile, *, run=subprocess.run, sleep=time.sleep, attempts=3):
    artifact = Path(artifact)
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    record = artifact.with_suffix(artifact.suffix + ".notary.json")
    submission = None
    if record.exists():
        saved = json.loads(record.read_text())
        if saved.get("sha256") == digest:
            submission = saved.get("id")

    def command(operation, *args):
        result = run(["xcrun","notarytool",operation,*args,"--keychain-profile",profile],capture_output=True)
        try:
            payload = plistlib.loads(result.stdout)
        except (ValueError, plistlib.InvalidFileException):
            payload = {}
        return result, payload

    def diagnosis(operation, attempt, result):
        """notarytool explains failures (profile, network, agreements) on stderr; keep the tail of it."""
        detail = (result.stderr or b"").decode(errors="replace").strip()[-2000:] or "no output"
        line = f"notarytool {operation} attempt {attempt + 1} failed (exit {result.returncode}): {detail}"
        print(line, file=sys.stderr, flush=True)
        return line

    last = ""
    if not submission:
        for attempt in range(attempts):
            result, payload = command("submit",str(artifact),"--output-format","plist")
            submission = payload.get("id")
            if submission:
                record.write_text(json.dumps({"sha256":digest,"id":submission}) + "\n")
                break
            last = diagnosis("submit", attempt, result)
            if attempt + 1 < attempts:
                sleep(5 * (attempt + 1))
        if not submission:
            raise RuntimeError(f"Notarization did not return a submission ID. Last error: {last}")
    print(f"Notary submission: {submission}",flush=True)
    status = "no verdict"
    for attempt in range(attempts):
        result, payload = command("wait",submission,"--timeout","60s","--output-format","plist")
        status = payload.get("status", "no verdict")
        if "status" not in payload:
            last = diagnosis("wait", attempt, result)
        if status == "Accepted":
            return submission
        if status in ("Invalid","Rejected"):
            result, _ = command("log",submission)
            artifact.with_suffix(artifact.suffix + ".rejection.log").write_bytes(result.stdout + result.stderr)
            raise RuntimeError(f"Notarization {status}; see artifact rejection log")
        if attempt + 1 < attempts:
            sleep(5 * (attempt + 1))
    raise RuntimeError(f"Notarization polling ended with {status}; rerun to resume {submission}. Last error: {last or 'none'}")


if __name__ == "__main__":
    try:
        if sys.argv[1] == "notarize":
            notarize(sys.argv[2],sys.argv[3])
        elif sys.argv[1] == "distribution":
            check_distribution(sys.argv[2],sys.argv[3])
        elif sys.argv[1] == "binary":
            check_binary(sys.argv[2])
        elif sys.argv[1] == "metadata":
            with open(sys.argv[2],"rb") as file:
                validate_metadata(plistlib.load(file),sys.argv[3],sys.argv[4])
        elif sys.argv[1] == "cask":
            version, _ = read_version(Path(sys.argv[5]).read_text())
            Path(sys.argv[4]).write_text(render_cask(Path(sys.argv[2]).read_text(),sys.argv[3],version))
        elif sys.argv[1] == "source":
            print(release_commit(sys.argv[2]))
        elif sys.argv[1] == "dmg-commit" and sys.argv[2] == "record":
            record_dmg_commit(sys.argv[3],sys.argv[4])
        elif sys.argv[1] == "dmg-commit" and sys.argv[2] == "check":
            check_dmg_commit(sys.argv[3],sys.argv[4])
        elif sys.argv[1] == "version":
            print(*read_version(Path(sys.argv[2]).read_text()))
        else:
            raise ValueError("Unknown operation")
    except (ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
